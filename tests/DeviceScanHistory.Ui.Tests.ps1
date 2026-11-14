param(
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $ScreenshotDirectory,
    [switch] $SummaryOnly,
    [switch] $ObservationsOnly
)

$ErrorActionPreference = "Stop"
if ($SummaryOnly -and $ObservationsOnly) { throw "Choose summary or observation coverage, not both." }
if ($env:GITHUB_ACTIONS -ne "true") { throw "History UI checks require a disposable GitHub Actions desktop." }
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScreenshot.ps1")
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewAppearance.ps1")
. (Join-Path $PSScriptRoot "UiRegression\Helpers.ps1")
. (Join-Path $PSScriptRoot "Inventory.Sqlite.Helpers.ps1")
Initialize-InventorySqlite $AppPath

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class HistoryReviewContrast {
    [StructLayout(LayoutKind.Sequential)] private struct HC { public uint Size; public uint Flags; public IntPtr Scheme; }
    [DllImport("user32.dll", SetLastError=true)] private static extern bool SystemParametersInfo(uint action, uint parameter, ref HC value, uint flags);
    public static uint Get() {
        var value = new HC { Size = (uint)Marshal.SizeOf<HC>() };
        if (!SystemParametersInfo(0x0042, value.Size, ref value, 0)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return value.Flags;
    }
    public static void Set(uint flags) {
        var value = new HC { Size = (uint)Marshal.SizeOf<HC>(), Flags = flags };
        if (!SystemParametersInfo(0x0043, value.Size, ref value, 2)) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }
}
'@

function Find-HistoryControl([string] $Value, [switch] $ByName, [switch] $Optional, [switch] $NoTabSwitch) {
    $property = if ($ByName) { [System.Windows.Automation.AutomationElement]::NameProperty }
        else { [System.Windows.Automation.AutomationElement]::AutomationIdProperty }
    $historyCondition = [System.Windows.Automation.PropertyCondition]::new($property, $Value)
    $call = Start-UiRegressionCall lookup
    try {
        $element = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $historyCondition)
        if (-not $element -and -not $NoTabSwitch -and (Show-UiRegressionDeviceTabFor $script:root $Value)) {
            $element = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $historyCondition)
        }
        if (-not $element -and -not $NoTabSwitch) {
            $disclosure = if ($Value -in @("DeviceHistorySince", "DeviceHistorySummaryScope")) { "DeviceHistorySummaryDetails" }
                elseif ($Value -in @("DeviceHistoryScope", "DeviceHistoryLatest")) { "DeviceScanHistoryDetails" }
            if ($disclosure) {
                $details = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                    [System.Windows.Automation.PropertyCondition]::new(
                        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $disclosure))
                if ($details) {
                    $details.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
                    $element = Wait-UiRegressionState -Description "disclosed history control '$Value'" -Condition {
                        $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $historyCondition)
                    }
                }
            }
        }
    }
    finally { Complete-UiRegressionCall $call }
    if (-not $element -and -not $Optional) { throw "Missing scan-history control '$Value'." }
    return $element
}

function Wait-HistoryState([scriptblock] $Predicate, [string] $Description) {
    $call = Start-UiRegressionCall wait
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        do {
            if (& $Predicate) { return }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)
        throw "Timed out waiting for $Description."
    }
    finally { Complete-UiRegressionCall $call }
}

function Start-HistoryApp {
    $call = Start-UiRegressionCall launch
    try {
        $script:process = Start-Process -FilePath $AppPath -PassThru
        Wait-HistoryState {
            $script:process.Refresh()
            if ($script:process.HasExited) { throw "Scan-history app exited: $($script:process.ExitCode)." }
            $script:process.MainWindowHandle -ne [IntPtr]::Zero
        } "scan-history app window"
        Initialize-UiReviewWindow $script:process.MainWindowHandle
        $script:root = [System.Windows.Automation.AutomationElement]::FromHandle($script:process.MainWindowHandle)
        Wait-HistoryState { Find-HistoryControl DevicesNavItem -Optional } "device navigation"
        Start-Sleep -Milliseconds 500
    }
    finally { Complete-UiRegressionCall $call }
}

function Stop-HistoryApp {
    $call = Start-UiRegressionCall close
    try {
        if ($script:process -and -not $script:process.HasExited) {
            $null = $script:process.CloseMainWindow()
            if (-not $script:process.WaitForExit(5000)) {
                Stop-Process -Id $script:process.Id -Force
                throw "Scan-history app did not close normally."
            }
        }
    }
    finally { Complete-UiRegressionCall $call }
}

function Select-HistoryDevices {
    $back = Find-HistoryControl "Back to devices" -ByName -Optional
    if ($back -and -not $back.Current.IsOffscreen) {
        $back.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    }
    else {
        (Find-HistoryControl DevicesNavItem).GetCurrentPattern(
            [System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    }
    Wait-HistoryState {
        $list = Find-HistoryControl ResultsList -Optional
        $list -and -not $list.Current.IsOffscreen
    } "device list"
}

function Find-HistoryDeviceRow([string] $Name) {
    Select-HistoryDevices
    $search = (Find-HistoryControl "Search devices" -ByName).GetCurrentPattern(
        [System.Windows.Automation.ValuePattern]::Pattern)
    if ($search.Current.Value -cne $Name) {
        $search.SetValue($Name)
        Start-Sleep -Milliseconds 300
    }
    $rowCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::ListItem)
    $nameCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "DeviceNameText")
    return Wait-UiRegressionState -Description "exactly one visible history device matching '$Name'" -Condition {
        $list = Find-HistoryControl ResultsList -Optional
        if (-not (Test-UiRegressionElementVisible $list)) { return $null }
        $rows = $list.FindAll([System.Windows.Automation.TreeScope]::Children, $rowCondition)
        if ($rows.Count -ne 1) { return $null }
        $nameCell = $rows[0].FindFirst([System.Windows.Automation.TreeScope]::Descendants, $nameCondition)
        if ((Test-UiRegressionElementVisible $rows[0]) -and $nameCell -and $nameCell.Current.Name -ceq $Name) {
            return $rows[0]
        }
    }
}

function Get-HistoryLastSeenCell([string] $Name, [switch] $Rendered) {
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "DeviceLastSeenText")
    $cell = (Find-HistoryDeviceRow $Name).FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if (-not $cell) { throw "Devices row '$Name' lacks a Last seen value." }
    if ($Rendered) {
        return $cell.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(-1)
    }
    return $cell.Current.Name
}

function Assert-HistoryLastSeenCell([string] $Name, [string] $Expected) {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $actual = Get-HistoryLastSeenCell $Name
        if ($actual -like $Expected) { return $actual }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Devices Last seen for '$Name' is '$actual', expected '$Expected'."
}

# Visible text is a compact relative age; a clock earlier than the fixture shows its local time instead.
function Assert-HistoryLastSeenAge([string] $Name, [int] $Index) {
    $rendered = Get-HistoryLastSeenCell $Name -Rendered
    $local = (Get-HistoryLocalTime $Index).ToString("yyyy-MM-dd HH:mm", [Globalization.CultureInfo]::InvariantCulture)
    if ($rendered -cnotmatch '^(< 1 min\. ago|\d+ min\. ago|\d+ h ago|\d+ (day|month|year)s? ago)$' -and $rendered -cne $local) {
        throw "Devices Last seen for '$Name' must render a relative age, not '$rendered'."
    }
}

function Get-HistoryExactTime([int] $Index) {
    return (Get-HistoryLocalTime $Index).ToString("yyyy-MM-dd HH:mm:ss zzz", [Globalization.CultureInfo]::InvariantCulture)
}

function Open-HistoryDetails([string] $Name) {
    $row = Find-HistoryDeviceRow $Name
    $row.SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
    Wait-HistoryState {
        $scroll = Find-HistoryControl DeviceDetailsScroll -Optional
        $scroll -and -not $scroll.Current.IsOffscreen
    } "details for $Name"
    $overview = (Find-HistoryControl DeviceOverviewTab).GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    if (-not $overview.Current.IsSelected -or (Find-HistoryControl DeviceHistoryScope -Optional -NoTabSwitch)) {
        throw "Opening a device must start on its Overview tab."
    }
    foreach ($id in @("DeviceImportedMetadata")) {
        $pattern = (Find-HistoryControl $id).GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
        if ($pattern.Current.ExpandCollapseState -ne [System.Windows.Automation.ExpandCollapseState]::Collapsed) {
            throw "$id must start collapsed on opening a device."
        }
        if ($SummaryOnly) { return }
    }
    $expander = Find-HistoryControl DeviceScanHistoryExpander
    Wait-HistoryState {
        (Find-HistoryControl DeviceScanHistoryExpander).GetCurrentPattern(
            [System.Windows.Automation.ExpandCollapsePattern]::Pattern).Current.ExpandCollapseState -eq
                [System.Windows.Automation.ExpandCollapseState]::Expanded
    } "completed observations immediately expanded"
}

function Test-HistoryTabs {
    $pageStatus = (Find-HistoryControl DeviceHistoryPageStatus).Current.Name
    $null = Select-UiRegressionDeviceTab -Root $script:root -Tab Overview -Keyboard
    $edit = Find-HistoryControl "Edit device identification" -ByName
    $edit.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-HistoryState { -not $edit.Current.IsEnabled } "identification editor"
    $draft = "Tab draft model"
    (Find-HistoryControl DeviceModelInput).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($draft)
    $null = Select-UiRegressionDeviceTab -Root $script:root -Tab History -Keyboard
    if ((Find-HistoryControl DeviceHistoryPageStatus).Current.Name -cne $pageStatus) {
        throw "Switching tabs changed the observation page."
    }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "history-tab-retained-page.png")
    $null = Select-UiRegressionDeviceTab -Root $script:root -Tab Overview -Keyboard
    $model = (Find-HistoryControl DeviceModelInput).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value
    if ($model -cne $draft -or (Find-HistoryControl "Edit device identification" -ByName).Current.IsEnabled) {
        throw "Switching tabs discarded the identification draft ('$model')."
    }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "history-tab-retained-draft.png")
    (Find-HistoryControl DeviceClassificationCancelButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-HistoryState { (Find-HistoryControl "Edit device identification" -ByName).Current.IsEnabled } "cancelled identification draft"
    $link = Show-HistorySection DeviceViewHistory
    $link.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-HistoryState {
        $tab = Find-HistoryControl DeviceHistoryTab -NoTabSwitch
        $tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected -and
            [System.Windows.Automation.AutomationElement]::FocusedElement.Current.AutomationId -eq "DeviceHistoryTab"
    } "View history selecting and focusing the History tab"
    if ((Find-HistoryControl DeviceHistoryPageStatus -NoTabSwitch).Current.Name -cne $pageStatus) {
        throw "View history changed the observation page."
    }
}

function Get-HistoryLocalTime([int] $Index) {
    return ([DateTimeOffset]::Parse("2026-11-01T12:0${Index}:00+00:00")).ToLocalTime()
}

function Get-HistoryTimestamp([int] $Index) {
    return (Get-HistoryLocalTime $Index).ToString("yyyy-MM-dd HH:mm:ss '(local)'", [Globalization.CultureInfo]::InvariantCulture)
}

function Get-FriendlyHistoryTime([DateTimeOffset] $Time) {
    $local = $Time.ToLocalTime()
    $days = ([DateTime]::Today - $local.Date).Days
    $date = if ($days -eq 0) { "Today" } elseif ($days -eq 1) { "Yesterday" }
        elseif ($days -gt 1) { "$days days ago" } else { $local.ToString("d MMM yyyy") }
    "$date, $($local.ToString('h:mm tt'))$(if ($Time -gt [DateTimeOffset]::UtcNow) { ' (future timestamp)' })"
}

function Wait-HistoryPage([int] $Page, [int] $After = 0, [string] $State = "Ready") {
    Wait-UiRegressionSurfaceState -GetElement { Find-HistoryControl DeviceScanHistoryExpander -Optional } `
        -Description "Completed observations" -Selection "Page $Page" -State $State -After $After
}

function Move-HistoryPage([string] $Id, [int] $Page, [switch] $Keyboard, [string] $State = "Ready") {
    $before = (Get-UiRegressionSurfaceState -GetElement { Find-HistoryControl DeviceScanHistoryExpander } `
        -Description "Completed observations").Request
    $button = Show-HistorySection $Id
    if ($Keyboard) {
        $button.SetFocus()
        [System.Windows.Forms.SendKeys]::SendWait(" ")
    }
    else { $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
    $null = Wait-HistoryPage $Page $before $State
}

function Assert-HistoryPage([int] $PageIndex, [switch] $Traverse) {
    $start = 100 * $PageIndex
    $count = [Math]::Min(100, 205 - $start)
    if ((Find-HistoryControl DeviceHistoryPageStatus).Current.Name -notlike "Showing $($start + 1)-$($start + $count) of 205.*" -or
        (Find-HistoryControl DeviceScanHistoryCount).Current.Name -ne "205 completed scan observations") {
        throw "Incorrect scoped count/range on observation page $PageIndex."
    }
    $list = Show-HistorySection DeviceScanHistoryList
    $pageViewport = Find-HistoryControl DeviceDetailsScroll
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::DataItem)
    $items = $list.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if ($items.Count -ne $count) { throw "Expected $count bounded rows, got $($items.Count)." }
    $rowHeight = ($items | ForEach-Object { $_.Current.BoundingRectangle.Height } | Measure-Object -Maximum).Maximum
    if ($rowHeight -le 0) { throw "The observation page has no rendered row geometry." }
    $labels = @()
    for ($index = 0; $index -lt $count; $index++) {
        $second = 204 - $start - $index
        $time = ([DateTimeOffset]::Parse("2026-11-01T12:00:00Z").AddSeconds($second)).ToLocalTime()
        $state = if ($second % 4 -lt 2) { "present" } else { "absent" }
        $expected = "$($time.ToString('yyyy-MM-dd HH:mm:ss zzz')); Observed $state"
        $item = $items[$index]
        if ($item.Current.Name -cne $expected) { throw "Wrong row/order/state on page ${PageIndex}: '$($item.Current.Name)', expected '$expected'." }
        if ($Traverse) {
            $item.GetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()
            $null = Wait-UiRegressionState -Description "physically visible observation '$expected'" -Condition {
                if ($item.Current.BoundingRectangle.Height -ge $rowHeight - 1 -and
                    (Test-UiRegressionElementWithin $item $list $script:root) -and
                    (Test-UiRegressionElementWithin $item $pageViewport $script:root)) { return $true }
            }
        }
        $labels += $expected
    }
    return $labels
}

function Assert-HistoryScrollMovement {
    $list = Show-HistorySection DeviceScanHistoryList
    $items = $list.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::DataItem))
    $scroll = $list.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    if (-not $scroll.Current.VerticallyScrollable) { throw "The 100-row page must be scrollable." }
    $scroll.SetScrollPercent(-1, 0)
    $firstVisible = {
        for ($index = 0; $index -lt $items.Count; $index++) {
            $bounds = $items[$index].Current.BoundingRectangle
            $viewport = $list.Current.BoundingRectangle
            if (-not $bounds.IsEmpty -and $bounds.Height -gt 0 -and $bounds.Width -gt 0 -and
                -not $items[$index].Current.IsOffscreen -and
                $bounds.Top -ge $viewport.Top -and $bounds.Bottom -le $viewport.Bottom) {
                return [pscustomobject]@{
                    Index = $index; Label = $items[$index].Current.Name
                    Top = $bounds.Top; Bottom = $bounds.Bottom
                }
            }
        }
    }
    $before = Wait-UiRegressionState -Condition $firstVisible -Description "first visible history row"
    foreach ($amount in @("LargeIncrement", "LargeIncrement", "LargeIncrement", "SmallDecrement", "LargeIncrement")) {
        Write-Host "History $amount before: row $($before.Index), bounds $($before.Top)-$($before.Bottom), scroll $($scroll.Current.VerticalScrollPercent)%."
        $scroll.Scroll([System.Windows.Automation.ScrollAmount]::NoAmount,
            [System.Windows.Automation.ScrollAmount]::$amount)
        $after = Wait-UiRegressionState -Description "$amount to move actual visible rows without snap-back" -Condition {
            $current = & $firstVisible
            if ($current -and $(if ($amount -eq "SmallDecrement") {
                    $current.Index -lt $before.Index -or ($current.Index -eq $before.Index -and
                        ($current.Top -gt $before.Top -or $current.Bottom -gt $before.Bottom))
                }
                else {
                    $current.Index -gt $before.Index -or ($current.Index -eq $before.Index -and
                        ($current.Top -lt $before.Top -or $current.Bottom -lt $before.Bottom))
                })) { return $current }
        }
        Write-Host "History $amount moved row $($before.Index) at $($before.Top)-$($before.Bottom) '$($before.Label)' -> $($after.Index) at $($after.Top)-$($after.Bottom) '$($after.Label)'."
        $before = $after
    }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "history-scroll-movement.png")
    $scroll.SetScrollPercent(-1, 0)
}

function Show-HistorySection([string] $Id, [int] $TopMargin = 35, [string[]] $AdditionalIds = @()) {
    $ids = @($Id) + $AdditionalIds
    $call = Start-UiRegressionCall positioning
    try {
        $target = Find-HistoryControl $Id
        $scrollItem = $null
        if ($AdditionalIds.Count -eq 0 -and ($target.Current.IsKeyboardFocusable -or
            $target.TryGetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern, [ref] $scrollItem))) {
            if ($target.Current.IsKeyboardFocusable) { $target.SetFocus() }
            if ($scrollItem -or $target.TryGetCurrentPattern(
                [System.Windows.Automation.ScrollItemPattern]::Pattern, [ref] $scrollItem)) { $scrollItem.ScrollIntoView() }
            $script:historySectionBounds = $null
            return Wait-UiRegressionState -Description "visible history section '$Id'" -Condition {
                $current = Find-HistoryControl $Id -Optional
                if (-not (Test-UiRegressionElementWithin $current (Find-HistoryControl DeviceDetailsScroll) $script:root)) {
                    $null = Show-UiRegressionScrollTargets -Description "Scan-history section '$Id'" -TopMargin $TopMargin -BottomMargin 10 `
                        -GetViewport { Find-HistoryControl DeviceDetailsScroll } -GetWindow { $script:root } `
                        -GetTargets { Find-HistoryControl $Id }
                    $script:historySectionBounds = $null
                    return
                }
                # Expander and tab layout can still be moving; require the same position on consecutive polls.
                $bounds = $current.Current.BoundingRectangle
                $stable = $bounds -eq $script:historySectionBounds
                $script:historySectionBounds = $bounds
                if ($stable) { return $current }
            }
        }
        Show-UiRegressionScrollTargets -Description "Scan-history section '$Id'" -TopMargin $TopMargin -BottomMargin 10 `
            -GetViewport { Find-HistoryControl DeviceDetailsScroll } -GetWindow { $script:root } `
            -GetTargets { $ids | ForEach-Object { Find-HistoryControl $_ } }
    }
    finally { Complete-UiRegressionCall $call }
}

function Assert-HistoryRows([string] $Capture, [int] $LastIndex = 4) {
    $count = $LastIndex + 1
    if ((Find-HistoryControl DeviceScanHistoryCount).Current.Name -ne "$count completed scan observations") {
        throw "Expected $count individual completed scans; got '$((Find-HistoryControl DeviceScanHistoryCount).Current.Name)' in '$((Find-HistoryControl DeviceHistoryScope).Current.Name)'."
    }
    $list = Show-HistorySection DeviceScanHistoryList
    $positioned = "list $($list.Current.BoundingRectangle) in page $((Find-HistoryControl DeviceDetailsScroll).Current.BoundingRectangle)"
    $scroll = $list.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    $seen = @{}
    $itemCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::DataItem)
    $textCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Text)
    foreach ($percent in @(0, 50, 100)) {
        if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, $percent) }
        Start-Sleep -Milliseconds 100
        $times = @()
        foreach ($item in $list.FindAll([System.Windows.Automation.TreeScope]::Descendants, $itemCondition)) {
            if (-not (Test-UiRegressionElementWithin $item $list $script:root)) {
                # Bounds are clipped to the visible area; rows below the page edge bring themselves into view.
                $rowScroll = $null
                if (-not $item.TryGetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern, [ref] $rowScroll)) { continue }
                $rowScroll.ScrollIntoView()
                Start-Sleep -Milliseconds 150
                if (-not (Test-UiRegressionElementWithin $item $list $script:root)) { continue }
            }
            $texts = @($item.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCondition) |
                ForEach-Object { $_.Current.Name })
            if ($texts.Count -eq 0) { continue }
            if ($texts.Count -ne 2) { throw "Each scan row must expose friendly When and Result: $texts." }
            $matching = @(0..$LastIndex | Where-Object { $item.Current.Name.StartsWith((Get-HistoryExactTime $_) + ";") })
            if ($matching.Count -ne 1) { throw "Unexpected exact scan timestamp '$($item.Current.Name)'." }
            $time = (Get-HistoryLocalTime $matching[0]).ToString("yyyy-MM-dd HH:mm:ss")
            $state = if ($matching[0] -in @(2, 3)) { "Absent" } else { "Present" }
            $result = if ($state -eq "Present") { "Responded" } else { "Scanned, no response" }
            if ($texts[1] -ne $result -or $texts[0] -ne (Get-FriendlyHistoryTime (Get-HistoryLocalTime $matching[0]))) {
                throw "Incorrect scan observation: $texts."
            }
            $label = "$((Get-HistoryLocalTime $matching[0]).ToString('yyyy-MM-dd HH:mm:ss zzz')); Observed $($state.ToLowerInvariant())"
            if ($item.Current.Name -ne $label) {
                throw "Scan row lacks an accessible full timestamp with UTC offset and observed state."
            }
            $seen[$time] = $true
            $times += $time
        }
        if (($times -join "|") -ne (($times | Sort-Object -Descending) -join "|")) {
            throw "Scan rows are not newest first: $times."
        }
    }
    if ($seen.Count -ne $count) {
        throw "Not all $count scans are reachable in the native history list; saw $($seen.Keys -join ', '). Positioned $positioned; finally list $($list.Current.BoundingRectangle)."
    }
    foreach ($index in 0..$LastIndex) {
        if (-not $seen.ContainsKey((Get-HistoryLocalTime $index).ToString("yyyy-MM-dd HH:mm:ss"))) {
            throw "Scan $index is missing from history."
        }
    }
    if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, 0) }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "$Capture.png")
}

function Assert-HistoryTableRendering([string] $Capture) {
    $list = Show-HistorySection DeviceScanHistoryList 85
    $headers = @("When (local)", "Result") | ForEach-Object { Find-HistoryControl $_ -ByName }
    $items = $list.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::DataItem))
    $path = Join-Path $ScreenshotDirectory "$Capture.png"
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle $path
    $window = Get-UiReviewWindowBounds $script:process.MainWindowHandle
    $bitmap = [System.Drawing.Bitmap]::FromFile($path)
    try {
        $stripeColors = @()
        $states = @{}
        # Bounds are clipped to the visible area; only rows at full height have their whole status dot rendered.
        $fullHeight = ($items | ForEach-Object { $_.Current.BoundingRectangle.Height } | Measure-Object -Maximum).Maximum
        foreach ($item in $items) {
            if ($item.Current.IsOffscreen -or $item.Current.BoundingRectangle.Height -lt $fullHeight - 1) { continue }
            $texts = $item.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [System.Windows.Automation.ControlType]::Text))
            if ($texts.Count -ne 2) { throw "Rendered table row must expose two columns." }
            for ($column = 0; $column -lt 2; $column++) {
                $bounds = $texts[$column].Current.BoundingRectangle
                $header = $headers[$column].Current.BoundingRectangle
                $expectedLeft = $header.Left + $(if ($column -eq 1) { 18 * [UiReviewNativeWindow]::GetDpiForWindow($script:process.MainWindowHandle) / 96 } else { 0 })
                if ([Math]::Abs($bounds.Left - $expectedLeft) -gt 3 -or $bounds.Right -gt $header.Right + 3) {
                    throw "Column $column is misaligned/clipped relative to its header: $bounds / $header."
                }
            }
            $row = $item.Current.BoundingRectangle
            $stripeColors += $bitmap.GetPixel([int]($row.Left - $window.Left + 3), [int]($row.Top - $window.Top + 3)).ToArgb()
            $status = $texts[1].Current.BoundingRectangle
            $green = 0
            $red = 0
            for ($x = [int]($status.Left - $window.Left - 20); $x -lt $status.Left - $window.Left; $x++) {
                for ($y = [int]($status.Top - $window.Top); $y -lt $status.Bottom - $window.Top; $y++) {
                    $pixel = $bitmap.GetPixel($x, $y)
                    if ($pixel.G -gt $pixel.R + 20 -and $pixel.G -gt $pixel.B + 10) { $green++ }
                    if ($pixel.R -gt $pixel.G + 20 -and $pixel.R -gt $pixel.B + 10) { $red++ }
                }
            }
            $state = $texts[1].Current.Name
            if (($state -eq "Responded" -and $green -lt 20) -or ($state -eq "Scanned, no response" -and $red -lt 20)) {
                throw "$state row lacks its rendered green/red status dot."
            }
            $states[$state] = $true
        }
        if (($stripeColors | Select-Object -Unique).Count -lt 2) { throw "History rows lack visible zebra stripes." }
        if ($states.Count -ne 2) { throw "Rendering evidence must include both present and absent rows." }
    }
    finally { $bitmap.Dispose() }
}

function Assert-HistorySummary([string] $Capture, [int] $LastIndex = 4) {
    $lastSeen = @(0, 1, 1, 1, 4)[$LastIndex]
    $since = @(0, 0, 2, 2, 4)[$LastIndex]
    $state = if ($LastIndex -in @(2, 3)) { "offline" } else { "online" }
    $expected = @{
        DeviceHistorySummaryScope = "Current network: ui-review-network | 127.0.0.1/32"
        DeviceHistoryFirstSeen = "First seen: $(Get-FriendlyHistoryTime (Get-HistoryLocalTime 0))"
        DeviceHistoryLastSeen = "Last seen: $(Get-FriendlyHistoryTime (Get-HistoryLocalTime $lastSeen))"
        DeviceHistorySince = "Latest recorded $(if ($state -eq 'online') { 'responding' } else { 'nonresponding' }) run started: $(Get-HistoryTimestamp $since)"
        DeviceHistoryState = "Last recorded state: $(if ($state -eq 'online') { 'Responded' } else { 'Scanned, no response' })"
    }
    if (-not $SummaryOnly) {
        $expected.DeviceHistoryScope = $expected.DeviceHistorySummaryScope
        $expected.DeviceHistoryLatest = "Latest recorded scan: $(Get-HistoryTimestamp $LastIndex). Saved observations do not establish current live presence."
    }
    foreach ($id in $expected.Keys) {
        $actual = (Find-HistoryControl $id).Current.Name
        if ($actual -ne $expected[$id]) { throw "Incorrect summary $id : '$actual', expected '$($expected[$id])'." }
    }
    $expansion = $null
    if (-not $SummaryOnly) {
        $expansion = (Find-HistoryControl DeviceScanHistoryExpander).GetCurrentPattern(
            [System.Windows.Automation.ExpandCollapsePattern]::Pattern)
        $expansion.Collapse()
    }
    foreach ($id in @("DeviceHistoryFirstSeen", "DeviceHistoryLastSeen", "DeviceHistorySince")) {
        $element = Show-HistorySection $id
        $area = (Find-HistoryControl DeviceDetailsScroll).Current.BoundingRectangle
        $bounds = $element.Current.BoundingRectangle
        if ($element.Current.IsOffscreen -or $bounds.Top -lt $area.Top -or $bounds.Bottom -gt $area.Bottom) {
            Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "$Capture-clipped.png")
            throw "Summary field $id is clipped: bounds=$bounds; viewport=$area."
        }
    }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "$Capture-summary.png")
    if ($expansion) {
        # The expander lives on the History tab, so re-resolve it after the Overview summary was shown.
        (Find-HistoryControl DeviceScanHistoryExpander).GetCurrentPattern(
            [System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    }
}

function Invoke-HistoryScan {
    Select-HistoryDevices
    (Find-HistoryControl "Search devices" -ByName).GetCurrentPattern(
        [System.Windows.Automation.ValuePattern]::Pattern).SetValue("")
    (Find-HistoryControl "Scan LAN" -ByName).GetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 200
}

function Wait-HistoryScan {
    Wait-HistoryState {
        $scan = Find-HistoryControl "Scan LAN" -ByName -Optional
        $scan -and -not $scan.Current.IsOffscreen -and $scan.Current.IsEnabled
    } "completed or stopped scan"
}

$previous = @{}
foreach ($key in @("FINGVIBE_UI_REVIEW", "FINGVIBE_UI_REVIEW_INVENTORY", "FINGVIBE_UI_REVIEW_SNAPSHOT",
    "FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT", "FINGVIBE_UI_REVIEW_SCAN_HOLD", "FINGVIBE_UI_REVIEW_NETWORK")) {
    $previous[$key] = [Environment]::GetEnvironmentVariable($key)
}
$fixtureDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "fingvibe-history-ui-$([Guid]::NewGuid().ToString('N'))"
$inventory = Join-Path $fixtureDirectory "inventory.json"
$database = [System.IO.Path]::ChangeExtension($inventory, ".sqlite")
$snapshot = Join-Path $fixtureDirectory "snapshot.json"
$hold = Join-Path $fixtureDirectory "scan.hold"
$script:process = $null
$lock = $null
$contrast = $null
$phase = $null
$failed = $false
try {
    $null = New-Item -ItemType Directory -Path $fixtureDirectory
    $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
    $phase = Step-UiRegressionPhase $phase "history/fixture" $ScreenshotDirectory
    $history = @(0..4 | ForEach-Object {
        @{ completedAt = "2026-11-01T12:0${_}:00+00:00"; networkId = "ui-review-network"
           subnet = "127.0.0.1/32"; present = ($_ -notin @(2, 3)) }
    })
    function New-HistoryObservation([string] $Address, [bool] $Present, [string] $Vendor) {
        @{ networkId = "ui-review-network"; subnet = "127.0.0.1/32"; address = $Address
           hostname = $null; vendor = $Vendor; ports = @(); latency = 1; probeDuration = "00:00:00.001"
           classification = @{ type = 0; operatingSystem = 0; typeEvidence = "Synthetic fixture"; operatingSystemEvidence = "Synthetic fixture" }
           firstSeen = "2026-11-01T12:00:00+00:00"; lastSeen = "2026-11-01T12:04:00+00:00"
           lastChecked = "2026-11-01T12:04:00+00:00"; present = $Present }
    }
    $old = New-HistoryObservation "127.0.0.1" $false "Private"
    $current = New-HistoryObservation "127.0.0.1" $true "Private"
    $normal = New-HistoryObservation "127.0.0.1" $true "Example"
    $legacy = New-HistoryObservation "127.0.0.1" $true "Example"
    $unmatched = New-HistoryObservation "127.0.0.1" $true "Example"
    $unmatched.networkId = "another-network"
    $decoyHistory = @(
        @{ completedAt = "2026-10-01T12:00:00+00:00"; networkId = "another-network"; subnet = "127.0.0.1/32"; present = $true },
        @{ completedAt = "2026-11-02T12:00:00+00:00"; networkId = "ui-review-network"; subnet = "192.0.2.0/24"; present = $false }
    )
    $data = @{
        revision = [Guid]::NewGuid().ToString()
        devices = @{
            "020000000001" = @{ mac = "020000000001"; imported = @{ name = "History normal" }
                observations = @($normal, $unmatched); scanHistory = $history + $decoyHistory }
            "D0C907000001" = @{ mac = "D0C907000001"; imported = @{}; observations = @($old); scanHistory = @() }
            "D0C907000002" = @{ mac = "D0C907000002"; imported = @{}; observations = @($current); scanHistory = @() }
            "001122334466" = @{ mac = "001122334466"; imported = @{ name = "History imported" }; observations = @(); scanHistory = @() }
            "001122334477" = @{ mac = "001122334477"; imported = @{ name = "History legacy" }; observations = @($legacy); scanHistory = @() }
            "001122334488" = @{ mac = "001122334488"; imported = @{ name = "History unmatched" }; observations = @($unmatched); scanHistory = $decoyHistory }
        }
        names = @{}; classifications = @{}; peopleRooms = @{ people = @(); rooms = @(); assignments = @{} }
        virtualDevices = @(@{
            id = [Guid]::NewGuid().ToString(); networkId = "ui-review-network"; subnet = "127.0.0.1/32"
            prefix = "D0C907"; number = 1; lastActiveMac = "D0C907000002"; lastChecked = "2026-11-01T12:04:00+00:00"
            present = $true; name = "History virtual"; scanHistory = $history
            history = @(@{ mac = "D0C907000001"; observation = $old; inferred = $true },
                @{ mac = "D0C907000002"; observation = $current; inferred = $true })
        })
    }
    @{ version = 3; subnet = "127.0.0.1/32"; completedAt = "2026-11-01T12:04:00+00:00"; results = @() } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $snapshot -Encoding UTF8
    $env:FINGVIBE_UI_REVIEW = "1"
    $env:FINGVIBE_UI_REVIEW_INVENTORY = $inventory
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = $snapshot
    $env:FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT = "0"
    $env:FINGVIBE_UI_REVIEW_NETWORK = "ui-review-network"
    $env:FINGVIBE_UI_REVIEW_SCAN_HOLD = $hold
    $phase = Step-UiRegressionPhase $phase "history/summary-cases" $ScreenshotDirectory
    foreach ($index in 0..4) {
        $lastSeen = @(0, 1, 1, 1, 4)[$index]
        $present = $index -notin @(2, 3)
        $time = "2026-11-01T12:0${index}:00+00:00"
        $normal.lastSeen = "2026-11-01T12:0${lastSeen}:00+00:00"
        $normal.lastChecked = $time
        $normal.present = $present
        $old.lastSeen = "2026-11-01T12:00:00+00:00"
        $old.lastChecked = $time
        $old.present = $index -eq 0
        $current.firstSeen = "2026-11-01T12:01:00+00:00"
        $current.lastSeen = "2026-11-01T12:0$([Math]::Max(1, $lastSeen)):00+00:00"
        $current.lastChecked = "2026-11-01T12:0$([Math]::Max(1, $index)):00+00:00"
        $current.present = $present -and $index -gt 0
        $slot = $data.virtualDevices[0]
        $slot.lastActiveMac = if ($index -eq 0) { "D0C907000001" } else { "D0C907000002" }
        $slot.lastChecked = $time
        $slot.present = $present
        $slot.history = @(@{ mac = "D0C907000001"; observation = $old; inferred = $true })
        if ($index -gt 0) { $slot.history += @{ mac = "D0C907000002"; observation = $current; inferred = $true } }
        $slot.scanHistory = @($history[0..$index])
        $data.devices.'020000000001'.scanHistory = @($history[0..$index]) + $decoyHistory
        @{ version = 3; data = $data } | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $inventory -Encoding UTF8
        if (Test-Path -LiteralPath $database) { Remove-Item -LiteralPath $database }
        Start-HistoryApp
        foreach ($kind in @("normal", "virtual")) {
            if (-not $ObservationsOnly) {
                $null = Assert-HistoryLastSeenCell "History $kind" "Last seen: $(Get-HistoryExactTime $lastSeen)"
                Assert-HistoryLastSeenAge "History $kind" $lastSeen
            }
            Open-HistoryDetails "History $kind"
            if (-not $ObservationsOnly) { Assert-HistorySummary "history-$kind-$index" $index }
            if (-not $SummaryOnly) { Assert-HistoryRows "history-$kind-$index" $index }
        }
        Stop-HistoryApp
    }
    $phase = Step-UiRegressionPhase $phase "history/provenance-and-scope" $ScreenshotDirectory
    $original = Get-Content -LiteralPath $inventory -Raw
    $originalDatabase = Get-InventoryFingerprint $database
    Start-HistoryApp
    $null = Assert-HistoryLastSeenCell "History legacy" `
        "Last seen: $(Get-HistoryExactTime 4) (historical aggregate; individual scan unavailable)"
    Assert-HistoryLastSeenAge "History legacy" 4
    $null = Assert-HistoryLastSeenCell "History unmatched" `
        "Last seen: Unavailable - no matching local presence evidence for the current network/subnet."
    if ((Get-HistoryLastSeenCell "History unmatched" -Rendered) -cne "Unavailable") { throw "Missing evidence must stay Unavailable." }
    $null = Assert-HistoryLastSeenCell "History imported" `
        "Last seen: Never - not observed by a local scan.*not mean the device was never present on any network."
    if ((Get-HistoryLastSeenCell "History imported" -Rendered) -cne "Never") { throw "Imported-only devices must render Never." }
    Open-HistoryDetails "History legacy"
    foreach ($id in @("DeviceHistoryFirstSeen", "DeviceHistoryLastSeen")) {
        if ((Find-HistoryControl $id).Current.Name -notlike "*Historical aggregate*") {
            throw "Legacy timestamps must retain their aggregate provenance."
        }
    }
    if ((Find-HistoryControl DeviceHistorySince).Current.Name -notlike "*Unavailable*") { throw "Legacy aggregates fabricated since." }
    $null = Show-HistorySection DeviceHistoryFirstSeen
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "history-legacy-summary.png")
    Open-HistoryDetails "History unmatched"
    foreach ($id in @("DeviceHistoryFirstSeen", "DeviceHistoryLastSeen", "DeviceHistorySince")) {
        if ((Find-HistoryControl $id).Current.Name -notlike "*Unavailable*") { throw "Other-network/subnet evidence leaked into $id." }
    }
    if (-not $SummaryOnly -and (Find-HistoryControl DeviceScanHistoryCount).Current.Name -ne "0 completed scan observations") { throw "Other-scope history leaked." }
    Open-HistoryDetails "History imported"
    foreach ($id in @("DeviceHistoryFirstSeen", "DeviceHistoryLastSeen", "DeviceHistorySince")) {
        if ((Find-HistoryControl $id).Current.Name -notlike "*Unavailable*") { throw "Imported-only history fabricated $id." }
    }
    if (-not $SummaryOnly) {
        $empty = Show-HistorySection DeviceScanHistoryEmpty
        if ($empty.Current.Name -ne "No local scan history. Imported Fing data is not a local scan observation.") {
            throw "Imported-only history needs an explanatory empty state."
        }
    }
    else { $null = Show-HistorySection DeviceHistoryFirstSeen }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "history-imported.png")
    Stop-HistoryApp
    $phase = Step-UiRegressionPhase $phase "history/restart-and-appearance" $ScreenshotDirectory
    Start-HistoryApp
    Open-HistoryDetails "History normal"
    Assert-HistorySummary "history-restarted"
    if (-not $SummaryOnly) { Assert-HistoryRows "history-restarted" }
    foreach ($theme in @("Standard Light", "Standard Dark")) {
        $condition = [System.Windows.Automation.AndCondition]::new(
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, "Settings"),
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::ListItem))
        $settings = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if (-not $settings) { throw "Settings navigation was not found." }
        $settings.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        Wait-HistoryState {
            $picker = Find-HistoryControl ModePicker -Optional
            $picker -and -not $picker.Current.IsOffscreen
        } "appearance settings"
        Set-UiReviewTheme -Root $script:root -Theme $theme
        Open-HistoryDetails "History normal"
        $label = $theme.Replace(" ", "-").ToLowerInvariant()
        if (-not $SummaryOnly) { Assert-HistoryTableRendering "history-table-$label" }
        else { Assert-HistorySummary "history-$label" }
        $bounds = Get-UiReviewWindowBounds $script:process.MainWindowHandle
        if (-not [UiReviewNativeWindow]::SetWindowPos($script:process.MainWindowHandle, [IntPtr]::Zero,
            $bounds.Left, $bounds.Top, 640, $bounds.Height, 0x0044)) { throw "Cannot resize history review window." }
        Start-Sleep -Milliseconds 500
        if (-not $SummaryOnly) {
            Assert-HistoryTableRendering "history-table-$label-narrow"
            (Find-HistoryControl DeviceScanHistoryExpander).GetCurrentPattern(
                [System.Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse()
        }
        else { Assert-HistorySummary "history-$label-narrow" }
        $null = Show-HistorySection DeviceHistoryFirstSeen
        Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "history-summary-$label-narrow.png")
        $null = [UiReviewNativeWindow]::SetWindowPos($script:process.MainWindowHandle, [IntPtr]::Zero,
            $bounds.Left, $bounds.Top, $bounds.Width, $bounds.Height, 0x0044)
        Start-Sleep -Milliseconds 500
    }
    if (-not $SummaryOnly) {
        $contrast = [HistoryReviewContrast]::Get()
        [HistoryReviewContrast]::Set($contrast -bor 1)
        Start-Sleep -Seconds 2
        if (([HistoryReviewContrast]::Get() -band 1) -eq 0) { throw "High contrast did not activate." }
        Open-HistoryDetails "History normal"
        Assert-HistoryRows "history-high-contrast"
        [HistoryReviewContrast]::Set($contrast)
        $contrast = $null
    }
    $phase = Step-UiRegressionPhase $phase "history/scan-outcomes" $ScreenshotDirectory
    if (-not $ObservationsOnly) {
    Open-HistoryDetails "History virtual"
    Assert-HistorySummary "history-virtual-restarted"
    if ((Get-Content -LiteralPath $inventory -Raw) -cne $original) { throw "Restoration must not write new scan entries." }
    if ((Get-InventoryFingerprint $database) -cne $originalDatabase) { throw "Restoration changed SQLite history." }
    foreach ($count in @(8, 9)) {
        Invoke-HistoryScan
        Wait-HistoryScan
        if ((Get-InventorySqliteValue $database "SELECT COUNT(*) FROM scan_history WHERE kind='mac' AND id='020000000001'") -ne $count) {
            throw "Each successful repeated scan must persist one new observation."
        }
        if ((Get-InventorySqliteValue $database "SELECT COUNT(*) FROM scan_history WHERE kind='virtual'") -ne $count - 2) { throw "Same-network scan did not record virtual absence." }
    }
    $normalPresent = Get-InventorySqliteValue $database "SELECT present FROM scan_history WHERE kind='mac' AND id='020000000001' ORDER BY sequence DESC LIMIT 1"
    $expectedNormal = if ("$normalPresent" -eq "1") { "Last seen: Online - responded in the displayed scan (*)" } else { "Last seen: $(Get-HistoryExactTime 4)" }
    $beforeLastSeen = @{
        "History normal" = Assert-HistoryLastSeenCell "History normal" $expectedNormal
        "History virtual" = Assert-HistoryLastSeenCell "History virtual" "Last seen: $(Get-HistoryExactTime 4)"
    }
    if ("$normalPresent" -eq "1") {
        if ($beforeLastSeen["History normal"] -notmatch '^Last seen: Online - responded in the displayed scan \((.+)\)$') {
            throw "The completed response must expose its exact Last seen timestamp."
        }
        # A new scan removes fresh-response presentation, not the retained timestamp or Online status.
        $beforeLastSeen["History normal"] = "Last seen: $($Matches[1])"
    }
    $beforeStop = Get-InventoryFingerprint $database
    Open-HistoryDetails "History normal"
    $beforeSummary = @{}
    foreach ($id in @("DeviceHistoryFirstSeen", "DeviceHistoryLastSeen", "DeviceHistorySince", "DeviceHistoryLatest")) {
        $beforeSummary[$id] = (Find-HistoryControl $id).Current.Name
    }
    Set-Content -LiteralPath $hold -Value "hold for cancellation"
    Invoke-HistoryScan
    Wait-HistoryState { Find-HistoryControl "Cancel scan" -ByName -Optional } "cancel action"
    (Find-HistoryControl "Cancel scan" -ByName).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-HistoryScan
    if ((Get-InventoryFingerprint $database) -cne $beforeStop) { throw "Cancelled scan changed durable history." }
    Open-HistoryDetails "History normal"
    if (-not $SummaryOnly -and (Find-HistoryControl DeviceScanHistoryCount).Current.Name -ne "7 completed scan observations") {
        throw "Cancelled scan changed displayed history."
    }
    foreach ($id in $beforeSummary.Keys) {
        if ((Find-HistoryControl $id).Current.Name -ne $beforeSummary[$id]) { throw "Cancelled scan changed $id." }
    }
    foreach ($name in $beforeLastSeen.Keys) {
        if ((Get-HistoryLastSeenCell $name) -cne $beforeLastSeen[$name]) { throw "Cancelled scan changed Last seen for $name." }
    }
    @{ completed = -1; total = 1 } | ConvertTo-Json | Set-Content -LiteralPath "$hold.progress"
    Invoke-HistoryScan
    Wait-HistoryScan
    if ((Find-HistoryControl ScanStatusText).Current.Name -notlike "*UI-review progress fixture is invalid*") {
        throw "Failed scan must display its error."
    }
    if ((Get-InventoryFingerprint $database) -cne $beforeStop) { throw "Failed scan changed durable history." }
    Open-HistoryDetails "History normal"
    if (-not $SummaryOnly -and (Find-HistoryControl DeviceScanHistoryCount).Current.Name -ne "7 completed scan observations") {
        throw "Failed scan changed displayed history."
    }
    foreach ($id in $beforeSummary.Keys) {
        if ((Find-HistoryControl $id).Current.Name -ne $beforeSummary[$id]) { throw "Failed scan changed $id." }
    }
    foreach ($name in $beforeLastSeen.Keys) {
        if ((Get-HistoryLastSeenCell $name) -cne $beforeLastSeen[$name]) { throw "Failed scan changed Last seen for $name." }
    }
    Remove-Item -LiteralPath $hold, "$hold.progress"
    $lock = [System.IO.FileStream]::new("$inventory.lock", [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    Invoke-HistoryScan
    Wait-HistoryScan
    if ((Find-HistoryControl ScanStatusText).Current.Name -notlike "*Scan checkpoint could not be saved*") {
        throw "Failed history persistence must be visibly reported."
    }
    if ((Get-InventoryFingerprint $database) -cne $beforeStop) { throw "A failed save changed durable history." }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "history-save-error.png")
    $lock.Dispose()
    $lock = $null
    Set-Content -LiteralPath $database -Value "invalid inventory fixture"
    Invoke-HistoryScan
    Wait-HistoryScan
    if ((Find-HistoryControl ScanStatusText).Current.Name -notlike "*Scan checkpoint could not be saved*") {
        throw "Invalid saved history encountered while saving must be visibly reported."
    }
    if ((Get-Content -LiteralPath $database -Raw).Trim() -ne "invalid inventory fixture") {
        throw "Saving must not overwrite invalid history."
    }
    Stop-HistoryApp
    $phase = Step-UiRegressionPhase $phase "history/load-failure" $ScreenshotDirectory
    Start-HistoryApp
    Wait-HistoryState {
        $status = Find-HistoryControl ScanStatusText -Optional
        $status -and $status.Current.Name -like "*Saved inventory could not be loaded. Changes are disabled*"
    } "visible inventory load failure"
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "history-load-error.png")
    if ((Get-Content -LiteralPath $database -Raw).Trim() -ne "invalid inventory fixture") {
        throw "Invalid saved history must not be overwritten."
    }
    Stop-HistoryApp
    }
    else { Stop-HistoryApp }
    if ($SummaryOnly) {
        $phase = Step-UiRegressionPhase $phase $null $ScreenshotDirectory
        Write-Host "Summaries, Last seen, persistence, scan outcomes and collapsed completed-observation checks passed."
        return
    }
    $phase = Step-UiRegressionPhase $phase "history/paging" $ScreenshotDirectory
    $pagedHistory = @(0..204 | ForEach-Object {
        @{ completedAt = ([DateTimeOffset]::Parse("2026-11-01T12:00:00Z").AddSeconds($_)).ToString("o")
           networkId = "ui-review-network"; subnet = "127.0.0.1/32"; present = ($_ % 4 -lt 2) }
    })
    $data.devices.'020000000001'.scanHistory = $pagedHistory + $decoyHistory
    $normal.lastSeen = "2026-11-01T12:03:24+00:00"
    $normal.lastChecked = $normal.lastSeen
    $normal.present = $true
    @{ version = 3; data = $data } | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $inventory -Encoding UTF8
    Remove-Item -LiteralPath $database
    Start-HistoryApp
    Open-HistoryDetails "History normal"
    $reachable = @{}
    Assert-HistoryScrollMovement
    foreach ($pageIndex in 0..2) {
        $null = Wait-HistoryPage ($pageIndex + 1)
        $pageRows = @(Assert-HistoryPage $pageIndex -Traverse)
        foreach ($label in $pageRows) {
            if ($reachable.ContainsKey($label)) { throw "Observation duplicated across history pages: $label." }
            $reachable[$label] = $true
        }
        $list = Show-HistorySection DeviceScanHistoryList
        $scroll = $list.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
        if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, 0) }
        Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "history-page-$($pageIndex + 1).png")
        $pageRows | ConvertTo-Json | Set-Content (Join-Path $ScreenshotDirectory "history-page-$($pageIndex + 1).json")
        if ($pageIndex -lt 2) {
            Move-HistoryPage DeviceHistoryOlder ($pageIndex + 2) -Keyboard
        }
    }
    if ($reachable.Count -ne 205) { throw "All 205 retained observations must remain reachable." }
    if ((Find-HistoryControl DeviceHistoryOlder).Current.IsEnabled) { throw "Older navigation must stop at the oldest page." }
    foreach ($pageIndex in @(1, 0)) {
        Move-HistoryPage DeviceHistoryNewer ($pageIndex + 1)
        $null = Assert-HistoryPage $pageIndex
    }
    if ((Find-HistoryControl DeviceHistoryNewer).Current.IsEnabled) { throw "Newer navigation must stop at the newest page." }
    $beforeError = @(Assert-HistoryPage 0)
    $savedDatabase = [IO.File]::ReadAllBytes($database)
    Set-Content -LiteralPath $database -Value "invalid observation page fixture"
    Move-HistoryPage DeviceHistoryOlder 2 -State Error
    if ((Find-HistoryControl DeviceHistoryPageStatus).Current.Name -notlike "Scan history page could not be loaded:*") {
        throw "Page errors must be explicit without replacing valid rows."
    }
    $retained = @((Show-HistorySection DeviceScanHistoryList).FindAll(
        [System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::DataItem)) | ForEach-Object { $_.Current.Name })
    if (($retained -join "|") -cne ($beforeError -join "|")) { throw "A failed page load replaced the last valid page." }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "history-page-error.png")
    [IO.File]::WriteAllBytes($database, $savedDatabase)
    Move-HistoryPage DeviceHistoryOlder 2
    $null = Assert-HistoryPage 1
    Test-HistoryTabs
    Move-HistoryPage DeviceHistoryOlder 3
    Open-HistoryDetails "History imported"
    if ((Find-HistoryControl DeviceScanHistoryCount).Current.Name -ne "0 completed scan observations") {
        throw "Selection changes must not retain the previous device's page."
    }
    Open-HistoryDetails "History normal"
    $null = Wait-HistoryPage 1
    $null = Assert-HistoryPage 0
    if ((Find-HistoryControl DeviceHistoryNewer).Current.IsEnabled) { throw "Newer navigation must stop at the newest page." }
    Stop-HistoryApp
    $phase = Step-UiRegressionPhase $phase $null $ScreenshotDirectory
    Write-Host "Device scan-history native UI checks passed."
}
catch {
    $failed = $true
    Write-Host $_.ScriptStackTrace
    if ($script:process -and -not $script:process.HasExited -and $script:process.MainWindowHandle -ne [IntPtr]::Zero) {
        try { Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "history-failure.png") }
        catch { Write-Warning "Could not capture scan-history failure: $($_.Exception.Message)" }
    }
    throw
}
finally {
    Invoke-UiRegressionCleanup -PrimaryFailed $failed -Steps @(
        { if ($phase) { Complete-UiRegressionPhase -Phase $phase -Directory $ScreenshotDirectory -Succeeded $false } },
        { Write-UiRegressionCallCosts -Directory $ScreenshotDirectory -Name "DeviceScanHistory.Ui" },
        { if ($lock) { $lock.Dispose() } },
        { if ($null -ne $contrast) { [HistoryReviewContrast]::Set($contrast) } },
        { if ($script:process -and -not $script:process.HasExited) { Stop-Process -Id $script:process.Id -Force } },
        { foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key]) } },
        { if (Test-Path -LiteralPath $fixtureDirectory) { Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force } }
    )
}
