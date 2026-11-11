$ErrorActionPreference = "Stop"
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot "SqlEditor.Ui.Tests.ps1"), [ref]$null, [ref]$parseErrors)
if ($parseErrors) { throw ($parseErrors.Message -join "; ") }
foreach ($name in @("Wait-SqlState", "Wait-SqlControl", "Select-SqlPage", "Select-SqlTools", "Assert-SqlResult", "Stop-SqlApp", "Test-SqlActionBounds")) {
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if (-not $definition) { throw "Missing SQL UI helper $name." }
    Invoke-Expression $definition.Extent.Text
}

function Assert-Equal($Actual, $Expected, [string] $Message) {
    if ($Actual -cne $Expected) { throw "$Message Expected '$Expected', got '$Actual'." }
}

function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected failure matching '$Pattern'."
}

$editor = [Windows.Rect]::new(24, 100, 600, 136)
$run = [Windows.Rect]::new(24, 250, 60, 32)
$cancel = [Windows.Rect]::new(92, 250, 70, 32)
$summary = [Windows.Rect]::new(174, 256, 450, 20)
Assert-Equal (Test-SqlActionBounds $editor $run $cancel $summary) $true "Completed status should share the action row"
$wrapped = [Windows.Rect]::new(174, 242, 450, 48)
Assert-Equal (Test-SqlActionBounds $editor $run $cancel $wrapped) $true "Wrapped errors should remain centered beside actions"
$below = [Windows.Rect]::new(24, 294, 600, 20)
Assert-Equal (Test-SqlActionBounds $editor $run $cancel $below) $false "The old separate status row must fail"
$overlap = [Windows.Rect]::new(150, 256, 474, 20)
Assert-Equal (Test-SqlActionBounds $editor $run $cancel $overlap) $false "Status must not overlap Cancel"
$short = [Windows.Rect]::new(174, 256, 200, 20)
Assert-Equal (Test-SqlActionBounds $editor $run $cancel $short) $false "Status must reach the right content edge"
$progress = [Windows.Rect]::new(170, 254, 24, 24)
Assert-Equal (Test-SqlActionBounds $editor $run $cancel $summary $progress) $false "Running status must leave room for progress"
Assert-Equal (Test-SqlActionBounds $editor $run $cancel ([Windows.Rect]::new(206, 256, 418, 20)) $progress) $true "Running status should fit beside progress"

$script:state = @{
    Mode = "Delayed"; Reads = @{}; Selections = 0; Invocations = 0; PaneOpen = $true; Toggles = 0
}
$selection = [pscustomobject]@{}
$selection | Add-Member ScriptMethod Select { $script:state.Selections++ }
$navigation = [pscustomobject]@{}
$navigation | Add-Member ScriptMethod GetCurrentPattern { param($Pattern) return $selection }
function Find-SqlControl([string] $Id, [switch] $Optional) {
    if ($Id -in @("ToolsNavItem", "OverviewNavItem")) {
        if (-not $script:state.PaneOpen) { return $null }
        return $navigation
    }
    if ($Id -eq "TogglePaneButton") {
        return [pscustomobject]@{ Current = [pscustomobject]@{ IsOffscreen = $false; IsEnabled = $true } }
    }
    if ($Id -notin @("SqlEditorCard", "SqlText", "CancelButton", "QueryStatus", "RunButton")) {
        throw "Unexpected synthetic SQL control '$Id'."
    }
    $script:state.Reads[$Id]++
    $reads = $script:state.Reads[$Id]
    if ($script:state.Mode -eq "Error") { throw "Synthetic automation lookup failure." }
    if ($script:state.Mode -eq "Missing" -or ($script:state.Mode -eq "Delayed" -and $reads -le 2)) {
        if (-not $Optional) { throw "Missing SQL editor control '$Id'." }
        return $null
    }
    return [pscustomobject]@{ Current = [pscustomobject]@{
        IsOffscreen = $script:state.Mode -eq "Hidden" -or ($script:state.Mode -eq "Delayed" -and $reads -lt 4)
        IsEnabled = $script:state.Mode -ne "Disabled" -and ($script:state.Mode -ne "Delayed" -or $reads -ge 5)
        Name = "1 row, 3 columns; Complete."
    } }
}
function Invoke-SqlControl([string] $Id) {
    if ($Id -eq "TogglePaneButton") {
        $script:state.PaneOpen = $true
        $navigation.Current.IsOffscreen = $false
        $script:state.Toggles++
        return
    }
    Assert-Equal $Id "SqlEditorCard" "Only the SQL card should be invoked"
    Assert-Equal $script:state.Reads[$Id] 5 "Navigation must wait for a visible, enabled card"
    $script:state.Invocations++
}

$navigation | Add-Member NoteProperty Current ([pscustomobject]@{ IsOffscreen = $false; IsEnabled = $true })
Select-SqlTools
Assert-Equal $script:state.Selections 1 "Tools should be selected once"
Assert-Equal $script:state.Invocations 1 "The SQL editor should be opened once"
Assert-Equal $script:state.Reads.SqlText 5 "An absent, then hidden/disabled editor must be retried"
Wait-SqlControl CancelButton -Enabled
Assert-Equal $script:state.Reads.CancelButton 5 "Cancellation must wait for an enabled peer"
Assert-SqlResult "1 row, 3 columns;*Complete."
Assert-Equal $script:state.Reads.RunButton 5 "Result completion must wait for Run to be enabled"

$script:state.PaneOpen = $false
Select-SqlPage OverviewNavItem
Assert-Equal $script:state.Toggles 1 "Narrow navigation must open the collapsed pane"
Assert-Equal $script:state.Selections 2 "Navigation must still select Overview"
Select-SqlPage ToolsNavItem
Assert-Equal $script:state.Toggles 1 "Visible navigation must not close an open pane"
Assert-Equal $script:state.Selections 3 "Tools must be selected after returning from Overview"
$navigation.Current.IsOffscreen = $true
Select-SqlPage OverviewNavItem
Assert-Equal $script:state.Toggles 2 "Offscreen navigation must also open the pane"
Assert-Equal $script:state.Selections 4 "An offscreen item must become visible before selection"

foreach ($mode in @("Missing", "Hidden", "Disabled")) {
    $script:state.Mode = $mode
    $script:state.Reads.Clear()
    Assert-Throws { Wait-SqlControl SqlText -Visible -Enabled -Seconds 0 } "*Timed out waiting for SQL control 'SqlText' readiness."
    Assert-Equal $script:state.Reads.SqlText 1 "$mode controls must fail at the deadline, not pass or retry indefinitely"
}
$script:state.Mode = "Ready"
$script:state.Reads.Clear()
Wait-SqlControl SqlText -Visible -Enabled
Assert-Equal $script:state.Reads.SqlText 1 "Ready controls must not need a retry"
$script:state.Mode = "Hidden"
Wait-SqlControl CancelButton -Enabled
$script:state.Mode = "Error"
Assert-Throws { Wait-SqlControl SqlText -Visible -Enabled } "*Synthetic automation lookup failure."

$script:cleanupEvents = [Collections.Generic.List[string]]::new()
$script:process = [pscustomobject]@{ HasExited = $false; Id = 123; ExitReady = $true }
$script:process | Add-Member ScriptMethod WaitForExit {
    param($Milliseconds)
    Assert-Equal $Milliseconds 5000 "Cleanup must have a bounded process-exit wait"
    $script:cleanupEvents.Add("wait")
    return $this.ExitReady
}
$script:process | Add-Member ScriptMethod Dispose { $script:cleanupEvents.Add("dispose") }
function Stop-Process {
    param($Id, [switch] $Force)
    Assert-Equal $Id 123 "Cleanup must terminate only the fixture app"
    Assert-Equal $Force.IsPresent $true "Failed fixture apps must be terminated"
    $script:cleanupEvents.Add("stop")
}
Stop-SqlApp
Assert-Equal ($script:cleanupEvents -join ",") "stop,wait,dispose" "Cleanup must wait for file handles before disposal"
$script:cleanupEvents.Clear()
$script:process.HasExited = $true
Stop-SqlApp
Assert-Equal ($script:cleanupEvents -join ",") "wait,dispose" "Already-closed apps must not be killed"
$script:cleanupEvents.Clear()
$script:process.ExitReady = $false
Assert-Throws { Stop-SqlApp } "*SQL editor app did not exit during fixture cleanup."
Assert-Equal ($script:cleanupEvents -join ",") "wait,dispose" "An exit timeout must fail explicitly and dispose the process"

$fixtureTry = $ast.EndBlock.Statements |
    Where-Object { $_ -is [System.Management.Automation.Language.TryStatementAst] } |
    Select-Object -Last 1
$failureHarness = "try { throw 'Original SQL assertion failure.' } " +
    $fixtureTry.CatchClauses[0].Extent.Text + " finally " + $fixtureTry.Finally.Extent.Text
$testFailure = $null
$highContrast = $null
$phase = $null
$previous = @{}
$fixtureDirectory = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-sql-script-no-fixture"
$script:cleanupWarnings = [Collections.Generic.List[string]]::new()
function Write-Warning([string] $Message) { $script:cleanupWarnings.Add($Message) }
Assert-Throws {
    Invoke-Expression $failureHarness
} "*Original SQL assertion failure."
Assert-Equal $script:cleanupWarnings.Count 1 "A secondary cleanup error must be reported without replacing the assertion"
Assert-Equal ($script:cleanupWarnings[0] -like "*SQL editor app did not exit*") $true "Cleanup warnings must retain the cause"
$testFailure = $null
Assert-Throws {
    Invoke-Expression ("try {} finally " + $fixtureTry.Finally.Extent.Text)
} "*SQL editor app did not exit during fixture cleanup."
$script:process = $null
Stop-SqlApp
Write-Host "SQL editor polling, narrow navigation and process cleanup regressions passed without desktop automation."
