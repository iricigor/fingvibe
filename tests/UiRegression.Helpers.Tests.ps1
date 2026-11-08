$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UiRegression\Helpers.ps1')

function Assert-Regression([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-RegressionFailure([scriptblock] $Action, [string] $Pattern) {
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected failure matching '$Pattern'."
}

$state = @{ Attempts = 0 }
$result = Wait-UiRegressionState -Description 'current result' -PollMilliseconds 1 -Condition {
    $state.Attempts++
    if ($state.Attempts -eq 2) { return 'ready' }
}
Assert-Regression ($result -eq 'ready' -and $state.Attempts -eq 2) 'Wait must return the current successful result.'
foreach ($condition in @({ $false }, { $null }, {})) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Assert-RegressionFailure { Wait-UiRegressionState -Condition $condition -Description 'bounded failure' -TimeoutMilliseconds 20 -PollMilliseconds 5 } '*20 ms*bounded failure*'
    Assert-Regression ($clock.ElapsedMilliseconds -ge 20 -and $clock.ElapsedMilliseconds -lt 2000) 'Wait did not respect its deadline.'
}
Assert-RegressionFailure { Wait-UiRegressionState -Description 'unexpected error' -Condition { throw 'unexpected condition error' } } 'unexpected condition error'

Add-Type -TypeDefinition @'
namespace System.Windows.Automation {
    public sealed class ElementNotAvailableException : System.Exception {}
}
'@
$rectangle = [pscustomobject]@{ IsEmpty = $false; Width = 100; Height = 30 }
$element = [pscustomobject]@{ Current = [pscustomobject]@{ IsOffscreen = $false; BoundingRectangle = $rectangle } }
$state = @{ Owners = 0; Lookups = 0 }
$found = Find-UiRegressionElement -Description 'reacquired owner' -Condition 'match' -Container {
    $state.Owners++
    [pscustomobject]@{ Generation = $state.Owners }
} -Find {
    param($Owner, $Match)
    $state.Lookups++
    Assert-Regression ($Owner.Generation -eq $state.Lookups -and $Match -eq 'match') 'Lookup did not use a fresh owner and condition.'
    if ($state.Lookups -eq 1) { throw [System.Windows.Automation.ElementNotAvailableException]::new() }
    return $element
}
Assert-Regression ($found -eq $element -and $state.Owners -eq 2) 'Stale elements must be reacquired.'
$found = Find-UiRegressionElement -Description 'wrapped stale owner' -Condition 'match' -Optional -Container {
    throw [InvalidOperationException]::new('UI Automation wrapper', [System.Windows.Automation.ElementNotAvailableException]::new())
} -Find { throw 'Lookup must not run with an unavailable owner.' }
Assert-Regression ($null -eq $found) 'Native exceptions wrapped by PowerShell must still invalidate an optional owner.'
foreach ($invalid in @('offscreen', 'empty', 'zeroWidth', 'zeroHeight', 'absent')) {
    $element.Current.IsOffscreen = $invalid -eq 'offscreen'
    $rectangle.IsEmpty = $invalid -eq 'empty'
    $rectangle.Width = if ($invalid -eq 'zeroWidth') { 0 } else { 100 }
    $rectangle.Height = if ($invalid -eq 'zeroHeight') { 0 } else { 30 }
    $state.Lookups = 0
    $found = Find-UiRegressionElement -Description $invalid -Condition 'match' -Optional -Container { 'owner' } -Find {
        param($Owner, $Match)
        $state.Lookups++
        if ($invalid -ne 'absent') { return $element }
    }
    Assert-Regression ($null -eq $found -and $state.Lookups -eq 1) "Optional $invalid lookup must inspect current state once."
}
Assert-RegressionFailure { Find-UiRegressionElement -Description 'failed lookup' -Condition 'match' -Container { 'owner' } -Find { throw 'unexpected lookup error' } } 'unexpected lookup error'
$found = Find-UiRegressionElement -Description 'missing owner' -Condition 'match' -Optional -Container { $null } -Find { throw 'Lookup must not run without an owner.' }
Assert-Regression ($null -eq $found) 'Missing owner must not produce a control.'

$app = [pscustomobject]@{ Id = 123; HasExited = $false; ExitCode = 9; MainWindowHandle = [IntPtr]::Zero; Refreshes = 0; Closed = 0; Waits = 0; Forced = 0; Mode = 'normal' }
$app | Add-Member ScriptMethod Refresh {
    $this.Refreshes++
    if ($this.Refreshes -eq 2) { $this.MainWindowHandle = [IntPtr]::new(456) }
}
$app | Add-Member ScriptMethod CloseMainWindow { $this.Closed++; return $true }
$app | Add-Member ScriptMethod WaitForExit {
    param($Timeout)
    $this.Waits++
    return $this.Mode -eq 'normal' -or ($this.Mode -eq 'forced' -and $this.Waits -gt 1)
}
$handle = Wait-UiRegressionWindow -Process $app -TimeoutMilliseconds 1000
Assert-Regression ($handle -eq [IntPtr]::new(456) -and $app.Refreshes -eq 2) 'Window must wait for the live handle.'
$app.MainWindowHandle = [IntPtr]::Zero
Assert-RegressionFailure { Wait-UiRegressionWindow -Process $app -TimeoutMilliseconds 20 } '*20 ms*app window*'
$app.HasExited = $true
Assert-RegressionFailure { Wait-UiRegressionWindow -Process $app } '*exited with code 9*'
Stop-UiRegressionApp -Process $app
Stop-UiRegressionApp -Process $null
Assert-Regression ($app.Closed -eq 0) 'Exited/null process must not be closed again.'
$app.HasExited = $false
$terminate = { param($Process) $Process.Forced++ }
Stop-UiRegressionApp -Process $app -Terminate $terminate
Assert-Regression ($app.Closed -eq 1 -and $app.Forced -eq 0) 'Normal close must not force termination.'
foreach ($mode in @('forced', 'stuck')) {
    $app.Mode = $mode
    $app.Waits = 0
    $app.Forced = 0
    $pattern = if ($mode -eq 'forced') { '*did not close normally*forced cleanup*' } else { '*did not terminate*' }
    Assert-RegressionFailure { Stop-UiRegressionApp -Process $app -Terminate $terminate } $pattern
    Assert-Regression ($app.Forced -eq 1 -and $app.Waits -eq 2) 'Forced cleanup must target the supplied process and verify exit.'
}
$app.Waits = 0
Assert-RegressionFailure { Stop-UiRegressionApp -Process $app -Terminate { throw 'termination denied' } } 'termination denied'

$directory = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-foundation-$([Guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $directory
$names = @('FINGVIBE_FOUNDATION_TEST_PRESENT', 'FINGVIBE_FOUNDATION_TEST_ABSENT', 'GITHUB_STEP_SUMMARY')
$original = Save-UiRegressionEnvironment -Names $names
$fixtureDirectories = @()
try {
    $fixtureDirectories = @(New-UiRegressionFixtureDirectory -Suite foundation-test; New-UiRegressionFixtureDirectory -Suite foundation-test)
    Assert-Regression ($fixtureDirectories[0] -ne $fixtureDirectories[1]) 'Independent invocations must have different fixtures.'
    foreach ($fixtureDirectory in $fixtureDirectories) {
        Assert-Regression ((Test-Path -LiteralPath $fixtureDirectory -PathType Container) -and
            [IO.Path]::GetDirectoryName($fixtureDirectory) -eq [IO.Path]::GetTempPath().TrimEnd('\')) 'Fixtures must be newly created temporary directories.'
    }
    [Environment]::SetEnvironmentVariable($names[0], 'before')
    if (Test-Path -LiteralPath "Env:\$($names[1])") { Remove-Item -LiteralPath "Env:\$($names[1])" }
    $env:GITHUB_STEP_SUMMARY = Join-Path $directory 'summary.md'
    $saved = Save-UiRegressionEnvironment -Names $names
    Assert-RegressionFailure {
        try { $env:FINGVIBE_FOUNDATION_TEST_PRESENT = 'changed'; $env:FINGVIBE_FOUNDATION_TEST_ABSENT = 'created'; throw 'scenario failure' }
        finally { Restore-UiRegressionEnvironment -Saved $saved }
    } 'scenario failure'
    Assert-Regression ($env:FINGVIBE_FOUNDATION_TEST_PRESENT -eq 'before' -and $null -eq $env:FINGVIBE_FOUNDATION_TEST_ABSENT) 'Environment must restore values and absence on failure.'
    & {
        $state = @{ Fail = $false; Captures = 0 }
        function Save-UiReviewWindowScreenshot {
            param($WindowHandle, $Path)
            $state.Captures++
            if ($state.Fail) { throw 'capture failure' }
        }
        Save-UiRegressionScreenshot -WindowHandle ([IntPtr]::new(1)) -Path (Join-Path $directory 'success.png')
        $state.Fail = $true
        Assert-RegressionFailure { Save-UiRegressionScreenshot -WindowHandle ([IntPtr]::new(1)) -Path (Join-Path $directory 'failure.png') } 'capture failure'
        $records = @(Get-Content -LiteralPath (Join-Path $directory 'phases.jsonl') | ConvertFrom-Json)
        Assert-Regression ($state.Captures -eq 2 -and $records.Count -eq 2 -and $records[0].succeeded -and -not $records[1].succeeded) 'Capture timing must preserve failures, not report success.'
        Assert-Regression ($records[0].elapsedMilliseconds -ge 0 -and $records[0].phase -eq 'capture/success.png') 'Capture phase must include measured timing and name.'
    }
}
finally {
    Restore-UiRegressionEnvironment -Saved $original
    Remove-Item -LiteralPath $directory -Recurse -Force
    foreach ($fixtureDirectory in $fixtureDirectories) { Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force }
}

function Get-RegressionSignature([string] $Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Text -replace "`r", '').Trim())
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hasher.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
}

$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'UiRegression\coverage.json') -Raw | ConvertFrom-Json
foreach ($suite in $manifest.suites) {
    $entry = Join-Path $PSScriptRoot $suite.entry
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($entry, [ref]$null, [ref]$errors)
    Assert-Regression (-not $errors) "Entry $entry must parse."
    $loop = $ast.Find({ param($node) $node -is [Management.Automation.Language.ForEachStatementAst] -and $node.Variable.VariablePath.UserPath -eq 'regressionModule' }, $true)
    $order = @($loop.Condition.FindAll({ param($node) $node -is [Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object Value)
    Assert-Regression (($order -join ',') -eq ($suite.scenarioOrder -join ',')) "$($suite.name) scenario order changed."
    $execution = $loop.Body.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.InvocationOperator -eq 'Dot' }, $true)
    Assert-Regression ($null -ne $execution) 'Modules must execute at entry script scope, preserving inter-scenario state.'
    $loadedHelpers = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.StringConstantExpressionAst] -and $node.Value -match '\.Helpers\.ps1$'
    }, $true) | ForEach-Object { [IO.Path]::GetFileName($_.Value) })
    $requiredHelpers = @($suite.files | Where-Object kind -eq 'helpers' | ForEach-Object file)
    Assert-Regression (($loadedHelpers -join ',') -eq ($requiredHelpers -join ',')) 'Every mapped helper must be loaded exactly once in the original dependency order.'
    foreach ($module in $suite.files) {
        $path = Join-Path $PSScriptRoot "UiRegression\$($module.file)"
        $errors = $null
        $moduleAst = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
        Assert-Regression (-not $errors) "Module $path must parse."
        if (-not $module.refactored) {
            Assert-Regression ((Get-RegressionSignature $moduleAst.Extent.Text) -eq $module.baselineSha256) "Unchanged coverage in $path differs from the baseline."
        }
        $functions = @($moduleAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true))
        Assert-Regression (($functions.Name -join ',') -eq ($module.functions.name -join ',')) "A mapped function was lost or duplicated in $path."
        foreach ($definition in $module.functions) {
            $actual = @($functions | Where-Object Name -eq $definition.name)[0]
            if (-not $definition.refactored) {
                Assert-Regression ((Get-RegressionSignature $actual.Extent.Text) -eq $definition.baselineSha256) "Unchanged function $($definition.name) differs from baseline."
            }
            if ($definition.name -in @('Test-DeviceRefresh', 'Save-SidebarAppearance', 'Save-DeviceCapture')) {
                $assertions = @($actual.Body.FindAll({ param($node) $node -is [Management.Automation.Language.ThrowStatementAst] }, $true) |
                    ForEach-Object { Get-RegressionSignature $_.Extent.Text })
                foreach ($assertion in $definition.assertions) {
                    Assert-Regression ($assertion -in $assertions) "Behavioral failure coverage in $($definition.name) was lost."
                }
            }
        }
        $captures = @($moduleAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
                $node.GetCommandName() -in @('Save-DeviceCapture', 'Save-SidebarAppearance', 'Save-ScheduledScanFailure')
        }, $true) | ForEach-Object { Get-RegressionSignature $_.Extent.Text })
        Assert-Regression (($captures -join ',') -eq ($module.captures -join ',')) "Capture coverage/order changed in $path."
        $fixtureAssignments = @($moduleAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$results'
        }, $true) | ForEach-Object { Get-RegressionSignature $_.Extent.Text })
        Assert-Regression (($fixtureAssignments -join ',') -eq ($module.fixtureAssignments -join ',')) "Synthetic fixture data changed in $path."
    }
    $fixtureRoot = New-UiRegressionFixtureDirectory -Suite foundation-test
    try {
        $null = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'UiRegression')
        foreach ($name in $suite.scenarioOrder) {
            $script = @"
`$events.Add('$name')
if ('$name' -eq 'Setup') { `$sharedSelection = `$invocation }
elseif (`$sharedSelection -ne `$invocation) { throw 'Scenario state was lost across scopes.' }
if (`$failAt -eq '$name') { throw 'Synthetic module failure: $name' }
"@
            $script | Set-Content -LiteralPath (Join-Path $fixtureRoot "UiRegression\$($suite.name).$name.Scenario.ps1")
        }
        $loopSource = $loop.Extent.Text.Replace('$PSScriptRoot', '$fixtureRoot')
        $ScreenshotDirectory = $fixtureRoot
        $events = [Collections.Generic.List[string]]::new()
        $invocation = [Guid]::NewGuid()
        $failAt = $null
        Invoke-Expression $loopSource
        Assert-Regression (($events -join ',') -eq ($suite.scenarioOrder -join ',')) 'Original orchestration must execute every scenario exactly once with shared state.'
        $events = [Collections.Generic.List[string]]::new()
        $invocation = [Guid]::NewGuid()
        $failAt = $suite.scenarioOrder[1]
        Assert-RegressionFailure { Invoke-Expression $loopSource } "Synthetic module failure: $failAt"
        Assert-Regression ($events.Count -eq 2) 'A failed scenario must stop later scenarios rather than succeed.'
        $record = Get-Content -LiteralPath (Join-Path $fixtureRoot 'phases.jsonl') | Select-Object -Last 1 | ConvertFrom-Json
        Assert-Regression (-not $record.succeeded -and $record.phase -eq "$($suite.name)/$failAt") 'Original orchestration must retain the failed phase.'
    }
    finally { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}
Write-Host 'UI regression helper, cleanup, timing, and orchestration checks passed.'
