param(
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $ScreenshotDirectory
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScreenshot.ps1")
. (Join-Path $PSScriptRoot "UiRegression\Helpers.ps1")
. (Join-Path $PSScriptRoot "Inventory.Sqlite.Helpers.ps1")

function Find-DiscoveryControl([string] $Id, [switch] $Optional) {
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)
    $call = Start-UiRegressionCall lookup
    try { $element = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition) }
    finally { Complete-UiRegressionCall $call }
    if (-not $element -and -not $Optional) { throw "Missing discovery control '$Id'." }
    return $element
}

function Wait-DiscoveryState([scriptblock] $Predicate, [string] $Description) {
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

function Start-DiscoveryApp {
    $call = Start-UiRegressionCall launch
    try {
        $script:process = Start-Process -FilePath $AppPath -PassThru
        Wait-DiscoveryState {
            $script:process.Refresh()
            if ($script:process.HasExited) { throw "Discovery app exited: $($script:process.ExitCode)." }
            $script:process.MainWindowHandle -ne [IntPtr]::Zero
        } "discovery window"
        Initialize-UiReviewWindow $script:process.MainWindowHandle
        $script:root = [System.Windows.Automation.AutomationElement]::FromHandle($script:process.MainWindowHandle)
        Wait-DiscoveryState { Find-DiscoveryControl DevicesNavItem -Optional } "device navigation"
        (Find-DiscoveryControl DevicesNavItem).GetCurrentPattern(
            [System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        Wait-DiscoveryState {
            $scan = Find-DiscoveryControl ScanButton -Optional
            $scan -and $scan.Current.IsEnabled
        } "ready scan"
        Assert-NoDiscovery
    }
    finally { Complete-UiRegressionCall $call }
}

function Stop-DiscoveryApp {
    $call = Start-UiRegressionCall close
    try {
        $null = $script:process.CloseMainWindow()
        if (-not $script:process.WaitForExit(5000)) { throw "Discovery app did not close normally." }
    }
    finally { Complete-UiRegressionCall $call }
}

function Assert-NoDiscovery {
    $popup = Find-DiscoveryControl DiscoveryPopup -Optional
    if ($popup -and -not $popup.Current.IsOffscreen) { throw "Unexpected discovery popup." }
}

function Set-DiscoveryResults([string[]] $Macs) {
    $results = @($Macs | ForEach-Object {
        @{ address = "127.0.0.1"; status = 0; roundtripTimeMilliseconds = 1; probeDuration = "00:00:00.001"
           deviceName = $null; macAddress = $_; vendorName = $(if ($_ -like "D0C907*") { "Private" } else { "Example" })
           openPorts = @() }
    })
    @{ version = 3; subnet = "127.0.0.1/32"; completedAt = "2026-11-01T12:01:00+00:00"; results = $results } |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $fixture -Encoding UTF8
}

function Invoke-DiscoveryScan {
    $call = Start-UiRegressionCall scan
    try {
        $backCondition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, "Back to devices")
        $back = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $backCondition)
        if ($back -and -not $back.Current.IsOffscreen) {
            $back.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        }
        (Find-DiscoveryControl ScanButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        Wait-DiscoveryState {
            $scan = Find-DiscoveryControl ScanButton -Optional
            $scan -and -not $scan.Current.IsOffscreen -and $scan.Current.IsEnabled
        } "completed scan"
        Start-Sleep -Milliseconds 300
    }
    finally { Complete-UiRegressionCall $call }
}

function Assert-DiscoveryEntries([string[]] $Macs, [string] $Capture) {
    Wait-DiscoveryState { Find-DiscoveryControl DiscoveryPopup -Optional } "discovery popup"
    $buttons = $script:root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition) |
        Where-Object { $_.Current.AutomationId -like "Discovery-*" }
    if (@($buttons).Count -ne $Macs.Count) { throw "Expected $($Macs.Count) entries; got $(@($buttons).Count)." }
    foreach ($mac in $Macs) {
        $link = Find-DiscoveryControl "Discovery-$mac"
        $formatted = ($mac -split '(.{2})' | Where-Object { $_ }) -join "-"
        if ($link.Current.Name -ne "Open details for $formatted" -or $link.Current.IsOffscreen) {
            throw "Incorrect or hidden discovery link for $mac."
        }
        $bounds = $link.Current.BoundingRectangle
        $window = $script:root.Current.BoundingRectangle
        if ($bounds.Left -lt $window.Left -or $bounds.Right -gt $window.Right -or $bounds.Bottom -gt $window.Bottom) {
            throw "Discovery link is clipped."
        }
    }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "$Capture.png")
}

$previous = @{}
foreach ($key in @("FINGVIBE_UI_REVIEW", "FINGVIBE_UI_REVIEW_INVENTORY", "FINGVIBE_UI_REVIEW_SNAPSHOT",
    "FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT", "FINGVIBE_UI_REVIEW_SCAN_RESULTS", "FINGVIBE_UI_REVIEW_NETWORK",
    "FINGVIBE_UI_REVIEW_SCAN_HOLD", "FINGVIBE_UI_REVIEW_PERIODIC_SCAN", "FINGVIBE_UI_REVIEW_PERIODIC_SCAN_TIME_SCALE",
    "FINGVIBE_UI_REVIEW_CHECKPOINT_HOLD", "FINGVIBE_UI_REVIEW_DEVICE_TABLE")) {
    $previous[$key] = [Environment]::GetEnvironmentVariable($key)
}
$directory = Join-Path ([System.IO.Path]::GetTempPath()) "fingvibe-discovery-ui-$([Guid]::NewGuid().ToString('N'))"
$inventory = Join-Path $directory "inventory.json"
$database = [System.IO.Path]::ChangeExtension($inventory, ".sqlite")
$fixture = Join-Path $directory "results.json"
$snapshot = Join-Path $directory "snapshot.json"
$hold = Join-Path $directory "scan.hold"
$checkpointHold = Join-Path $directory "checkpoint.hold"
$periodicScan = Join-Path $directory "periodic-scan.json"
$script:process = $null
$lock = $null
$phase = $null
$failed = $false
try {
    $null = New-Item -ItemType Directory -Path $directory
    $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
    $phase = Step-UiRegressionPhase $phase "discovery/target-links" $ScreenshotDirectory
    $env:FINGVIBE_UI_REVIEW = "1"
    $env:FINGVIBE_UI_REVIEW_INVENTORY = $inventory
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = $snapshot
    $env:FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT = "0"
    $env:FINGVIBE_UI_REVIEW_SCAN_RESULTS = $fixture
    $env:FINGVIBE_UI_REVIEW_SCAN_HOLD = $hold
    $env:FINGVIBE_UI_REVIEW_NETWORK = "ui-review-network"
    $env:FINGVIBE_UI_REVIEW_CHECKPOINT_HOLD = $null
    $env:FINGVIBE_UI_REVIEW_DEVICE_TABLE = $null
    $observation = @{
        networkId = "ui-review-network"; subnet = "127.0.0.1/32"; address = "127.0.0.1"; hostname = $null
        vendor = "Example"; ports = @(); latency = 1; probeDuration = "00:00:00.001"
        classification = @{ type = 0; operatingSystem = 0; typeEvidence = "Fixture"; operatingSystemEvidence = "Fixture" }
        firstSeen = "2026-11-01T12:00:00+00:00"; lastSeen = "2026-11-01T12:00:00+00:00"
        lastChecked = "2026-11-01T12:00:00+00:00"; present = $true
    }
    $legacy = @{ version = 3; data = @{
        revision = [Guid]::NewGuid().ToString()
        devices = @{
            "020000000001" = @{ mac = "020000000001"; imported = @{}; observations = @($observation) }
            "001122334466" = @{ mac = "001122334466"; imported = @{ name = "Imported discovery" }; observations = @() }
        }
        names = @{}; classifications = @{}; peopleRooms = @{ people = @(); rooms = @(); assignments = @{} }
        virtualDevices = @()
    }} | ConvertTo-Json -Depth 15
    foreach ($target in @("001122334466", "D0C907000001")) {
        Set-Content -LiteralPath $inventory -Value $legacy -Encoding UTF8
        if (Test-Path -LiteralPath $database) { Remove-Item -LiteralPath $database }
        if (Test-Path -LiteralPath $snapshot) { Remove-Item -LiteralPath $snapshot }
        Start-DiscoveryApp
        Set-DiscoveryResults @("020000000001")
        Invoke-DiscoveryScan
        Assert-NoDiscovery
        Set-DiscoveryResults @("020000000001", "001122334466", "D0C907000001")
        Invoke-DiscoveryScan
        Assert-DiscoveryEntries @("001122334466", "D0C907000001") "discovery-$target"
        (Find-DiscoveryControl "Discovery-$target").GetCurrentPattern(
            [System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        Wait-DiscoveryState {
            $details = Find-DiscoveryControl DeviceDetailsScroll -Optional
            $details -and -not $details.Current.IsOffscreen
        } "linked details"
        $expectedName = if ($target -eq "001122334466") { "Imported discovery" } else { "Private D0-C9-07" }
        $nameCondition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, $expectedName)
        if (-not (Find-DiscoveryControl DeviceDetailsScroll).FindFirst(
            [System.Windows.Automation.TreeScope]::Descendants, $nameCondition)) {
            throw "Discovery did not open details for $expectedName."
        }
        Invoke-DiscoveryScan
        Assert-NoDiscovery
        Stop-DiscoveryApp
    }
    $phase = Step-UiRegressionPhase $phase "discovery/cancel-failure-save" $ScreenshotDirectory
    Start-DiscoveryApp
    Set-DiscoveryResults @()
    Invoke-DiscoveryScan
    Assert-NoDiscovery
    Set-DiscoveryResults @("020000000001", "001122334466", "D0C907000002")
    Invoke-DiscoveryScan
    Assert-NoDiscovery
    $before = Get-InventoryFingerprint $database
    Set-DiscoveryResults @("001122334477")
    Set-Content -LiteralPath $hold -Value "cancelled scan"
    (Find-DiscoveryControl ScanButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-DiscoveryState { (Find-DiscoveryControl CancelButton).Current.IsEnabled } "cancellable scan"
    (Find-DiscoveryControl CancelButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-DiscoveryState { (Find-DiscoveryControl ScanButton).Current.IsEnabled } "cancelled scan"
    Assert-NoDiscovery
    if ((Get-InventoryFingerprint $database) -cne $before) { throw "Cancellation persisted discovery evidence." }
    Remove-Item -LiteralPath $hold
    Set-Content -LiteralPath $fixture -Value "invalid scan fixture"
    Invoke-DiscoveryScan
    Assert-NoDiscovery
    if ((Find-DiscoveryControl ScanStatusText).Current.Name -notlike "*Unable to scan*") { throw "Scan failure was hidden." }
    if ((Get-InventoryFingerprint $database) -cne $before) { throw "Failed scan persisted discovery evidence." }
    Set-DiscoveryResults @("001122334477")
    $lock = [System.IO.FileStream]::new("$inventory.lock", [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    Invoke-DiscoveryScan
    Assert-NoDiscovery
    if ((Find-DiscoveryControl ScanStatusText).Current.Name -notlike "*Scan checkpoint could not be saved*") {
        throw "Discovery persistence failure was hidden."
    }
    if ((Get-InventoryFingerprint $database) -cne $before) { throw "Failed save changed durable newness." }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "discovery-save-failure.png")
    $lock.Dispose()
    $lock = $null
    Invoke-DiscoveryScan
    Assert-DiscoveryEntries @("001122334477") "discovery-save-retry"
    (Find-DiscoveryControl CloseDiscoveryPopup).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Stop-DiscoveryApp
    $phase = Step-UiRegressionPhase $phase "discovery/network-scope" $ScreenshotDirectory
    $env:FINGVIBE_UI_REVIEW_NETWORK = "unavailable"
    Start-DiscoveryApp
    Set-DiscoveryResults @("001122334488")
    Invoke-DiscoveryScan
    Assert-NoDiscovery
    if ((Find-DiscoveryControl ScanStatusText).Current.Name -notlike "*alerts and baseline establishment are disabled*") {
        throw "Unknown-network discovery limitation was hidden."
    }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "discovery-unknown-network.png")
    Stop-DiscoveryApp
    $env:FINGVIBE_UI_REVIEW_NETWORK = "network-b"
    Start-DiscoveryApp
    Set-DiscoveryResults @()
    Invoke-DiscoveryScan
    Assert-NoDiscovery
    Stop-DiscoveryApp
    Start-DiscoveryApp
    Set-DiscoveryResults @("001122334466")
    Invoke-DiscoveryScan
    Assert-DiscoveryEntries @("001122334466") "discovery-other-network"
    (Find-DiscoveryControl CloseDiscoveryPopup).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Stop-DiscoveryApp
    Start-DiscoveryApp
    Invoke-DiscoveryScan
    Assert-NoDiscovery
    Stop-DiscoveryApp
    $phase = Step-UiRegressionPhase $phase "discovery/checkpoint" $ScreenshotDirectory
    # Initial checkpoints restore browsing but retain cancellation and defer discoveries until completion.
    $env:FINGVIBE_UI_REVIEW_CHECKPOINT_HOLD = $checkpointHold
    Set-Content -LiteralPath $checkpointHold -Value "pending retries"
    Set-DiscoveryResults @("001122334466", "0011223344AA")
    Start-DiscoveryApp
    (Find-DiscoveryControl ScanButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-DiscoveryState {
        (Find-DiscoveryControl ScanStatusText).Current.Name -like "*Initial results shown*(1/5) Background ARP:*"
    } "checkpointed initial results"
    $pendingScanButton = Find-DiscoveryControl ScanButton -Optional
    if (($pendingScanButton -and $pendingScanButton.Current.IsEnabled) -or
        -not (Find-DiscoveryControl CancelButton).Current.IsEnabled) { throw "Pending retries must retain scan exclusion and cancellation." }
    Assert-NoDiscovery
    $checkpoint = Get-Content -LiteralPath $snapshot -Raw | ConvertFrom-Json
    if ($checkpoint.state -ne 1) { throw "Initial checkpoint was not durably marked Pending." }
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem)
    Wait-DiscoveryState {
        (Find-DiscoveryControl ResultsList).FindAll([System.Windows.Automation.TreeScope]::Children, $condition).Count -gt 0
    } "realized initial result rows"
    $row = (Find-DiscoveryControl ResultsList).FindAll([System.Windows.Automation.TreeScope]::Children, $condition)[0]
    $row.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $row.SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
    Wait-DiscoveryState {
        $details = Find-DiscoveryControl DeviceDetailsScroll -Optional
        $details -and -not $details.Current.IsOffscreen
    } "browsable initial results"
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "scan-initial-checkpoint.png")
    # Closing during the pending phase drains its incomplete checkpoint before the process exits.
    Stop-DiscoveryApp
    $checkpoint = Get-Content -LiteralPath $snapshot -Raw | ConvertFrom-Json
    if ($checkpoint.state -ne 2) { throw "Normal close did not retain an Incomplete checkpoint." }
    Start-DiscoveryApp
    if ((Find-DiscoveryControl ScanFreshnessText).Current.Name -notlike "*Incomplete scan*") {
        throw "Restart misrepresented an interrupted checkpoint as complete."
    }
    if (-not (Find-DiscoveryControl ScanButton).Current.IsEnabled) { throw "Restart resumed an old retry timer." }
    Assert-NoDiscovery
    # A later final checkpoint updates the same scan without stealing focus from browsing.
    (Find-DiscoveryControl ScanButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-DiscoveryState {
        (Find-DiscoveryControl ScanStatusText).Current.Name -like "*Initial results shown*(1/5) Background ARP:*"
    } "second initial checkpoint"
    Wait-DiscoveryState {
        (Find-DiscoveryControl ResultsList).FindAll([System.Windows.Automation.TreeScope]::Children, $condition).Count -gt 0
    } "realized second result rows"
    $row = (Find-DiscoveryControl ResultsList).FindAll([System.Windows.Automation.TreeScope]::Children, $condition)[0]
    $row.SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
    Wait-DiscoveryState {
        $details = Find-DiscoveryControl DeviceDetailsScroll -Optional
        $details -and -not $details.Current.IsOffscreen
    } "details during background confirmation"
    (Find-DiscoveryControl DeviceRenameButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $nameInput = Find-DiscoveryControl DeviceNameInput
    $nameInput.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue("Keep this draft")
    $nameInput.SetFocus()
    $id = (Get-Content -LiteralPath $snapshot -Raw | ConvertFrom-Json).scanId
    Remove-Item -LiteralPath $checkpointHold
    Wait-DiscoveryState {
        $saved = Get-Content -LiteralPath $snapshot -Raw | ConvertFrom-Json
        $cancel = Find-DiscoveryControl CancelButton -Optional
        $saved.state -eq 0 -and (-not $cancel -or -not $cancel.Current.IsEnabled)
    } "final checkpoint"
    if (-not $nameInput.Current.HasKeyboardFocus -or $nameInput.Current.IsOffscreen -or
        $nameInput.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -ne "Keep this draft") {
        throw "Final checkpoint stole focus or discarded an in-progress device-name edit."
    }
    $checkpoint = Get-Content -LiteralPath $snapshot -Raw | ConvertFrom-Json
    if ($checkpoint.state -ne 0 -or $checkpoint.scanId -ne $id) { throw "Finalization did not complete the same logical scan." }
    Assert-NoDiscovery
    Stop-DiscoveryApp
    $env:FINGVIBE_UI_REVIEW_CHECKPOINT_HOLD = $null
    $phase = Step-UiRegressionPhase $phase "discovery/minimized-scheduled" $ScreenshotDirectory
    # Scheduled scans keep running while minimized and defer discoveries until the window is restored.
    Set-Content -LiteralPath $periodicScan -Value '{"isEnabled":true,"intervalMinutes":15}' -Encoding ASCII
    $env:FINGVIBE_UI_REVIEW_PERIODIC_SCAN = $periodicScan
    $env:FINGVIBE_UI_REVIEW_PERIODIC_SCAN_TIME_SCALE = "60"
    Set-DiscoveryResults @("001122334466", "001122334499")
    Start-DiscoveryApp
    $handle = $script:process.MainWindowHandle
    if ((Test-Path -LiteralPath $snapshot) -and (Get-Content -LiteralPath $snapshot -Raw) -like "*001122334499*") {
        throw "The scheduled scan ran before the window could be minimized."
    }
    $null = [UiReviewNativeWindow]::ShowWindow($handle, 6)
    Wait-DiscoveryState { [UiReviewNativeWindow]::IsIconic($handle) } "minimized window"
    Wait-DiscoveryState {
        # Controls in a minimized window can report as offscreen, so only check that scanning has finished.
        $scan = Find-DiscoveryControl ScanButton -Optional
        (Get-Content -LiteralPath $snapshot -Raw -ErrorAction SilentlyContinue) -like "*001122334499*" -and
            $scan -and $scan.Current.IsEnabled
    } "scheduled scan while minimized"
    Start-Sleep -Seconds 1
    if (Find-DiscoveryControl DiscoveryPopup -Optional) { throw "Discoveries must wait until FingVibe is restored." }
    Initialize-UiReviewWindow $handle
    Assert-DiscoveryEntries @("001122334499") "discovery-minimized"
    $summary = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::NameProperty,
        "1 newly observed devices while FingVibe was minimized. Saved locally.")
    if (-not $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $summary)) {
        throw "Restored discoveries must say they were found while FingVibe was minimized."
    }
    (Find-DiscoveryControl CloseDiscoveryPopup).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Stop-DiscoveryApp
    $env:FINGVIBE_UI_REVIEW_PERIODIC_SCAN = $null
    $phase = Step-UiRegressionPhase $phase "discovery/status-filter-persistence" $ScreenshotDirectory
    $tableSettings = Join-Path $directory "device-table.json"
    $env:FINGVIBE_UI_REVIEW_DEVICE_TABLE = $tableSettings
    Start-DiscoveryApp
    (Find-DiscoveryControl OnlineChip).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    Wait-DiscoveryState {
        (Find-DiscoveryControl InventoryStatusFilter).Current.Name -eq "Status: Online"
    } "Online Status filter"
    Stop-DiscoveryApp
    Start-DiscoveryApp
    if ((Find-DiscoveryControl InventoryStatusFilter).Current.Name -ne "Status: Online" -or
        (Find-DiscoveryControl OnlineChip).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne
            [System.Windows.Automation.ToggleState]::On) {
        throw "Online Status selection was not restored in the dropdown and summary chip."
    }
    (Find-DiscoveryControl OfflineChip).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    Wait-DiscoveryState {
        (Find-DiscoveryControl InventoryStatusFilter).Current.Name -eq "Status: Online, Offline"
    } "multiple Status selections"
    Stop-DiscoveryApp
    Start-DiscoveryApp
    if ((Find-DiscoveryControl InventoryStatusFilter).Current.Name -ne "Status: Online, Offline") {
        throw "Multiple Status selections were not restored."
    }
    (Find-DiscoveryControl ClearFiltersLink).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-DiscoveryState {
        (Find-DiscoveryControl InventoryStatusFilter).Current.Name -eq "Status: All"
    } "cleared Status selection"
    Stop-DiscoveryApp
    Start-DiscoveryApp
    if ((Find-DiscoveryControl InventoryStatusFilter).Current.Name -ne "Status: All") {
        throw "Cleared Status selection was not restored."
    }
    Stop-DiscoveryApp
    $invalidTableSettings = '{"columns":{},"statusFilters":[99]}'
    Set-Content -LiteralPath $tableSettings -Value $invalidTableSettings -Encoding ASCII
    Start-DiscoveryApp
    (Find-DiscoveryControl OnlineChip).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    Wait-DiscoveryState {
        (Find-DiscoveryControl InventoryStatusFilter).Current.Name -eq "Status: Online"
    } "session-only selection after invalid preferences"
    if ((Get-Content -LiteralPath $tableSettings -Raw).Trim() -ne $invalidTableSettings) {
        throw "Changing Status must not overwrite invalid saved table preferences."
    }
    Stop-DiscoveryApp
    $phase = Step-UiRegressionPhase $phase $null $ScreenshotDirectory
    Write-Host "Device discovery native UI checks passed."
}
catch {
    $failed = $true
    Write-Host $_.ScriptStackTrace
    if ($script:process -and -not $script:process.HasExited -and $script:process.MainWindowHandle -ne [IntPtr]::Zero) {
        try { Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "discovery-failure.png") }
        catch { Write-Warning "Could not capture discovery failure: $($_.Exception.Message)" }
    }
    throw
}
finally {
    Invoke-UiRegressionCleanup -PrimaryFailed $failed -Steps @(
        { if ($phase) { Complete-UiRegressionPhase -Phase $phase -Directory $ScreenshotDirectory -Succeeded $false } },
        { Write-UiRegressionCallCosts -Directory $ScreenshotDirectory -Name "DeviceDiscovery.Ui" },
        { if ($lock) { $lock.Dispose() } },
        { if ($script:process -and -not $script:process.HasExited) { Stop-Process -Id $script:process.Id -Force } },
        { foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key]) } },
        { if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force } }
    )
}
