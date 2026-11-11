[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $ScreenshotDirectory,
    [string] $Group = "All",
    [string] $Version,
    [string] $BuildKind,
    [string] $BuildTimestamp,
    [string] $BuildCommit,
    [int] $PullRequestNumber
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot 'UiRegression\Helpers.ps1')
$regressionGroups = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'UiRegression\Tools.Groups.psd1')
Invoke-UiRegressionGroups -Suite Tools -Definition $regressionGroups -Group $Group `
    -ModuleDirectory (Join-Path $PSScriptRoot 'UiRegression') -Directory $ScreenshotDirectory `
    -EnvironmentNames @('FINGVIBE_UI_REVIEW', 'FINGVIBE_UI_REVIEW_SNAPSHOT', 'FINGVIBE_UI_REVIEW_INVENTORY')
