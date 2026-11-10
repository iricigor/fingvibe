[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $AppPath,

    [Parameter(Mandatory)]
    [string] $ScreenshotDirectory,

    [string] $Group = "All"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScreenshot.ps1")
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewAppearance.ps1")
. (Join-Path $PSScriptRoot 'UiRegression\Helpers.ps1')
. (Join-Path $PSScriptRoot 'UiRegression\Devices.Controls.Helpers.ps1')
. (Join-Path $PSScriptRoot 'UiRegression\Devices.Rendering.Helpers.ps1')
. (Join-Path $PSScriptRoot 'UiRegression\Devices.Previews.Helpers.ps1')
. (Join-Path $PSScriptRoot 'UiRegression\Devices.Filters.Helpers.ps1')
. (Join-Path $PSScriptRoot 'UiRegression\Devices.Columns.Helpers.ps1')
. (Join-Path $PSScriptRoot 'UiRegression\Devices.Sorting.Helpers.ps1')

$regressionGroups = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'UiRegression\Devices.Groups.psd1')
$previousContext = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
try {
    Invoke-UiRegressionGroups -Suite Devices -Definition $regressionGroups -Group $Group `
        -ModuleDirectory (Join-Path $PSScriptRoot 'UiRegression') -Directory $ScreenshotDirectory `
        -EnvironmentNames @('FINGVIBE_UI_REVIEW', 'FINGVIBE_UI_REVIEW_SNAPSHOT', 'FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT',
            'FINGVIBE_UI_REVIEW_INVENTORY') `
        -StateVariables @('process', 'windowHandle', 'root', 'scale', 'fixture', 'fixtureDirectory') `
        -OnFailure {
            param([string] $FailedGroup)
            if ($windowHandle -and $process -and -not $process.HasExited) {
                $failureBounds = Get-UiReviewWindowBounds $windowHandle
                if ($failureBounds.Width -ge 640 -and $failureBounds.Height -ge 480) {
                    $null = Save-DeviceCapture "devices-failure-$FailedGroup" -KeepPointer
                }
                else { Write-Host "Failure window $failureBounds is below the screenshot helper's minimum; retaining its automation tree." }
                $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                    [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object {
                        "$($_.Current.AutomationId) | $($_.Current.Name) | offscreen=$($_.Current.IsOffscreen) | $($_.Current.BoundingRectangle)"
                    } | Set-Content -LiteralPath (Join-Path $ScreenshotDirectory "devices-failure-$FailedGroup-tree.txt")
            }
        } `
        -Cleanup @(
            { Stop-UiRegressionApp -Process $process },
            {
                if ($fixtureDirectory -and (Test-Path -LiteralPath $fixtureDirectory)) {
                    Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force
                }
            })
    Write-Host "Device toolbar/dropdowns, conditional columns, six-theme stripes/header underline, recycling, sorting/filtering, metadata updates, hover, selection and keyboard checks passed for group(s): $Group."
}
finally { $null = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext($previousContext) }
