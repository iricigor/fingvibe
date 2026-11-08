param([string] $SourceDirectory = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = "Stop"
$probeErrors = $null
$probeTestAst = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot "HistoryScroll.Investigation.ps1"), [ref]$null, [ref]$probeErrors)
if ($probeErrors) { throw ($probeErrors.Message -join "; ") }
foreach ($probeTestName in @("Get-HistoryProbeRectangle", "Test-HistoryProbeIntersection",
    "Get-HistoryInvestigationSource", "Add-HistoryCommandInstrumentation", "Invoke-HistoryObservedCommand")) {
    $probeTestFunction = $probeTestAst.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $probeTestName
    }, $true)
    if (-not $probeTestFunction) { throw "Missing diagnostic helper $probeTestName." }
    Invoke-Expression $probeTestFunction.Extent.Text
}
Add-Type -AssemblyName WindowsBase
$probeTestEmpty = [System.Windows.Rect]::Empty
if (-not (Get-HistoryProbeRectangle $probeTestEmpty).empty) { throw "Native empty rectangles must stay explicit." }
$probeTestWindow = [System.Windows.Rect]::new(100, 100, 500, 400)
$probeTestInside = [System.Windows.Rect]::new(110, 110, 40, 20)
$probeTestOutside = [System.Windows.Rect]::new(110, -1000, 40, 20)
$probeTestClipped = [System.Windows.Rect]::new(110, 495, 40, 20)
if (-not (Test-HistoryProbeIntersection $probeTestInside $probeTestWindow) -or
    -not (Test-HistoryProbeIntersection $probeTestClipped $probeTestWindow) -or
    (Test-HistoryProbeIntersection $probeTestOutside $probeTestWindow) -or
    (Test-HistoryProbeIntersection $probeTestEmpty $probeTestWindow)) {
    throw "Physical intersection must distinguish empty/offscreen/clipped bounds."
}
$probeTestParts = Get-HistoryInvestigationSource (
    Join-Path $SourceDirectory "tests\DeviceScanHistory.Ui.Tests.ps1")
if ($probeTestParts.fixture.Count -lt 10 -or
    $probeTestParts.sectionLoop -notmatch 'Assert-HistorySummary' -or
    $probeTestParts.sectionLoop -notmatch 'Assert-HistoryRows' -or
    $probeTestParts.themeLoop -notmatch '640' -or
    ($probeTestParts.pagedFixture.Extent.Text -join "`n") -notmatch '0\.\.204') {
    throw "Diagnostic must reuse the real fixture/reproduction sequences, not invent replacements."
}
$probeTestSection = $probeTestParts.functions | Where-Object { $_.Name -eq "Show-HistorySectionCore" }
if (-not $probeTestSection) { throw "Missing pinned section helper." }
$probeTestInstrumented = Add-HistoryCommandInstrumentation $probeTestSection
$probeTestInstrumentErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseInput(
    $probeTestInstrumented, [ref]$null, [ref]$probeTestInstrumentErrors)
if ($probeTestInstrumentErrors) { throw ($probeTestInstrumentErrors.Message -join "; ") }
if ($probeTestInstrumented -notmatch "Invoke-HistoryObservedCommand" -or
    $probeTestInstrumented -notmatch 'SetScrollPercent') { throw "Command instrumentation is missing." }
& {
    $script:probeQuiet = $true
    $probeTestEvents = [System.Collections.Generic.List[object]]::new()
    $probeTestPolls = [System.Collections.Generic.List[int]]::new()
    $probeTestActions = @{ count = 0 }
    function Write-HistoryProbeEvent([string] $Event, $Data) {
        $probeTestEvents.Add(@{ event = $Event; data = $Data })
    }
    function Write-HistoryProbeSnapshot([string] $Phase, [string] $Command) {
        $probeTestEvents.Add(@{ event = $Phase })
        return @{ list = @{ scroll = @{ percent = 0 } }; details = @{ scroll = @{ percent = 0 } }
            visibleLabels = @("unchanged-row"); expander = @{ status = "missing" } }
    }
    function Start-Sleep([int] $Milliseconds) { $probeTestPolls.Add($Milliseconds) }
    Invoke-HistoryObservedCommand fixture { $probeTestActions.count++ }
    if ($probeTestActions.count -ne 1 -or $probeTestPolls.Count -ne 8 -or
        @($probeTestPolls | Where-Object { $_ -ne 250 }).Count -ne 0 -or
        ($probeTestEvents.event -join "|") -ne "command|before|immediate|command-duration|poll|poll|poll|poll|poll|poll|poll|poll|observation") {
        throw "Controlled observation must issue exactly one command and eight bounded polls in order."
    }
    if ($probeTestEvents[-1].data.visibleLabelsChanged) { throw "Ineffective movement must stay explicit." }
    try {
        Invoke-HistoryObservedCommand failure { throw "fixture command failed" }
        throw "Command failure was swallowed."
    }
    catch {
        if ($_.Exception.Message -ne "fixture command failed") { throw }
        if ($probeTestEvents[-1].event -ne "command-error") { throw "Missing explicit command failure event." }
    }
}
& {
    $probeTestCalls = [System.Collections.Generic.List[object]]::new()
    $probeTestPattern = [pscustomobject]@{}
    $probeTestPattern | Add-Member ScriptMethod SetScrollPercent {
        param($Horizontal, $Vertical)
        $probeTestCalls.Add(@($Horizontal, $Vertical))
    }
    function Invoke-HistoryObservedCommand([string] $CommandText, [scriptblock] $CommandAction,
        [object[]] $CommandArguments, $CommandOwner) {
        if (($CommandArguments -join "|") -ne "-1|32" -or $CommandOwner -ne $probeTestPattern) {
            throw "Instrumentation lost the resolved arguments or owner."
        }
        & $CommandAction
    }
    $probeTestFunctionAst = [System.Management.Automation.Language.Parser]::ParseInput(
        'function Invoke-TestCommand { $target = 32; $probeTestPattern.SetScrollPercent(-1, $target) }',
        [ref]$null, [ref]$null).Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true)
    Invoke-Expression (Add-HistoryCommandInstrumentation $probeTestFunctionAst)
    Invoke-TestCommand
    if ($probeTestCalls.Count -ne 1 -or ($probeTestCalls[0] -join "|") -ne "-1|32") {
        throw "Instrumentation must preserve exactly one original method invocation."
    }
}
$probeTestSource = Get-Content -LiteralPath (Join-Path $PSScriptRoot "HistoryScroll.Investigation.ps1") -Raw
if ($probeTestSource -notmatch 'GITHUB_ACTIONS -ne "true"' -or
    $probeTestSource -notmatch 'RUNNER_OS -ne "Windows"') { throw "Working-desktop guard is missing." }
$probeTestWorkflow = Get-Content -LiteralPath (Join-Path $PSScriptRoot "..\.github\workflows\history-investigation.yml") -Raw
if ($probeTestWorkflow -notmatch "ebd4f07d731d5f4df45d1949f4c3b79fb1ebb9e2" -or
    $probeTestWorkflow -notmatch "always\(\) && steps.publish.outcome" -or
    $probeTestWorkflow -notmatch "(?s)Preserve investigation evidence\s+if: always\(\)") {
    throw "Immutable source, independent list execution, and failure artifact retention are required."
}
Write-Host "History diagnostic source extraction, command instrumentation, native rectangle and isolation checks passed."
