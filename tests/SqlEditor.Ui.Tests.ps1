param(
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $ScreenshotDirectory
)

$ErrorActionPreference = "Stop"
if ($env:GITHUB_ACTIONS -ne "true" -or $env:RUNNER_ENVIRONMENT -ne "github-hosted") {
    throw "SQL editor UI checks require a disposable GitHub-hosted desktop."
}
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScreenshot.ps1")
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewAppearance.ps1")
. (Join-Path $PSScriptRoot "UiRegression\Helpers.ps1")
. (Join-Path $PSScriptRoot "UiRegression\Sidebar.Controls.Helpers.ps1")
. (Join-Path $PSScriptRoot "Inventory.Sqlite.Helpers.ps1")
Initialize-InventorySqlite $AppPath

function Find-SqlControl([string] $Id, [switch] $Optional) {
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)
    $element = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if (-not $element -and -not $Optional) { throw "Missing SQL editor control '$Id'." }
    return $element
}

function Wait-SqlState([scriptblock] $Predicate, [string] $Description, [int] $Seconds = 10) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if (& $Predicate) { return }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Description."
}

function Wait-SqlControl([string] $Id, [switch] $Visible, [switch] $Enabled, [int] $Seconds = 10) {
    Wait-SqlState {
        $control = Find-SqlControl $Id -Optional
        $control -and (-not $Visible -or -not $control.Current.IsOffscreen) -and
            (-not $Enabled -or $control.Current.IsEnabled)
    } "SQL control '$Id' readiness" $Seconds
}

function Invoke-SqlControl([string] $Id) {
    (Find-SqlControl $Id).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Select-SqlPage([string] $Id) {
    $item = Find-SqlControl $Id -Optional
    if (-not $item -or $item.Current.IsOffscreen) {
        Wait-SqlControl TogglePaneButton -Visible -Enabled
        Invoke-SqlControl TogglePaneButton
    }
    Wait-SqlControl $Id -Visible -Enabled
    (Find-SqlControl $Id).GetCurrentPattern(
        [System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
}

function Select-SqlTools {
    Select-SqlPage ToolsNavItem
    Wait-SqlControl SqlEditorCard -Visible -Enabled
    Invoke-SqlControl SqlEditorCard
    Wait-SqlControl SqlText -Visible -Enabled
}

function Find-SqlSettingsItem {
    $condition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, "Settings"),
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::ListItem))
    $item = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if ($item -and -not $item.Current.IsOffscreen) { return $item }
    return $null
}

function Select-SqlSettings {
    # The built-in Settings item has no automation id; it is found by name and list-item type.
    if (-not (Find-SqlSettingsItem)) {
        Wait-SqlControl TogglePaneButton -Visible -Enabled
        Invoke-SqlControl TogglePaneButton
    }
    Wait-SqlState { Find-SqlSettingsItem } "the Settings navigation item"
    $item = Find-SqlSettingsItem
    if (-not $item) { throw "The Settings navigation item disappeared before it could be selected." }
    $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Wait-SqlControl ModePicker -Visible -Enabled
}

function Start-SqlQuery([string] $Sql) {
    (Find-SqlControl SqlText).GetCurrentPattern(
        [System.Windows.Automation.ValuePattern]::Pattern).SetValue($Sql)
    Invoke-SqlControl RunButton
}

function Assert-SqlResult([string] $Pattern) {
    Wait-SqlState {
        $status = Find-SqlControl QueryStatus -Optional
        $run = Find-SqlControl RunButton -Optional
        $status -and $run -and $status.Current.Name -like $Pattern -and $run.Current.IsEnabled
    } "SQL result '$Pattern'"
}

function Save-SqlCapture([string] $Name, [double] $Scroll = 0) {
    $pattern = (Find-SqlControl SqlPageScroll).GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    if ($pattern.Current.VerticallyScrollable) { $pattern.SetScrollPercent(-1, $Scroll) }
    Start-Sleep -Milliseconds 200
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "$Name.png")
}

function Test-SqlActionBounds($Editor, $Run, $Cancel, $Status, $Progress = $null) {
    foreach ($bounds in @($Editor, $Run, $Cancel, $Status)) {
        if ($bounds.IsEmpty -or $bounds.Width -le 0 -or $bounds.Height -le 0) { return $false }
    }
    $right = if ($Progress) { $Progress.Right } else { $Cancel.Right }
    $center = $Run.Top + $Run.Height / 2
    return $Run.Left -ge $Editor.Left -and $Cancel.Left -ge $Run.Right -and
        $Status.Left -ge $right -and [Math]::Abs($Status.Right - $Editor.Right) -le 2 -and
        [Math]::Abs($Cancel.Top + $Cancel.Height / 2 - $center) -le 2 -and
        [Math]::Abs($Status.Top + $Status.Height / 2 - $center) -le 2
}

function Assert-SqlActionLayout {
    try {
        $null = Show-UiRegressionScrollTargets -GetViewport { Find-SqlControl SqlPageScroll } `
            -GetTargets {
                foreach ($id in @("SqlText", "RunButton", "CancelButton", "QueryStatus")) { Find-SqlControl $id }
            } -GetWindow { $script:root } -Description "SQL editor and action row"
        Wait-SqlState {
            $progress = Find-SqlControl QueryProgress -Optional
            $progressBounds = if ($progress -and -not $progress.Current.IsOffscreen) { $progress.Current.BoundingRectangle }
            Test-SqlActionBounds (Find-SqlControl SqlText).Current.BoundingRectangle `
                (Find-SqlControl RunButton).Current.BoundingRectangle (Find-SqlControl CancelButton).Current.BoundingRectangle `
                (Find-SqlControl QueryStatus).Current.BoundingRectangle $progressBounds
        } "Run, Cancel and right-aligned status on one non-overlapping row"
    }
    catch {
        $geometry = @(
            foreach ($id in @("SqlText", "RunButton", "CancelButton", "QueryStatus", "QueryProgress", "SqlPageScroll")) {
                Format-SqlBounds $id (Find-SqlControl $id -Optional)
            }
            Format-SqlBounds window $script:root
        ) -join "; "
        throw "SQL action layout failed: $($_.Exception.Message) Last geometry: $geometry."
    }
}

function Test-SqlResultWidth($Editor, $Result) {
    foreach ($bounds in @($Editor, $Result)) {
        if ($bounds.IsEmpty -or $bounds.Width -le 0 -or $bounds.Height -le 0) { return $false }
    }
    return [Math]::Abs($Result.Left - $Editor.Left) -le 2 -and [Math]::Abs($Result.Right - $Editor.Right) -le 2
}

function Format-SqlBounds([string] $Id, $Element) {
    if (-not $Element) { return "$Id missing" }
    $bounds = $Element.Current.BoundingRectangle
    if ($bounds.IsEmpty) { return "$Id empty (offscreen $($Element.Current.IsOffscreen))" }
    return "$Id [$($bounds.Left), $($bounds.Right)] x [$($bounds.Top), $($bounds.Bottom)] (offscreen $($Element.Current.IsOffscreen))"
}

function Assert-SqlResultWidth {
    try {
        Wait-SqlState {
            $editor = Find-SqlControl SqlText -Optional
            $result = Find-SqlControl ResultScroll -Optional
            $editor -and $result -and
                (Test-SqlResultWidth $editor.Current.BoundingRectangle $result.Current.BoundingRectangle)
        } "SQL result surface matching the editor's content width"
    }
    catch {
        $geometry = @(
            Format-SqlBounds SqlText (Find-SqlControl SqlText -Optional)
            Format-SqlBounds ResultScroll (Find-SqlControl ResultScroll -Optional)
            Format-SqlBounds SqlPageScroll (Find-SqlControl SqlPageScroll -Optional)
            Format-SqlBounds window $script:root
        ) -join "; "
        throw "The SQL result surface does not fill the editor's content width. Last geometry: $geometry."
    }
}

function Assert-SqlResultLayout([switch] $Wide) {
    $null = Show-UiRegressionScrollTargets -GetViewport { Find-SqlControl SqlPageScroll } `
        -GetTargets { Find-SqlControl ResultScroll } -GetWindow { $script:root } -Description "SQL result table"
    Assert-SqlResultWidth
    $viewport = (Find-SqlControl ResultScroll).Current.BoundingRectangle
    $scroll = (Find-SqlControl ResultScroll).GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    Wait-SqlState { $scroll.Current.HorizontallyScrollable -eq $Wide.IsPresent } "SQL horizontal overflow (wide result: $Wide)"
    if (-not $Wide) {
        Wait-SqlState {
            $rows = (Find-SqlControl ResultRows).Current.BoundingRectangle
            [Math]::Abs($rows.Left - $viewport.Left) -le 2 -and [Math]::Abs($rows.Right - $viewport.Right) -le 2
        } "narrow SQL result rows stretching across the result surface"
    }
    else {
        $scroll.SetScrollPercent(100, -1)
        $condition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, "last_column")
        Wait-SqlState {
            $last = (Find-SqlControl ResultScroll).FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
            Test-UiRegressionElementWithin $last (Find-SqlControl ResultScroll) $script:root
        } "last SQL column reachable by horizontal scrolling"
        $scroll.SetScrollPercent(0, -1)
    }
    (Find-SqlControl SqlText).SetFocus()
}

function Show-SqlSchemaPicker([string] $Id) {
    $expander = (Find-SqlControl SchemaExpander).GetCurrentPattern(
        [System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    if ($expander.Current.ExpandCollapseState -ne [System.Windows.Automation.ExpandCollapseState]::Expanded) {
        $expander.Expand()
    }
    # Expanded content joins the automation tree only after XAML lays out again.
    Wait-SqlControl $Id -Enabled
    $null = Show-UiRegressionScrollTargets -GetViewport { Find-SqlControl SqlPageScroll } `
        -GetTargets { Find-SqlControl $Id -Optional } -GetWindow { $script:root } -Description "SQL schema picker '$Id'"
}

function Focus-SqlWindow {
    $handle = $script:process.MainWindowHandle
    if ([UiReviewNativeWindow]::GetForegroundWindow() -eq $handle) { return }
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        [SidebarReviewKeyboard]::Tap(0x12)
        $null = [UiReviewNativeWindow]::SetForegroundWindow($handle)
        Start-Sleep -Milliseconds 100
        if ([UiReviewNativeWindow]::GetForegroundWindow() -eq $handle) { return }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "SQL editor window could not be brought to the foreground."
}

function Send-SqlKeys([string] $Keys) {
    [System.Windows.Forms.SendKeys]::SendWait($Keys)
}

function Send-SqlPickerKeys([string] $Id, [string] $Keys) {
    Show-SqlSchemaPicker $Id
    Focus-SqlWindow
    (Find-SqlControl $Id).SetFocus()
    Send-SqlKeys $Keys
}

function Select-SqlSchemaEndpoint([string] $Id, [switch] $Last) {
    # On a closed ComboBox the arrow keys change the selection immediately, while Enter would only open its list.
    Send-SqlPickerKeys $Id $(if ($Last) { "{END}" } else { "{HOME}" })
}

function Find-SqlExampleButton {
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::NameProperty, "Use SQL example")
    return $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Get-SqlFocusState {
    try {
        $focused = [System.Windows.Automation.AutomationElement]::FocusedElement
        $foreground = [UiReviewNativeWindow]::GetForegroundWindow() -eq $script:process.MainWindowHandle
        return "Focused: '$($focused.Current.AutomationId)' '$($focused.Current.Name)' ($($focused.Current.ControlType.ProgrammaticName)); SQL window is foreground: $foreground."
    }
    catch { return "Focus state unavailable: $($_.Exception.Message)" }
}

function Wait-SqlKeyboardOutcome([scriptblock] $Predicate, [string] $Description, [int] $Seconds = 10) {
    try { Wait-SqlState $Predicate $Description $Seconds }
    catch { throw "$($_.Exception.Message) $(Get-SqlFocusState)" }
}

function Stop-SqlApp {
    if (-not $script:process) { return }
    try {
        if (-not $script:process.HasExited) {
            Stop-Process -Id $script:process.Id -Force
        }
        if (-not $script:process.WaitForExit(5000)) {
            throw "SQL editor app did not exit during fixture cleanup."
        }
    }
    finally { $script:process.Dispose() }
}

$previous = @{}
foreach ($key in @("FINGVIBE_UI_REVIEW", "FINGVIBE_UI_REVIEW_INVENTORY", "FINGVIBE_UI_REVIEW_SNAPSHOT")) {
    $previous[$key] = [Environment]::GetEnvironmentVariable($key)
}
$fixtureDirectory = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-sql-ui-$([Guid]::NewGuid().ToString('N'))"
$inventory = Join-Path $fixtureDirectory "inventory.json"
$database = [IO.Path]::ChangeExtension($inventory, ".sqlite")
$script:process = $null
$testFailure = $null
$highContrast = $null
$phase = $null
try {
    $null = New-Item -ItemType Directory -Path $fixtureDirectory
    $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
    $phase = Step-UiRegressionPhase $phase "SQL/setup" -Directory $ScreenshotDirectory
    @{
        version = 4
        data = @{
            revision = [Guid]::NewGuid().ToString()
            devices = @{
                "001122334455" = @{
                    mac = "001122334455"; imported = @{ name = "Synthetic SQL device"; model = "Review model" }
                    observations = @(); scanHistory = @()
                }
            }
            names = @{}; classifications = @{}
            peopleRooms = @{ people = @(); rooms = @(); assignments = @{} }
            virtualDevices = @(); discoveryBaselines = @()
        }
    } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $inventory -Encoding utf8
    $env:FINGVIBE_UI_REVIEW = "1"
    $env:FINGVIBE_UI_REVIEW_INVENTORY = $inventory
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = Join-Path $fixtureDirectory "unused-snapshot.json"
    $script:process = Start-Process -FilePath $AppPath -PassThru
    Wait-SqlState {
        $script:process.Refresh()
        if ($script:process.HasExited) { throw "SQL editor app exited: $($script:process.ExitCode)." }
        $script:process.MainWindowHandle -ne [IntPtr]::Zero
    } "SQL editor app window" 30
    Initialize-UiReviewWindow $script:process.MainWindowHandle
    $script:root = [System.Windows.Automation.AutomationElement]::FromHandle($script:process.MainWindowHandle)
    Wait-SqlState { (Test-Path -LiteralPath $database) -and (Find-SqlControl ToolsNavItem -Optional) } "fixture migration"
    Start-Sleep -Milliseconds 500
    $fingerprint = Get-InventoryFingerprint $database
    Select-SqlTools
    Assert-SqlActionLayout

    $phase = Step-UiRegressionPhase $phase "SQL/result-layout" -Directory $ScreenshotDirectory
    Start-SqlQuery "SELECT imported_name, imported_model, imported_os FROM r_devices;"
    Assert-SqlResult "1 row, 3 columns;*Complete."
    Assert-SqlActionLayout
    Assert-SqlResultLayout
    foreach ($column in @("imported_name", "imported_model", "imported_os")) {
        $condition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, $column)
        Wait-SqlState {
            $results = Find-SqlControl ResultScroll -Optional
            $results -and $results.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        } "result header '$column' preserving the returned SQL column name"
    }
    $nameCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::NameProperty, "Synthetic SQL device")
    Wait-SqlState {
        $rows = Find-SqlControl ResultRows -Optional
        $rows -and $rows.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $nameCondition)
    } "persisted synthetic inventory rendered in the result table"
    Save-SqlCapture "sql-results" 25
    Save-SqlCapture "sql-editor"

    Start-SqlQuery "SELECT NULL AS missing;"
    Assert-SqlResult "1 row, 1 column;*Complete."
    Assert-SqlResultLayout
    $nullCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::NameProperty, "NULL")
    if (-not (Find-SqlControl ResultRows).FindFirst([System.Windows.Automation.TreeScope]::Descendants, $nullCondition)) {
        throw "Missing SQL values must still render as NULL."
    }
    Start-SqlQuery "SELECT device_id FROM r_devices WHERE 0;"
    Assert-SqlResult "0 rows, 1 column;*Complete."
    Assert-SqlResultLayout
    $wide = "SELECT 1 AS first_column, 2 AS second_column, 3 AS third_column, 4 AS fourth_column, 5 AS fifth_column, 6 AS sixth_column, 7 AS seventh_column, 8 AS last_column;"
    Start-SqlQuery $wide
    Assert-SqlResult "1 row, 8 columns;*Complete."
    Assert-SqlResultLayout -Wide
    Save-SqlCapture "sql-wide-results"

    $phase = Step-UiRegressionPhase $phase "SQL/limits-cancellation" -Directory $ScreenshotDirectory
    Start-SqlQuery "DELETE FROM devices;"
    Assert-SqlResult "Error*not authorized*"
    Assert-SqlActionLayout
    Save-SqlCapture "sql-readonly-error"
    Start-SqlQuery "SELECT missing_column FROM r_devices;"
    Assert-SqlResult "Error*no such column*"
    Start-SqlQuery "WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<1001) SELECT i FROM n;"
    Assert-SqlResult "1,000 rows, 1 column;*Truncated*"
    Save-SqlCapture "sql-row-limit" 25
    Start-SqlQuery "SELECT zeroblob(600000) AS oversized;"
    Assert-SqlResult "0 rows, 1 column;*1 MiB*"
    Start-SqlQuery "SELECT hex(zeroblob(3000)) AS long_value;"
    Assert-SqlResult "1 row, 1 column;*Cell previews are limited*"

    $expensive = "WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n) SELECT sum(i) FROM n;"
    Start-SqlQuery $expensive
    Wait-SqlControl CancelButton -Enabled
    Assert-SqlActionLayout
    Invoke-SqlControl CancelButton
    Assert-SqlResult "Cancelled*"
    Assert-SqlActionLayout
    Save-SqlCapture "sql-cancelled"
    Start-SqlQuery $expensive
    Assert-SqlResult "Error*5-second execution limit*"

    $phase = Step-UiRegressionPhase $phase "SQL/schema-examples" -Directory $ScreenshotDirectory
    Show-SqlSchemaPicker SchemaPicker
    Wait-SqlState {
        $columns = Find-SqlControl SchemaColumns -Optional
        $columns -and $columns.Current.Name.Contains("device_id")
    } "schema browser reporting columns"
    Select-SqlSchemaEndpoint SchemaPicker -Last
    Wait-SqlKeyboardOutcome {
        (Find-SqlControl SchemaColumns).Current.Name -like "device_kind, device_id, sequence,*completed_ticks"
    } "reporting view columns after keyboard selection"
    # Home then Down selects the second example whichever one the picker showed before.
    Send-SqlPickerKeys ExamplePicker "{HOME}{DOWN}"
    $null = Show-UiRegressionScrollTargets -GetViewport { Find-SqlControl SqlPageScroll } `
        -GetTargets { Find-SqlExampleButton } -GetWindow { $script:root } -Description "SQL example button"
    Focus-SqlWindow
    (Find-SqlExampleButton).SetFocus()
    [SidebarReviewKeyboard]::Tap(0x20)
    Wait-SqlKeyboardOutcome {
        (Find-SqlControl SqlText).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -like "*FROM r_assignments*"
    } "existing example selected by keyboard"
    Select-SqlSchemaEndpoint TablePicker -Last
    Wait-SqlKeyboardOutcome {
        (Find-SqlControl TableColumns).Current.Name -eq "kind, id, sequence, completed_at, network_id, subnet, present, completed_ticks, scan_id, virtual_id"
    } "underlying scan_history columns after keyboard selection"
    Select-SqlSchemaEndpoint TablePicker
    Wait-SqlKeyboardOutcome { (Find-SqlControl TableColumns).Current.Name -eq "id, data" } "JSON entity columns after keyboard selection"
    Save-SqlCapture "sql-table-discovery" 100

    $phase = Step-UiRegressionPhase $phase "SQL/appearance" -Directory $ScreenshotDirectory
    foreach ($theme in @("Standard Light", "Standard Dark")) {
        Select-SqlSettings
        Set-UiReviewTheme -Root $script:root -Theme $theme
        Select-SqlTools
        Start-SqlQuery "SELECT imported_name FROM r_devices;"
        Assert-SqlResult "1 row, 1 column;*Complete."
        Assert-SqlActionLayout
        Assert-SqlResultLayout
        Save-SqlCapture ("sql-results-" + $theme.Replace(" ", "-").ToLowerInvariant())
    }
    $highContrast = [SidebarReviewKeyboard]::GetHighContrastFlags()
    [SidebarReviewKeyboard]::SetHighContrastFlags($highContrast -bor 1)
    if (([SidebarReviewKeyboard]::GetHighContrastFlags() -band 1) -eq 0) { throw "SQL high contrast did not activate." }
    Start-Sleep -Seconds 2
    Initialize-UiReviewWindow $script:process.MainWindowHandle
    Assert-SqlActionLayout
    Assert-SqlResultLayout
    Save-SqlCapture "sql-high-contrast"
    [SidebarReviewKeyboard]::SetHighContrastFlags($highContrast)
    $highContrast = $null
    Start-Sleep -Seconds 2

    $phase = Step-UiRegressionPhase $phase "SQL/narrow-lifecycle" -Directory $ScreenshotDirectory
    if (-not [UiReviewNativeWindow]::SetWindowPos($script:process.MainWindowHandle, [IntPtr]::Zero,
        0, 0, 640, 800, 0x0044)) { throw [System.ComponentModel.Win32Exception]::new() }
    Initialize-UiReviewWindow $script:process.MainWindowHandle
    Show-SqlSchemaPicker TablePicker
    Save-SqlCapture "sql-narrow-schema" 100
    (Find-SqlControl SqlText).SetFocus()
    Start-SqlQuery "SELECT imported_name FROM r_devices;"
    Assert-SqlResult "1 row, 1 column;*Complete."
    Assert-SqlActionLayout
    Assert-SqlResultLayout
    Start-SqlQuery $wide
    Assert-SqlResult "1 row, 8 columns;*Complete."
    Assert-SqlResultLayout -Wide
    Save-SqlCapture "sql-narrow-editor"
    foreach ($id in @("SqlText", "RunButton", "CancelButton", "QueryStatus")) {
        $bounds = (Find-SqlControl $id).Current.BoundingRectangle
        $window = $script:root.Current.BoundingRectangle
        if ($bounds.IsEmpty -or $bounds.Left -lt $window.Left -or $bounds.Right -gt $window.Right) {
            throw "Required SQL control '$id' is horizontally clipped at narrow width."
        }
    }
    Start-SqlQuery "SELECT missing_column FROM r_devices;"
    Assert-SqlResult "Error*no such column*"
    Assert-SqlActionLayout
    Start-SqlQuery $expensive
    Wait-SqlControl CancelButton -Enabled
    Assert-SqlActionLayout
    Select-SqlPage OverviewNavItem
    Start-Sleep -Milliseconds 300
    Select-SqlTools
    Assert-SqlResult "Cancelled*"
    if ((Get-InventoryFingerprint $database) -cne $fingerprint) { throw "Queries changed the persisted fixture." }

    Start-SqlQuery $expensive
    Wait-SqlControl CancelButton -Enabled
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $null = $script:process.CloseMainWindow()
    if (-not $script:process.WaitForExit(3000)) { throw "Window close did not cancel SQL promptly." }
    if ((Get-InventoryFingerprint $database) -cne $fingerprint) { throw "Window close changed the persisted fixture." }
    Write-Host "SQL editor native results/errors/limits/schema/narrow layout/cancellation/lifecycle passed ($($clock.ElapsedMilliseconds) ms close)."
}
catch {
    $testFailure = $_
    Write-Host "SQL editor native failure: $($_.Exception.Message)"
    Write-Host $_.ScriptStackTrace
    throw
}
finally {
    try {
        try {
            if ($phase) {
                Complete-UiRegressionPhase -Phase $phase -Directory $ScreenshotDirectory -Succeeded ($null -eq $testFailure)
            }
        }
        finally {
            try { Stop-SqlApp }
            finally {
                try {
                    if ($null -ne $highContrast) { [SidebarReviewKeyboard]::SetHighContrastFlags($highContrast) }
                }
                finally {
                    foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key]) }
                }
            }
        }
        if (Test-Path -LiteralPath $fixtureDirectory) { Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force }
    }
    catch {
        if (-not $testFailure) { throw }
        Write-Warning "SQL fixture cleanup also failed: $($_.Exception.Message). Fixture: $fixtureDirectory"
    }
}
