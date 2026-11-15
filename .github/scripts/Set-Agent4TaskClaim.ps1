[CmdletBinding()]
param(
    [int] $Issue,
    [ValidateSet("claim", "release")] [string] $Action,
    [string] $Repository = "iricigor/fingvibe",
    [string] $ProjectOwner = "iricigor",
    [int] $Project = 5
)

$ErrorActionPreference = "Stop"

function Invoke-Agent4Gh([string[]] $Arguments) {
    $output = gh @Arguments
    if ($LASTEXITCODE -ne 0) { throw "gh $($Arguments[0..1] -join ' ') failed." }
    $output -join "`n"
}

# Claim: add `active` and set project Status to In Progress. Release: remove `active`, Status Todo.
function Set-Agent4TaskClaim([int] $Issue, [string] $Action, [string] $Repository, [string] $ProjectOwner, [int] $Project) {
    if ($Issue -le 0 -or $Action -notin @("claim", "release")) { throw "Positive issue and claim/release action required." }
    $status = if ($Action -eq "claim") { "In Progress" } else { "Todo" }
    $labelSwitch = if ($Action -eq "claim") { "--add-label" } else { "--remove-label" }
    $null = Invoke-Agent4Gh @("issue", "edit", "$Issue", "--repo", $Repository, $labelSwitch, "active")
    $projectInfo = Invoke-Agent4Gh @("project", "view", "$Project", "--owner", $ProjectOwner, "--format", "json") | ConvertFrom-Json
    $item = Invoke-Agent4Gh @("project", "item-add", "$Project", "--owner", $ProjectOwner,
        "--url", "https://github.com/$Repository/issues/$Issue", "--format", "json") | ConvertFrom-Json
    $field = (Invoke-Agent4Gh @("project", "field-list", "$Project", "--owner", $ProjectOwner, "--format", "json") |
        ConvertFrom-Json).fields | Where-Object name -EQ "Status"
    $option = @($field.options | Where-Object name -EQ $status)
    if (-not $projectInfo.id -or -not $item.id -or -not $field.id -or $option.Count -ne 1) {
        throw "Project $Project Status option '$status' is unavailable."
    }
    $null = Invoke-Agent4Gh @("project", "item-edit", "--id", $item.id, "--project-id", $projectInfo.id,
        "--field-id", $field.id, "--single-select-option-id", $option[0].id)
    $view = Invoke-Agent4Gh @("issue", "view", "$Issue", "--repo", $Repository, "--json", "labels,projectItems") | ConvertFrom-Json
    $hasActive = "active" -in @($view.labels.name)
    $actual = @($view.projectItems | Where-Object title -EQ $projectInfo.title)[0].status.name
    if ($hasActive -ne ($Action -eq "claim") -or $actual -ne $status) {
        throw "Claim verification failed for #${Issue}: active=$hasActive, Status=$actual."
    }
    @{ issue = $Issue; action = $Action; active = $hasActive; status = $actual }
}

if ($MyInvocation.InvocationName -ne ".") {
    Set-Agent4TaskClaim $Issue $Action $Repository $ProjectOwner $Project | ConvertTo-Json -Compress
}
