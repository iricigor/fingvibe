[CmdletBinding()]
param(
    [Parameter(Mandatory)][int] $PullRequestNumber,
    [Parameter(Mandatory)][string] $Repository,
    [Parameter(Mandatory)][string] $Marker,
    [ValidateSet("Append", "Upsert", "Remove")][string] $Mode = "Upsert",
    [string] $Body
)

$ErrorActionPreference = "Stop"
if ($Mode -ne "Remove" -and ([string]::IsNullOrWhiteSpace($Body) -or -not $Body.Contains($Marker))) {
    throw "The comment body must include its marker."
}
if ($Mode -eq "Append") {
    gh pr comment $PullRequestNumber --repo $Repository --body $Body
    if ($LASTEXITCODE -ne 0) { throw "Could not append the pull-request comment." }
    return
}

$response = gh api "repos/$Repository/issues/$PullRequestNumber/comments" --paginate --slurp
if ($LASTEXITCODE -ne 0) { throw "Could not list pull-request comments." }
$existing = @(
    foreach ($page in ($response | ConvertFrom-Json)) {
        foreach ($comment in $page) {
            if ($comment.user.login -eq "github-actions[bot]" -and $comment.body.Contains($Marker)) {
                $comment
            }
        }
    }
) | Select-Object -First 1

if ($Mode -eq "Remove") {
    if ($existing) {
        gh api --method DELETE "repos/$Repository/issues/comments/$($existing.id)"
        if ($LASTEXITCODE -ne 0) { throw "Could not remove the resolved failure comment." }
    }
}
elseif ($existing) {
    @{ body = $Body } | ConvertTo-Json | gh api --method PATCH "repos/$Repository/issues/comments/$($existing.id)" --input -
    if ($LASTEXITCODE -ne 0) { throw "Could not update the pull-request comment." }
}
else {
    gh pr comment $PullRequestNumber --repo $Repository --body $Body
    if ($LASTEXITCODE -ne 0) { throw "Could not create the pull-request comment." }
}
