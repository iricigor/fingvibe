$savedInventory = $env:FINGVIBE_UI_REVIEW_INVENTORY
$savedSnapshot = $env:FINGVIBE_UI_REVIEW_SNAPSHOT
$savedCurrentSnapshot = $env:FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT
$savedNetwork = $env:FINGVIBE_UI_REVIEW_NETWORK
$inventory = Join-Path $fixtureDirectory 'virtual-expansion-inventory.json'
$snapshot = Join-Path $fixtureDirectory 'virtual-expansion-scan.json'
$time = [DateTimeOffset]::new(2026, 11, 18, 6, 0, 0, [TimeSpan]::Zero)
$devices = @{}
$history = @()
foreach ($index in 1..6) {
    $mac = "D0C907{0:D6}" -f $index
    $seen = $time.AddMinutes($index).ToString('o')
    $observation = @{
        networkId = 'ui-review-network'; subnet = '127.0.0.1/32'
        address = "127.0.0.$index"; hostname = $null; vendor = if ($index -eq 1) { "Long expansion vendor $index" } else { "Private" }
        ports = @(); latency = $index; probeDuration = '00:00:00.001'
        classification = @{ type = 0; operatingSystem = 0; typeEvidence = 'Synthetic'; operatingSystemEvidence = 'Synthetic' }
        firstSeen = $seen; lastSeen = $seen; lastChecked = $seen; present = $index -eq 6
    }
    $devices[$mac] = @{ mac = $mac; imported = @{}; observations = @($observation); scanHistory = @() }
    $history += @{ mac = $mac; observation = $observation; inferred = $true }
}
$devices["001122334455"] = @{
    mac = "001122334455"; imported = @{ name = "Expansion normal" }
    observations = @(@{
        networkId = 'ui-review-network'; subnet = '127.0.0.1/32'; address = '127.0.0.20'
        hostname = 'normal'; vendor = 'Example'; ports = @(); latency = 1; probeDuration = '00:00:00.001'
        classification = @{ type = 1; operatingSystem = 2; typeEvidence = 'Synthetic'; operatingSystemEvidence = 'Synthetic' }
        firstSeen = $time.ToString('o'); lastSeen = $time.ToString('o'); lastChecked = $time.ToString('o'); present = $true
    }); scanHistory = @()
}
$data = @{
    revision = [Guid]::NewGuid().ToString(); devices = $devices; names = @{}; classifications = @{}
    peopleRooms = @{ people = @(); rooms = @(); assignments = @{} }; discoveryBaselines = @()
    virtualDevices = @(@{
        id = [Guid]::NewGuid().ToString(); networkId = 'ui-review-network'; subnet = '127.0.0.1/32'
        prefix = 'D0C907'; number = 1; lastActiveMac = 'D0C907000006'; lastChecked = $time.AddMinutes(6).ToString('o')
        present = $true; name = 'Expansion virtual'; history = $history; scanHistory = @()
    })
}
@{ version = 4; data = $data } | ConvertTo-Json -Depth 18 |
    Set-Content -LiteralPath $inventory -Encoding UTF8
@{ version = 3; subnet = '127.0.0.1/32'; completedAt = $time.AddMinutes(6).ToString('o')
   duration = '00:00:00.100'; results = @() } | ConvertTo-Json -Depth 8 |
    Set-Content -LiteralPath $snapshot -Encoding UTF8

Stop-UiRegressionApp -Process $process
try {
    $env:FINGVIBE_UI_REVIEW_INVENTORY = $inventory
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = $snapshot
    $env:FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT = '0'
    $env:FINGVIBE_UI_REVIEW_NETWORK = 'ui-review-network'
    $process = Start-Process -FilePath (Resolve-Path -LiteralPath $AppPath).Path -PassThru
    $windowHandle = Wait-UiRegressionWindow -Process $process
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
    $scale = [UiReviewNativeWindow]::GetDpiForWindow($windowHandle) / 96.0
    Set-DeviceWidth 1280
    Select-DevicePage DevicesNavItem
    $row = Wait-UiRegressionState -Description 'virtual row expansion fixture' -Condition {
        @(Get-DeviceRows) | Where-Object {
            $_.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::NameProperty, 'Expansion virtual'))
        } | Select-Object -First 1
    }
    $normal = @(Get-DeviceRows) | Where-Object {
        $_.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, 'Expansion normal'))
    } | Select-Object -First 1
    if (-not $normal) { throw 'The expansion fixture must retain a normal single-MAC row.' }
    $normalChevron = $normal.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionButton'))
    if ($normalChevron) { throw 'A single-MAC row must not expose a MAC expansion chevron.' }
    if ([Math]::Abs($normal.Current.BoundingRectangle.Height - $row.Current.BoundingRectangle.Height) -gt $scale) {
        throw 'Collapsed multi-MAC rows must retain the same height as single-MAC rows.'
    }
    $chevron = $row.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionButton'))
    if (-not $chevron -or $chevron.Current.Name -ne 'Show 5 more MAC addresses') {
        throw 'A multi-MAC virtual row must expose the count-aware collapsed chevron.'
    }
    $chevron.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $null = Wait-UiRegressionState -Description 'three earlier MAC rows' -Condition {
        $row.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionLabel')).Count -eq 3
    }
    $more = $row.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionMore'))
    if (-not $more -or $more.Current.Name -notlike '+2 more MAC addresses*') {
        throw 'The expanded row must summarize MACs beyond the three-line preview.'
    }
    $row.SetFocus()
    [DevicesReviewInput]::Tap(0x25)
    $null = Wait-UiRegressionState -Description 'keyboard-collapsed MAC row' -Condition {
        $row.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionLabel')).Count -eq 0
    }
    [DevicesReviewInput]::Tap(0x27)
    $null = Wait-UiRegressionState -Description 'keyboard-expanded MAC row' -Condition {
        $row.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionLabel')).Count -eq 3
    }
    $rowName = $row.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceNameText'))
    $nameBounds = $rowName.Current.BoundingRectangle
    [DevicesReviewInput]::MoveTo(
        [int]($nameBounds.Left + $nameBounds.Width / 2),
        [int]($nameBounds.Top + $nameBounds.Height / 2))
    [DevicesReviewInput]::Click()
    $null = Find-DeviceElement DeviceDetailsScroll
    (Find-DeviceElement DeviceBackButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $row = Wait-UiRegressionState -Description 'MAC expansion retained across page navigation' -Condition {
        @(Get-DeviceRows) | Where-Object {
            $_.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::NameProperty, 'Expansion virtual'))
        } | Select-Object -First 1
    }
    if ($row.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionLabel')).Count -ne 3) {
        throw 'MAC expansion state must survive opening Device Details and returning.'
    }
    (Find-DeviceElement NameSortButton).GetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $null = Wait-UiRegressionState -Description 'MAC expansion retained across sorting' -Condition {
        $candidate = @(Get-DeviceRows) | Where-Object {
            $_.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::NameProperty, 'Expansion virtual'))
        } | Select-Object -First 1
        $candidate -and $candidate.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionLabel')).Count -eq 3
    }
    $row = @(Get-DeviceRows) | Where-Object {
        $_.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, 'Expansion virtual'))
    } | Select-Object -First 1
    $row.SetFocus()
    [DevicesReviewInput]::Tap(0x25)
    $search = (Find-DeviceElement ResultSearchBox).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $search.SetValue('D0-C9-07-00-00-01')
    $null = Wait-UiRegressionState -Description 'search-revealed earlier MAC' -Condition {
        $candidate = @(Get-DeviceRows) | Where-Object {
            $_.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::NameProperty, 'Expansion virtual'))
        } | Select-Object -First 1
        $candidate -and $candidate.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionLabel')).Count -eq 4
    }
    $search.SetValue('')
    $null = Wait-UiRegressionState -Description 'previous collapsed MAC state restored after search' -Condition {
        $candidate = @(Get-DeviceRows) | Where-Object {
            $_.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::NameProperty, 'Expansion virtual'))
        } | Select-Object -First 1
        $candidate -and $candidate.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionLabel')).Count -eq 0
    }
    $row = @(Get-DeviceRows) | Where-Object {
        $_.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, 'Expansion virtual'))
    } | Select-Object -First 1
    $row.SetFocus()
    [DevicesReviewInput]::Tap(0x27)
    $null = Wait-UiRegressionState -Description 'wide expanded MAC row' -Condition {
        $row.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionLabel')).Count -eq 3
    }
    Save-DeviceCapture 'devices-mac-expansion-wide'
    Set-DeviceWidth 640
    $row = @(Get-DeviceRows) | Where-Object {
        $_.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, 'Expansion virtual'))
    } | Select-Object -First 1
    $narrowChevron = $row.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionButton'))
    $null = Wait-UiRegressionState -Description 'narrow expanded MAC row' -Condition {
        $row.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionLabel')).Count -eq 3
    }
    $narrowChevron.SetFocus()
    Save-DeviceCapture 'devices-mac-expansion-narrow'
    Stop-UiRegressionApp -Process $process
    $process = Start-Process -FilePath (Resolve-Path -LiteralPath $AppPath).Path -PassThru
    $windowHandle = Wait-UiRegressionWindow -Process $process
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
    $scale = [UiReviewNativeWindow]::GetDpiForWindow($windowHandle) / 96.0
    Set-DeviceWidth 1280
    Select-DevicePage DevicesNavItem
    $restarted = Wait-UiRegressionState -Description 'MAC expansion reset after restart' -Condition {
        @(Get-DeviceRows) | Where-Object {
            $_.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::NameProperty, 'Expansion virtual'))
        } | Select-Object -First 1
    }
    if ($restarted.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceMacExpansionLabel')).Count -ne 0) {
        throw 'MAC row expansion must start collapsed after an application restart.'
    }
    Write-Host 'Virtual-device chevron, extra MAC lines, search restore, keyboard and round-trip state passed.'
}
finally {
    Stop-UiRegressionApp -Process $process
    $env:FINGVIBE_UI_REVIEW_INVENTORY = $savedInventory
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = $savedSnapshot
    $env:FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT = $savedCurrentSnapshot
    $env:FINGVIBE_UI_REVIEW_NETWORK = $savedNetwork
    $process = Start-Process -FilePath (Resolve-Path -LiteralPath $AppPath).Path -PassThru
    $windowHandle = Wait-UiRegressionWindow -Process $process
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
    $scale = [UiReviewNativeWindow]::GetDpiForWindow($windowHandle) / 96.0
    Set-DeviceWidth 1280
    Select-DevicePage DevicesNavItem
}
