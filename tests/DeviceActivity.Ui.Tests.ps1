param(
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $ScreenshotDirectory
)

$ErrorActionPreference = "Stop"
if ($env:GITHUB_ACTIONS -ne "true") { throw "Device activity UI checks require a disposable GitHub Actions desktop." }
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScreenshot.ps1")
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewAppearance.ps1")
. (Join-Path $PSScriptRoot "Inventory.Sqlite.Helpers.ps1")
. (Join-Path $PSScriptRoot "DeviceActivity.Fixture.ps1")
Initialize-InventorySqlite $AppPath
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms

Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ActivityReviewContrast {
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

function Find-Activity([string] $Id, [switch] $ByName, [switch] $Optional) {
    if (-not $script:root -and $Optional) { return $null }
    $property = if ($ByName) { [Windows.Automation.AutomationElement]::NameProperty } else { [Windows.Automation.AutomationElement]::AutomationIdProperty }
    $condition = [Windows.Automation.PropertyCondition]::new($property, $Id)
    $scope = $script:root
    if (-not $ByName -and $Id -like "ActivityCell-*") {
        # Cell lookups and absence checks stay inside the grid instead of walking the whole window.
        $scope = $script:root.FindFirst([Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, "ActivityScroll"))
        if (-not $scope) {
            if ($Optional) { return $null }
            throw "Missing activity control '$Id'."
        }
    }
    $element = $scope.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition)
    if (-not $element -and -not $Optional) { throw "Missing activity control '$Id'." }
    return $element
}

function Wait-Activity([scriptblock] $Condition, [string] $Description) {
    $deadline = [DateTime]::UtcNow.AddSeconds(25)
    do {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Description. Status: $((Find-Activity ActivityStatus -Optional).Current.Name)"
}

function Start-ActivityApp {
    $script:process = Start-Process -FilePath $AppPath -PassThru
    Wait-Activity {
        $script:process.Refresh()
        if ($script:process.HasExited) { throw "Activity test app exited: $($script:process.ExitCode)." }
        $script:process.MainWindowHandle -ne [IntPtr]::Zero
    } "startup"
    Initialize-UiReviewWindow $script:process.MainWindowHandle
    $script:root = [Windows.Automation.AutomationElement]::FromHandle($script:process.MainWindowHandle)
    Wait-Activity { Find-Activity DevicesNavItem -Optional } "navigation"
}

function Stop-ActivityApp {
    if ($script:process -and -not $script:process.HasExited) {
        $null = $script:process.CloseMainWindow()
        if (-not $script:process.WaitForExit(5000)) { throw "Activity app failed to close." }
    }
}

function Test-ActivityFits($Control, $Viewport) {
    $bounds = $Control.Current.BoundingRectangle
    $area = $Viewport.Current.BoundingRectangle
    $bottom = [Math]::Min($area.Bottom, $script:root.Current.BoundingRectangle.Bottom - 16)
    return -not $Control.Current.IsOffscreen -and $bounds.Height -gt 0 -and
        $bounds.Top -ge $area.Top -and $bounds.Bottom -le $bottom
}

function Show-Activity([string] $Id) {
    $viewport = Find-Activity DeviceDetailsScroll
    $scroll = $viewport.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern)
    $control = Find-Activity $Id
    foreach ($percent in 0..100) {
        if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, $percent) }
        Start-Sleep -Milliseconds 10
        try { $fits = Test-ActivityFits $control $viewport }
        catch [Windows.Automation.ElementNotAvailableException] {
            $control = Find-Activity $Id
            $fits = Test-ActivityFits $control $viewport
        }
        if (-not $fits) { continue }
        # Confirm on a fresh lookup once layout settles, as callers re-resolve the control themselves.
        Start-Sleep -Milliseconds 150
        $control = Find-Activity $Id
        if (Test-ActivityFits $control $viewport) { return $control }
    }
    throw "Activity control '$Id' is clipped or unreachable."
}

function Open-ActivityDevice([string] $Name = "Activity laptop") {
    $back = Find-Activity "Back to devices" -ByName -Optional
    if ($back -and -not $back.Current.IsOffscreen) {
        $back.GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    } else {
        (Find-Activity DevicesNavItem).GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    }
    Wait-Activity {
        $list = Find-Activity ResultsList -Optional
        $list -and -not $list.Current.IsOffscreen
    } "Devices"
    (Find-Activity "Search devices" -ByName).GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).SetValue($Name)
    $script:row = $null
    Wait-Activity {
        $rows = (Find-Activity ResultsList).FindAll([Windows.Automation.TreeScope]::Children,
            [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,
                [Windows.Automation.ControlType]::ListItem))
        if ($rows.Count -ne 1) { return $false }
        $cell = $rows[0].FindFirst([Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, "DeviceNameText"))
        if ($cell.Current.Name -cne $Name) { return $false }
        $script:row = $rows[0]
        return $true
    } "the requested device row"
    $script:row.SetFocus()
    [Windows.Forms.SendKeys]::SendWait("{ENTER}")
    Wait-Activity {
        $scroll = Find-Activity DeviceDetailsScroll -Optional
        $scroll -and -not $scroll.Current.IsOffscreen
    } "device details"
}

function Choose-ActivityPeriod([string] $Label, [int] $LastRow) {
    $null = Show-Activity ActivityPeriod
    Set-UiReviewAppearanceChoice -Root $script:root -Picker ActivityPeriod -Choice $Label
    Wait-Activity {
        $last = Find-Activity "ActivityCell-$LastRow-0" -Optional
        $first = Find-Activity "ActivityCell-0-0" -Optional
        $modeMatches = if ($Label -eq "30 days by weekday") {
            $first -and $first.Current.Name -like "Monday *" -and -not (Find-Activity ActivityCell-7-0 -Optional)
        } else { (Find-Activity ActivityWindow).Current.Name -like "*($($LastRow + 1) calendar dates)*" }
        $last -and $modeMatches -and (Find-Activity ActivityStatus).Current.Name -notlike "Loading*"
    } $Label
}

function Select-ActivityCell([int] $Row, [int] $Column) {
    $null = Show-Activity ActivityHours
    $cell = Find-Activity "ActivityCell-$Row-$Column"
    $cell.SetFocus()
    Wait-Activity { (Find-Activity ActivityDetail).Current.Name -eq $cell.Current.Name } "keyboard-accessible cell details"
    return $cell
}

function Capture-Activity([string] $Name) {
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "$Name.png")
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-activity-ui-$([Guid]::NewGuid().ToString('N'))"
$previous = @{}
$script:process = $null
$script:root = $null
$contrast = $null
$lock = $null
foreach ($key in @("FINGVIBE_UI_REVIEW", "FINGVIBE_UI_REVIEW_INVENTORY", "FINGVIBE_UI_REVIEW_SNAPSHOT",
    "FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT", "FINGVIBE_UI_REVIEW_DEVICE_TABLE", "FINGVIBE_UI_REVIEW_NETWORK")) {
    $previous[$key] = [Environment]::GetEnvironmentVariable($key)
}
try {
    $null = New-Item -ItemType Directory -Path $fixture
    $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
    New-DeviceActivityFixture $fixture
    $env:FINGVIBE_UI_REVIEW = "1"
    $env:FINGVIBE_UI_REVIEW_INVENTORY = Join-Path $fixture "inventory.json"
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = Join-Path $fixture "snapshot.json"
    $env:FINGVIBE_UI_REVIEW_DEVICE_TABLE = Join-Path $fixture "table.json"
    $env:FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT = "0"
    $env:FINGVIBE_UI_REVIEW_NETWORK = "ui-review-network"
    $database = Join-Path $fixture "inventory.sqlite"
    Start-ActivityApp
    Open-ActivityDevice
    Wait-Activity { Find-Activity ActivityCell-5-11 -Optional } "seven-date activity"
    $positive = Select-ActivityCell 5 11
    if ($positive.Current.Name -notlike "*1 responses, 2 nonresponses*" -or $positive.Current.Name -notlike "*At least one response*") {
        throw "Daily response-wins cell has incorrect evidence: $($positive.Current.Name)"
    }
    $negative = Select-ActivityCell 5 12
    if ($negative.Current.Name -notlike "*Scanned, no response*") { throw "Known nonresponse was not preserved." }
    $unknown = Select-ActivityCell 5 13
    if ($unknown.Current.Name -notlike "*Unknown - no eligible scans*") { throw "Unknown evidence was interpolated." }
    Capture-Activity "activity-seven-days"
    foreach ($hours in 1..4) {
        $slider = Show-Activity ActivityHours
        $slider.SetFocus()
        [Windows.Forms.SendKeys]::SendWait("{HOME}" + ("{RIGHT}" * ($hours - 1)))
        $columns = 24 / $hours
        Wait-Activity {
            $last = Find-Activity "ActivityCell-6-$($columns - 1)" -Optional
            $last -and $last.Current.Name -like "*-24:00*" -and -not (Find-Activity "ActivityCell-6-$columns" -Optional)
        } "$hours-hour keyboard group"
    }
    $slider = Show-Activity ActivityHours
    $slider.GetCurrentPattern([Windows.Automation.RangeValuePattern]::Pattern).SetValue(1)
    Wait-Activity {
        (Find-Activity ActivityCell-6-23 -Optional) -and (Find-Activity ActivityStatus).Current.Name -notlike "Loading*"
    } "one-hour grid after the slider reset"
    Choose-ActivityPeriod "Last 30 days" 29
    $null = Select-ActivityCell 28 11
    Capture-Activity "activity-thirty-days"
    Choose-ActivityPeriod "30 days by weekday" 6
    $wednesday = Select-ActivityCell 2 9
    if ($wednesday.Current.Name -notmatch '3 responding days / [45] applicable dates') {
        throw "Weekday denominator/count is incorrect: $($wednesday.Current.Name)"
    }
    Capture-Activity "activity-weekdays"
    [Windows.Forms.SendKeys]::SendWait("{RIGHT}{LEFT}{ENTER}")
    Wait-Activity { (Find-Activity ActivityDetail).Current.Name -eq $wednesday.Current.Name } "arrow and Enter cell navigation"

    $lock = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$database;Pooling=False")
    $lock.Open()
    $command = $lock.CreateCommand()
    $command.CommandText = "BEGIN EXCLUSIVE"
    $null = $command.ExecuteNonQuery()
    (Show-Activity ActivityRefresh).GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-Activity { (Find-Activity ActivityStatus).Current.Name -like "Loading*" } "loading state"
    if (Find-Activity ActivityCell-2-9 -Optional) { throw "Old cells remain during loading." }
    Capture-Activity "activity-loading"
    $null = Show-Activity ActivityPeriod
    Set-UiReviewAppearanceChoice -Root $script:root -Picker ActivityPeriod -Choice "Last 30 days"
    $command.CommandText = "ROLLBACK"
    $null = $command.ExecuteNonQuery()
    $command.Dispose()
    $lock.Dispose()
    $lock = $null
    Wait-Activity {
        (Find-Activity ActivityCell-29-0 -Optional) -and
            (Find-Activity ActivityStatus).Current.Name -like "Scan evidence in*"
    } "new selection after cancelling the blocked weekday query"
    Choose-ActivityPeriod "30 days by weekday" 6
    Open-ActivityDevice "Activity imported"
    Wait-Activity { (Find-Activity ActivityStatus).Current.Name -like "No completed scan history*" } "no-history selection"
    $empty = Select-ActivityCell 2 9
    if ($empty.Current.Name -notlike "*0 responding days*" -or $empty.Current.Name -notmatch '[45] dates without eligible evidence') {
        throw "Imported metadata manufactured scan evidence: $($empty.Current.Name)"
    }
    Capture-Activity "activity-no-history"
    Open-ActivityDevice
    Wait-Activity { (Find-Activity ActivityStatus).Current.Name -like "Scan evidence in*" } "restored device selection"
    $connection = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$database;Pooling=False")
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        try {
            $command.CommandText = "UPDATE inventory SET revision='$([Guid]::NewGuid())'"
            $null = $command.ExecuteNonQuery()
        } finally { $command.Dispose() }
    } finally { $connection.Dispose() }
    (Show-Activity ActivityRefresh).GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-Activity { (Find-Activity ActivityRefresh).Current.Name -eq "Retry" } "explicit stale-revision error"
    if (Find-Activity ActivityCell-2-9 -Optional) { throw "Failed query kept stale cells." }
    $null = Show-Activity ActivityError
    Capture-Activity "activity-query-error"
    Stop-ActivityApp
    Start-ActivityApp
    Open-ActivityDevice
    Wait-Activity { Find-Activity ActivityCell-5-11 -Optional } "restarted activity"
    foreach ($theme in @("Standard Light", "Standard Dark")) {
        $settings = $null
        Wait-Activity {
            $script:activitySettings = $script:root.FindFirst([Windows.Automation.TreeScope]::Descendants,
                [Windows.Automation.AndCondition]::new(
                    [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty, "Settings"),
                    [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::ListItem)))
            $script:activitySettings -and -not $script:activitySettings.Current.IsOffscreen
        } "Settings navigation after resizing"
        $settings = $script:activitySettings
        $settings.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
        Wait-Activity { -not (Find-Activity ModePicker).Current.IsOffscreen } "Settings"
        Set-UiReviewTheme -Root $script:root -Theme $theme
        Open-ActivityDevice
        Wait-Activity { Find-Activity ActivityCell-5-11 -Optional } "themed grid"
        $bounds = Get-UiReviewWindowBounds $script:process.MainWindowHandle
        foreach ($width in @($bounds.Width, 640)) {
            $null = [UiReviewNativeWindow]::SetWindowPos($script:process.MainWindowHandle, [IntPtr]::Zero,
                $bounds.Left, $bounds.Top, $width, $bounds.Height, 0x0044)
            Start-Sleep -Milliseconds 300
            foreach ($id in @("ActivityPeriod", "ActivityHours", "ActivityRefresh")) {
                $control = Show-Activity $id
                if (-not $script:root.Current.BoundingRectangle.Contains($control.Current.BoundingRectangle)) { throw "$id is clipped." }
            }
            $null = Select-ActivityCell 5 11
            if ($width -eq 640 -and -not (Find-Activity ActivityScroll).GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern).Current.HorizontallyScrollable) {
                throw "Narrow grid must scroll instead of squeezing cells."
            }
            Capture-Activity "activity-$($theme.Replace(' ', '-'))-$width"
        }
        $null = [UiReviewNativeWindow]::SetWindowPos($script:process.MainWindowHandle, [IntPtr]::Zero,
            $bounds.Left, $bounds.Top, $bounds.Width, $bounds.Height, 0x0044)
        Start-Sleep -Milliseconds 500
    }
    $contrast = [ActivityReviewContrast]::Get()
    [ActivityReviewContrast]::Set($contrast -bor 1)
    Start-Sleep -Seconds 2
    if (([ActivityReviewContrast]::Get() -band 1) -eq 0) { throw "High contrast did not activate." }
    $null = Select-ActivityCell 5 11
    Capture-Activity "activity-high-contrast"
    [ActivityReviewContrast]::Set($contrast)
    $contrast = $null
    $history = Show-Activity DeviceScanHistoryExpander
    $history.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    $null = Show-Activity DeviceHistoryOlder
    Write-Host "Device Activity exact daily/weekday evidence, all stops, keyboard details, loading/error/no history, selection, narrow themes and high contrast passed; history remains reachable."
}
finally {
    if ($lock) { $lock.Dispose() }
    if ($null -ne $contrast) { [ActivityReviewContrast]::Set($contrast) }
    if ($script:process -and -not $script:process.HasExited) {
        $null = $script:process.CloseMainWindow()
        if (-not $script:process.WaitForExit(5000)) { Stop-Process -Id $script:process.Id -Force }
    }
    foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key]) }
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
