[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet("Baseline", "Focused", "Full")][string] $Mode,
    [Parameter(Mandatory)][ValidateSet("capture", "sidebar", "devices", "details-summary", "details-identity", "details-observations", "details-activity", "tools")][string] $Suite,
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $ScreenshotDirectory,
    [string] $SourceDirectory,
    [string[]] $Scenarios = @(),
    [string] $Version,
    [string] $BuildKind = "Test",
    [string] $BuildTimestamp,
    [string] $BuildCommit,
    [int] $PullRequestNumber
)

$ErrorActionPreference = "Stop"
if (-not $SourceDirectory) { $SourceDirectory = Join-Path $PSScriptRoot "..\.." }
. (Join-Path $PSScriptRoot "NativeValidation.ps1")
. (Join-Path $PSScriptRoot "..\..\tests\UiRegression\Helpers.ps1")
$SourceDirectory = [IO.Path]::GetFullPath($SourceDirectory)
. (Join-Path $SourceDirectory ".github\scripts\UiReviewScenarios.ps1")
$plan = @(Get-NativeValidationPlan -Mode $Mode -Suite $Suite -Scenarios $Scenarios)
$null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
$planPath = Join-Path $ScreenshotDirectory "capture-plan.json"
ConvertTo-Json -InputObject $plan -Depth 5 | Set-Content -LiteralPath $planPath -Encoding UTF8
$started = [DateTime]::UtcNow
$clock = [Diagnostics.Stopwatch]::StartNew()
$result = "failure"
$fixtureDirectory = $null
$savedEnvironment = Save-UiRegressionEnvironment @(
    "FINGVIBE_UI_REVIEW", "FINGVIBE_UI_REVIEW_INVENTORY", "FINGVIBE_UI_REVIEW_SNAPSHOT",
    "FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT")
Start-Transcript -Path (Join-Path $ScreenshotDirectory "execution.log")
try {
    if ($Suite -eq "capture") {
        $fixtureDirectory = New-UiRegressionFixtureDirectory -Suite native-capture
        $env:FINGVIBE_UI_REVIEW = "1"
        $env:FINGVIBE_UI_REVIEW_INVENTORY = Join-Path $fixtureDirectory "inventory.sqlite"
        $env:FINGVIBE_UI_REVIEW_SNAPSHOT = Join-Path $fixtureDirectory "latest-scan.json"
        $env:FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT = "0"
        if ($Mode -eq "Full") {
            & (Join-Path $SourceDirectory "tests\UiReviewScreenshot.Tests.ps1")
        }
        & (Join-Path $PSScriptRoot "Invoke-UiReview.ps1") -Mode $Mode `
            -AppPath $AppPath -ScreenshotDirectory $ScreenshotDirectory -CapturePlanPath $planPath `
            -SourceDirectory $SourceDirectory
    }
    else {
        & (Join-Path $SourceDirectory ".github\scripts\Invoke-UiRegression.ps1") -Suite $Suite `
            -AppPath $AppPath -ScreenshotDirectory $ScreenshotDirectory -CapturePlanPath $planPath `
            -Version $Version -BuildKind $BuildKind -BuildTimestamp $BuildTimestamp `
            -BuildCommit $BuildCommit -PullRequestNumber $PullRequestNumber
    }
    $result = "success"
}
catch {
    Write-Host $_
    Write-Host $_.ScriptStackTrace
    throw
}
finally {
    try {
        Restore-UiRegressionEnvironment -Saved $savedEnvironment
        if ($fixtureDirectory) { Remove-Item -LiteralPath $fixtureDirectory -Recurse -Force }
    }
    catch {
        $result = "failure"
        Write-Host "Native fixture cleanup failed: $_"
        throw
    }
    finally {
        $clock.Stop()
        $evidence = [ordered]@{
            mode = $Mode; suite = $Suite; result = $result
            revision = $BuildCommit; pullRequest = $PullRequestNumber
            runId = $env:GITHUB_RUN_ID; runAttempt = $env:GITHUB_RUN_ATTEMPT; job = $env:GITHUB_JOB
            harnessRevision = $env:NATIVE_VALIDATION_HARNESS_REVISION
            startedUtc = $started.ToString("O"); completedUtc = [DateTime]::UtcNow.ToString("O")
            executionSeconds = $clock.Elapsed.TotalSeconds
            scenarios = @($plan.Scenario)
            coverage = if ($Mode -eq "Baseline") { "Launch, scan, filter/reset and selected-device details only." }
                else { "Existing runnable suites/captures; temporarily disabled feature coverage remains dormant." }
            omittedCoverage = if ($Mode -eq "Baseline") {
                "Exhaustive refresh, navigation, assignments, theme/layout/scrolling/behavior matrices; non-UI and installer checks."
            } else { "Activity/observation UI coverage disabled in this revision is not restored by validation modes." }
        }
        $evidence | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $ScreenshotDirectory "execution.json") -Encoding UTF8
        $timing = "$Mode / $Suite execution: $($clock.Elapsed.TotalSeconds.ToString('F1', [Globalization.CultureInfo]::InvariantCulture)) seconds ($result); excludes runner setup and application build."
        Write-Host $timing
        if ($env:GITHUB_STEP_SUMMARY) {
            $timing >> $env:GITHUB_STEP_SUMMARY
            "Revision: $BuildCommit; PR: $PullRequestNumber; run: $($env:GITHUB_RUN_ID), attempt $($env:GITHUB_RUN_ATTEMPT)." >> $env:GITHUB_STEP_SUMMARY
            "Coverage: $($evidence.coverage) Omitted: $($evidence.omittedCoverage)" >> $env:GITHUB_STEP_SUMMARY
            if ($Mode -eq "Baseline") {
                "Baseline execution design target: 60-90 seconds, not a merge gate or established coverage equivalence." >> $env:GITHUB_STEP_SUMMARY
            }
        }
        Stop-Transcript
    }
}
