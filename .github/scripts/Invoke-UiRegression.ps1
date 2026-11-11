[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("sidebar", "sidebar-presentation", "sidebar-scan-flows", "sidebar-preferences-scheduling",
        "devices", "devices-presentation", "devices-filters-previews", "devices-columns-sorting",
        "details-summary", "details-identity", "details-observations", "details-activity",
        "tools", "tools-utilities", "tools-device-data")]
    [string] $Suite,
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $ScreenshotDirectory,
    [Parameter(Mandatory)][string] $CapturePlanPath,
    [string] $Version,
    [string] $BuildKind,
    [string] $BuildTimestamp,
    [string] $BuildCommit,
    [int] $PullRequestNumber
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "UiReviewScenarios.ps1")
$plan = if ($Suite -like "details-*") { @(Read-UiReviewCapturePlan -Path $CapturePlanPath) } else { @() }
$null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force

function Invoke-RegressionCheck([string] $Name, [hashtable] $Parameters = @{}) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    Write-Host "Starting native UI check: $Name"
    try {
        & (Join-Path $PSScriptRoot "..\..\tests\$Name.Tests.ps1") -AppPath $AppPath @Parameters
    }
    finally {
        $clock.Stop()
        $timing = "$Suite / $Name elapsed: $($clock.Elapsed.TotalSeconds.ToString('F1', [Globalization.CultureInfo]::InvariantCulture)) seconds"
        Write-Host $timing
        if ($env:GITHUB_STEP_SUMMARY) { $timing >> $env:GITHUB_STEP_SUMMARY }
    }
}

Start-Transcript -Path (Join-Path $ScreenshotDirectory "regression.log")
try {
    switch ($Suite) {
        { $_ -eq "sidebar" -or $_ -like "sidebar-*" } {
            $sidebarParameters = @{ ScreenshotDirectory = (Join-Path $ScreenshotDirectory "sidebar") }
            if ($Suite -ne "sidebar") { $sidebarParameters.Group = $Suite.Substring("sidebar-".Length) }
            Invoke-RegressionCheck "SidebarNavigation" $sidebarParameters
        }
        { $_ -eq "devices" -or $_ -like "devices-*" } {
            # Each Devices group launches its own fixture and app, so CI runs the groups on separate workers;
            # the full devices suite runs every group sequentially.
            $devicesParameters = @{ ScreenshotDirectory = (Join-Path $ScreenshotDirectory "devices") }
            if ($Suite -ne "devices") { $devicesParameters.Group = $Suite.Substring("devices-".Length) }
            Invoke-RegressionCheck "DevicesList.Ui" $devicesParameters
        }
        { $_ -like "details-*" } {
            # Device Details suites follow the Overview/History boundary; each launches its own fixtures and app instances.
            if (-not ($plan.Scenario | Where-Object { $_ -in @("DeviceDetails", "DeviceHistory") })) {
                Write-Host "Device Details checks are not required by this capture plan, preserving existing selection."
            }
            elseif ($Suite -eq "details-summary") {
                Invoke-RegressionCheck "DeviceScanHistory.Ui" @{
                    ScreenshotDirectory = (Join-Path $ScreenshotDirectory "scan-history"); SummaryOnly = $true
                }
            }
            if ($Suite -eq "details-summary" -and $plan.Scenario -contains "PersonDetails") {
                Invoke-RegressionCheck "EquipmentActivity.Ui" @{ ScreenshotDirectory = (Join-Path $ScreenshotDirectory "equipment-activity") }
            }
            if ($Suite -eq "details-identity" -and
                ($plan.Scenario | Where-Object { $_ -in @("DeviceDetails", "DeviceHistory") })) {
                Invoke-RegressionCheck "DeviceDiscovery.Ui" @{ ScreenshotDirectory = (Join-Path $ScreenshotDirectory "discovery") }
                Invoke-RegressionCheck "UsageCategory.Ui" @{ ScreenshotDirectory = (Join-Path $ScreenshotDirectory "usage-category") }
            }
            if ($Suite -eq "details-identity" -and $plan.Scenario -contains "Network") {
                Invoke-RegressionCheck "NetworkActivity.Ui" @{ ScreenshotDirectory = (Join-Path $ScreenshotDirectory "network-activity") }
            }
            if ($Suite -eq "details-observations" -and
                ($plan.Scenario | Where-Object { $_ -in @("DeviceDetails", "DeviceHistory") })) {
                Invoke-RegressionCheck "DeviceScanHistory.Ui" @{
                    ScreenshotDirectory = (Join-Path $ScreenshotDirectory "observations"); ObservationsOnly = $true
                }
            }
            elseif ($Suite -eq "details-activity" -and
                ($plan.Scenario | Where-Object { $_ -in @("DeviceDetails", "DeviceHistory") })) {
                Invoke-RegressionCheck "DeviceActivity.Ui" @{ ScreenshotDirectory = (Join-Path $ScreenshotDirectory "activity") }
            }
        }
        { $_ -eq "tools" -or $_ -like "tools-*" } {
            $toolsParameters = @{
                Version = $Version; BuildKind = $BuildKind; BuildTimestamp = $BuildTimestamp
                BuildCommit = $BuildCommit; PullRequestNumber = $PullRequestNumber
                ScreenshotDirectory = $ScreenshotDirectory
            }
            if ($Suite -ne "tools") { $toolsParameters.Group = $Suite.Substring("tools-".Length) }
            Invoke-RegressionCheck "Tools.Ui" $toolsParameters
        }
    }
}
catch {
    Write-Host $_
    throw
}
finally {
    Stop-Transcript
}
