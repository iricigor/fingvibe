$fixtureDirectory = New-UiRegressionFixtureDirectory -Suite sidebar
$scanHoldPath = Join-Path $fixtureDirectory 'scan.hold'
$navigationPreferencePath = Join-Path $fixtureDirectory 'navigation.json'
$periodicScanDirectory = Join-Path $fixtureDirectory 'periodic-scan'
$periodicScanPath = Join-Path $periodicScanDirectory 'periodic-scan.json'
$env:FINGVIBE_UI_REVIEW = "1"
$env:FINGVIBE_UI_REVIEW_SNAPSHOT = Join-Path $fixtureDirectory 'latest-scan.json'
$env:FINGVIBE_UI_REVIEW_INVENTORY = $null
$env:FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT = '0'
$env:FINGVIBE_UI_REVIEW_PERIODIC_SCAN = $null
$env:FINGVIBE_UI_REVIEW_PERIODIC_SCAN_TIME_SCALE = $null
$env:FINGVIBE_UI_REVIEW_SCAN_HOLD = $scanHoldPath
$env:FINGVIBE_UI_REVIEW_NAVIGATION = $null
$null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
Start-SidebarApp
$area = [System.Windows.Forms.Screen]::FromHandle($windowHandle).WorkingArea
$availableWidth = [int] [Math]::Floor($area.Width / $scale)
$expandedWidth = [Math]::Min($ExpandedWindowWidth, $availableWidth)
if ($expandedWidth -lt 1024) { throw "Expanded sidebar checks require a desktop at least 1024 logical pixels wide." }
Write-Host "Testing expanded navigation at $expandedWidth logical pixels, within the available $availableWidth."
Set-SidebarWindowWidth $expandedWidth
