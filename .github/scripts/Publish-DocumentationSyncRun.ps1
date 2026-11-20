[CmdletBinding()]
param(
    [string] $Repository = "iricigor/fingvibe",
    [int] $TaskNumber = 650,
    [ValidateSet("updated", "clean", "blocked")]
    [string] $Status,
    [DateTimeOffset] $StartedAt,
    [string] $StartSha,
    [string] $AuditedMainSha,
    [string] $PullRequestUrl = "",
    [string[]] $Evidence = @(),
    [string[]] $Uncertainties = @(),
    [string] $Blocker = ""
)

$ErrorActionPreference = "Stop"

function New-DocumentationSyncRunBody {
    param(
        [Parameter(Mandatory)] [string] $Status,
        [Parameter(Mandatory)] [DateTimeOffset] $StartedAt,
        [Parameter(Mandatory)] [DateTimeOffset] $CompletedAt,
        [Parameter(Mandatory)] [string] $StartSha,
        [Parameter(Mandatory)] [string] $AuditedMainSha,
        [string] $PullRequestUrl = "",
        [string[]] $Evidence = @(),
        [string[]] $Uncertainties = @(),
        [string] $Blocker = ""
    )

    if ($Status -eq "updated" -and
        $PullRequestUrl -notmatch '^https://github\.com/[^/]+/[^/]+/pull/\d+$') {
        throw "An updated run requires a verifiable GitHub pull request URL."
    }
    if ($Status -eq "blocked" -and -not $Blocker.Trim()) {
        throw "A blocked run requires an explicit blocker."
    }
    if ($CompletedAt -lt $StartedAt) {
        throw "The completed time cannot precede the started time."
    }

    $record = [ordered]@{
        schema = "fingvibe-documentation-sync-run-v1"
        status = $Status
        startedAt = $StartedAt.ToUniversalTime().ToString("O")
        completedAt = $CompletedAt.ToUniversalTime().ToString("O")
        startSha = $StartSha
        auditedMainSha = $AuditedMainSha
        pullRequestUrl = $(if ($PullRequestUrl) { $PullRequestUrl } else { $null })
        evidence = @($Evidence)
        uncertainties = @($Uncertainties)
        blocker = $(if ($Blocker) { $Blocker } else { $null })
    }

    $summary = switch ($Status) {
        "updated" { "Documentation synchronization updated or created a pull request." }
        "clean" { "Documentation synchronization completed without supported edits." }
        "blocked" { "Documentation synchronization is blocked; the previous checkpoint is retained." }
    }
    $json = $record | ConvertTo-Json -Depth 10
    return @"
<!-- documentation-sync-run:v1
$json
-->

## Documentation sync result

$summary

- **Window:** $($StartSha)..$($AuditedMainSha)
- **Pull request:** $(if ($PullRequestUrl) { $PullRequestUrl } else { "None" })
- **Blocker:** $(if ($Blocker) { $Blocker } else { "None" })
- **Evidence:** $(if ($Evidence.Count) { $Evidence -join "; " } else { "None" })
- **Uncertainty:** $(if ($Uncertainties.Count) { $Uncertainties -join "; " } else { "None" })
"@
}

if ($MyInvocation.InvocationName -eq ".") {
    return
}

if ($Status -notin @("updated", "clean", "blocked")) {
    throw "A documentation sync status is required."
}
if ($StartSha -notmatch '^[0-9a-f]{40}$') {
    throw "A 40-character starting revision is required."
}
if ($AuditedMainSha -notmatch '^[0-9a-f]{40}$') {
    throw "A 40-character audited main revision is required."
}
if ($StartedAt -eq [DateTimeOffset]::MinValue) {
    throw "A started time is required."
}

$body = New-DocumentationSyncRunBody `
    -Status $Status `
    -StartedAt $StartedAt `
    -CompletedAt ([DateTimeOffset]::UtcNow) `
    -StartSha $StartSha `
    -AuditedMainSha $AuditedMainSha `
    -PullRequestUrl $PullRequestUrl `
    -Evidence $Evidence `
    -Uncertainties $Uncertainties `
    -Blocker $Blocker

$payload = @{ body = $body } | ConvertTo-Json -Compress
$output = $payload | & gh api --method POST `
    "repos/$Repository/issues/$TaskNumber/comments" --input -
if ($LASTEXITCODE -ne 0) {
    throw "Could not publish the documentation sync run on issue #$TaskNumber."
}
$created = ($output -join "`n") | ConvertFrom-Json -Depth 20
$readback = & gh api "repos/$Repository/issues/comments/$($created.id)"
if ($LASTEXITCODE -ne 0) {
    throw "Could not read back documentation sync comment $($created.id)."
}
$saved = ($readback -join "`n") | ConvertFrom-Json -Depth 20
if ([string] $saved.body -cne $body) {
    throw "Documentation sync comment $($created.id) did not match the published body."
}

[pscustomobject]@{
    id = $saved.id
    url = $saved.html_url
    status = $Status
    auditedMainSha = $AuditedMainSha
} | ConvertTo-Json -Depth 10
