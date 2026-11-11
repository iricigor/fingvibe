[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $AppPath,

    [Parameter(Mandatory)]
    [string] $ScreenshotDirectory,

    [ValidateRange(1024, 1280)]
    [int] $ExpandedWindowWidth = 1280,

    [string] $Group = "All"
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

$regressionGroups = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'UiRegression\Sidebar.Groups.psd1')
$previousContext = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
try {
    Invoke-UiRegressionGroups -Suite Sidebar -Definition $regressionGroups -Group $Group `
        -ModuleDirectory (Join-Path $PSScriptRoot 'UiRegression') -Directory $ScreenshotDirectory `
        -EnvironmentNames @(
            'FINGVIBE_UI_REVIEW', 'FINGVIBE_UI_REVIEW_SCAN_HOLD', 'FINGVIBE_UI_REVIEW_NAVIGATION',
            'FINGVIBE_UI_REVIEW_PERIODIC_SCAN', 'FINGVIBE_UI_REVIEW_PERIODIC_SCAN_TIME_SCALE',
            'FINGVIBE_UI_REVIEW_SNAPSHOT', 'FINGVIBE_UI_REVIEW_INVENTORY', 'FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT',
            'FINGVIBE_UI_REVIEW_NO_NETWORK') `
        -StateVariables @('fixtureDirectory') `
        -OnFailure {
            param([string] $FailedGroup)
            if ($root -and $process -and -not $process.HasExited) {
                $bounds = Get-UiReviewWindowBounds $windowHandle
                if ($bounds.Width -ge 640 -and $bounds.Height -ge 480) {
                    Save-SidebarAppearance "sidebar-failure-$FailedGroup"
                }
                $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                    [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object {
                        "$($_.Current.AutomationId) | $($_.Current.Name) | offscreen=$($_.Current.IsOffscreen)"
                    } | Set-Content -LiteralPath (Join-Path $ScreenshotDirectory "sidebar-failure-$FailedGroup-tree.txt")
            }
        } `
        -Cleanup @(
            { Stop-SidebarApp },
            {
                if ($fixtureDirectory -and (Test-Path -LiteralPath $fixtureDirectory)) {
                    Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force
                }
            })
}
finally { $null = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext($previousContext) }
