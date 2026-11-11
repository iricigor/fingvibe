param([Parameter(Mandatory)][string] $AppPath, [Parameter(Mandatory)][string] $ScreenshotDirectory)
$ErrorActionPreference = "Stop"
if ($env:GITHUB_ACTIONS -ne "true") { throw "Equipment activity checks require a disposable GitHub Actions desktop." }
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScreenshot.ps1")
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewAppearance.ps1")
. (Join-Path $PSScriptRoot "UiRegression\Helpers.ps1")
. (Join-Path $PSScriptRoot "Inventory.Sqlite.Helpers.ps1")
. (Join-Path $PSScriptRoot "NetworkActivity.Fixture.ps1")
Initialize-InventorySqlite $AppPath
$null = [Reflection.Assembly]::LoadFrom((Join-Path (Split-Path $AppPath) "FingVibe.Core.dll"))
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms

function Find-Equipment([string] $Id, [switch] $ByName) {
    if (-not $script:root) { return $null }
    $scope = $script:root
    if ($Id -like "EquipmentActivityCell-*") { $scope = Find-Equipment EquipmentActivityScroll }
    $property = if ($ByName) { [Windows.Automation.AutomationElement]::NameProperty }
        else { [Windows.Automation.AutomationElement]::AutomationIdProperty }
    if ($scope) {
        $scope.FindFirst([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.PropertyCondition]::new($property, $Id))
    }
}
function Wait-Equipment([int] $After = 0, [string] $State = "Ready") {
    Wait-UiRegressionSurfaceState -GetElement { Find-Equipment EquipmentActivityScroll } `
        -Description "Person equipment activity" -After $After -State $State
}
function Show-Equipment([string] $Id, [switch] $ByName) {
    $target = Wait-UiRegressionState -Description "Equipment '$Id' peer" -Condition { Find-Equipment $Id -ByName:$ByName }
    if ($target.Current.IsKeyboardFocusable) {
        $target.SetFocus()
        $pattern = $null
        if ($target.TryGetCurrentPattern([Windows.Automation.ScrollItemPattern]::Pattern, [ref]$pattern)) { $pattern.ScrollIntoView() }
        $null = Wait-UiRegressionState -Description "Equipment '$Id' reachability" -Condition {
            Test-UiRegressionElementWithin (Find-Equipment $Id -ByName:$ByName) (Find-Equipment PersonDetailPage) $script:root
        }
        return Find-Equipment $Id -ByName:$ByName
    }
    Show-UiRegressionScrollTargets -Description "Equipment '$Id'" -GetViewport { Find-Equipment PersonDetailPage } `
        -GetWindow { $script:root } -GetTargets { Find-Equipment $Id -ByName:$ByName }
}
function Open-EquipmentPerson([string] $Name = "Equipment person") {
    (Find-Equipment PeopleNavItem).GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    if (Find-Equipment "Back to people" -ByName) {
        (Show-Equipment "Back to people" -ByName).GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    }
    $row = Wait-UiRegressionState -Description "Equipment person list row" -Condition { Find-Equipment $Name -ByName }
    $walker = [Windows.Automation.TreeWalker]::ControlViewWalker
    while ($row -and $row.Current.ControlType -ne [Windows.Automation.ControlType]::ListItem) { $row = $walker.GetParent($row) }
    if (-not $row) { throw "Missing Person list item for '$Name'." }
    $row.SetFocus()
    [Windows.Forms.SendKeys]::SendWait("{ENTER}")
}
function Start-EquipmentApp {
    $script:process = Start-Process -FilePath $AppPath -PassThru
    $null = Wait-UiRegressionState -Description "Equipment fixture startup" -Condition {
        $script:process.Refresh()
        if ($script:process.HasExited) { throw "Equipment fixture app exited." }
        $script:process.MainWindowHandle -ne [IntPtr]::Zero
    }
    Initialize-UiReviewWindow $script:process.MainWindowHandle
    $script:root = [Windows.Automation.AutomationElement]::FromHandle($script:process.MainWindowHandle)
    $null = Wait-UiRegressionState -Description "Equipment navigation" -Condition { Find-Equipment PeopleNavItem }
    Open-EquipmentPerson
}
function Assert-EquipmentPeers {
    Assert-UiRegressionPeers -Root $script:root -Description "Equipment state" -AutomationIds @(
        "EquipmentIndicator", "EquipmentIndicatorContext", "EquipmentActivityPeriod", "EquipmentActivityHours",
        "EquipmentActivityWindow", "EquipmentActivityContributors", "EquipmentActivityStatus", "EquipmentActivityScroll",
        "EquipmentActivityLegend", "EquipmentActivityDetail", "EquipmentActivityRefresh")
}
function Assert-EquipmentCell([string] $Id, [string] $Pattern) {
    $cell = Show-Equipment $Id
    if ($cell.Current.Name -notlike $Pattern) { throw "Incorrect $Id`: $($cell.Current.Name)" }
    if ((Find-Equipment EquipmentActivityDetail).Current.Name -ne $cell.Current.Name) {
        throw "Keyboard focus must expose current equipment cell details."
    }
}
function Choose-EquipmentPeriod([string] $Choice) {
    $before = (Get-UiRegressionSurfaceState -GetElement { Find-Equipment EquipmentActivityScroll } -Description Equipment).Request
    $null = Show-Equipment EquipmentActivityPeriod
    Set-UiReviewAppearanceChoice -Root $script:root -Picker EquipmentActivityPeriod -Choice $Choice
    $null = Wait-Equipment $before
}
function Hold-Equipment {
    $before = (Get-UiRegressionSurfaceState -GetElement { Find-Equipment EquipmentActivityScroll } -Description Equipment).Request
    $existing = @([IO.Directory]::GetFiles($fixture, "equipment-hold.*.started"))
    Set-Content -LiteralPath $hold -Value hold
    (Show-Equipment EquipmentActivityRefresh).GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    $state = Wait-Equipment $before Loading
    Assert-EquipmentPeers
    if (Find-Equipment EquipmentActivityCell-0-0) { throw "Stale cells remain while loading." }
    $started = Wait-UiRegressionState -Description "Held equipment loader" -Condition {
        $requests = @([IO.Directory]::GetFiles($fixture, "equipment-hold.*.started") | Where-Object { $_ -notin $existing })
        if ($requests.Count -eq 1) { return $requests[0] }
        return $null
    }
    return @{ Path = $started -replace '\.started$', ''; Number = $state.Request }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-equipment-ui-$([Guid]::NewGuid().ToString('N'))"
$hold = Join-Path $fixture "equipment-hold"
$previous = @{}
$script:process = $null
$script:root = $null
$lock = $null
$phase = $null
$succeeded = $false
$primaryFailure = $null
foreach ($key in @("FINGVIBE_UI_REVIEW", "FINGVIBE_UI_REVIEW_INVENTORY", "FINGVIBE_UI_REVIEW_SNAPSHOT",
    "FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT", "FINGVIBE_UI_REVIEW_DEVICE_TABLE", "FINGVIBE_UI_REVIEW_NETWORK",
    "FINGVIBE_UI_REVIEW_EQUIPMENT_ACTIVITY_HOLD")) { $previous[$key] = [Environment]::GetEnvironmentVariable($key) }
try {
    $null = New-Item -ItemType Directory -Path $fixture
    $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
    $phase = Start-UiRegressionPhase -Name "equipment/counts-indicator-and-lifecycle"
    New-NetworkActivityFixture $fixture -Equipment
    $env:FINGVIBE_UI_REVIEW = "1"
    $env:FINGVIBE_UI_REVIEW_INVENTORY = Join-Path $fixture "inventory.json"
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = Join-Path $fixture "snapshot.json"
    $env:FINGVIBE_UI_REVIEW_DEVICE_TABLE = Join-Path $fixture "table.json"
    $env:FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT = "0"
    $env:FINGVIBE_UI_REVIEW_NETWORK = "ui-review-network"
    $env:FINGVIBE_UI_REVIEW_EQUIPMENT_ACTIVITY_HOLD = $hold
    Start-EquipmentApp
    $null = Wait-Equipment
    Assert-EquipmentPeers
    if ((Find-Equipment EquipmentIndicator).Current.Name -ne "Equipment online" -or
        (Find-Equipment EquipmentIndicatorContext).Current.Name -notlike "*2 of 3*ui-review-network*Older scan*") {
        throw "Latest selected-network equipment response count/age is incorrect."
    }
    Assert-EquipmentCell EquipmentActivityCell-5-12 "*2 distinct devices*Responded: network-0, network-1*"
    Assert-EquipmentCell EquipmentActivityCell-5-13 "*0 distinct devices*"
    Assert-EquipmentCell EquipmentActivityCell-5-14 "*At least 2 devices*Unknown/ineligible: network-999*"
    Assert-EquipmentCell EquipmentActivityCell-5-15 "*Unknown - no eligible scan evidence*"
    Choose-EquipmentPeriod "Last 30 days"
    Assert-EquipmentCell EquipmentActivityCell-29-23 "*-24:00*"
    Choose-EquipmentPeriod "30 days by weekday"
    Assert-EquipmentCell EquipmentActivityCell-2-10 "*Average 1.5 devices; exact sum 3 / 2 exact dates*"
    [Windows.Forms.SendKeys]::SendWait("{RIGHT}{LEFT}{ENTER}")
    Assert-EquipmentCell EquipmentActivityCell-2-10 "*2 / * applicable dates observed*"
    Save-UiRegressionScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "equipment-weekdays.png")
    $null = Show-Equipment "Permanent - Manual" -ByName
    $null = Show-Equipment "Guest - Manual" -ByName

    foreach ($action in @("period", "hours", "person", "navigation")) {
        $request = Hold-Equipment
        switch ($action) {
            period {
                $null = Show-Equipment EquipmentActivityPeriod
                Set-UiReviewAppearanceChoice -Root $script:root -Picker EquipmentActivityPeriod -Choice "Last 7 days"
            }
            hours { (Show-Equipment EquipmentActivityHours).GetCurrentPattern([Windows.Automation.RangeValuePattern]::Pattern).SetValue(2) }
            person { Open-EquipmentPerson "No equipment" }
            navigation { (Find-Equipment DevicesNavItem).GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select() }
        }
        $null = Wait-UiRegressionState -Description "$action cancels obsolete equipment" -Condition {
            Test-Path -LiteralPath "$($request.Path).cancelled"
        }
        Remove-Item -LiteralPath $hold
        if ($action -eq "person") {
            $null = Wait-Equipment $request.Number Empty
            if ((Find-Equipment EquipmentIndicator).Current.Name -ne "No equipment assigned" -or
                (Find-Equipment EquipmentActivityCell-0-0)) { throw "No assignments must not invent a grid estimate." }
            Open-EquipmentPerson
        }
        if ($action -eq "navigation") { Open-EquipmentPerson }
        $null = Wait-Equipment $request.Number
        Assert-EquipmentPeers
    }
    Complete-UiRegressionPhase -Phase $phase -Directory $ScreenshotDirectory -Succeeded $true
    $phase = Start-UiRegressionPhase -Name "equipment/error-retry-appearance-and-empty"
    $lock = [Microsoft.Data.Sqlite.SqliteConnection]::new("Data Source=$(Join-Path $fixture 'inventory.sqlite');Pooling=False")
    $lock.Open()
    $command = $lock.CreateCommand()
    $command.CommandText = "BEGIN EXCLUSIVE"
    $null = $command.ExecuteNonQuery()
    $before = (Get-UiRegressionSurfaceState -GetElement { Find-Equipment EquipmentActivityScroll } -Description Equipment).Request
    (Show-Equipment EquipmentActivityRefresh).GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    $errorState = Wait-Equipment $before Error
    Assert-EquipmentPeers
    if ((Find-Equipment EquipmentActivityRefresh).Current.Name -ne "Retry" -or
        (Find-Equipment EquipmentIndicator).Current.Name -ne "Unknown" -or (Find-Equipment EquipmentActivityCell-0-0)) {
        throw "A failed query must clear stale grid/indicator evidence and offer Retry."
    }
    $command.CommandText = "ROLLBACK"; $null = $command.ExecuteNonQuery(); $command.Dispose(); $lock.Dispose(); $lock = $null
    (Show-Equipment EquipmentActivityRefresh).GetCurrentPattern([Windows.Automation.InvokePattern]::Pattern).Invoke()
    $null = Wait-Equipment $errorState.Request
    foreach ($hours in @(3, 4, 1)) {
        $before = (Get-UiRegressionSurfaceState -GetElement { Find-Equipment EquipmentActivityScroll } -Description Equipment).Request
        (Show-Equipment EquipmentActivityHours).GetCurrentPattern([Windows.Automation.RangeValuePattern]::Pattern).SetValue($hours)
        $null = Wait-Equipment $before
        Assert-EquipmentCell "EquipmentActivityCell-5-$((24 / $hours) - 1)" "*-24:00*"
    }
    foreach ($theme in @("Standard Light", "Standard Dark")) {
        $settings = $script:root.FindFirst([Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.AndCondition]::new(
                [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty, "Settings"),
                [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [Windows.Automation.ControlType]::ListItem)))
        $settings.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
        $null = Wait-UiRegressionState -Description "Equipment appearance settings" -Condition {
            $picker = Find-Equipment ModePicker
            $picker -and -not $picker.Current.IsOffscreen
        }
        Set-UiReviewTheme -Root $script:root -Theme $theme
        Open-EquipmentPerson
        $null = Wait-Equipment
        Assert-EquipmentCell EquipmentActivityCell-5-12 "*2 distinct devices*"
        Save-UiRegressionScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "equipment-$($theme.Replace(' ', '-')).png")
    }
    $bounds = Get-UiReviewWindowBounds $script:process.MainWindowHandle
    $null = [UiReviewNativeWindow]::SetWindowPos($script:process.MainWindowHandle, [IntPtr]::Zero,
        $bounds.Left, $bounds.Top, 640, $bounds.Height, 0x0044)
    Start-Sleep -Milliseconds 300
    $null = Show-Equipment EquipmentActivityPeriod
    $null = Show-Equipment EquipmentActivityHours
    Assert-EquipmentCell EquipmentActivityCell-5-23 "*-24:00*"
    if (-not (Find-Equipment EquipmentActivityScroll).GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern).Current.HorizontallyScrollable) {
        throw "Narrow equipment cells must remain horizontally reachable."
    }
    $null = Show-Equipment AssignPersonDevicesButton
    $null = Show-Equipment EditPersonDetailButton
    $null = Show-Equipment DeletePersonDetailButton
    Save-UiRegressionScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "equipment-narrow.png")
    $request = Hold-Equipment
    Stop-UiRegressionApp -Process $script:process
    if (-not (Test-Path -LiteralPath "$($request.Path).cancelled")) { throw "Closing failed to cancel equipment activity." }
    $empty = Join-Path $fixture "empty"
    $null = New-Item -ItemType Directory -Path $empty
    New-NetworkActivityFixture $empty -Equipment -Empty
    $env:FINGVIBE_UI_REVIEW_INVENTORY = Join-Path $empty "inventory.json"
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = Join-Path $empty "snapshot.json"
    Remove-Item -LiteralPath $hold
    Start-EquipmentApp
    $null = Wait-Equipment -State Empty
    Assert-EquipmentPeers
    if ((Find-Equipment EquipmentActivityStatus).Current.Name -notlike "*No completed scan history*" -or
        (Find-Equipment EquipmentIndicator).Current.Name -ne "Unknown") { throw "Missing equipment history was not disclosed." }
    Assert-EquipmentCell EquipmentActivityCell-5-12 "*Unknown - no eligible scan evidence*"
    Stop-UiRegressionApp -Process $script:process
    $succeeded = $true
}
catch {
    $primaryFailure = $_
    Write-Host $_
    Write-Host $_.ScriptStackTrace
    if ($script:process -and -not $script:process.HasExited) {
        Write-Host "Equipment state: $((Find-Equipment EquipmentActivityScroll).Current.ItemStatus)"
        try { Save-UiRegressionScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "equipment-failure.png") }
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
    Get-ChildItem -LiteralPath $fixture -Filter "equipment-hold.*" -ErrorAction SilentlyContinue | Copy-Item -Destination $ScreenshotDirectory
    foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key]) }
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
