[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Repository,
    [Parameter(Mandatory)][string] $Destination,
    [Parameter(Mandatory)][ValidateSet('baseline', 'flaui')][string] $Backend,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string] $ConsentToken,
    [string] $SourceRevision = '6fd07fd04ffc7a3e919eaa7916f2487f2b59a870'
)

$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $Destination) { throw 'Prepared sources must use a new directory.' }
& git -C $Repository diff --quiet $SourceRevision -- src tests .github/scripts
if ($LASTEXITCODE -ne 0) { throw 'Production source/harness differs from the frozen revision.' }
$paths = @(& git -C $Repository ls-files -- src tests .github/scripts)
if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate frozen inputs.' }
$manifest = [Collections.Generic.List[object]]::new()
$mapped = @('AutomationElement', 'TreeWalker', 'InvokePattern', 'ValuePattern', 'TogglePattern',
    'ExpandCollapsePattern', 'SelectionItemPattern', 'SelectionPattern', 'ScrollPattern',
    'ScrollItemPattern', 'RangeValuePattern', 'TextPattern')

foreach ($gitPath in $paths) {
    $relative = $gitPath.Replace('/', '\')
    $inputPath = Join-Path $Repository $relative
    $outputPath = Join-Path $Destination $relative
    $null = New-Item -ItemType Directory -Path (Split-Path $outputPath) -Force
    if ([IO.Path]::GetExtension($relative) -ne '.ps1') {
        Copy-Item -LiteralPath $inputPath -Destination $outputPath
        continue
    }
    $text = [IO.File]::ReadAllText($inputPath)
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref] $tokens, [ref] $errors)
    if ($errors.Count) { throw "Cannot parse frozen script '$relative': $errors" }
    $edits = [Collections.Generic.List[object]]::new()
    foreach ($node in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.BinaryExpressionAst] }, $true)) {
        $left = $node.Left.Extent.Text
        $right = $node.Right.Extent.Text.Trim('"', "'")
        $isHost = ($left -eq '$env:GITHUB_ACTIONS' -and $right -eq 'true') -or
            ($left -eq '$env:RUNNER_ENVIRONMENT' -and $right -eq 'github-hosted')
        if (-not $isHost) { continue }
        if ($node.Operator.ToString() -notin @('Ieq', 'Ine')) { throw "Unmapped host guard in '$relative'." }
        $permission = "`$env:FINGVIBE_UI_COMPARISON_DESKTOP -eq '$ConsentToken'"
        $replacement = if ($node.Operator.ToString() -eq 'Ieq') {
            "($($node.Extent.Text) -or ($permission))"
        } else { "($($node.Extent.Text) -and -not ($permission))" }
        $edits.Add(@{ start = $node.Extent.StartOffset; end = $node.Extent.EndOffset
            replacement = $replacement; kind = 'explicit-desktop-consent' })
    }
    if ($relative -eq '.github\scripts\UiReviewScreenshot.ps1') {
        $initialize = $ast.Find({ param($n)
            $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Initialize-UiReviewWindow'
        }, $true)
        if (-not $initialize) { throw 'Window initialization helper was not found.' }
        $offset = $initialize.Body.ParamBlock.Extent.EndOffset
        $edits.Add(@{ start = $offset; end = $offset
            replacement = "`n    Enter-ComparisonWindow -WindowHandle `$WindowHandle`n"
            kind = 'shared-local-activation' })
    }
    if ($Backend -eq 'flaui') {
        foreach ($node in $ast.FindAll({ param($n)
            $n -is [Management.Automation.Language.TypeExpressionAst] -or
            $n -is [Management.Automation.Language.TypeConstraintAst]
        }, $true)) {
            $name = $node.TypeName.FullName
            if ($name -notmatch '^(?:System\.)?Windows\.Automation\.([^+]+)(.*)$') { continue }
            if ($Matches[1] -notin $mapped) { continue }
            $replacement = '[FingVibe.UiComparison.' + $Matches[1] + $Matches[2] + ']'
            $edits.Add(@{ start = $node.Extent.StartOffset; end = $node.Extent.EndOffset
                replacement = $replacement; kind = 'flaui-type' })
        }
        if ($relative -eq '.github\scripts\Invoke-UiReview.ps1') {
            $request = $ast.Find({ param($n)
                $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-WebDriverRequest'
            }, $true)
            if (-not $request) { throw 'Capture request function was not found.' }
            $edits.Add(@{ start = $request.Extent.StartOffset; end = $request.Extent.EndOffset
                replacement = @'
function Invoke-WebDriverRequest {
    param([Parameter(Mandatory)][string] $Method, [Parameter(Mandatory)][string] $Endpoint, [hashtable] $Body)
    $json = if ($Body) { $Body | ConvertTo-Json -Depth 10 -Compress } else { '{}' }
    [FingVibe.UiComparison.CaptureDriver]::Request($Method, $Endpoint, $json) | ConvertFrom-Json
}
'@
                kind = 'flaui-capture-transport' })
            $driver = @($ast.FindAll({ param($n)
                $n -is [Management.Automation.Language.AssignmentStatementAst] -and
                $n.Left.Extent.Text -eq '$driverProcess' -and $n.Right.Extent.Text -match 'Start-Process'
            }, $true))
            if ($driver.Count -ne 1) { throw 'Expected one capture-driver process launch.' }
            $edits.Add(@{ start = $driver[0].Extent.StartOffset; end = $driver[0].Extent.EndOffset
                replacement = '$driverProcess = $null'; kind = 'flaui-capture-transport' })
        }
    }
    $ordered = @($edits | Sort-Object start -Descending)
    $boundary = $text.Length
    foreach ($edit in $ordered) {
        if ($edit.end -gt $boundary) { throw "Overlapping source transformations in '$relative'." }
        $text = $text.Remove($edit.start, $edit.end - $edit.start).Insert($edit.start, $edit.replacement)
        $boundary = $edit.start
    }
    $prepared = [Management.Automation.Language.Parser]::ParseInput($text, [ref] $tokens, [ref] $errors)
    if ($errors.Count) { throw "Prepared script '$relative' does not parse: $errors" }
    $originalThrows = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.ThrowStatementAst] }, $true) |
        ForEach-Object { $_.Extent.Text })
    $preparedThrows = @($prepared.FindAll({ param($n) $n -is [Management.Automation.Language.ThrowStatementAst] }, $true) |
        ForEach-Object { $_.Extent.Text })
    if (($originalThrows -join "`n") -cne ($preparedThrows -join "`n")) {
        throw "Explicit failure statements changed in '$relative'."
    }
    [IO.File]::WriteAllText($outputPath, $text, [Text.UTF8Encoding]::new($true))
    $manifest.Add([ordered]@{
        path = $relative
        originalSha256 = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash
        preparedSha256 = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash
        originalThrowCount = $originalThrows.Count
        edits = @($ordered | ForEach-Object { @{ start = $_.start; end = $_.end; kind = $_.kind } })
    })
}
$manifest | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $Destination 'transforms.json') -Encoding utf8
