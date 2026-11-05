param(
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $ScreenshotDirectory
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScreenshot.ps1")
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewAppearance.ps1")

function Find-HistoryControl([string] $Value, [switch] $ByName, [switch] $Optional) {
    $property = if ($ByName) { [System.Windows.Automation.AutomationElement]::NameProperty }
        else { [System.Windows.Automation.AutomationElement]::AutomationIdProperty }
    $condition = [System.Windows.Automation.PropertyCondition]::new($property, $Value)
    $element = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if (-not $element -and -not $Optional) { throw "Missing scan-history control '$Value'." }
    return $element
}

function Wait-HistoryState([scriptblock] $Predicate, [string] $Description) {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        if (& $Predicate) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Description."
}

function Start-HistoryApp {
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

function Stop-HistoryApp {
    if ($script:process -and -not $script:process.HasExited) {
        $null = $script:process.CloseMainWindow()
        if (-not $script:process.WaitForExit(5000)) {
            Stop-Process -Id $script:process.Id -Force
            throw "Scan-history app did not close normally."
        }
    }
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

function Open-HistoryDetails([string] $Name) {
    Select-HistoryDevices
    (Find-HistoryControl "Search devices" -ByName).GetCurrentPattern(
        [System.Windows.Automation.ValuePattern]::Pattern).SetValue($Name)
    Start-Sleep -Milliseconds 300
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::ListItem)
    $rows = (Find-HistoryControl ResultsList).FindAll([System.Windows.Automation.TreeScope]::Children, $condition)
    if ($rows.Count -ne 1) { throw "Expected one device matching '$Name', got $($rows.Count)." }
    $rows[0].SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
    Wait-HistoryState {
        $scroll = Find-HistoryControl DeviceDetailsScroll -Optional
        $scroll -and -not $scroll.Current.IsOffscreen
    } "details for $Name"
}

function Show-HistorySection([string] $Id) {
    $scrollElement = Find-HistoryControl DeviceDetailsScroll
    $scroll = $scrollElement.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    foreach ($percent in 0..100) {
        if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, $percent) }
        Start-Sleep -Milliseconds 20
        $element = Find-HistoryControl $Id
        $bounds = $element.Current.BoundingRectangle
        $area = $scrollElement.Current.BoundingRectangle
        if (-not $element.Current.IsOffscreen -and $bounds.Height -gt 0 -and
            $bounds.Top -ge $area.Top + 35 -and $bounds.Bottom -le $area.Bottom - 10) { return $element }
    }
    throw "Scan-history section '$Id' does not fit the details viewport."
}

function Assert-HistoryRows([string] $Capture) {
    if ((Find-HistoryControl DeviceScanHistoryCount).Current.Name -ne "4 completed scan observations") {
        throw "The history must contain exactly four individual completed scans."
    }
    $list = Show-HistorySection DeviceScanHistoryList
    $scroll = $list.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    $seen = @{}
    $itemCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::ListItem)
    $textCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Text)
    foreach ($percent in @(0, 50, 100)) {
        if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, $percent) }
        Start-Sleep -Milliseconds 100
        $times = @()
        foreach ($item in $list.FindAll([System.Windows.Automation.TreeScope]::Children, $itemCondition)) {
            $texts = @($item.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCondition) |
                ForEach-Object { $_.Current.Name })
            if ($texts.Count -eq 0) { continue }
            if ($texts.Count -ne 3) { throw "Each scan row must expose time, state and network: $texts." }
            $time = $texts[0]
            if ($time -notmatch '^2026-11-01 12:0[0-3]:00 UTC$') { throw "Unexpected scan timestamp '$time'." }
            $state = if ($time -eq "2026-11-01 12:02:00 UTC") { "Observed absent" } else { "Observed present" }
            if ($texts[1] -ne $state -or $texts[2] -ne "Network synthetic-network | 192.0.2.0/24") {
                throw "Incorrect scan observation: $texts."
            }
            $seen[$time] = $true
            $times += $time
        }
        if (($times -join "|") -ne (($times | Sort-Object -Descending) -join "|")) {
            throw "Scan rows are not newest first: $times."
        }
    }
    if ($seen.Count -ne 4) { throw "Not all four scans are reachable in the native history list." }
    if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, 0) }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "$Capture.png")
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
    "FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT", "FINGVIBE_UI_REVIEW_SCAN_HOLD")) {
    $previous[$key] = [Environment]::GetEnvironmentVariable($key)
}
$fixtureDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "fingvibe-history-ui-$([Guid]::NewGuid().ToString('N'))"
$inventory = Join-Path $fixtureDirectory "inventory.json"
$snapshot = Join-Path $fixtureDirectory "snapshot.json"
$hold = Join-Path $fixtureDirectory "scan.hold"
$script:process = $null
$lock = $null
try {
    $null = New-Item -ItemType Directory -Path $fixtureDirectory
    $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
    $history = @(0..3 | ForEach-Object {
        @{ completedAt = "2026-11-01T12:0${_}:00+00:00"; networkId = "synthetic-network"
           subnet = "192.0.2.0/24"; present = ($_ -ne 2) }
    })
    function New-HistoryObservation([string] $Address, [bool] $Present, [string] $Vendor) {
        @{ networkId = "synthetic-network"; subnet = "192.0.2.0/24"; address = $Address
           hostname = $null; vendor = $Vendor; ports = @(); latency = 1; probeDuration = "00:00:00.001"
           classification = @{ type = 0; operatingSystem = 0; typeEvidence = "Synthetic fixture"; operatingSystemEvidence = "Synthetic fixture" }
           firstSeen = "2026-11-01T12:00:00+00:00"; lastSeen = "2026-11-01T12:03:00+00:00"
           lastChecked = "2026-11-01T12:03:00+00:00"; present = $Present }
    }
    $old = New-HistoryObservation "192.0.2.2" $false "Private"
    $current = New-HistoryObservation "192.0.2.3" $true "Private"
    $data = @{
        revision = [Guid]::NewGuid().ToString()
        devices = @{
            "020000000001" = @{ mac = "020000000001"; imported = @{ name = "History normal" }
                observations = @((New-HistoryObservation "192.0.2.1" $true "Example")); scanHistory = $history }
            "D0C907000001" = @{ mac = "D0C907000001"; imported = @{}; observations = @($old); scanHistory = @() }
            "D0C907000002" = @{ mac = "D0C907000002"; imported = @{}; observations = @($current); scanHistory = @() }
            "001122334466" = @{ mac = "001122334466"; imported = @{ name = "History imported" }; observations = @(); scanHistory = @() }
        }
        names = @{}; classifications = @{}; peopleRooms = @{ people = @(); rooms = @(); assignments = @{} }
        virtualDevices = @(@{
            id = [Guid]::NewGuid().ToString(); networkId = "synthetic-network"; subnet = "192.0.2.0/24"
            prefix = "D0C907"; number = 1; lastActiveMac = "D0C907000002"; lastChecked = "2026-11-01T12:03:00+00:00"
            present = $true; name = "History virtual"; scanHistory = $history
            history = @(@{ mac = "D0C907000001"; observation = $old; inferred = $true },
                @{ mac = "D0C907000002"; observation = $current; inferred = $true })
        })
    }
    @{ version = 3; data = $data } | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $inventory -Encoding UTF8
    @{ version = 3; subnet = "192.0.2.0/24"; completedAt = "2026-11-01T12:03:00+00:00"; results = @() } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $snapshot -Encoding UTF8
    $original = Get-Content -LiteralPath $inventory -Raw
    $env:FINGVIBE_UI_REVIEW = "1"
    $env:FINGVIBE_UI_REVIEW_INVENTORY = $inventory
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = $snapshot
    $env:FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT = "0"
    $env:FINGVIBE_UI_REVIEW_SCAN_HOLD = $hold
    Start-HistoryApp
    Open-HistoryDetails "History normal"
    Assert-HistoryRows "history-normal"
    Open-HistoryDetails "History virtual"
    Assert-HistoryRows "history-virtual"
    Open-HistoryDetails "History imported"
    $empty = Show-HistorySection DeviceScanHistoryEmpty
    if ($empty.Current.Name -ne "No local scan history. Imported Fing data is not a local scan observation.") {
        throw "Imported-only history needs an explanatory empty state."
    }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "history-imported.png")
    Stop-HistoryApp
    Start-HistoryApp
    Open-HistoryDetails "History normal"
    Assert-HistoryRows "history-restarted"
    if ((Get-Content -LiteralPath $inventory -Raw) -cne $original) { throw "Restoration must not write new scan entries." }
    foreach ($count in @(5, 6)) {
        Invoke-HistoryScan
        Wait-HistoryScan
        $saved = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json
        if ($saved.data.devices.'020000000001'.scanHistory.Count -ne $count) {
            throw "Each successful repeated scan must persist one new observation."
        }
        if ($saved.data.virtualDevices[0].scanHistory.Count -ne 4) { throw "Another subnet fabricated virtual absence." }
    }
    $beforeStop = Get-Content -LiteralPath $inventory -Raw
    Set-Content -LiteralPath $hold -Value "hold for cancellation"
    Invoke-HistoryScan
    Wait-HistoryState { Find-HistoryControl "Cancel scan" -ByName -Optional } "cancel action"
    (Find-HistoryControl "Cancel scan" -ByName).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-HistoryScan
    if ((Get-Content -LiteralPath $inventory -Raw) -cne $beforeStop) { throw "Cancelled scan changed durable history." }
    Open-HistoryDetails "History normal"
    if ((Find-HistoryControl DeviceScanHistoryCount).Current.Name -ne "6 completed scan observations") {
        throw "Cancelled scan changed displayed history."
    }
    @{ completed = -1; total = 1 } | ConvertTo-Json | Set-Content -LiteralPath "$hold.progress"
    Invoke-HistoryScan
    Wait-HistoryScan
    if ((Find-HistoryControl ScanStatusText).Current.Name -notlike "*UI-review progress fixture is invalid*") {
        throw "Failed scan must display its error."
    }
    if ((Get-Content -LiteralPath $inventory -Raw) -cne $beforeStop) { throw "Failed scan changed durable history." }
    Open-HistoryDetails "History normal"
    if ((Find-HistoryControl DeviceScanHistoryCount).Current.Name -ne "6 completed scan observations") {
        throw "Failed scan changed displayed history."
    }
    Remove-Item -LiteralPath $hold, "$hold.progress"
    $lock = [System.IO.FileStream]::new("$inventory.lock", [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    Invoke-HistoryScan
    Wait-HistoryScan
    if ((Find-HistoryControl ScanStatusText).Current.Name -notlike "*inventory and scan history could not be saved*") {
        throw "Failed history persistence must be visibly reported."
    }
    if ((Get-Content -LiteralPath $inventory -Raw) -cne $beforeStop) { throw "A failed save changed durable history." }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "history-save-error.png")
    $lock.Dispose()
    $lock = $null
    Stop-HistoryApp
    Set-Content -LiteralPath $inventory -Value "invalid inventory fixture"
    Start-HistoryApp
    Wait-HistoryState {
        $status = Find-HistoryControl ScanStatusText -Optional
        $status -and $status.Current.Name -like "*Saved inventory could not be loaded. Changes are disabled*"
    } "visible inventory load failure"
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "history-load-error.png")
    if ((Get-Content -LiteralPath $inventory -Raw).Trim() -ne "invalid inventory fixture") {
        throw "Invalid saved history must not be overwritten."
    }
    Write-Host "Device scan-history native UI checks passed."
}
finally {
    if ($lock) { $lock.Dispose() }
    if ($script:process -and -not $script:process.HasExited) { Stop-Process -Id $script:process.Id -Force }
    foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key]) }
    if (Test-Path -LiteralPath $fixtureDirectory) { Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force }
}
