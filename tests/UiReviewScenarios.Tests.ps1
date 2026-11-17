$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScenarios.ps1")
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewNavigation.ps1")

function Assert-Equal($Actual, $Expected, [string] $Message) {
    if (($Actual -join "|") -cne ($Expected -join "|")) {
        throw "$Message Expected '$($Expected -join ', ')', got '$($Actual -join ', ')'."
    }
}

function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected failure matching '$Pattern'."
}

. (Join-Path $PSScriptRoot "UiReviewScenarios.Tests.DetailsContracts.ps1")
. (Join-Path $PSScriptRoot "UiReviewScenarios.Tests.HeaderContracts.ps1")
. (Join-Path $PSScriptRoot "UiReviewScenarios.Tests.HistoryContracts.ps1")
. (Join-Path $PSScriptRoot "UiReviewScenarios.Tests.AppearanceContracts.ps1")

$repository = Join-Path ([System.IO.Path]::GetTempPath()) "fingvibe-scenarios-$([Guid]::NewGuid())"
$null = New-Item -ItemType Directory -Path $repository
try {
    . (Join-Path $PSScriptRoot "UiReviewScenarios.Tests.Selection.ps1")
    . (Join-Path $PSScriptRoot "UiReviewScenarios.Tests.Layout.ps1")
    . (Join-Path $PSScriptRoot "UiReviewScenarios.Tests.ViewSelection.ps1")
    . (Join-Path $PSScriptRoot "UiReviewScenarios.Tests.Publishing.ps1")
    . (Join-Path $PSScriptRoot "UiReviewScenarios.Tests.Navigation.ps1")
    Write-Host "UI review scenario selection, manifest, publishing, and navigation regression tests passed."
}
finally {
    Remove-Item -LiteralPath $repository -Recurse -Force
}
