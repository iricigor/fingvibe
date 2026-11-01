[CmdletBinding()]
param(
    [string] $BaseRevision,
    [string] $HeadRevision = "HEAD",
    [switch] $Manual
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "UiReviewScenarios.ps1")

function Get-PrValidationChanges {
    param([string[]] $Paths, [switch] $Manual)

    $tests = [bool] $Manual
    $build = [bool] $Manual
    $ui = [bool] $Manual
    foreach ($path in $Paths) {
        if ($path -match '^(src/|tests/|tools/|\.github/(scripts/|workflows/|agents/ui-ux-reviewer\.agent\.md))' -or
            $path -match '(^|/)([^/]+\.(sln|slnx|props|targets)|global\.json|[Nn]u[Gg]et\.[Cc]onfig)$') {
            $tests = $true
        }
        if ($path -match '^(src/|tools/|tests/(UiReviewScreenshot|NetworkTroubleshooting\.Ui)\.Tests\.ps1$|\.github/(scripts/|workflows/|agents/ui-ux-reviewer\.agent\.md))' -or
            $path -match '(^|/)([^/]+\.(sln|slnx|props|targets)|global\.json|[Nn]u[Gg]et\.[Cc]onfig)$') {
            $build = $true
            $ui = $true
        }
    }
    [pscustomobject]@{ Tests = $tests; Build = $build; Ui = $ui }
}

if ($MyInvocation.InvocationName -ne ".") {
    if (-not $Manual -and [string]::IsNullOrWhiteSpace($BaseRevision)) {
        throw "BaseRevision is required for automatic PR validation."
    }
    $paths = if ($Manual) { @() } else {
        $mergeBase = Invoke-UiReviewGit (Get-Location).Path @("merge-base", $BaseRevision, $HeadRevision)
        @(Invoke-UiReviewGit (Get-Location).Path @("diff", "--name-only", "--no-renames", $mergeBase, $HeadRevision, "--"))
    }
    $changes = Get-PrValidationChanges -Paths $paths -Manual:$Manual
    foreach ($name in @("Tests", "Build", "Ui")) {
        $line = "$($name.ToLowerInvariant())=$($changes.$name.ToString().ToLowerInvariant())"
        Write-Host $line
        if ($env:GITHUB_OUTPUT) { $line >> $env:GITHUB_OUTPUT }
    }
    if ($env:GITHUB_STEP_SUMMARY) {
        "Validation plan: tests=$($changes.Tests), build=$($changes.Build), UI=$($changes.Ui). Documentation-only changes skip native build/capture; test-only changes run tests." >> $env:GITHUB_STEP_SUMMARY
    }
}
