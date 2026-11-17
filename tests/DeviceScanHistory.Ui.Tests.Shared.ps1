# Shared fixture/lifecycle helpers: controls, app lifecycle, details tabs, times and scans.
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
