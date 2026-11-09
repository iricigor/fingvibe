[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $AppPath,

    [Parameter(Mandatory)]
    [string] $ScreenshotDirectory,

    [ValidateRange(1024, 1280)]
    [int] $ExpandedWindowWidth = 1280
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScreenshot.ps1")
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewAppearance.ps1")
. (Join-Path $PSScriptRoot 'UiRegression\Helpers.ps1')
. (Join-Path $PSScriptRoot 'UiRegression\Sidebar.Controls.Helpers.ps1')
. (Join-Path $PSScriptRoot 'UiRegression\Sidebar.Navigation.Helpers.ps1')
. (Join-Path $PSScriptRoot 'UiRegression\Sidebar.Settings.Helpers.ps1')
. (Join-Path $PSScriptRoot 'UiRegression\Sidebar.Scans.Helpers.ps1')
. (Join-Path $PSScriptRoot 'UiRegression\Sidebar.Scheduled.Helpers.ps1')
. (Join-Path $PSScriptRoot 'UiRegression\Sidebar.PeopleRooms.Helpers.ps1')

$regressionSavedEnvironment = Save-UiRegressionEnvironment @(
    'FINGVIBE_UI_REVIEW', 'FINGVIBE_UI_REVIEW_SCAN_HOLD', 'FINGVIBE_UI_REVIEW_NAVIGATION',
    'FINGVIBE_UI_REVIEW_PERIODIC_SCAN', 'FINGVIBE_UI_REVIEW_PERIODIC_SCAN_TIME_SCALE',
    'FINGVIBE_UI_REVIEW_SNAPSHOT', 'FINGVIBE_UI_REVIEW_INVENTORY', 'FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT')
$fixtureDirectory = $null
$process = $null
$windowHandle = [IntPtr]::Zero
$previousContext = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
try {
    foreach ($regressionModule in @('Setup', 'Navigation', 'Settings', 'Appearance', 'Responsive', 'Refresh', 'Progress', 'PeopleRooms', 'Persistence', 'Scheduled')) {
        $regressionPhase = Start-UiRegressionPhase -Name "Sidebar/$regressionModule"
        $regressionSucceeded = $false
        try {
            . (Join-Path $PSScriptRoot "UiRegression\Sidebar.$regressionModule.Scenario.ps1")
            $regressionSucceeded = $true
        }
        finally {
            Complete-UiRegressionPhase -Phase $regressionPhase -Directory $ScreenshotDirectory -Succeeded $regressionSucceeded
        }
    }
}
finally {
    try { Stop-SidebarApp }
    finally {
        try {
            Restore-UiRegressionEnvironment -Saved $regressionSavedEnvironment
            if ($fixtureDirectory -and (Test-Path -LiteralPath $fixtureDirectory)) {
                Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force
            }
        }
        finally { $null = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext($previousContext) }
    }
}
