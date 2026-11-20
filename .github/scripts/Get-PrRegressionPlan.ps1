[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepositoryPath,
    [Parameter(Mandatory)][string] $BaseRevision,
    [Parameter(Mandatory)][string] $HeadRevision,
    [Parameter(Mandatory)][string] $PullRequestBody,
    [Parameter(Mandatory)][string] $OutputPath
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "PrRegressionCoverage.ps1")
$RepositoryPath = [IO.Path]::GetFullPath($RepositoryPath)
$paths = @(Get-PrRegressionChangedPaths -RepositoryPath $RepositoryPath `
    -BaseRevision $BaseRevision -HeadRevision $HeadRevision)
$plan = Get-PrRegressionPlan -RepositoryPath $RepositoryPath -PullRequestBody $PullRequestBody `
    -ChangedPaths $paths -BaseRevision $BaseRevision -HeadRevision $HeadRevision
$directory = Split-Path -Parent $OutputPath
if ($directory) { $null = New-Item -ItemType Directory -Path $directory -Force }
$plan | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "Regression coverage plan: category=$($plan.category), selectors=$(@($plan.selectors.id) -join ',')."
