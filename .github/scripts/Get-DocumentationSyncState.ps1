[CmdletBinding()]
param(
    [string] $Repository = "iricigor/fingvibe",
    [string] $RepositoryPath = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path,
    [int] $TaskNumber = 650,
    [DateTimeOffset] $NowUtc = [DateTimeOffset]::UtcNow,
    [string] $MainRef = "origin/main",
    [string] $CommentsInputPath,
    [string] $PullRequestsInputPath
)

$ErrorActionPreference = "Stop"

function Read-DocumentationSyncJsonPages {
    param([Parameter(Mandatory)] [string] $Text)

    $pages = $Text | ConvertFrom-Json -Depth 100
    return @($pages | ForEach-Object { @($_) } | ForEach-Object { $_ })
}

function Get-DocumentationSyncRecords {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Comments
    )

    $records = [Collections.Generic.List[object]]::new()
    foreach ($comment in $Comments) {
        $body = [string] $comment.body
        if (-not $body.Contains("documentation-sync-run:v1")) {
            continue
        }

        $match = [regex]::Match(
            $body,
            '(?ms)<!--\s*documentation-sync-run:v1\s*(?<json>\{.*?\})\s*-->'
        )
        if (-not $match.Success) {
            throw "Documentation sync marker is malformed in comment $($comment.id)."
        }

        $record = $match.Groups["json"].Value | ConvertFrom-Json -Depth 20
        if ($record.schema -ne "fingvibe-documentation-sync-run-v1") {
            throw "Documentation sync schema is invalid in comment $($comment.id)."
        }
        if (@("clean", "updated", "blocked") -notcontains [string] $record.status) {
            throw "Documentation sync status is invalid in comment $($comment.id)."
        }
        if ([string] $record.startSha -notmatch '^[0-9a-f]{40}$') {
            throw "Documentation sync starting revision is invalid in comment $($comment.id)."
        }
        if ([string] $record.auditedMainSha -notmatch '^[0-9a-f]{40}$') {
            throw "Documentation sync audited revision is invalid in comment $($comment.id)."
        }
        if ($record.status -eq "updated" -and
            [string] $record.pullRequestUrl -notmatch '^https://github\.com/[^/]+/[^/]+/pull/\d+$') {
            throw "Documentation sync updated record has no valid pull request in comment $($comment.id)."
        }
        [DateTimeOffset] $startedAt = $record.startedAt
        [DateTimeOffset] $completedAt = $record.completedAt
        if ($completedAt -lt $startedAt) {
            throw "Documentation sync timing is invalid in comment $($comment.id)."
        }
        $records.Add([pscustomobject]@{
            record = $record
            commentId = $comment.id
            completedAt = $completedAt
        })
    }

    return @($records | Sort-Object completedAt, commentId)
}

function Get-DocumentationSyncCheckpoint {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Comments
    )

    $successful = @(Get-DocumentationSyncRecords -Comments $Comments |
        Where-Object { $_.record.status -in @("clean", "updated") })
    if ($successful.Count -eq 0) {
        return $null
    }
    return $successful[-1].record
}

function Select-DocumentationSyncPullRequest {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $PullRequests,
        [string] $Repository = "iricigor/fingvibe",
        [int] $TaskNumber = 650
    )

    $marker = "<!-- documentation-sync-agent:$TaskNumber -->"
    $titlePrefix = "Documentation sync:"
    $branchPrefix = "copilot/documentation-sync/"
    $matches = @(
        $PullRequests | Where-Object {
            [string] $_.state -ieq "open" -and
            [string] $_.base.ref -ieq "main" -and
            [string] $_.head.repo.full_name -ieq $Repository -and
            ([string] $_.head.ref).StartsWith($branchPrefix, [StringComparison]::Ordinal) -and
            ([string] $_.title).StartsWith($titlePrefix, [StringComparison]::Ordinal) -and
            ([string] $_.body).Contains($marker) -and
            [regex]::IsMatch(
                [string] $_.body,
                "(?m)#$TaskNumber\b",
                [Text.RegularExpressions.RegexOptions]::IgnoreCase
            ) -and
            -not [regex]::IsMatch(
                [string] $_.body,
                "(?im)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s+#$TaskNumber\b",
                [Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
        }
    )

    if ($matches.Count -gt 1) {
        $numbers = ($matches.number | Sort-Object) -join ", "
        throw "Multiple agent-owned documentation sync pull requests are open: $numbers."
    }
    return $(if ($matches.Count -eq 1) { $matches[0] } else { $null })
}

function Invoke-DocumentationSyncGit {
    param(
        [Parameter(Mandatory)] [string] $RepositoryPath,
        [Parameter(Mandatory)] [string[]] $Arguments
    )

    $output = & git -C $RepositoryPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
    return @($output)
}

function Test-DocumentationSyncAncestor {
    param(
        [Parameter(Mandatory)] [string] $RepositoryPath,
        [Parameter(Mandatory)] [string] $Ancestor,
        [Parameter(Mandatory)] [string] $Descendant
    )

    & git -C $RepositoryPath merge-base --is-ancestor $Ancestor $Descendant 2>$null
    if ($LASTEXITCODE -eq 0) {
        return $true
    }
    if ($LASTEXITCODE -eq 1) {
        return $false
    }
    throw "Could not compare revisions $Ancestor and $Descendant."
}

function Resolve-DocumentationSyncStart {
    param(
        [Parameter(Mandatory)] [string] $RepositoryPath,
        [Parameter(Mandatory)] [string] $HeadSha,
        [AllowNull()] [object] $Checkpoint,
        [Parameter(Mandatory)] [DateTimeOffset] $NowUtc
    )

    $cutoff = $NowUtc.ToUniversalTime().AddHours(-24)
    $before = $cutoff.ToString("O")
    $cutoffSha = @(Invoke-DocumentationSyncGit -RepositoryPath $RepositoryPath `
        -Arguments @("rev-list", "--first-parent", "--max-count=1", "--before=$before", $HeadSha) |
        Where-Object { $_ }) | Select-Object -First 1
    if (-not $cutoffSha) {
        $cutoffSha = @(Invoke-DocumentationSyncGit -RepositoryPath $RepositoryPath `
            -Arguments @("rev-list", "--first-parent", "--max-parents=0", $HeadSha)) |
            Select-Object -First 1
    }
    if (-not $cutoffSha -or $cutoffSha -notmatch '^[0-9a-f]{40}$') {
        throw "Could not determine the 24-hour audit boundary for $HeadSha."
    }

    $startSha = [string] $cutoffSha
    $checkpointSha = if ($null -ne $Checkpoint) { [string] $Checkpoint.auditedMainSha } else { $null }
    if ($checkpointSha) {
        if (-not (Test-DocumentationSyncAncestor -RepositoryPath $RepositoryPath `
            -Ancestor $checkpointSha -Descendant $HeadSha)) {
            throw "Checkpoint $checkpointSha is not an ancestor of main head $HeadSha."
        }

        if (-not (Test-DocumentationSyncAncestor -RepositoryPath $RepositoryPath `
            -Ancestor $checkpointSha -Descendant $cutoffSha)) {
            $startSha = $cutoffSha
        } else {
            $startSha = $checkpointSha
        }
    }

    return [pscustomobject]@{
        startSha = $startSha
        cutoffSha = [string] $cutoffSha
        cutoffAt = $cutoff.ToString("O")
    }
}

if ($MyInvocation.InvocationName -eq ".") {
    return
}

if (-not (Test-Path -LiteralPath $RepositoryPath)) {
    throw "Repository path does not exist: $RepositoryPath"
}

$shallow = Invoke-DocumentationSyncGit -RepositoryPath $RepositoryPath `
    -Arguments @("rev-parse", "--is-shallow-repository") | Select-Object -First 1
if ($shallow -eq "true") {
    throw "Documentation sync requires complete Git history; the repository is shallow."
}

if ($CommentsInputPath) {
    $comments = @(Get-Content -LiteralPath $CommentsInputPath -Raw | ConvertFrom-Json -Depth 100)
} else {
    $output = & gh api --paginate --slurp `
        "repos/$Repository/issues/$TaskNumber/comments?per_page=100"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read complete documentation sync history for issue #$TaskNumber."
    }
    $comments = @(Read-DocumentationSyncJsonPages -Text ($output -join "`n"))
}

if ($PullRequestsInputPath) {
    $pullRequests = @(Get-Content -LiteralPath $PullRequestsInputPath -Raw | ConvertFrom-Json -Depth 100)
} else {
    $output = & gh api --paginate --slurp `
        "repos/$Repository/pulls?state=open&per_page=100"
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read the complete open pull request list."
    }
    $pullRequests = @(Read-DocumentationSyncJsonPages -Text ($output -join "`n"))
}

$checkpoint = Get-DocumentationSyncCheckpoint -Comments $comments
$headSha = Invoke-DocumentationSyncGit -RepositoryPath $RepositoryPath `
    -Arguments @("rev-parse", "$MainRef^{commit}") | Select-Object -First 1
$window = Resolve-DocumentationSyncStart -RepositoryPath $RepositoryPath `
    -HeadSha $headSha -Checkpoint $checkpoint -NowUtc $NowUtc
$pullRequest = Select-DocumentationSyncPullRequest -PullRequests $pullRequests `
    -Repository $Repository -TaskNumber $TaskNumber

$changedFiles = @(Invoke-DocumentationSyncGit -RepositoryPath $RepositoryPath `
    -Arguments @("diff", "--name-only", "$($window.startSha)..$headSha") |
    Where-Object { $_ })
$commits = @(Invoke-DocumentationSyncGit -RepositoryPath $RepositoryPath `
    -Arguments @("rev-list", "--reverse", "$($window.startSha)..$headSha") |
    Where-Object { $_ })
$headAt = Invoke-DocumentationSyncGit -RepositoryPath $RepositoryPath `
    -Arguments @("show", "-s", "--format=%cI", $headSha) | Select-Object -First 1

[pscustomobject]@{
    schema = "fingvibe-documentation-sync-state-v1"
    repository = $Repository
    task = $TaskNumber
    checkpoint = $checkpoint
    auditWindow = [pscustomobject]@{
        nowUtc = $NowUtc.ToUniversalTime().ToString("O")
        minimumLookbackHours = 24
        cutoffAt = $window.cutoffAt
        cutoffSha = $window.cutoffSha
        startSha = $window.startSha
        headSha = $headSha
        headAt = $headAt
        commits = $commits
        changedFiles = $changedFiles
    }
    reusablePullRequest = $pullRequest
} | ConvertTo-Json -Depth 30
