param(
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $ScreenshotDirectory,
    [switch] $SummaryOnly
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScreenshot.ps1")
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewAppearance.ps1")
. (Join-Path $PSScriptRoot "Inventory.Sqlite.Helpers.ps1")
Initialize-InventorySqlite $AppPath

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

function Find-HistoryDeviceRow([string] $Name) {
    Select-HistoryDevices
    (Find-HistoryControl "Search devices" -ByName).GetCurrentPattern(
        [System.Windows.Automation.ValuePattern]::Pattern).SetValue($Name)
    Start-Sleep -Milliseconds 300
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::ListItem)
    $rows = (Find-HistoryControl ResultsList).FindAll([System.Windows.Automation.TreeScope]::Children, $condition)
    if ($rows.Count -ne 1) { throw "Expected one device matching '$Name', got $($rows.Count)." }
    return $rows[0]
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
    if ($SummaryOnly) {
        foreach ($id in @("DeviceActivityCard", "ActivityPeriod", "ActivityRefresh", "ActivityScroll",
            "DeviceScanHistoryExpander", "DeviceScanHistoryList", "DeviceHistoryOlder", "DeviceHistoryNewer",
            "DeviceHistoryTab", "DeviceViewHistory")) {
            $element = Find-HistoryControl $id -Optional
            if ($element -and (-not $element.Current.IsOffscreen -or $element.Current.IsKeyboardFocusable)) {
                throw "Disabled history control '$id' remains visible or keyboard accessible."
            }
        }
        return
    }
    foreach ($id in @("DeviceScanHistoryExpander", "DeviceImportedMetadata")) {
        $pattern = (Find-HistoryControl $id).GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
        if ($pattern.Current.ExpandCollapseState -ne [System.Windows.Automation.ExpandCollapseState]::Collapsed) {
            throw "$id must start collapsed on opening a device."
        }
    }
    $expander = Show-HistorySection DeviceScanHistoryExpander
    $expander.SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait(" ")
    Wait-HistoryState {
        (Find-HistoryControl DeviceScanHistoryExpander).GetCurrentPattern(
            [System.Windows.Automation.ExpandCollapsePattern]::Pattern).Current.ExpandCollapseState -eq
                [System.Windows.Automation.ExpandCollapseState]::Expanded
    } "keyboard expansion of completed observations"
}

function Get-HistoryLocalTime([int] $Index) {
    return ([DateTimeOffset]::Parse("2026-11-01T12:0${Index}:00+00:00")).ToLocalTime()
}

function Get-HistoryTimestamp([int] $Index) {
    return (Get-HistoryLocalTime $Index).ToString("yyyy-MM-dd HH:mm:ss '(local)'", [Globalization.CultureInfo]::InvariantCulture)
}

function Show-HistorySection([string] $Id, [int] $TopMargin = 35, [string[]] $AdditionalIds = @()) {
    $scrollElement = Find-HistoryControl DeviceDetailsScroll
    $scroll = $scrollElement.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    # Resolve once: a whole-tree search per scroll step also walks every Device Activity cell.
    $ids = @($Id) + $AdditionalIds
    $elements = @($ids | ForEach-Object { Find-HistoryControl $_ })
    foreach ($percent in 0..100) {
        if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, $percent) }
        Start-Sleep -Milliseconds 20
        $area = $scrollElement.Current.BoundingRectangle
        $fits = $true
        for ($index = 0; $index -lt $elements.Count; $index++) {
            try { $current = $elements[$index].Current }
            catch [System.Windows.Automation.ElementNotAvailableException] {
                $elements[$index] = Find-HistoryControl $ids[$index]
                $current = $elements[$index].Current
            }
            $bounds = $current.BoundingRectangle
            if ($current.IsOffscreen -or $bounds.Height -le 0 -or
                $bounds.Top -lt $area.Top + $TopMargin -or $bounds.Bottom -gt $area.Bottom - 10) {
                $fits = $false
            }
        }
        if ($fits) { return $elements[0] }
    }
    throw "Scan-history section '$Id' does not fit the details viewport."
}

function Assert-HistoryRows([string] $Capture, [int] $LastIndex = 4) {
    $count = $LastIndex + 1
    if ((Find-HistoryControl DeviceScanHistoryCount).Current.Name -ne "$count completed scan observations") {
        throw "The history must contain exactly $count individual completed scans in the current scope."
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
            if ($texts.Count -ne 3) { throw "Each scan row must expose date, local time and state, without repeated network: $texts." }
            $time = "$($texts[0]) $($texts[1])"
            $matching = @(0..$LastIndex | Where-Object { (Get-HistoryLocalTime $_).ToString("yyyy-MM-dd HH:mm:ss") -eq $time })
            if ($matching.Count -ne 1) { throw "Unexpected local scan timestamp '$time'." }
            $state = if ($matching[0] -in @(2, 3)) { "Absent" } else { "Present" }
            if ($texts[2] -ne $state) {
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
    if ($seen.Count -ne $count) { throw "Not all $count scans are reachable in the native history list." }
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
    $headers = @("Date", "Time (local)", "Status") | ForEach-Object { Find-HistoryControl $_ -ByName }
    $items = $list.FindAll([System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::ListItem))
    $path = Join-Path $ScreenshotDirectory "$Capture.png"
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle $path
    $window = Get-UiReviewWindowBounds $script:process.MainWindowHandle
    $bitmap = [System.Drawing.Bitmap]::FromFile($path)
    try {
        $stripeColors = @()
        $states = @{}
        foreach ($item in $items) {
            if ($item.Current.IsOffscreen) { continue }
            $texts = $item.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [System.Windows.Automation.ControlType]::Text))
            if ($texts.Count -ne 3) { throw "Rendered table row must expose three columns." }
            for ($column = 0; $column -lt 3; $column++) {
                $bounds = $texts[$column].Current.BoundingRectangle
                $header = $headers[$column].Current.BoundingRectangle
                $expectedLeft = $header.Left + $(if ($column -eq 2) { 18 * [UiReviewNativeWindow]::GetDpiForWindow($script:process.MainWindowHandle) / 96 } else { 0 })
                if ([Math]::Abs($bounds.Left - $expectedLeft) -gt 3 -or $bounds.Right -gt $header.Right + 3) {
                    throw "Column $column is misaligned/clipped relative to its header: $bounds / $header."
                }
            }
            $row = $item.Current.BoundingRectangle
            $stripeColors += $bitmap.GetPixel([int]($row.Left - $window.Left + 3), [int]($row.Top - $window.Top + 3)).ToArgb()
            $status = $texts[2].Current.BoundingRectangle
            $green = 0
            $red = 0
            for ($x = [int]($status.Left - $window.Left - 20); $x -lt $status.Left - $window.Left; $x++) {
                for ($y = [int]($status.Top - $window.Top); $y -lt $status.Bottom - $window.Top; $y++) {
                    $pixel = $bitmap.GetPixel($x, $y)
                    if ($pixel.G -gt $pixel.R + 20 -and $pixel.G -gt $pixel.B + 10) { $green++ }
                    if ($pixel.R -gt $pixel.G + 20 -and $pixel.R -gt $pixel.B + 10) { $red++ }
                }
            }
            $state = $texts[2].Current.Name
            if (($state -eq "Present" -and $green -lt 20) -or ($state -eq "Absent" -and $red -lt 20)) {
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
        DeviceHistoryScope = "Current network: ui-review-network | 127.0.0.1/32"
        DeviceHistoryFirstSeen = "First seen: $(Get-HistoryTimestamp 0)"
        DeviceHistoryLastSeen = "Last seen: $(Get-HistoryTimestamp $lastSeen)"
        DeviceHistorySince = "Observed $state since: $(Get-HistoryTimestamp $since)"
        DeviceHistoryState = "Last observed: $(if ($state -eq 'online') { 'Present' } else { 'Absent' })"
        DeviceHistoryLatest = "Latest recorded scan: $(Get-HistoryTimestamp $LastIndex). Saved observations do not establish current live presence."
    }
    foreach ($id in $expected.Keys) {
        $actual = (Find-HistoryControl $id).Current.Name
        if ($actual -ne $expected[$id]) { throw "Incorrect summary $id : '$actual', expected '$($expected[$id])'." }
    }
    foreach ($id in @("DeviceHistoryFirstSeenAge", "DeviceHistoryLastSeenAge")) {
        if ((Find-HistoryControl $id).Current.Name -notmatch '^(in )?\d+ (minute|hour|day|month|year)s?( ago)?$') {
            throw "Summary $id lacks a rounded relative age in the requested units."
        }
    }
    $expansion = $null
    if (-not $SummaryOnly) {
        $expansion = (Find-HistoryControl DeviceScanHistoryExpander).GetCurrentPattern(
            [System.Windows.Automation.ExpandCollapsePattern]::Pattern)
        $expansion.Collapse()
    }
    $null = Show-HistorySection DeviceHistoryFirstSeen -AdditionalIds @(
        "DeviceHistoryLastSeen", "DeviceHistorySince", "DeviceHistoryState", "DeviceHistoryScope", "DeviceHistoryLatest")
    foreach ($id in @("DeviceHistoryFirstSeen", "DeviceHistoryLastSeen", "DeviceHistorySince")) {
        $element = Find-HistoryControl $id
        $area = (Find-HistoryControl DeviceDetailsScroll).Current.BoundingRectangle
        $bounds = $element.Current.BoundingRectangle
        if ($element.Current.IsOffscreen -or $bounds.Top -lt $area.Top -or $bounds.Bottom -gt $area.Bottom) {
            Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "$Capture-clipped.png")
            throw "Summary field $id is clipped: bounds=$bounds; viewport=$area."
        }
    }
    Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "$Capture-summary.png")
    if ($expansion) { $expansion.Expand() }
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
$database = [System.IO.Path]::ChangeExtension($inventory, ".sqlite")
$snapshot = Join-Path $fixtureDirectory "snapshot.json"
$hold = Join-Path $fixtureDirectory "scan.hold"
$script:process = $null
$lock = $null
try {
    $null = New-Item -ItemType Directory -Path $fixtureDirectory
    $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
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
    $env:FINGVIBE_UI_REVIEW_SCAN_HOLD = $hold
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
            $null = Assert-HistoryLastSeenCell "History $kind" "Last seen: $(Get-HistoryExactTime $lastSeen)"
            Assert-HistoryLastSeenAge "History $kind" $lastSeen
            Open-HistoryDetails "History $kind"
            Assert-HistorySummary "history-$kind-$index" $index
            if (-not $SummaryOnly) { Assert-HistoryRows "history-$kind-$index" $index }
        }
        Stop-HistoryApp
    }
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
        if ((Find-HistoryControl $id).Current.Name -notlike "*historical aggregate; individual scan unavailable*") {
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
    if ($SummaryOnly) {
        Write-Host "Retained summaries, Last seen, persistence, scan outcomes and disabled history UI checks passed."
        return
    }
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
    foreach ($pageIndex in 0..2) {
        $start = 1 + 100 * $pageIndex
        $end = [Math]::Min(100 * ($pageIndex + 1), 205)
        Wait-HistoryState {
            (Find-HistoryControl DeviceHistoryPageStatus).Current.Name -like "Showing $start-$end of 205.*"
        } "bounded history page $($pageIndex + 1)"
        if ((Find-HistoryControl DeviceScanHistoryCount).Current.Name -ne "205 completed scan observations") {
            throw "Paging must retain the exact scoped observation count."
        }
        $list = Show-HistorySection DeviceScanHistoryList
        $scroll = $list.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
        $condition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::ListItem)
        $pageRows = @{}
        foreach ($percent in 0..100) {
            if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, $percent) }
            Start-Sleep -Milliseconds 20
            foreach ($item in $list.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)) {
                $label = $item.Current.Name
                if ($label -match '; Observed (present|absent)$') { $pageRows[$label] = $true }
            }
        }
        if ($pageRows.Count -ne $end - $start + 1) { throw "Not every observation on page $pageIndex is reachable: $($pageRows.Count)." }
        foreach ($label in $pageRows.Keys) {
            if ($reachable.ContainsKey($label)) { throw "Observation duplicated across history pages: $label." }
            $reachable[$label] = $true
        }
        if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, 0) }
        Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "history-page-$($pageIndex + 1).png")
        if ($pageIndex -lt 2) {
            $older = Show-HistorySection DeviceHistoryOlder
            $older.SetFocus()
            [System.Windows.Forms.SendKeys]::SendWait(" ")
        }
    }
    if ($reachable.Count -ne 205) { throw "All 205 retained observations must remain reachable." }
    if ((Find-HistoryControl DeviceHistoryOlder).Current.IsEnabled) { throw "Older navigation must stop at the oldest page." }
    (Show-HistorySection DeviceHistoryNewer).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Wait-HistoryState { (Find-HistoryControl DeviceHistoryPageStatus).Current.Name -like "Showing 101-200 of 205.*" } "reverse history paging"
    (Show-HistorySection DeviceHistoryOlder).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Open-HistoryDetails "History imported"
    if ((Find-HistoryControl DeviceScanHistoryCount).Current.Name -ne "0 completed scan observations") {
        throw "Selection changes must not retain the previous device's page."
    }
    Open-HistoryDetails "History normal"
    Wait-HistoryState { (Find-HistoryControl DeviceHistoryPageStatus).Current.Name -like "Showing 1-100 of 205.*" } "reset history traversal after selection change"
    if ((Find-HistoryControl DeviceHistoryNewer).Current.IsEnabled) { throw "Newer navigation must stop at the newest page." }
    Write-Host "Device scan-history native UI checks passed."
}
finally {
    if ($lock) { $lock.Dispose() }
    if ($script:process -and -not $script:process.HasExited) { Stop-Process -Id $script:process.Id -Force }
    foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key]) }
    if (Test-Path -LiteralPath $fixtureDirectory) { Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force }
}
