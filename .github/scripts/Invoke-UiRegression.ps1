[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet("sidebar", "devices", "history", "tools")]
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
$plan = if ($Suite -eq "history") { @(Read-UiReviewCapturePlan -Path $CapturePlanPath) } else { @() }
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
        sidebar {
            Invoke-RegressionCheck "SidebarNavigation" @{ ScreenshotDirectory = (Join-Path $ScreenshotDirectory "sidebar") }
        }
        devices {
            Invoke-RegressionCheck "DevicesList.Ui" @{ ScreenshotDirectory = (Join-Path $ScreenshotDirectory "devices") }
        }
        history {
            if ($plan.Scenario -contains "DeviceDetails") {
                Invoke-RegressionCheck "DeviceScanHistory.Ui" @{
                    ScreenshotDirectory = (Join-Path $ScreenshotDirectory "scan-history"); SummaryOnly = $true
                }
                Invoke-RegressionCheck "DeviceDiscovery.Ui" @{ ScreenshotDirectory = (Join-Path $ScreenshotDirectory "discovery") }
                Invoke-RegressionCheck "UsageCategory.Ui" @{ ScreenshotDirectory = (Join-Path $ScreenshotDirectory "usage-category") }
            }
            else {
                Write-Host "History/discovery checks are not required by this capture plan, preserving existing selection."
            }
        }
        tools {
            Invoke-RegressionCheck "BuildIdentity.Ui" @{
                Version = $Version; BuildKind = $BuildKind; BuildTimestamp = $BuildTimestamp
                BuildCommit = $BuildCommit; PullRequestNumber = $PullRequestNumber
                ScreenshotDirectory = (Join-Path $ScreenshotDirectory "build-identity")
            }
            Invoke-RegressionCheck "NetworkTroubleshooting.Ui" @{ ScreenshotDirectory = (Join-Path $ScreenshotDirectory "troubleshooting") }
            Invoke-RegressionCheck "FingImport.Ui" @{ ScreenshotDirectory = (Join-Path $ScreenshotDirectory "fing-import") }
            Invoke-RegressionCheck "AdditionalServices.Ui" @{ ScreenshotDirectory = (Join-Path $ScreenshotDirectory "additional-services") }
            Invoke-RegressionCheck "SqlEditor.Ui" @{ ScreenshotDirectory = (Join-Path $ScreenshotDirectory "sql-editor") }
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
