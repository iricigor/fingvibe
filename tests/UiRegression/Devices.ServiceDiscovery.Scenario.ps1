Stop-UiRegressionApp -Process $process
$serviceFixture = Join-Path $fixtureDirectory 'service-discovery-scan.json'
$serviceObserved = [DateTimeOffset]::UtcNow.AddMinutes(-2).ToString('O')
function New-ServiceFixtureAdvertisement([string] $Type, [string] $Label, [string] $Role, [string] $Instance,
    [int] $Port, [int] $Verification, $Name = $null, $Model = $null) {
    # Untyped optional values stay null; a [string] parameter would turn them into invalid empty metadata.
    @{
        protocol = 0; serviceType = $Type; serviceLabel = $Label; role = $Role; instanceName = $Instance
        host = 'synthetic-host.local'; port = $Port; transport = 0; advertisedName = $Name; manufacturer = $null
        model = $Model; observedAt = $serviceObserved; verification = $Verification
    }
}
$serviceResults = @(
    @{
        address = '127.0.0.1'; status = 0; roundtripTimeMilliseconds = 5; probeDuration = '00:00:00.002'
        deviceName = 'Fixture router'; macAddress = '001122334401'; vendorName = 'Example Devices'
        openPorts = @(@{ port = 443; serviceName = 'HTTPS' })
    },
    @{
        address = '127.0.0.2'; status = 0; roundtripTimeMilliseconds = $null; probeDuration = '00:00:00'
        deviceName = 'Kitchen speaker'; macAddress = '001122334402'; vendorName = 'Example Devices'
        openPorts = @(@{ port = 4070; serviceName = 'Spotify Connect (advertised)' }, @{ port = 8009; serviceName = 'Cast' })
        serviceAdvertisements = @(
            (New-ServiceFixtureAdvertisement '_googlecast._tcp.local' 'Google Cast' 'Cast receiver' 'Kitchen' 8009 1 -Model 'Synthetic speaker'),
            (New-ServiceFixtureAdvertisement '_spotify-connect._tcp.local' 'Spotify Connect' 'Spotify Connect playback endpoint' 'Kitchen' 4070 1))
    },
    @{
        address = '127.0.0.3'; status = 0; roundtripTimeMilliseconds = $null; probeDuration = '00:00:00'
        deviceName = 'hue-bridge.local'; macAddress = $null; vendorName = 'Unknown'; openPorts = @()
        serviceAdvertisements = @(
            (New-ServiceFixtureAdvertisement '_hue._tcp.local' 'Philips Hue' 'Hue bridge service' 'Hue Bridge' 443 2 -Name 'Hue Bridge'))
    }
)
@{ version = 4; subnet = '127.0.0.0/24'; completedAt = [DateTimeOffset]::UtcNow.ToString('O')
   duration = '00:00:02.500'; results = $serviceResults } |
    ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $serviceFixture -Encoding UTF8
$env:FINGVIBE_UI_REVIEW_SNAPSHOT = $serviceFixture
$process = Start-Process -FilePath (Resolve-Path -LiteralPath $AppPath).Path -PassThru
$windowHandle = Wait-UiRegressionWindow -Process $process
$root = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
$null = [UiReviewNativeWindow]::ShowWindow($windowHandle, 9)
$scale = [UiReviewNativeWindow]::GetDpiForWindow($windowHandle) / 96.0
Set-DeviceWidth 1280
Focus-DeviceWindow
Select-DevicePage DevicesNavItem
Set-DeviceFilterChoice InventoryStatusFilter "All statuses"
$null = Wait-UiRegressionState -Description 'the three-device service-discovery fixture' -Condition {
    (Find-DeviceElement ResultCountText).Current.Name -eq 'Showing 3 devices'
}

function Find-ServiceDiscoveryRow([string] $Name) {
    $nameCondition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceNameText'),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $Name))
    $row = @(Get-DeviceRows | Where-Object { $_.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $nameCondition) })
    if ($row.Count -ne 1) { throw "Expected one '$Name' device row; found $($row.Count)." }
    $row[0]
}

function Find-ServiceDiscoveryIcon($Row) {
    $button = $Row.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'ServiceDiscoveryButton'))
    if ($button -and -not $button.Current.IsOffscreen -and -not $button.Current.BoundingRectangle.IsEmpty) { $button }
}

$speaker = Find-ServiceDiscoveryRow 'Kitchen speaker'
$speakerIcon = Find-ServiceDiscoveryIcon $speaker
if (-not $speakerIcon) { throw 'A device with latest-scan advertisements must show the service-discovery icon.' }
if ($speakerIcon.Current.Name -cne 'Service discovery: 2 advertised services' -or
    $speakerIcon.Current.HelpText -notlike '*Spotify Connect (Spotify Connect playback endpoint) - mDNS/DNS-SD*' -or
    $speakerIcon.Current.HelpText -notlike '*Advertised in the latest scan, observed*' -or
    -not $speakerIcon.Current.IsKeyboardFocusable) {
    throw "The service-discovery icon must expose its name, services, observation time and keyboard focus: $($speakerIcon.Current.Name) / $($speakerIcon.Current.HelpText)"
}
$iconBounds = $speakerIcon.Current.BoundingRectangle
foreach ($portName in @('4070/TCP*', '8009/TCP*')) {
    $port = @($speaker.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition) | Where-Object { $_.Current.Name -like $portName })
    if ($port.Count -eq 0 -or $port[0].Current.BoundingRectangle.Right -gt $iconBounds.Left) {
        throw "Verified port '$portName' must stay left of the right-aligned service-discovery icon."
    }
}
if (Find-ServiceDiscoveryIcon (Find-ServiceDiscoveryRow 'Fixture router')) {
    throw 'Devices without latest-scan advertisements must not show the service-discovery icon.'
}
$null = Save-DeviceCapture 'devices-service-discovery'

$bridgeIcon = Find-ServiceDiscoveryIcon (Find-ServiceDiscoveryRow 'hue-bridge.local')
if (-not $bridgeIcon) { throw 'A MAC-less service-discovery responder must remain visible with its icon.' }
Focus-DeviceWindow
$bridgeIcon.SetFocus()
$null = Wait-UiRegressionState -Description 'keyboard focus on the service-discovery icon' -Condition {
    (Find-ServiceDiscoveryIcon (Find-ServiceDiscoveryRow 'hue-bridge.local')).Current.HasKeyboardFocus
}
[DevicesReviewInput]::Tap(0x0D)
$heading = Wait-UiRegressionState -Description 'Service discovery (1) in Device Details' -Condition {
    $candidate = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'ServiceDiscoveryHeading'))
    if ($candidate -and -not $candidate.Current.IsOffscreen -and $candidate.Current.Name -eq 'Service discovery (1)') { $candidate }
}
$viewport = (Find-DeviceElement DeviceDetailsScroll).Current.BoundingRectangle
if ($heading.Current.BoundingRectangle.Top -lt $viewport.Top -or $heading.Current.BoundingRectangle.Top -ge $viewport.Bottom) {
    throw 'Activating the icon must bring Service discovery into view.'
}
$texts = @($root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
    [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)))
foreach ($expected in @('MAC unavailable', '--', 'Hue Bridge', '_hue._tcp.local',
        'TCP verified: no response - not counted as open', 'Philips Hue (Hue bridge service)')) {
    if (-not ($texts | Where-Object { $_.Current.Name -ceq $expected })) {
        throw "Device Details must show '$expected' for the MAC-less service-discovery responder."
    }
}
$identification = @($texts | Where-Object { $_.Current.Name -ceq 'Device identification' })
$ports = @($texts | Where-Object { $_.Current.Name -like 'Ports & services (*' })
if ($identification.Count -ne 1 -or $ports.Count -ne 1 -or
    $identification[0].Current.BoundingRectangle.Top -ge $heading.Current.BoundingRectangle.Top -or
    $heading.Current.BoundingRectangle.Top -ge $ports[0].Current.BoundingRectangle.Top) {
    throw 'Service discovery must sit below Device identification and above Ports & services.'
}
$null = Save-DeviceCapture 'device-details-service-discovery'
Write-Host 'Service-discovery icon, MAC-unavailable responder, keyboard activation and Device Details section passed.'
