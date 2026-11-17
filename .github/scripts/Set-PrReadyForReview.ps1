[CmdletBinding()]
param(
    [string] $Repository,
    [int] $PullRequestNumber,
    [string] $ExpectedHead,
    [string] $EventName,
    [string] $EventAction,
    [string] $RunAttempt
)

$ErrorActionPreference = "Stop"

# Token match: WIP, [WIP], WIP:, wip; not words such as "wipe" or "swipe".
function Test-PrTitleWip([string] $Title) {
    $Title -match '(?i)(?<![a-z0-9])wip(?![a-z0-9])'
}

function Get-PrReadyForReviewState([string] $Repository, [int] $PullRequestNumber) {
    $json = gh api "repos/$Repository/pulls/$PullRequestNumber"
    if ($LASTEXITCODE -ne 0) { throw "Could not read pull request #$PullRequestNumber." }
    return $json | ConvertFrom-Json
}

function Set-PrReadyForReview {
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [int] $PullRequestNumber,
        [Parameter(Mandatory)] [string] $ExpectedHead,
        [Parameter(Mandatory)] [string] $EventName,
        [string] $EventAction,
        [string] $RunAttempt
    )

    function Skip([string] $Reason) { [pscustomobject]@{ Outcome = "unchanged"; Reason = $Reason } }

    # Only the first attempt of a new or updated head promotes; re-runs, reopen and manual runs never do.
    if ($EventName -ne "pull_request") { return Skip "$EventName runs never promote." }
    if ($EventAction -notin @("opened", "synchronize")) { return Skip "pull_request '$EventAction' runs never promote." }
    if ($RunAttempt -ne "1") { return Skip "Re-run attempt $RunAttempt never promotes; push a new commit." }

    $pull = Get-PrReadyForReviewState $Repository $PullRequestNumber
    if ($pull.state -ne "open" -or $pull.merged) { return Skip "Pull request is closed or merged." }
    if (-not $pull.draft) { return Skip "Pull request is already ready for review." }
    if ($pull.head.repo.full_name -ne $Repository) { return Skip "Fork pull requests are never promoted." }
    if ($pull.author_association -notin @("OWNER", "MEMBER", "COLLABORATOR") -and $pull.user.login -ne "Copilot") {
        return Skip "Untrusted authors are never promoted."
    }
    if ($pull.head.sha -ne $ExpectedHead) { return Skip "Validated head $ExpectedHead was superseded by $($pull.head.sha)." }
    if (Test-PrTitleWip $pull.title) { return Skip "Title contains WIP." }

    $null = gh api graphql -f query='mutation($id: ID!) { markPullRequestReadyForReview(input: { pullRequestId: $id }) { pullRequest { isDraft } } }' -f "id=$($pull.node_id)"
    if ($LASTEXITCODE -ne 0) { throw "Could not mark pull request #$PullRequestNumber ready for review." }
    if ((Get-PrReadyForReviewState $Repository $PullRequestNumber).draft) {
        throw "Pull request #$PullRequestNumber is still a draft after the ready-for-review request."
    }
    [pscustomobject]@{ Outcome = "ready"; Reason = "Validated head $ExpectedHead marked ready for review." }
}

if ($MyInvocation.InvocationName -ne ".") {
    $result = Set-PrReadyForReview -Repository $Repository -PullRequestNumber $PullRequestNumber `
        -ExpectedHead $ExpectedHead -EventName $EventName -EventAction $EventAction -RunAttempt $RunAttempt
    $line = "Draft readiness: $($result.Outcome). $($result.Reason)"
    Write-Host $line
    if ($env:GITHUB_STEP_SUMMARY) { $line >> $env:GITHUB_STEP_SUMMARY }
}
