param(
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $ScreenshotDirectory,
    [switch] $SummaryOnly,
    [switch] $ObservationsOnly
)

$ErrorActionPreference = "Stop"
if ($SummaryOnly -and $ObservationsOnly) { throw "Choose summary or observation coverage, not both." }
if ($env:GITHUB_ACTIONS -ne "true") { throw "History UI checks require a disposable GitHub Actions desktop." }
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScreenshot.ps1")
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewAppearance.ps1")
. (Join-Path $PSScriptRoot "UiRegression\Helpers.ps1")
. (Join-Path $PSScriptRoot "Inventory.Sqlite.Helpers.ps1")
Initialize-InventorySqlite $AppPath

. (Join-Path $PSScriptRoot "DeviceScanHistory.Ui.Tests.Shared.ps1")
. (Join-Path $PSScriptRoot "DeviceScanHistory.Ui.Tests.Summary.ps1")
. (Join-Path $PSScriptRoot "DeviceScanHistory.Ui.Tests.Observations.ps1")

$previous = @{}
foreach ($key in @("FINGVIBE_UI_REVIEW", "FINGVIBE_UI_REVIEW_INVENTORY", "FINGVIBE_UI_REVIEW_SNAPSHOT",
    "FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT", "FINGVIBE_UI_REVIEW_SCAN_HOLD", "FINGVIBE_UI_REVIEW_NETWORK")) {
    $previous[$key] = [Environment]::GetEnvironmentVariable($key)
}
$fixtureDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "fingvibe-history-ui-$([Guid]::NewGuid().ToString('N'))"
$inventory = Join-Path $fixtureDirectory "inventory.json"
$database = [System.IO.Path]::ChangeExtension($inventory, ".sqlite")
$snapshot = Join-Path $fixtureDirectory "snapshot.json"
$hold = Join-Path $fixtureDirectory "scan.hold"
$script:process = $null
$lock = $null
$contrast = $null
$phase = $null
$failed = $false
try {
    . (Join-Path $PSScriptRoot "DeviceScanHistory.Ui.Tests.FixturePhase.ps1")
    . (Join-Path $PSScriptRoot "DeviceScanHistory.Ui.Tests.StatePhases.ps1")
    if ($SummaryOnly) {
        $phase = Step-UiRegressionPhase $phase $null $ScreenshotDirectory
        Write-Host "Summaries, Last seen, persistence, scan outcomes and collapsed completed-observation checks passed."
        return
    }
    . (Join-Path $PSScriptRoot "DeviceScanHistory.Ui.Tests.PagingPhase.ps1")
    $phase = Step-UiRegressionPhase $phase $null $ScreenshotDirectory
    Write-Host "Device scan-history native UI checks passed."
}
catch {
    $failed = $true
    Write-Host $_.ScriptStackTrace
    if ($script:process -and -not $script:process.HasExited -and $script:process.MainWindowHandle -ne [IntPtr]::Zero) {
        try { Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $ScreenshotDirectory "history-failure.png") }
        catch { Write-Warning "Could not capture scan-history failure: $($_.Exception.Message)" }
    }
    throw
}
finally {
    Invoke-UiRegressionCleanup -PrimaryFailed $failed -Steps @(
        { if ($phase) { Complete-UiRegressionPhase -Phase $phase -Directory $ScreenshotDirectory -Succeeded $false } },
        { Write-UiRegressionCallCosts -Directory $ScreenshotDirectory -Name "DeviceScanHistory.Ui" },
        { if ($lock) { $lock.Dispose() } },
        { if ($null -ne $contrast) { [HistoryReviewContrast]::Set($contrast) } },
        { if ($script:process -and -not $script:process.HasExited) { Stop-Process -Id $script:process.Id -Force } },
        { foreach ($key in $previous.Keys) { [Environment]::SetEnvironmentVariable($key, $previous[$key]) } },
        { if (Test-Path -LiteralPath $fixtureDirectory) { Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force } }
    )
}
