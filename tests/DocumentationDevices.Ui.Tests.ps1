param(
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $ScreenshotDirectory
)

$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows') {
    throw 'Documentation capture requires a disposable GitHub Actions Windows desktop.'
}
. (Join-Path $PSScriptRoot '..\.github\scripts\UiReviewScreenshot.ps1')
. (Join-Path $PSScriptRoot '..\.github\scripts\UiReviewAppearance.ps1')
. (Join-Path $PSScriptRoot 'UiRegression\Helpers.ps1')
. (Join-Path $PSScriptRoot 'UiRegression\Devices.Controls.Helpers.ps1')
. (Join-Path $PSScriptRoot 'UiRegression\Devices.Filters.Helpers.ps1')
. (Join-Path $PSScriptRoot 'Inventory.Sqlite.Helpers.ps1')
. (Join-Path $PSScriptRoot 'DocumentationDevices.Fixture.ps1')
Initialize-InventorySqlite $AppPath
$null = [Reflection.Assembly]::LoadFrom((Join-Path (Split-Path -Parent $AppPath) 'FingVibe.Core.dll'))
$null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
$fixtureDirectory = New-UiRegressionFixtureDirectory -Suite documentation-devices
$savedEnvironment = @{}
foreach ($name in @('FINGVIBE_UI_REVIEW', 'FINGVIBE_UI_REVIEW_INVENTORY',
    'FINGVIBE_UI_REVIEW_SNAPSHOT', 'FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}
$process = $null
$windowHandle = [IntPtr]::Zero
$previousContext = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
function Find-DocumentationRow([string] $Name) {
    @(Get-DeviceRows | Where-Object {
        $_.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.AndCondition]::new(
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, 'DeviceNameText'),
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::NameProperty, $Name)))
    }) | Select-Object -First 1
}
function Find-DocumentationCell($Row, [string] $Id) {
    $Row.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Id))
}
try {
    $fixture = New-DocumentationDevicesFixture $fixtureDirectory
    Add-DocumentationDevicesLink $fixture.Inventory
    $env:FINGVIBE_UI_REVIEW = '1'
    $env:FINGVIBE_UI_REVIEW_INVENTORY = $fixture.Inventory
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = $fixture.Snapshot
    $env:FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT = '1'
    $process = Start-Process -FilePath (Resolve-Path -LiteralPath $AppPath).Path -PassThru
    $windowHandle = Wait-UiRegressionWindow -Process $process
    Initialize-UiReviewWindow $windowHandle
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
    $scale = [UiReviewNativeWindow]::GetDpiForWindow($windowHandle) / 96.0
    $area = [System.Windows.Forms.Screen]::FromHandle($windowHandle).WorkingArea
    if ($area.Width -lt 1600 -or $area.Height -lt 900) { throw 'The complete 1600x900 showcase needs a wider disposable desktop.' }
    if (-not [UiReviewNativeWindow]::SetWindowPos($windowHandle, [IntPtr]::Zero,
        $area.Left, $area.Top, 1600, 900, 0x0044)) { throw [ComponentModel.Win32Exception]::new() }
    Focus-DeviceWindow
    Select-DevicePage Settings
    Set-UiReviewAppearanceChoice -Root $root -Picker ModePicker -Choice Dark
    Set-UiReviewAppearanceChoice -Root $root -Picker ThemePicker -Choice Standard
    Select-DevicePage DevicesNavItem
    Set-DeviceFilterChoice InventoryStatusFilter 'All statuses'
    Set-SecondaryFiltersExpanded $true
    $names = @('Home router', 'Workstation', 'Android phone', 'iPad', 'Living room TV',
        'Office printer', 'Home NAS', 'Kitchen speaker', 'Hue bridge')
    $null = Wait-UiRegressionState -Description 'all nine documentation device rows visible' -Condition {
        (Find-DeviceElement ResultCountText).Current.Name -eq 'Showing 9 devices' -and
            @($names | Where-Object { -not (Find-DocumentationRow $_) }).Count -eq 0
    }
    $pc = Find-DocumentationRow Workstation
    $chevron = Find-DocumentationCell $pc DeviceMacExpansionButton
    if (-not $chevron -or $chevron.Current.IsOffscreen -or
        $chevron.Current.HelpText -ne '1 more MAC address, collapsed') {
        throw 'The linked PC must show its two-NIC chevron in the collapsed state.'
    }
    foreach ($name in @('Kitchen speaker', 'Hue bridge')) {
        $row = Find-DocumentationRow $name
        $icon = Find-DocumentationCell $row ServiceDiscoveryButton
        $response = Find-DocumentationCell $row ResponseTimeText
        if (-not $icon -or $icon.Current.IsOffscreen -or $icon.Current.BoundingRectangle.IsEmpty -or
            $icon.Current.Name -notlike 'Service discovery: * advertised service*' -or
            -not $response -or $response.Current.IsOffscreen -or $response.Current.Name -ne '--') {
            throw "'$name' must visibly show SD advertisements and no measured ping latency."
        }
    }
    $null = Save-DeviceCapture 'documentation-devices'
    Stop-UiRegressionApp -Process $process
    $process = $null
    $mapDirectory = Join-Path $fixtureDirectory 'room-map'
    $null = New-Item -ItemType Directory -Path $mapDirectory
    $mapFixture = New-DocumentationDevicesFixture -Directory $mapDirectory -Subnet '127.0.0.1/32'
    Add-DocumentationDevicesLink $mapFixture.Inventory
    $env:FINGVIBE_UI_REVIEW_INVENTORY = $mapFixture.Inventory
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = $mapFixture.Snapshot
    $process = Start-Process -FilePath (Resolve-Path -LiteralPath $AppPath).Path -PassThru
    $windowHandle = Wait-UiRegressionWindow -Process $process
    Initialize-UiReviewWindow $windowHandle
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
    if (-not [UiReviewNativeWindow]::SetWindowPos($windowHandle, [IntPtr]::Zero,
        $area.Left, $area.Top, 1600, 900, 0x0044)) { throw [ComponentModel.Win32Exception]::new() }
    Focus-DeviceWindow
    Select-DevicePage Settings
    Set-UiReviewAppearanceChoice -Root $root -Picker ModePicker -Choice Dark
    Set-UiReviewAppearanceChoice -Root $root -Picker ThemePicker -Choice Standard
    Select-DevicePage ToolsNavItem
    $card = Find-DeviceElement RoomMapCard
    $null = Show-UiRegressionScrollTargets -Description 'Room map card on Tools' -GetViewport {
        Find-DeviceElement ToolsLanding
    } -GetWindow { $root } -GetTargets { $card }
    $card.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $null = Wait-UiRegressionState -Description 'populated Room map with its saved rooms and unassigned equipment' -Condition {
        $summary = Find-DeviceElement RoomMapSummaryText
        $summary.Current.Name -like '*9*' -and
            @(1..3 | Where-Object {
                $room = Find-DeviceElement ('RoomMapOpenRoom-10000000-0000-0000-0000-{0:D12}' -f $_)
                $room.Current.IsOffscreen -or $room.Current.BoundingRectangle.IsEmpty
            }).Count -eq 0
    }
    $null = Save-DeviceCapture 'documentation-room-map'
    @{ devices = $names; linkedPc = @{ name = 'Workstation'; macCount = 2; collapsed = $true }
        serviceDiscoveryOnly = @('Kitchen speaker', 'Hue bridge'); width = 1600; height = 900
        roomMap = @{ rooms = @('Hallway', 'Office', 'Living room'); devices = 9; unassigned = 2
            localPc = 'Review PC'; syntheticSubnet = '127.0.0.1/32' }
        source = $env:GITHUB_SHA; run = $env:GITHUB_RUN_ID; attempt = $env:GITHUB_RUN_ATTEMPT } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ScreenshotDirectory 'documentation-devices-manifest.json') -Encoding utf8
}
catch {
    if ($windowHandle -ne [IntPtr]::Zero -and $process -and -not $process.HasExited) {
        $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object {
                "$($_.Current.AutomationId) | $($_.Current.Name) | offscreen=$($_.Current.IsOffscreen) | $($_.Current.BoundingRectangle)"
            } | Set-Content -LiteralPath (Join-Path $ScreenshotDirectory 'documentation-devices-failure-tree.txt')
    }
    throw
}
finally {
    try { Stop-UiRegressionApp -Process $process }
    finally {
        foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name]) }
        $null = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext($previousContext)
        Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force
    }
}
