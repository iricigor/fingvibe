[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PlanPath,
    [string] $BaseRevision,
    [string] $HeadRevision = "HEAD",
    [string] $AdditionalScenarios
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "UiReviewScenarios.ps1")
$additional = @()
if (-not [string]::IsNullOrWhiteSpace($AdditionalScenarios)) {
    $additional = @($AdditionalScenarios.Split(",") | ForEach-Object { $_.Trim() })
}
$plan = @(Get-UiReviewCapturePlan -RepositoryPath (Get-Location).Path `
    -BaseRevision $BaseRevision -HeadRevision $HeadRevision -AdditionalScenarios $additional)
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $PlanPath) -Force
ConvertTo-Json -InputObject $plan -Depth 5 | Set-Content -LiteralPath $PlanPath -Encoding utf8
foreach ($capture in $plan) {
    Write-Host "$($capture.Label): $($capture.Reasons -join ' ')"
    if ($env:GITHUB_STEP_SUMMARY) {
        "### $($capture.Label)" >> $env:GITHUB_STEP_SUMMARY
        foreach ($reason in $capture.Reasons) {
            "<pre>$([System.Net.WebUtility]::HtmlEncode($reason))</pre>" >> $env:GITHUB_STEP_SUMMARY
        }
    }
}
