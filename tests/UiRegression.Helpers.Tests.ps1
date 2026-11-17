$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UiRegression\Helpers.ps1')
. (Join-Path $PSScriptRoot 'UiRegression\Sidebar.PeopleRooms.Helpers.ps1')

function Assert-Regression([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-RegressionFailure([scriptblock] $Action, [string] $Pattern) {
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected failure matching '$Pattern'."
}

. (Join-Path $PSScriptRoot "UiRegression.Helpers.Tests.Waits.ps1")
. (Join-Path $PSScriptRoot "UiRegression.Helpers.Tests.Sidebar.ps1")
. (Join-Path $PSScriptRoot "UiRegression.Helpers.Tests.Visibility.ps1")
. (Join-Path $PSScriptRoot "UiRegression.Helpers.Tests.Tools.ps1")
. (Join-Path $PSScriptRoot "UiRegression.Helpers.Tests.Lifecycle.ps1")
. (Join-Path $PSScriptRoot "UiRegression.Helpers.Tests.SourceContracts.ps1")
. (Join-Path $PSScriptRoot "UiRegression.Helpers.Tests.Groups.ps1")
. (Join-Path $PSScriptRoot "UiRegression.Helpers.Tests.Backups.ps1")
. (Join-Path $PSScriptRoot "UiRegression.Helpers.Tests.SurfaceStatus.ps1")
. (Join-Path $PSScriptRoot "UiRegression.Helpers.Tests.DevicesFilters.ps1")
Write-Host 'UI regression helper, cleanup, timing, async state, and orchestration checks passed.'
