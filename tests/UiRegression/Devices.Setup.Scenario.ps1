$null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
$fixtureDirectory = New-UiRegressionFixtureDirectory -Suite devices
$fixture = Join-Path $fixtureDirectory 'latest-scan.json'
$results = @(
    @{
        address = "127.0.0.1"; status = 0; roundtripTimeMilliseconds = 12
        probeDuration = "00:00:00.002"; deviceName = "Fixture device 01"
        macAddress = "001122334401"
        vendorName = "Example Devices with a deliberately long manufacturer name for hover inspection"
        classification = @{ type = 1; operatingSystem = 2; operatingSystemIsInferred = $true }
        openPorts = @(@{ port = 443; serviceName = "HTTPS" })
    },
    @{
        address = "127.0.0.2"; status = 0; roundtripTimeMilliseconds = 24
        probeDuration = "00:00:00.002"; deviceName = "Kitchen display"
        macAddress = "001122334402"; vendorName = "Example Devices"
        openPorts = @(@{ port = 8009; serviceName = "Cast" })
    },
    @{
        address = "127.0.0.3"; status = 0; roundtripTimeMilliseconds = 36
        probeDuration = "00:00:00.002"; deviceName = $null
        macAddress = "001122334403"; vendorName = "Unknown"; openPorts = @()
    },
    @{
        address = "127.0.0.4"; status = 0; roundtripTimeMilliseconds = 48
        probeDuration = "00:00:00.002"; deviceName = $null
        macAddress = "001122334404"; vendorName = "Unknown"; openPorts = @()
    },
    @{
        address = "127.0.0.5"; status = 0; roundtripTimeMilliseconds = 60
        probeDuration = "00:00:00.002"; deviceName = $null
        macAddress = "001122334405"; vendorName = "Private"; openPorts = @()
    }
)
$results += @(6..80 | ForEach-Object {
    $device = @{
        address = "127.0.0.$_"; status = 0; roundtripTimeMilliseconds = $_ * 2
        probeDuration = "00:00:00.002"; deviceName = "Fixture device $('{0:D2}' -f $_)"
        macAddress = "0011223344$('{0:X2}' -f $_)"
        vendorName = "Fixture vendor"; openPorts = @()
    }
    if ($_ % 2 -eq 0) { $device.openPorts = @(@{ port = 443; serviceName = "HTTPS" }) }
    $device
})
@{ version = 3; subnet = "127.0.0.0/24"; completedAt = [DateTimeOffset]::UtcNow.ToString("O")
   duration = "00:00:02.500"; results = $results } |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $fixture -Encoding UTF8
$env:FINGVIBE_UI_REVIEW = "1"
$env:FINGVIBE_UI_REVIEW_INVENTORY = $null
$env:FINGVIBE_UI_REVIEW_SNAPSHOT = $fixture
$env:FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT = "1"
$process = Start-Process -FilePath (Resolve-Path -LiteralPath $AppPath).Path -PassThru
$windowHandle = Wait-UiRegressionWindow -Process $process
$root = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
$null = [UiReviewNativeWindow]::ShowWindow($windowHandle, 9)
$scale = [UiReviewNativeWindow]::GetDpiForWindow($windowHandle) / 96.0
