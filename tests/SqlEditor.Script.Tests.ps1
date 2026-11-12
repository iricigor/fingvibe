$ErrorActionPreference = "Stop"
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $PSScriptRoot "SqlEditor.Ui.Tests.ps1"), [ref]$null, [ref]$parseErrors)
if ($parseErrors) { throw ($parseErrors.Message -join "; ") }
foreach ($name in @(
        "Wait-SqlState", "Wait-SqlControl", "Select-SqlPage", "Select-SqlTools", "Assert-SqlResult", "Stop-SqlApp",
        "Test-SqlActionBounds", "Show-SqlSchemaPicker", "Send-SqlPickerKeys", "Select-SqlSchemaEndpoint",
        "Wait-SqlKeyboardOutcome", "Find-SqlSettingsItem", "Select-SqlSettings",
        "Test-SqlResultWidth", "Format-SqlBounds", "Assert-SqlResultWidth", "Assert-SqlActionLayout")) {
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

& {
    $layout = @{ Positioned = $false; Positions = 0; Invalid = $false }
    function Find-SqlControl([string] $Id, [switch] $Optional) {
        if ($Id -eq "QueryProgress") { return $null }
        $bounds = switch ($Id) {
            SqlText { $editor }
            RunButton { $run }
            CancelButton { $cancel }
            QueryStatus { if ($layout.Invalid) { $below } else { $summary } }
            SqlPageScroll { [Windows.Rect]::new(0, 0, 640, 800) }
            default { throw "Unexpected layout control '$Id'." }
        }
        [pscustomobject]@{ Id = $Id; Current = [pscustomobject]@{
            BoundingRectangle = if ($layout.Positioned) { $bounds } else { [Windows.Rect]::Empty }
            IsOffscreen = -not $layout.Positioned
        } }
    }
    function Show-UiRegressionScrollTargets {
        param($GetViewport, $GetTargets, $GetWindow, $Description)
        Assert-Equal (& $GetViewport).Id SqlPageScroll "Action positioning must use the SQL viewport"
        Assert-Equal ((& $GetTargets).Id -join ",") "SqlText,RunButton,CancelButton,QueryStatus" "Position all measured action controls together"
        $layout.Positioned = $true
        $layout.Positions++
    }
    function Wait-SqlState([scriptblock] $Predicate, [string] $Description) {
        if (-not (& $Predicate)) { throw "Timed out waiting for $Description." }
    }
    Assert-SqlActionLayout
    Assert-Equal $layout.Positions 1 "Action geometry must first position the complete editor/action group"
    $layout.Invalid = $true
    Assert-Throws { Assert-SqlActionLayout } "*SQL action layout failed:*Last geometry:*QueryStatus*"
}

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

& {
    $ui = @{
        Events = [Collections.Generic.List[string]]::new(); Expanded = $false; LookupsAfterExpand = 0; LayoutLookups = 3
        Pickers = @{}; Scroll = [pscustomobject]@{ Tag = "SqlPageScroll" }; ExpansionPattern = $null; Expander = $null
        Toggle = [pscustomobject]@{ Current = [pscustomobject]@{ IsOffscreen = $false; IsEnabled = $true } }
        ModePage = $null; ShowsAfterSelect = $true; SettingsItem = $null; SettingsPolls = 0; ReadyAfter = 1
        GoneAfter = [int]::MaxValue; Selected = 0; SelectedAtPoll = -1
    }
    foreach ($pickerId in @("SchemaPicker", "ExamplePicker", "TablePicker")) {
        $picker = [pscustomobject]@{ Id = $pickerId; Current = [pscustomobject]@{ IsOffscreen = $false; IsEnabled = $true } }
        $picker | Add-Member ScriptMethod SetFocus { $ui.Events.Add("focus:$($this.Id)") }
        $picker | Add-Member ScriptMethod GetCurrentPattern { throw "Pickers must be driven by keys, not UI Automation patterns." }
        $ui.Pickers[$pickerId] = $picker
    }
    $ui.ExpansionPattern = [pscustomobject]@{ Current = [pscustomobject]@{
        ExpandCollapseState = [System.Windows.Automation.ExpandCollapseState]::Collapsed } }
    $ui.ExpansionPattern | Add-Member ScriptMethod Expand {
        $ui.Events.Add("expand")
        $ui.Expanded = $true
        $this.Current.ExpandCollapseState = [System.Windows.Automation.ExpandCollapseState]::Expanded
    }
    $ui.Expander = [pscustomobject]@{}
    $ui.Expander | Add-Member ScriptMethod GetCurrentPattern {
        param($PatternId)
        if ($PatternId -ne [System.Windows.Automation.ExpandCollapsePattern]::Pattern) {
            throw "The schema expander must be driven through ExpandCollapsePattern."
        }
        return $ui.ExpansionPattern
    }

    function Wait-SqlState([scriptblock] $Predicate, [string] $Description, [int] $Seconds = 10) {
        for ($attempt = 0; $attempt -lt 10; $attempt++) { if (& $Predicate) { return } }
        throw "Timed out waiting for $Description."
    }
    # Expanded content joins the automation tree only after a later layout pass.
    function Find-SqlControl([string] $Id, [switch] $Optional) {
        $element = $null
        if ($Id -eq "SchemaExpander") { $element = $ui.Expander }
        elseif ($Id -eq "SqlPageScroll") { $element = $ui.Scroll }
        elseif ($Id -eq "TogglePaneButton") { $element = $ui.Toggle }
        elseif ($Id -eq "ModePicker") { $element = $ui.ModePage }
        elseif ($ui.Pickers.ContainsKey($Id)) {
            if ($ui.Expanded) {
                $ui.LookupsAfterExpand++
                if ($ui.LookupsAfterExpand -gt $ui.LayoutLookups) { $element = $ui.Pickers[$Id] }
            }
        }
        else { throw "Unexpected synthetic SQL control '$Id'." }
        if (-not $element -and -not $Optional) { throw "Missing SQL editor control '$Id'." }
        return $element
    }
    function Invoke-SqlControl([string] $Id) { $ui.Events.Add("invoke:$Id") }
    function Show-UiRegressionScrollTargets {
        param([scriptblock] $GetViewport, [scriptblock] $GetTargets, [scriptblock] $GetWindow, [string] $Description)
        if ((& $GetViewport).Tag -ne "SqlPageScroll") { throw "Schema controls must be positioned inside the SQL page scroller." }
        if (-not (& $GetTargets)) { throw "Positioning needs a located target." }
        $ui.Events.Add("scroll:$Description")
    }
    function Focus-SqlWindow { $ui.Events.Add("foreground") }
    function Send-SqlKeys([string] $Keys) { $ui.Events.Add("keys:$Keys") }

    Show-SqlSchemaPicker SchemaPicker
    Assert-Equal ($ui.Events -join "|") "expand|scroll:SQL schema picker 'SchemaPicker'" "A collapsed expander must be expanded once and its late picker awaited before positioning"
    Assert-Equal ($ui.LookupsAfterExpand -gt $ui.LayoutLookups) $true "The picker must be awaited until the expanded layout exposes it"
    $ui.Events.Clear()
    Show-SqlSchemaPicker TablePicker
    Assert-Equal ($ui.Events -join "|") "scroll:SQL schema picker 'TablePicker'" "An already expanded expander must not be expanded again"

    $ui.Events.Clear()
    Select-SqlSchemaEndpoint SchemaPicker -Last
    Assert-Equal ($ui.Events -join "|") "scroll:SQL schema picker 'SchemaPicker'|foreground|focus:SchemaPicker|keys:{END}" "The last endpoint must be typed into the focused closed picker"
    $ui.Events.Clear()
    Select-SqlSchemaEndpoint TablePicker
    Assert-Equal ($ui.Events -join "|") "scroll:SQL schema picker 'TablePicker'|foreground|focus:TablePicker|keys:{HOME}" "The first endpoint must be typed into the focused closed picker"
    $ui.Events.Clear()
    Send-SqlPickerKeys ExamplePicker "{HOME}{DOWN}"
    Assert-Equal ($ui.Events -join "|") "scroll:SQL schema picker 'ExamplePicker'|foreground|focus:ExamplePicker|keys:{HOME}{DOWN}" "Example selection must type its keys only after the picker is shown and focused"

    $ui.Events.Clear()
    $ui.Expanded = $false
    $ui.LookupsAfterExpand = 0
    $ui.LayoutLookups = 1000
    $ui.ExpansionPattern.Current.ExpandCollapseState = [System.Windows.Automation.ExpandCollapseState]::Collapsed
    Assert-Throws { Select-SqlSchemaEndpoint SchemaPicker -Last } "Timed out waiting for SQL control 'SchemaPicker' readiness."
    Assert-Equal ($ui.Events -join "|") "expand" "A picker that never appears must fail before focus or keys are sent"

    function Get-SqlFocusState { $ui.Events.Add("focus-state"); return "Focused: 'FakePicker'." }
    $ui.Events.Clear()
    Wait-SqlKeyboardOutcome { $true } "synthetic outcome"
    Assert-Equal $ui.Events.Count 0 "A satisfied keyboard outcome must not collect focus diagnostics"
    Assert-Throws { Wait-SqlKeyboardOutcome { $false } "synthetic outcome" } "Timed out waiting for synthetic outcome. Focused: 'FakePicker'."
    Assert-Equal ($ui.Events -join "|") "focus-state" "A missed keyboard outcome must keep its timeout and append the focus state"

    # Settings is the built-in navigation item without an automation id, so it is found by name and list-item type.
    $script:root = [pscustomobject]@{}
    $script:root | Add-Member ScriptMethod FindFirst {
        param($Scope, $Condition)
        $parts = @($Condition.GetConditions())
        $nameId = [System.Windows.Automation.AutomationElement]::NameProperty.ProgrammaticName
        $typeId = [System.Windows.Automation.AutomationElement]::ControlTypeProperty.ProgrammaticName
        $name = @($parts | Where-Object { $_.Property.ProgrammaticName -eq $nameId })
        $type = @($parts | Where-Object { $_.Property.ProgrammaticName -eq $typeId })
        if ($Scope -ne [System.Windows.Automation.TreeScope]::Descendants -or $parts.Count -ne 2 -or $name.Count -ne 1 -or
            $type.Count -ne 1 -or $name[0].Value -ne "Settings" -or $type[0].Value -ne [System.Windows.Automation.ControlType]::ListItem.Id) {
            return $null
        }
        return $ui.SettingsItem
    }
    function New-SettingsDouble([switch] $Offscreen) {
        $selection = [pscustomobject]@{}
        $selection | Add-Member ScriptMethod Select {
            $ui.Selected++
            $ui.SelectedAtPoll = $ui.SettingsPolls
            $ui.Events.Add("select-settings")
            if ($ui.ShowsAfterSelect) {
                $ui.ModePage = [pscustomobject]@{ Current = [pscustomobject]@{ IsOffscreen = $false; IsEnabled = $true } }
            }
        }
        $item = [pscustomobject]@{ Tag = "Settings"; Selection = $selection; Current = [pscustomobject]@{ IsOffscreen = [bool] $Offscreen } }
        $item | Add-Member ScriptMethod GetCurrentPattern {
            param($PatternId)
            if ($PatternId -ne [System.Windows.Automation.SelectionItemPattern]::Pattern) { throw "Settings must be selected through SelectionItemPattern." }
            return $this.Selection
        }
        return $item
    }
    function Reset-SettingsState([int] $ReadyAfter = 1, [int] $GoneAfter = [int]::MaxValue, [bool] $ShowsAfterSelect = $true) {
        $ui.SettingsPolls = 0; $ui.Selected = 0; $ui.SelectedAtPoll = -1; $ui.ModePage = $null
        $ui.ReadyAfter = $ReadyAfter; $ui.GoneAfter = $GoneAfter; $ui.ShowsAfterSelect = $ShowsAfterSelect
        $ui.Events.Clear()
    }

    $ui.SettingsItem = New-SettingsDouble
    Assert-Equal (Find-SqlSettingsItem).Tag "Settings" "The on-screen Settings item must be found by name and list-item type"
    $ui.SettingsItem = $null
    Assert-Equal ($null -eq (Find-SqlSettingsItem)) $true "A collapsed navigation pane exposes no Settings item"
    $ui.SettingsItem = New-SettingsDouble -Offscreen
    Assert-Equal ($null -eq (Find-SqlSettingsItem)) $true "An off-screen Settings item must not be selected"

    function Find-SqlSettingsItem {
        $ui.SettingsPolls++
        if ($ui.SettingsPolls -lt $ui.ReadyAfter -or $ui.SettingsPolls -gt $ui.GoneAfter) { return $null }
        return $ui.SettingsItem
    }
    $ui.SettingsItem = New-SettingsDouble
    Reset-SettingsState
    Select-SqlSettings
    Assert-Equal ($ui.Events -join "|") "select-settings" "A visible Settings item must be selected without toggling the pane"
    Assert-Equal $ui.Selected 1 "Settings must be selected once"

    Reset-SettingsState -ReadyAfter 3
    Select-SqlSettings
    Assert-Equal ($ui.Events -join "|") "invoke:TogglePaneButton|select-settings" "A collapsed pane must be opened before Settings is selected"
    Assert-Equal ($ui.Selected -eq 1 -and $ui.SelectedAtPoll -ge 3) $true "Settings must be selected only after the pane exposes it"

    Reset-SettingsState -ReadyAfter 99
    Assert-Throws { Select-SqlSettings } "Timed out waiting for the Settings navigation item."
    Assert-Equal $ui.Selected 0 "A pane that never exposes Settings must time out without selecting anything"

    Reset-SettingsState -GoneAfter 2
    Assert-Throws { Select-SqlSettings } "The Settings navigation item disappeared before it could be selected."
    Assert-Equal $ui.Selected 0 "An item that vanishes after the wait must be reported, not dereferenced"

    Reset-SettingsState -ShowsAfterSelect $false
    Assert-Throws { Select-SqlSettings } "Timed out waiting for SQL control 'ModePicker' readiness."
    Assert-Equal $ui.Selected 1 "A Settings page that never appears must be reported after the item was selected"

    $script:root = $null
}
$nativeText = $ast.Extent.Text
Assert-Equal $nativeText.Contains("SettingsNavItem") $false "Settings has no automation id; it must be selected through Select-SqlSettings"

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

& {
    $content = [Windows.Rect]::new(34, 300, 572, 136)
    Assert-Equal (Test-SqlResultWidth $content ([Windows.Rect]::new(35, 480, 570, 280))) $true "A result surface within 2 px of the editor must pass"
    Assert-Equal (Test-SqlResultWidth $content ([Windows.Rect]::new(34, 480, 400, 280))) $false "A result surface short of the editor's right edge must fail"
    Assert-Equal (Test-SqlResultWidth $content ([Windows.Rect]::Empty)) $false "An unmeasured result surface must fail"

    $sizes = @{ SqlText = @([Windows.Rect]::new(34, 300, 572, 136)); ResultScroll = @(
        [Windows.Rect]::Empty, [Windows.Rect]::new(34, 480, 1440, 280), [Windows.Rect]::new(34, 480, 572, 280)) }
    $reads = @{ SqlText = 0; ResultScroll = 0 }
    function Wait-SqlState([scriptblock] $Predicate, [string] $Description, [int] $Seconds = 10) {
        for ($attempt = 0; $attempt -lt 5; $attempt++) { if (& $Predicate) { return } }
        throw "Timed out waiting for $Description."
    }
    # Freshly shown results report empty, then unclamped, bounds until layout settles.
    function Find-SqlControl([string] $Id, [switch] $Optional) {
        $bounds = [Windows.Rect]::new(0, 0, 640, 800)
        if ($sizes.ContainsKey($Id)) {
            $values = $sizes[$Id]
            $bounds = $values[[Math]::Min($reads[$Id], $values.Count - 1)]
            $reads[$Id]++
        }
        return [pscustomobject]@{ Current = [pscustomobject]@{ BoundingRectangle = $bounds; IsOffscreen = $false } }
    }
    $script:root = Find-SqlControl window
    Assert-SqlResultWidth
    Assert-Equal $reads.ResultScroll 3 "Result width must be re-read until layout settles"
    Assert-Equal ($reads.SqlText -ge 3) $true "Editor bounds must be re-read with each result measurement"

    $sizes.ResultScroll = @([Windows.Rect]::new(34, 480, 400, 280))
    Assert-Throws { Assert-SqlResultWidth } "The SQL result surface does not fill the editor's content width. Last geometry: SqlText ``[34, 606``]*ResultScroll ``[34, 434``]*SqlPageScroll*window*"
    $sizes.ResultScroll = @([Windows.Rect]::Empty)
    Assert-Throws { Assert-SqlResultWidth } "*ResultScroll empty (offscreen False)*"
}
Write-Host "SQL editor polling, post-expand picker waits, keyboard selection, Settings navigation, narrow navigation, result width readiness and process cleanup regressions passed without desktop automation."
