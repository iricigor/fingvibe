param([Parameter(Mandatory)][string] $AppPath, [Parameter(Mandatory)][string] $ScreenshotDirectory)
$ErrorActionPreference = "Stop"
if ($env:GITHUB_ACTIONS -ne "true") { throw "Network activity checks require a disposable GitHub Actions desktop." }
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScreenshot.ps1")
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewAppearance.ps1")
. (Join-Path $PSScriptRoot "UiRegression\Helpers.ps1")
. (Join-Path $PSScriptRoot "Inventory.Sqlite.Helpers.ps1")
. (Join-Path $PSScriptRoot "NetworkActivity.Fixture.ps1")
Initialize-InventorySqlite $AppPath
$null = [Reflection.Assembly]::LoadFrom((Join-Path (Split-Path $AppPath) "FingVibe.Core.dll"))
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms

function Find-NetworkActivity([string] $Id) {
    if (-not $script:root) { return $null }
    $scope = $script:root
    if ($Id -like "NetworkActivityCell-*") { $scope = Find-NetworkActivity NetworkActivityScroll }
    if ($scope) {
        $scope.FindFirst([Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, $Id))
    }
}
function Wait-NetworkActivity([int] $After = 0, [string] $State = "Ready", [string] $Selection) {
    Wait-UiRegressionSurfaceState -GetElement { Find-NetworkActivity NetworkActivityScroll } `
        -Description "Network activity" -After $After -State $State -Selection $Selection
}
function Show-NetworkActivity([string] $Id) {
    $target = Find-NetworkActivity $Id
    if ($target.Current.IsKeyboardFocusable) {
        $target.SetFocus()
        $pattern = $null
        if ($target.TryGetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern, [ref]$pattern)) { $pattern.ScrollIntoView() }
        $null = Wait-UiRegressionState -Description "Visible Network activity $Id" -Condition {
            $current = Find-NetworkActivity $Id
            $current -and (Test-UiRegressionElementWithin $current (Find-NetworkActivity NetworkPage) $script:root)
        }
        return Find-NetworkActivity $Id
    }
    Show-UiRegressionScrollTargets -Description "Network activity $Id" -GetViewport { Find-NetworkActivity NetworkPage } `
        -GetWindow { $script:root } -GetTargets { Find-NetworkActivity $Id }
}
function Choose-NetworkActivity([string] $Id, [string] $Choice) {
    $before = (Get-UiRegressionSurfaceState -GetElement { Find-NetworkActivity NetworkActivityScroll } -Description Network).Request
    $null = Show-NetworkActivity $Id
    Set-UiReviewAppearanceChoice -Root $script:root -Picker $Id -Choice $Choice
    $null = Wait-NetworkActivity $before
}
function Assert-NetworkCell([string] $Id, [string] $Pattern) {
    $cell = Show-NetworkActivity $Id
    if ($cell.Current.Name -notlike $Pattern) { throw "Incorrect $Id`: $($cell.Current.Name)" }
    $null = Wait-UiRegressionState -Description "Current network cell details" -Condition {
        (Find-NetworkActivity NetworkActivityDetail).Current.Name -eq $cell.Current.Name
    }
}
function Assert-NetworkPeers {
    Assert-UiRegressionPeers -Root $script:root -Description "Network activity state" -AutomationIds @(
        "NetworkActivityPeriod", "NetworkActivityRoom", "NetworkActivityType", "NetworkActivityCategory",
        "NetworkActivityHours", "NetworkActivityWindow", "NetworkActivityStatus", "NetworkActivityScroll",
        "NetworkActivityLegend", "NetworkActivityDetail", "NetworkActivityRefresh")
}
function Start-NetworkApp {
    $script:process = Start-Process -FilePath $AppPath -PassThru
    $null = Wait-UiRegressionState -Description "Network fixture startup" -Condition {
        $script:process.Refresh()
        if ($script:process.HasExited) { throw "Network fixture app exited." }
        $script:process.MainWindowHandle -ne [IntPtr]::Zero
    }
    Initialize-UiReviewWindow $script:process.MainWindowHandle
    $script:root = [Windows.Automation.AutomationElement]::FromHandle($script:process.MainWindowHandle)
    $null = Wait-UiRegressionState -Description "Network navigation" -Condition { Find-NetworkActivity NetworkNavItem }
    (Find-NetworkActivity NetworkNavItem).GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
}
function Hold-NetworkActivity {
    $before = (Get-UiRegressionSurfaceState -GetElement { Find-NetworkActivity NetworkActivityScroll } -Description Network).Request
    $existing = @([IO.Directory]::GetFiles($fixture, "network-hold.*.started"))
    Set-Content -LiteralPath $hold -Value hold
    (Show-NetworkActivity NetworkActivityRefresh).GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    $state = Wait-NetworkActivity $before Loading
    Assert-NetworkPeers
    if (Find-NetworkActivity NetworkActivityCell-0-0) { throw "Stale cells remain while loading." }
    $script:held = $null
    $null = Wait-UiRegressionState -Description "Held network loader" -Condition {
        $requests = @([IO.Directory]::GetFiles($fixture, "network-hold.*.started") | Where-Object { $_ -notin $existing })
        if ($requests.Count -eq 1) { $script:held = $requests[0] -replace '\.started$', ''; return $true }
        return $false
    }
    return @{ Path = $script:held; Number = $state.Request }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-network-ui-$([Guid]::NewGuid().ToString('N'))"
$previous = @{}
$script:process = $null
$script:root = $null
$lock = $null
$phase = $null
$succeeded = $false
$primaryFailure = $null
$hold = Join-Path $fixture "network-hold"
foreach ($key in @("FINGVIBE_UI_REVIEW", "FINGVIBE_UI_REVIEW_INVENTORY", "FINGVIBE_UI_REVIEW_SNAPSHOT",
    "FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT", "FINGVIBE_UI_REVIEW_DEVICE_TABLE", "FINGVIBE_UI_REVIEW_NETWORK",
    "FINGVIBE_UI_REVIEW_NETWORK_ACTIVITY_HOLD")) { $previous[$key] = [Environment]::GetEnvironmentVariable($key) }
try {
    $null = New-Item -ItemType Directory -Path $fixture
    $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
    $phase = Start-UiRegressionPhase -Name "network-activity/counts-filters-and-lifecycle"
    New-NetworkActivityFixture $fixture
    $env:FINGVIBE_UI_REVIEW = "1"
    $env:FINGVIBE_UI_REVIEW_INVENTORY = Join-Path $fixture "inventory.json"
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = Join-Path $fixture "snapshot.json"
    $env:FINGVIBE_UI_REVIEW_DEVICE_TABLE = Join-Path $fixture "table.json"
    $env:FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT = "0"
    $env:FINGVIBE_UI_REVIEW_NETWORK = "ui-review-network"
    $env:FINGVIBE_UI_REVIEW_NETWORK_ACTIVITY_HOLD = $hold
    Start-NetworkApp
    $null = Wait-NetworkActivity
    Assert-NetworkPeers
    Assert-NetworkCell NetworkActivityCell-5-12 "*3 distinct devices; exact daily count*"
    Assert-NetworkCell NetworkActivityCell-5-13 "*0 distinct devices; exact daily count*"
    Assert-NetworkCell NetworkActivityCell-5-14 "*At least 2 devices*"
    Assert-NetworkCell NetworkActivityCell-5-15 "*Unknown - no eligible scan evidence*"
    Choose-NetworkActivity NetworkActivityRoom Office
    Choose-NetworkActivity NetworkActivityType Computer
    Choose-NetworkActivity NetworkActivityCategory Permanent
    Assert-NetworkCell NetworkActivityCell-5-12 "*1 distinct devices*"
    if ((Find-NetworkActivity NetworkActivityLegend).Current.Name -notlike "*to 1 *") { throw "Filtered scale was not recalculated." }
    Choose-NetworkActivity NetworkActivityRoom Unassigned
    Assert-NetworkCell NetworkActivityCell-5-12 "*0 distinct devices*"
    if ((Find-NetworkActivity NetworkActivityLegend).Current.Name -notlike "*0 only*") { throw "Zero-only legend is misleading." }
    Choose-NetworkActivity NetworkActivityType "All types"
    Choose-NetworkActivity NetworkActivityCategory "All categories"
    Choose-NetworkActivity NetworkActivityRoom "All rooms"
    Choose-NetworkActivity NetworkActivityPeriod "Last 30 days"
    Assert-NetworkCell NetworkActivityCell-29-23 "*-24:00*"
    Choose-NetworkActivity NetworkActivityPeriod "30 days by weekday"
    Assert-NetworkCell NetworkActivityCell-2-9 "*Average 12 devices; exact sum 36 / 3 exact dates*"
    [Windows.Forms.SendKeys]::SendWait("{RIGHT}{LEFT}{ENTER}")
    Assert-NetworkCell NetworkActivityCell-2-9 "*3 / * applicable dates observed*"
    Save-UiRegressionScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "network-weekdays.png")

    foreach ($action in @("filter", "period", "hours", "navigation")) {
        $request = Hold-NetworkActivity
        switch ($action) {
            filter { $null = Show-NetworkActivity NetworkActivityRoom; Set-UiReviewAppearanceChoice -Root $script:root -Picker NetworkActivityRoom -Choice Office }
            period { $null = Show-NetworkActivity NetworkActivityPeriod; Set-UiReviewAppearanceChoice -Root $script:root -Picker NetworkActivityPeriod -Choice "Last 7 days" }
            hours { (Show-NetworkActivity NetworkActivityHours).GetCurrentPattern([Windows.Automation.RangeValuePattern]::Pattern).SetValue(2) }
            navigation { (Find-NetworkActivity DevicesNavItem).GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select() }
        }
        $null = Wait-UiRegressionState -Description "$action cancels obsolete Network activity" -Condition { Test-Path -LiteralPath "$($request.Path).cancelled" }
        Remove-Item -LiteralPath $hold
        if ($action -eq "navigation") {
            (Find-NetworkActivity NetworkNavItem).GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
        }
        $null = Wait-NetworkActivity $request.Number
        Assert-NetworkPeers
    }
    $lock = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$(Join-Path $fixture 'inventory.sqlite');Pooling=False")
    $lock.Open()
    $command = $lock.CreateCommand()
    $command.CommandText = "BEGIN EXCLUSIVE"
    $null = $command.ExecuteNonQuery()
    $before = (Get-UiRegressionSurfaceState -GetElement { Find-NetworkActivity NetworkActivityScroll } -Description Network).Request
    (Show-NetworkActivity NetworkActivityRefresh).GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    $errorState = Wait-NetworkActivity $before Error
    Assert-NetworkPeers
    if ((Find-NetworkActivity NetworkActivityRefresh).Current.Name -ne "Retry" -or (Find-NetworkActivity NetworkActivityCell-0-0)) {
        throw "Query error must clear stale cells and offer Retry."
    }
    $command.CommandText = "ROLLBACK"; $null = $command.ExecuteNonQuery(); $command.Dispose(); $lock.Dispose(); $lock = $null
    (Show-NetworkActivity NetworkActivityRefresh).GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    $null = Wait-NetworkActivity $errorState.Request
    foreach ($hours in @(3, 4, 1)) {
        $before = (Get-UiRegressionSurfaceState -GetElement { Find-NetworkActivity NetworkActivityScroll } -Description Network).Request
        (Show-NetworkActivity NetworkActivityHours).GetCurrentPattern([Windows.Automation.RangeValuePattern]::Pattern).SetValue($hours)
        $null = Wait-NetworkActivity $before
        Assert-NetworkCell "NetworkActivityCell-5-$((24 / $hours) - 1)" "*-24:00*"
    }
    foreach ($theme in @("Standard Light", "Standard Dark")) {
        $before = (Get-UiRegressionSurfaceState -GetElement { Find-NetworkActivity NetworkActivityScroll } -Description Network).Request
        $settings = $script:root.FindFirst([Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.AndCondition]::new(
                [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty, "Settings"),
                [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [Windows.Automation.ControlType]::ListItem)))
        $settings.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
        $null = Wait-UiRegressionState -Description "Settings appearance" -Condition {
            $picker = Find-NetworkActivity ModePicker
            $picker -and -not $picker.Current.IsOffscreen
        }
        Set-UiReviewTheme -Root $script:root -Theme $theme
        (Find-NetworkActivity NetworkNavItem).GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
        $null = Wait-NetworkActivity $before
        Assert-NetworkCell NetworkActivityCell-5-12 "*2 distinct devices*"
        Save-UiRegressionScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "network-$($theme.Replace(' ', '-')).png")
    }
    $bounds = Get-UiReviewWindowBounds $script:process.MainWindowHandle
    $null = [UiReviewNativeWindow]::SetWindowPos($script:process.MainWindowHandle, [IntPtr]::Zero,
        $bounds.Left, $bounds.Top, 640, $bounds.Height, 0x0044)
    Start-Sleep -Milliseconds 300
    foreach ($id in @("NetworkActivityPeriod", "NetworkActivityRoom", "NetworkActivityType", "NetworkActivityCategory", "NetworkActivityHours")) {
        $null = Show-NetworkActivity $id
    }
    Assert-NetworkCell NetworkActivityCell-5-23 "*-24:00*"
    if (-not (Find-NetworkActivity NetworkActivityScroll).GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern).Current.HorizontallyScrollable) {
        throw "Narrow Network activity must retain horizontally reachable cells."
    }
    Save-UiRegressionScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "network-narrow.png")
    $request = Hold-NetworkActivity
    Stop-UiRegressionApp -Process $script:process
    if (-not (Test-Path -LiteralPath "$($request.Path).cancelled")) { throw "Closing failed to cancel Network activity." }
    $empty = Join-Path $fixture "empty"
    $null = New-Item -ItemType Directory -Path $empty
    New-NetworkActivityFixture $empty -Empty
    $env:FINGVIBE_UI_REVIEW_INVENTORY = Join-Path $empty "inventory.json"
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = Join-Path $empty "snapshot.json"
    Remove-Item -LiteralPath $hold
    Start-NetworkApp
    $null = Wait-NetworkActivity -State Empty
    Assert-NetworkPeers
    if ((Find-NetworkActivity NetworkActivityStatus).Current.Name -notlike "*No completed scan history*") { throw "Empty history was not disclosed." }
    Assert-NetworkCell NetworkActivityCell-5-12 "*Unknown - no eligible scan evidence*"
    Stop-UiRegressionApp -Process $script:process
    $succeeded = $true
}
catch {
    $primaryFailure = $_
    Write-Host $_
    Write-Host $_.ScriptStackTrace
    if ($script:process -and -not $script:process.HasExited) {
        Write-Host "Network activity state: $((Find-NetworkActivity NetworkActivityScroll).Current.ItemStatus)"
        try { Save-UiRegressionScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "network-activity-failure.png") }
        catch { Write-Warning "Failure screenshot unavailable: $_" }
    }
    throw
}
finally {
    if ($lock) { $lock.Dispose() }
    if ($script:process -and -not $script:process.HasExited) {
        try { Stop-UiRegressionApp -Process $script:process }
        catch { if ($primaryFailure) { Write-Warning "Cleanup also failed: $_" } else { throw } }
    }
    if ($phase) { Complete-UiRegressionPhase -Phase $phase -Directory $ScreenshotDirectory -Succeeded $succeeded }
    foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key]) }
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
