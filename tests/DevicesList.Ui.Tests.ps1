[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $AppPath,

    [Parameter(Mandatory)]
    [string] $ScreenshotDirectory
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

$regressionSavedEnvironment = Save-UiRegressionEnvironment @(
    'FINGVIBE_UI_REVIEW', 'FINGVIBE_UI_REVIEW_SNAPSHOT', 'FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT',
    'FINGVIBE_UI_REVIEW_INVENTORY')
$process = $null
$windowHandle = [IntPtr]::Zero
$fixture = $null
$fixtureDirectory = $null
$previousContext = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
try {
    foreach ($regressionModule in @('Setup', 'Overview', 'Filters', 'Refinements', 'Columns', 'Previews', 'Layout', 'Appearance', 'Interaction', 'Sorting')) {
        $regressionPhase = Start-UiRegressionPhase -Name "Devices/$regressionModule"
        $regressionSucceeded = $false
        try {
            . (Join-Path $PSScriptRoot "UiRegression\Devices.$regressionModule.Scenario.ps1")
            $regressionSucceeded = $true
        }
        finally {
            Complete-UiRegressionPhase -Phase $regressionPhase -Directory $ScreenshotDirectory -Succeeded $regressionSucceeded
        }
    }
    Write-Host "Device toolbar/dropdowns, conditional columns, six-theme stripes/header underline, recycling, sorting/filtering, metadata updates, hover, selection and keyboard checks passed."
}
catch {
    Write-Host $_
    Write-Host $_.ScriptStackTrace
    if ($windowHandle -and $process -and -not $process.HasExited) {
        $failureBounds = Get-UiReviewWindowBounds $windowHandle
        if ($failureBounds.Width -ge 640 -and $failureBounds.Height -ge 480) {
            $null = Save-DeviceCapture "devices-failure" -KeepPointer
        }
        else { Write-Host "Failure window $failureBounds is below the screenshot helper's minimum; retaining its automation tree." }
        $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object {
                "$($_.Current.AutomationId) | $($_.Current.Name) | offscreen=$($_.Current.IsOffscreen) | $($_.Current.BoundingRectangle)"
            } | Set-Content -LiteralPath (Join-Path $ScreenshotDirectory "devices-failure-tree.txt")
    }
    throw
}
finally {
    try { Stop-UiRegressionApp -Process $process }
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
