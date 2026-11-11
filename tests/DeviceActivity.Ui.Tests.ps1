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
    $isCell = -not $ByName -and $Id -like "ActivityCell-*"
    # A descendant search can miss while WinUI rebuilds the grid; required lookups and the always-present
    # ActivityScroll scope get a short retry, while Optional absence checks still answer immediately.
    $deadline = [DateTime]::UtcNow.AddSeconds(2)
    $tabChecked = $false
    while ($true) {
        $scope = $script:root
        if ($isCell) {
            # Cell lookups and absence checks stay inside the grid instead of walking the whole window.
            $scope = $script:root.FindFirst([Windows.Automation.TreeScope]::Descendants,
                [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, "ActivityScroll"))
        }
        $element = if ($scope) { $scope.FindFirst([Windows.Automation.TreeScope]::Descendants, $condition) }
        if (-not $element -and -not $tabChecked -and $Id -ne 'DeviceDetailsScroll') {
            $tabChecked = $true
            if (Show-UiRegressionDeviceTabFor $script:root $Id) { continue }
        }
        if ($element -or ($scope -and $Optional) -or [DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Milliseconds 50
    }
    if (-not $element -and -not $Optional) { throw "Missing activity control '$Id'." }
    return $element
}

function Wait-Activity([scriptblock] $Condition, [string] $Description) {
    try {
        $null = Wait-UiRegressionState -Condition $Condition -Description $Description -TimeoutMilliseconds 25000
    }
    catch {
        Write-ActivityDiagnostics
        throw
    }
}

function Write-ActivityDiagnostics {
    foreach ($id in @("ActivityStatus", "ActivityError", "ActivityWindow")) {
        Write-Host "$id`: $((Find-Activity $id -Optional).Current.Name)"
    }
    Write-Host "Activity state: $((Find-Activity ActivityScroll -Optional).Current.ItemStatus)"
}

# Activity's observable state (ItemStatus on ActivityScroll); waits use it instead of incidental cells or text.
function Get-ActivityState {
    Get-UiRegressionSurfaceState -GetElement { Find-Activity ActivityScroll -Optional } -Description "Activity"
}

function Wait-ActivityState([string] $Selection, [int] $After, [string] $State = "Ready") {
    try {
        Wait-UiRegressionSurfaceState -GetElement { Find-Activity ActivityScroll -Optional } -Description "Activity" `
            -State $State -Selection $Selection -After $After
    }
    catch {
        Write-ActivityDiagnostics
        throw
    }
}

function Assert-ActivityPeers([string] $Description) {
    Assert-UiRegressionPeers -Root $script:root -Description "Activity $Description" -AutomationIds @(
        "ActivityPeriod", "ActivityWindow", "ActivityHours", "ActivityStatus",
        "ActivityScroll", "ActivityLegend", "ActivityDetail")
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
    $target = Find-Activity $Id
    $scrollItem = $null
    $focusable = $target.Current.IsKeyboardFocusable
    if ($focusable -or $target.TryGetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern, [ref] $scrollItem)) {
        # Like a keyboard user, or WinUI's own bring-into-view: the page positions the control, so no scroll arithmetic is needed.
        # Focus first so a previously focused control cannot pull the view back, then bring the target into view,
        # because focusing an already-focused control does not scroll.
        if ($focusable) { $target.SetFocus() }
        if ($scrollItem -or $target.TryGetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern, [ref] $scrollItem)) { $scrollItem.ScrollIntoView() }
        $script:shownActivity = $null
        Wait-Activity {
            # Peers can be briefly absent while bring-into-view re-realizes the page; retry instead of failing.
            $current = Find-Activity $Id -Optional
            $viewport = Find-Activity DeviceDetailsScroll -Optional
            if ($current -and $viewport -and (Test-ActivityFits $current $viewport)) { $script:shownActivity = $current; return $true }
            return $false
        } "Activity control '$Id' brought inside the details viewport"
        return $script:shownActivity
    }
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
    $findRequestedRow = {
        $rows = (Find-Activity ResultsList).FindAll([Windows.Automation.TreeScope]::Children,
            [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,
                [Windows.Automation.ControlType]::ListItem))
        if ($rows.Count -ne 1 -or -not (Test-UiRegressionElementVisible $rows[0]) -or
            -not $rows[0].Current.IsEnabled) { return $null }
        $cell = $rows[0].FindFirst([Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, "DeviceNameText"))
        if (-not (Test-UiRegressionElementVisible $cell) -or $cell.Current.Name -cne $Name) { return $null }
        return $rows[0]
    }
    Wait-Activity {
        $script:row = & $findRequestedRow
        $null -ne $script:row
    } "the requested visible device row"
    Wait-Activity {
        $script:row = & $findRequestedRow
        $script:row -and $script:row.Current.IsKeyboardFocusable
    } "the requested device row ready for keyboard focus"
    $script:row.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $script:row.SetFocus()
    [Windows.Forms.SendKeys]::SendWait("{ENTER}")
    Wait-Activity {
        $scroll = Find-Activity DeviceDetailsScroll -Optional
        $scroll -and -not $scroll.Current.IsOffscreen
    } "device details"
}

function Choose-ActivityPeriod([string] $Label, [int] $LastRow) {
    $before = (Get-ActivityState).Request
    $null = Show-Activity ActivityPeriod
    Set-UiReviewAppearanceChoice -Root $script:root -Picker ActivityPeriod -Choice $Label
    $null = Wait-ActivityState "$Label, 1-hour cells" $before
    $first = Find-Activity "ActivityCell-0-0"
    $null = Find-Activity "ActivityCell-$LastRow-0"
    $modeMatches = if ($Label -eq "30 days by weekday") {
        $first.Current.Name -like "Monday *" -and -not (Find-Activity ActivityCell-7-0 -Optional)
    } else { (Find-Activity ActivityWindow).Current.Name -like "*of $($LastRow + 1) days*" }
    if (-not $modeMatches) { throw "Ready Activity grid does not match '$Label'." }
}

function Select-ActivityCell([int] $Row, [int] $Column) {
    $null = Show-Activity ActivityHours
    $cell = Find-Activity "ActivityCell-$Row-$Column"
    $cell.SetFocus()
    $script:selectedActivityCell = $null
    try {
        Wait-Activity {
            # Peers can be briefly absent while bring-into-view re-realizes the grid; retry instead of failing.
            $current = Find-Activity "ActivityCell-$Row-$Column" -Optional
            $detail = Find-Activity ActivityDetail -Optional
            $grid = Find-Activity ActivityScroll -Optional
            $page = Find-Activity DeviceDetailsScroll -Optional
            if (-not ($current -and $detail -and $grid -and $page)) { return $false }
            if ($detail.Current.Name -eq $current.Current.Name -and (Test-ActivityFits $current $grid) -and (Test-ActivityFits $current $page)) {
                $script:selectedActivityCell = $current
                return $true
            }
            return $false
        } "visible keyboard-accessible cell details"
    }
    catch {
        foreach ($id in @("ActivityCell-$Row-$Column", "ActivityScroll", "DeviceDetailsScroll", "ActivityDetail")) {
            $element = Find-Activity $id -Optional
            Write-Host "$id | offscreen=$($element.Current.IsOffscreen) | bounds=$($element.Current.BoundingRectangle) | name=$($element.Current.Name)"
        }
        throw
    }
    return $script:selectedActivityCell
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
    # ChangeExtension(path, $null) would keep a trailing dot because PowerShell passes $null as "".
    return $script:startedRequest -replace '\.started$', ''
}

function Start-HeldActivityRefresh {
    $previousRequests = @(Get-ActivityRequests)
    $before = (Get-ActivityState).Request
    Set-Content -LiteralPath $holdPath -Value "hold"
    Restart-Activity
    $request = Wait-ActivityRequest $previousRequests
    $state = Wait-ActivityState -State Loading -After $before
    if (Find-Activity ActivityCell-0-0 -Optional) { throw "Old cells remain during loading." }
    Assert-ActivityPeers "loading"
    return [pscustomobject]@{ Path = $request; Request = $state.Request }
}

function Restart-Activity {
    $null = Select-UiRegressionDeviceTab -Root $script:root -Tab Overview
    $null = Select-UiRegressionDeviceTab -Root $script:root -Tab History
}

function Assert-ActivityCancelled($Request) {
    Wait-Activity { Test-Path -LiteralPath "$($Request.Path).cancelled" } "obsolete Activity loader cancellation"
    if (Test-Path -LiteralPath "$($Request.Path).released") { throw "Obsolete Activity loader was released instead of cancelled." }
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
    $null = Wait-ActivityState "Last 7 days, 1-hour cells" 0
    Assert-ActivityPeers "ready"
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
        $before = (Get-ActivityState).Request
        $slider = Show-Activity ActivityHours
        $slider.SetFocus()
        [Windows.Forms.SendKeys]::SendWait("{HOME}" + ("{RIGHT}" * ($hours - 1)))
        # One hour is already selected on the first pass, so that keystroke starts no new request.
        $null = Wait-ActivityState "Last 7 days, $hours-hour cells" $(if ($hours -eq 1) { 0 } else { $before })
        $columns = 24 / $hours
        $last = Find-Activity "ActivityCell-6-$($columns - 1)"
        if ($last.Current.Name -notlike "*-24:00*" -or (Find-Activity "ActivityCell-6-$columns" -Optional)) {
            throw "$hours-hour keyboard group rendered the wrong columns."
        }
    }
    $before = (Get-ActivityState).Request
    $slider = Show-Activity ActivityHours
    $slider.GetCurrentPattern([Windows.Automation.RangeValuePattern]::Pattern).SetValue(1)
    $null = Wait-ActivityState "Last 7 days, 1-hour cells" $before
    $null = Find-Activity ActivityCell-6-23
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
    $null = Wait-ActivityState "Last 30 days, 1-hour cells" $weekdayRequest.Request
    if (-not (Find-Activity ActivityCell-29-0 -Optional) -or
        (Find-Activity ActivityWindow).Current.Name -notlike "*of 30 days*" -or
        (Find-Activity ActivityStatus).Current.Name -notlike "*squares have scan results*") {
        throw "The replacement daily query did not render a 30-date grid with scan evidence."
    }
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
    $imported = Wait-ActivityState "30 days by weekday, 1-hour cells" $deviceRequest.Request
    if ((Find-Activity ActivityStatus).Current.Name -notlike "No completed scan history*") { throw "No-history selection reported scan evidence." }
    $empty = Select-ActivityCell 2 9
    if ($empty.Current.Name -notlike "*0 responding days*" -or $empty.Current.Name -notmatch '[45] dates without eligible evidence') {
        throw "Imported metadata manufactured scan evidence: $($empty.Current.Name)"
    }
    Capture-Activity "activity-no-history"
    Open-ActivityDevice
    $null = Wait-ActivityState "30 days by weekday, 1-hour cells" $imported.Request
    if ((Find-Activity ActivityStatus).Current.Name -notlike "*squares have scan results*") { throw "Restored device selection lost scan evidence." }

    $hoursRequest = Start-HeldActivityRefresh
    $previousRequests = @(Get-ActivityRequests)
    (Show-Activity ActivityHours).GetCurrentPattern([Windows.Automation.RangeValuePattern]::Pattern).SetValue(2)
    Assert-ActivityCancelled $hoursRequest
    $null = Wait-ActivityRequest $previousRequests
    Remove-Item -LiteralPath $holdPath
    $twoHours = Wait-ActivityState "30 days by weekday, 2-hour cells" $hoursRequest.Request
    if (-not (Find-Activity ActivityCell-6-11 -Optional) -or (Find-Activity ActivityCell-6-12 -Optional) -or
        (Find-Activity ActivityStatus).Current.Name -notlike "*squares have scan results*") {
        throw "Replacement two-hour weekday grid is incorrect."
    }
    (Show-Activity ActivityHours).GetCurrentPattern([Windows.Automation.RangeValuePattern]::Pattern).SetValue(1)
    $null = Wait-ActivityState "30 days by weekday, 1-hour cells" $twoHours.Request
    $null = Find-Activity ActivityCell-6-23

    $navigationRequest = Start-HeldActivityRefresh
    (Find-Activity DevicesNavItem).GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Assert-ActivityCancelled $navigationRequest
    Remove-Item -LiteralPath $holdPath
    Open-ActivityDevice
    $null = Wait-ActivityState "30 days by weekday, 1-hour cells" $navigationRequest.Request
    if ((Find-Activity ActivityStatus).Current.Name -notlike "*squares have scan results*") { throw "Activity after leaving the page lost scan evidence." }

    # Real SQLite contention is an error/retry fixture, not a way to hold the loading UI.
    $lock = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$database;Pooling=False")
    $lock.Open()
    $command = $lock.CreateCommand()
    $command.CommandText = "BEGIN EXCLUSIVE"
    $null = $command.ExecuteNonQuery()
    $before = (Get-ActivityState).Request
    Restart-Activity
    $busy = Wait-ActivityState -State Error -After $before
    if ((Find-Activity ActivityRefresh).Current.Name -ne "Retry") { throw "Database contention error does not offer Retry." }
    if (Find-Activity ActivityCell-0-0 -Optional) { throw "Failed query kept stale cells." }
    Assert-ActivityPeers "error"
    $null = Show-Activity ActivityError
    Capture-Activity "activity-busy-error"
    $command.CommandText = "ROLLBACK"
    $null = $command.ExecuteNonQuery()
    $command.Dispose()
    $lock.Dispose()
    $lock = $null
    (Show-Activity ActivityRefresh).GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    $retried = Wait-ActivityState "30 days by weekday, 1-hour cells" $busy.Request
    if ((Find-Activity ActivityStatus).Current.Name -notlike "*squares have scan results*" -or
        (Find-Activity ActivityRefresh -Optional) -or -not (Find-Activity ActivityCell-2-9 -Optional)) {
        throw "Retry after database contention did not restore the grid."
    }
    Assert-ActivityPeers "Retry"
    $connection = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$database;Pooling=False")
    try {
        $connection.Open()
        $command = $connection.CreateCommand()
        try {
            $command.CommandText = "UPDATE inventory SET revision='$([Guid]::NewGuid())'"
            $null = $command.ExecuteNonQuery()
        } finally { $command.Dispose() }
    } finally { $connection.Dispose() }
    Restart-Activity
    $null = Wait-ActivityState -State Error -After $retried.Request
    if ((Find-Activity ActivityRefresh).Current.Name -ne "Retry") { throw "Stale-revision error does not offer Retry." }
    if (Find-Activity ActivityCell-2-9 -Optional) { throw "Failed query kept stale cells." }
    $null = Show-Activity ActivityError
    Capture-Activity "activity-query-error"
    Stop-ActivityApp
    Start-ActivityApp
    Open-ActivityDevice
    $null = Wait-ActivityState "Last 7 days, 1-hour cells" 0
    foreach ($theme in @("Standard Light", "Standard Dark")) {
        $before = (Get-ActivityState).Request
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
        $null = Wait-ActivityState "Last 7 days, 1-hour cells" $before
        $bounds = Get-UiReviewWindowBounds $script:process.MainWindowHandle
        foreach ($width in @($bounds.Width, 640)) {
            $null = [UiReviewNativeWindow]::SetWindowPos($script:process.MainWindowHandle, [IntPtr]::Zero,
                $bounds.Left, $bounds.Top, $width, $bounds.Height, 0x0044)
            Start-Sleep -Milliseconds 300
            foreach ($id in @("ActivityPeriod", "ActivityHours")) {
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
    if ((Find-Activity DeviceScanHistoryExpander).GetCurrentPattern(
        [Windows.Automation.ExpandCollapsePattern]::Pattern).Current.ExpandCollapseState -ne
        [Windows.Automation.ExpandCollapseState]::Expanded) {
        throw "History must show completed observations without another expansion."
    }
    $closeRequest = Start-HeldActivityRefresh
    Stop-ActivityApp
    if (-not (Test-Path -LiteralPath "$($closeRequest.Path).cancelled")) { throw "Closing did not cancel the pending Activity loader." }
    $succeeded = $true
    Write-Host "Device Activity exact evidence, automatic tab-entry reload, keyboard reachability, held-query cancellation, error/Retry, themes and narrow layouts passed; observations are immediately available."
}
catch {
    Write-Host $_
    Write-Host $_.ScriptStackTrace
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
