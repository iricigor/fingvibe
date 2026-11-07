$ErrorActionPreference = "Stop"
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot "SqlEditor.Ui.Tests.ps1"), [ref]$null, [ref]$parseErrors)
if ($parseErrors) { throw ($parseErrors.Message -join "; ") }
foreach ($name in @("Wait-SqlState", "Wait-SqlControl", "Select-SqlTools", "Assert-SqlResult")) {
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

$script:state = @{
    Mode = "Delayed"; Reads = @{}; Selections = 0; Invocations = 0
}
$selection = [pscustomobject]@{}
$selection | Add-Member ScriptMethod Select { $script:state.Selections++ }
$navigation = [pscustomobject]@{}
$navigation | Add-Member ScriptMethod GetCurrentPattern { param($Pattern) return $selection }
function Find-SqlControl([string] $Id, [switch] $Optional) {
    if ($Id -eq "ToolsNavItem") { return $navigation }
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
    Assert-Equal $Id "SqlEditorCard" "Only the SQL card should be invoked"
    Assert-Equal $script:state.Reads[$Id] 5 "Navigation must wait for a visible, enabled card"
    $script:state.Invocations++
}

Select-SqlTools
Assert-Equal $script:state.Selections 1 "Tools should be selected once"
Assert-Equal $script:state.Invocations 1 "The SQL editor should be opened once"
Assert-Equal $script:state.Reads.SqlText 5 "An absent, then hidden/disabled editor must be retried"
Wait-SqlControl CancelButton -Enabled
Assert-Equal $script:state.Reads.CancelButton 5 "Cancellation must wait for an enabled peer"
Assert-SqlResult "1 row, 3 columns;*Complete."
Assert-Equal $script:state.Reads.RunButton 5 "Result completion must wait for Run to be enabled"

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
Write-Host "SQL editor polling regressions passed without desktop automation."
