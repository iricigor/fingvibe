param(
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $ScreenshotDirectory
)

$ErrorActionPreference = "Stop"
if ($env:GITHUB_ACTIONS -ne "true") { throw "Device activity UI checks require a disposable GitHub Actions desktop." }
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScreenshot.ps1")
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewAppearance.ps1")
. (Join-Path $PSScriptRoot "UiRegression\Helpers.ps1")
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
    try {
        $null = Wait-UiRegressionState -Condition $Condition -Description $Description -TimeoutMilliseconds 25000
    }
    catch {
        Write-Host "Activity status: $((Find-Activity ActivityStatus -Optional).Current.Name)"
        Write-Host "Activity error: $((Find-Activity ActivityError -Optional).Current.Name)"
        Write-Host "Activity window: $((Find-Activity ActivityWindow -Optional).Current.Name)"
        throw
    }
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
    Stop-UiRegressionApp -Process $script:process
}

function Test-ActivityFits($Control, $Viewport) {
    Test-UiRegressionElementWithin $Control $Viewport $script:root
}

function Show-Activity([string] $Id) {
    Show-UiRegressionScrollTargets -Description "Activity control '$Id'" -BottomMargin 8 `
        -GetViewport { Find-Activity DeviceDetailsScroll } -GetWindow { $script:root } -GetTargets { Find-Activity $Id }
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
    try {
        Wait-Activity {
            $current = Find-Activity "ActivityCell-$Row-$Column"
            (Find-Activity ActivityDetail).Current.Name -eq $current.Current.Name -and
                (Test-ActivityFits $current (Find-Activity ActivityScroll)) -and
                (Test-ActivityFits $current (Find-Activity DeviceDetailsScroll))
        } "visible keyboard-accessible cell details"
    }
    catch {
        foreach ($id in @("ActivityCell-$Row-$Column", "ActivityScroll", "DeviceDetailsScroll", "ActivityDetail")) {
            $element = Find-Activity $id -Optional
            Write-Host "$id | offscreen=$($element.Current.IsOffscreen) | bounds=$($element.Current.BoundingRectangle) | name=$($element.Current.Name)"
        }
        throw
    }
    return $cell
}

function Capture-Activity([string] $Name) {
    Save-UiRegressionScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "$Name.png")
}

function Get-ActivityRequests {
    @([IO.Directory]::GetFiles($fixture, "activity-hold.*.started"))
}

function Wait-ActivityRequest([string[]] $Previous) {
    $script:startedRequest = $null
    Wait-Activity {
        $requests = @(Get-ActivityRequests | Where-Object { $_ -notin $Previous })
        if ($requests.Count -gt 1) { throw "One selection started multiple held Activity queries." }
        if ($requests.Count -eq 1) { $script:startedRequest = $requests[0]; return $true }
        return $false
    } "the selected Activity loader to start"
    return [IO.Path]::ChangeExtension($script:startedRequest, $null)
}

function Start-HeldActivityRefresh {
    $previousRequests = @(Get-ActivityRequests)
    Set-Content -LiteralPath $holdPath -Value "hold"
    (Show-Activity ActivityRefresh).GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    $request = Wait-ActivityRequest $previousRequests
    Wait-Activity { (Find-Activity ActivityStatus).Current.Name -like "Loading*" } "held loading state"
    if (Find-Activity ActivityCell-0-0 -Optional) { throw "Old cells remain during loading." }
    return $request
}

function Assert-ActivityCancelled([string] $Request) {
    Wait-Activity { Test-Path -LiteralPath "$Request.cancelled" } "obsolete Activity loader cancellation"
    if (Test-Path -LiteralPath "$Request.released") { throw "Obsolete Activity loader was released instead of cancelled." }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-activity-ui-$([Guid]::NewGuid().ToString('N'))"
$previous = @{}
$script:process = $null
$script:root = $null
$contrast = $null
$lock = $null
$holdPath = Join-Path $fixture "activity-hold"
$phase = $null
$succeeded = $false
foreach ($key in @("FINGVIBE_UI_REVIEW", "FINGVIBE_UI_REVIEW_INVENTORY", "FINGVIBE_UI_REVIEW_SNAPSHOT",
    "FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT", "FINGVIBE_UI_REVIEW_DEVICE_TABLE", "FINGVIBE_UI_REVIEW_NETWORK",
    "FINGVIBE_UI_REVIEW_ACTIVITY_HOLD")) {
    $previous[$key] = [Environment]::GetEnvironmentVariable($key)
}
try {
    $null = New-Item -ItemType Directory -Path $fixture
    $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
    $phase = Start-UiRegressionPhase -Name "activity/evidence-and-lifecycle"
    New-DeviceActivityFixture $fixture
    $env:FINGVIBE_UI_REVIEW = "1"
    $env:FINGVIBE_UI_REVIEW_INVENTORY = Join-Path $fixture "inventory.json"
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = Join-Path $fixture "snapshot.json"
    $env:FINGVIBE_UI_REVIEW_DEVICE_TABLE = Join-Path $fixture "table.json"
    $env:FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT = "0"
    $env:FINGVIBE_UI_REVIEW_NETWORK = "ui-review-network"
    $env:FINGVIBE_UI_REVIEW_ACTIVITY_HOLD = $holdPath
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

    $weekdayRequest = Start-HeldActivityRefresh
    Capture-Activity "activity-loading"
    $previousRequests = @(Get-ActivityRequests)
    $null = Show-Activity ActivityPeriod
    Set-UiReviewAppearanceChoice -Root $script:root -Picker ActivityPeriod -Choice "Last 30 days"
    Assert-ActivityCancelled $weekdayRequest
    $dailyRequest = Wait-ActivityRequest $previousRequests
    Remove-Item -LiteralPath $holdPath
    Wait-Activity {
        (Find-Activity ActivityCell-29-0 -Optional) -and
            (Find-Activity ActivityWindow).Current.Name -like "*(30 calendar dates)*" -and
            (Find-Activity ActivityStatus).Current.Name -like "Scan evidence in*"
    } "new selection after cancelling the blocked weekday query"
    if (-not (Test-Path -LiteralPath "$dailyRequest.released") -or
        (Find-Activity ActivityCell-28-11).Current.Name -notlike "*1 responses, 2 nonresponses*") {
        throw "The replacement daily query did not render its exact current-selection evidence."
    }
    Choose-ActivityPeriod "30 days by weekday" 6
    $deviceRequest = Start-HeldActivityRefresh
    $previousRequests = @(Get-ActivityRequests)
    Open-ActivityDevice "Activity imported"
    Assert-ActivityCancelled $deviceRequest
    $null = Wait-ActivityRequest $previousRequests
    Remove-Item -LiteralPath $holdPath
    Wait-Activity { (Find-Activity ActivityStatus).Current.Name -like "No completed scan history*" } "no-history selection"
    $empty = Select-ActivityCell 2 9
    if ($empty.Current.Name -notlike "*0 responding days*" -or $empty.Current.Name -notmatch '[45] dates without eligible evidence') {
        throw "Imported metadata manufactured scan evidence: $($empty.Current.Name)"
    }
    Capture-Activity "activity-no-history"
    Open-ActivityDevice
    Wait-Activity { (Find-Activity ActivityStatus).Current.Name -like "Scan evidence in*" } "restored device selection"

    $hoursRequest = Start-HeldActivityRefresh
    $previousRequests = @(Get-ActivityRequests)
    (Show-Activity ActivityHours).GetCurrentPattern([Windows.Automation.RangeValuePattern]::Pattern).SetValue(2)
    Assert-ActivityCancelled $hoursRequest
    $null = Wait-ActivityRequest $previousRequests
    Remove-Item -LiteralPath $holdPath
    Wait-Activity {
        (Find-Activity ActivityCell-6-11 -Optional) -and -not (Find-Activity ActivityCell-6-12 -Optional) -and
            (Find-Activity ActivityStatus).Current.Name -like "Scan evidence in*"
    } "replacement two-hour weekday grid"
    (Show-Activity ActivityHours).GetCurrentPattern([Windows.Automation.RangeValuePattern]::Pattern).SetValue(1)
    Wait-Activity { Find-Activity ActivityCell-6-23 -Optional } "restored one-hour weekday grid"

    $navigationRequest = Start-HeldActivityRefresh
    (Find-Activity DevicesNavItem).GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Assert-ActivityCancelled $navigationRequest
    Remove-Item -LiteralPath $holdPath
    Open-ActivityDevice
    Wait-Activity { (Find-Activity ActivityStatus).Current.Name -like "Scan evidence in*" } "activity after leaving the page"

    # Real SQLite contention is an error/retry fixture, not a way to hold the loading UI.
    $lock = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$database;Pooling=False")
    $lock.Open()
    $command = $lock.CreateCommand()
    $command.CommandText = "BEGIN EXCLUSIVE"
    $null = $command.ExecuteNonQuery()
    (Show-Activity ActivityRefresh).GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-Activity { (Find-Activity ActivityRefresh).Current.Name -eq "Retry" } "explicit database contention error"
    if (Find-Activity ActivityCell-0-0 -Optional) { throw "Failed query kept stale cells." }
    $null = Show-Activity ActivityError
    Capture-Activity "activity-busy-error"
    $command.CommandText = "ROLLBACK"
    $null = $command.ExecuteNonQuery()
    $command.Dispose()
    $lock.Dispose()
    $lock = $null
    (Show-Activity ActivityRefresh).GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-Activity {
        (Find-Activity ActivityStatus).Current.Name -like "Scan evidence in*" -and
            (Find-Activity ActivityRefresh).Current.Name -eq "Refresh activity" -and
            (Find-Activity ActivityCell-2-9 -Optional)
    } "successful Retry after database contention"
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
    $summary = Show-Activity DeviceHistoryFirstSeen
    if ($summary.Current.Name -notlike "First seen:*") { throw "Existing history summary is unreachable." }
    foreach ($id in @("DeviceScanHistoryExpander", "DeviceScanHistoryList", "DeviceHistoryOlder", "DeviceHistoryNewer")) {
        $control = Find-Activity $id -Optional
        if ($control -and (-not $control.Current.IsOffscreen -or $control.Current.IsKeyboardFocusable)) {
            throw "Restoring Activity also enabled completed-observation control '$id'."
        }
    }
    $closeRequest = Start-HeldActivityRefresh
    Stop-ActivityApp
    if (-not (Test-Path -LiteralPath "$closeRequest.cancelled")) { throw "Closing did not cancel the pending Activity loader." }
    $succeeded = $true
    Write-Host "Device Activity exact evidence, keyboard reachability, held-query cancellation, error/Retry, themes and narrow layouts passed; summaries remain reachable and completed observations disabled."
}
catch {
    Write-Host $_
    if ($script:process -and -not $script:process.HasExited -and $script:process.MainWindowHandle -ne [IntPtr]::Zero) {
        Capture-Activity "activity-failure"
    }
    throw
}
finally {
    if ($lock) { $lock.Dispose() }
    if ($null -ne $contrast) { [ActivityReviewContrast]::Set($contrast) }
    if ($script:process -and -not $script:process.HasExited) {
        $null = $script:process.CloseMainWindow()
        if (-not $script:process.WaitForExit(5000)) { Stop-Process -Id $script:process.Id -Force }
    }
    if ($phase) { Complete-UiRegressionPhase -Phase $phase -Directory $ScreenshotDirectory -Succeeded $succeeded }
    if (Test-Path -LiteralPath $fixture) {
        Get-ChildItem -LiteralPath $fixture -Filter "activity-hold.*" | Copy-Item -Destination $ScreenshotDirectory
    }
    foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key]) }
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
