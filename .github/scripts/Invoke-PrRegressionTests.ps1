[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PlanPath,
    [string] $RepositoryPath
)

$ErrorActionPreference = "Stop"
if (-not $RepositoryPath) { $RepositoryPath = Join-Path $PSScriptRoot "..\.." }
. (Join-Path $PSScriptRoot "PrRegressionCoverage.ps1")
$plan = Read-PrRegressionJson $PlanPath
if ($plan.schema -ne "fingvibe-pr-regression-plan-v1") {
    throw "Unsupported PR regression plan schema '$($plan.schema)'."
}
Invoke-PrRegressionPlan -Plan $plan -RepositoryPath ([IO.Path]::GetFullPath($RepositoryPath))
