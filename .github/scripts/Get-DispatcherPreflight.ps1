[CmdletBinding()]
param(
    [ValidatePattern("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$")]
    [string] $Repository,
    [int] $Epic,
    [int[]] $TaskOrder,
    [string] $OrderEvidenceUrl,
    [switch] $HistoricalCompletionSelfHealing,
    [string] $DiagnosticsDirectory = ([IO.Path]::GetTempPath())
)

$ErrorActionPreference = "Stop"

function Invoke-DispatcherGitHubRead {
    param([string] $Endpoint, [bool] $Paginated, [string] $Query)

    $text = if ($Query) {
        gh api graphql -f query=$Query
    } elseif ($Paginated) {
        gh api -X GET --paginate --slurp $Endpoint
    } else {
        gh api -X GET $Endpoint
    }
    if ($LASTEXITCODE -ne 0) { throw "GitHub read failed: $Endpoint (exit $LASTEXITCODE)." }
    $text -join "`n"
}

function Get-DispatcherPreflight {
    param(
        [Parameter(Mandatory)]
        [ValidatePattern("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$")]
        [string] $Repository,
        [Parameter(Mandatory)]
        [ValidateRange(1, [int]::MaxValue)]
        [int] $Epic,
        [int[]] $TaskOrder,
        [string] $OrderEvidenceUrl,
        [switch] $HistoricalCompletionSelfHealing,
        [DateTimeOffset] $Now = [DateTimeOffset]::UtcNow,
        [scriptblock] $ApiReader = ${function:Invoke-DispatcherGitHubRead}
    )

    $watch = [Diagnostics.Stopwatch]::StartNew()
    $cache = @{}
    $metrics = [Collections.Generic.List[object]]::new()
    $findings = [Collections.Generic.List[object]]::new()
    $skipped = [Collections.Generic.List[object]]::new()
    $candidate = $null
    $decision = "blocked"
    $targetBranch = $null
    $counts = [ordered]@{}
    $ordering = $null
    $failure = $null

    function Read-DispatcherEvidence([string] $Endpoint, [bool] $Paginated = $false, [string] $Query) {
        $key = "$Endpoint|$Paginated|$Query"
        if ($cache.ContainsKey($key)) { return $cache[$key] }
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $json = & $ApiReader $Endpoint $Paginated $Query
        if ($json -isnot [string] -or [string]::IsNullOrWhiteSpace($json)) {
            throw "GitHub reader must return one nonempty JSON string: $Endpoint."
        }
        $parseOptions = if ($HistoricalCompletionSelfHealing) { @{ DateKind = "String" } } else { @{} }
        $parsed = ConvertFrom-Json -InputObject $json -Depth 100 -NoEnumerate @parseOptions
        if ($Paginated) {
            if (-not $json.TrimStart().StartsWith("[") -or
                @($parsed | Where-Object { $_ -isnot [array] }).Count -gt 0) {
                throw "Expected fully paginated JSON pages: $Endpoint."
            }
            $value = @($parsed | ForEach-Object { foreach ($item in $_) { $item } })
        } else {
            if ($null -eq $parsed -or $parsed -is [array]) { throw "Expected a JSON object: $Endpoint." }
            $value = $parsed
        }
        $timer.Stop()
        $metrics.Add([pscustomobject]@{
            endpoint = $Endpoint
            seconds = [math]::Round($timer.Elapsed.TotalSeconds, 3)
            records = @($value).Count
            bytes = [Text.Encoding]::UTF8.GetByteCount($json)
        })
        $cache[$key] = $value
        return $value
    }

    function Add-DispatcherFinding([string] $Kind, [int] $Number, [string] $Url, [string] $Reason) {
        $findings.Add([pscustomobject]@{ kind = $Kind; issue = $Number; url = $Url; reason = $Reason })
    }

    function Get-DispatcherDelivery([int] $Number) {
        $parts = $Repository.Split("/")
        $cursor = ""
        $pulls = [Collections.Generic.List[object]]::new()
        $seenCursors = @{}
        $parent = $null
        $membershipRead = $false
        $closure = $null
        do {
            $after = if ($cursor) { ',after:"' + $cursor + '"' } else { "" }
            $issueCompletionFields = if ($HistoricalCompletionSelfHealing) { "state stateReason closedAt " } else { "" }
            $prCompletionFields = if ($HistoricalCompletionSelfHealing) { "mergedAt closedAt " } else { "" }
            $query = 'query { repository(owner:"' + $parts[0] + '",name:"' + $parts[1] +
                '") { issue(number:' + $Number +
                ') { number ' + $issueCompletionFields + 'parent { number labels(first:100) { nodes { name } pageInfo { hasNextPage } } }' +
                ' closedByPullRequestsReferences(first:100' + $after +
                ') { nodes { number url merged ' + $prCompletionFields + 'baseRefName state } pageInfo { hasNextPage endCursor } } } } }'
            $response = Read-DispatcherEvidence "graphql" $false $query
            $issue = $response.data.repository.issue
            if ($response.errors -or $null -eq $issue -or $issue.number -ne $Number -or
                "parent" -notin $issue.PSObject.Properties.Name -or
                $issue.closedByPullRequestsReferences.pageInfo.hasNextPage -isnot [bool] -or
                ($null -ne $issue.parent -and
                    ($issue.parent.number -isnot [long] -or $issue.parent.number -le 0 -or
                        $issue.parent.labels.nodes -isnot [array] -or
                        $issue.parent.labels.pageInfo.hasNextPage -isnot [bool] -or
                        $issue.parent.labels.pageInfo.hasNextPage))) {
                throw "Incomplete native membership/delivery evidence for #$Number."
            }
            if (($membershipRead -and
                    (($null -eq $parent) -ne ($null -eq $issue.parent) -or $parent.number -ne $issue.parent.number)) -or
                ($childNumbers.ContainsKey($Number) -and $issue.parent.number -ne $Epic) -or
                (-not $childNumbers.ContainsKey($Number) -and $issue.parent.number -eq $Epic)) {
                throw "Inconsistent native membership evidence for #$Number."
            }
            $currentClosure = "$($issue.state)|$($issue.stateReason)|$($issue.closedAt)"
            if ($HistoricalCompletionSelfHealing -and $membershipRead -and $currentClosure -cne $closure) {
                throw "Issue closure changed during delivery pagination for #$Number."
            }
            $closure = $currentClosure
            $parent = $issue.parent
            $membershipRead = $true
            foreach ($pr in $issue.closedByPullRequestsReferences.nodes) { $pulls.Add($pr) }
            $page = $issue.closedByPullRequestsReferences.pageInfo
            if ($page.hasNextPage) {
                if (-not $page.endCursor -or $seenCursors.ContainsKey($page.endCursor)) {
                    throw "Invalid delivery pagination for #$Number."
                }
                $seenCursors[$page.endCursor] = $true
                $cursor = $page.endCursor
            }
        } while ($page.hasNextPage)
        [pscustomobject]@{
            parent = $parent
            issue = $issue
            prs = @($pulls)
            delivered = $pulls.Count -gt 0 -and
                @($pulls | Where-Object { -not $_.merged -or $_.baseRefName -ne $targetBranch }).Count -eq 0
        }
    }

    function Read-CompletionTimestamp([object] $Value) {
        $timestamp = [DateTimeOffset]::MinValue
        $text = [string] $Value
        if ($text -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$' -or
            -not [DateTimeOffset]::TryParse($text, [ref] $timestamp) -or $timestamp -gt $Now) {
            throw "Missing, invalid or future historical completion timestamp: '$text'."
        }
        $timestamp
    }

    function Get-HistoricalCompletion($Issue, $Delivery) {
        if ($Delivery.issue.state -ne "CLOSED" -or $Delivery.issue.stateReason -ne "COMPLETED") {
            throw "Historical self-healing requires current completed closure for #$($Issue.number)."
        }
        $closed = Read-CompletionTimestamp $Delivery.issue.closedAt
        $latest = $closed
        $prEvidence = @(
            foreach ($pr in ($Delivery.prs | Sort-Object url)) {
                if ($pr.state -ne "MERGED" -or -not $pr.url) {
                    throw "Incomplete merged PR evidence for #$($Issue.number)."
                }
                $prClosed = Read-CompletionTimestamp $pr.closedAt
                $merged = Read-CompletionTimestamp $pr.mergedAt
                if ($merged -gt $prClosed) { throw "PR merge occurs after closure: $($pr.url)." }
                if ($prClosed -gt $latest) { $latest = $prClosed }
                if ($merged -gt $latest) { $latest = $merged }
                [ordered]@{ url = $pr.url; closedUtc = $prClosed.ToUniversalTime().ToString("o"); mergedUtc = $merged.ToUniversalTime().ToString("o") }
            }
        )
        $eligibleAfter = $latest.AddMinutes(30)
        $record = [ordered]@{
            schema = "fingvibe-historical-completion-v1"
            repository = $Repository
            task = $Issue.number
            targetBranch = $targetBranch
            issueClosedUtc = $closed.ToUniversalTime().ToString("o")
            pullRequests = $prEvidence
            checkedUtc = $Now.ToUniversalTime().ToString("o")
            evidence = @()
        }
        $notice = $null
        foreach ($comment in $comments) {
            if ($comment.issue_url -ne $Issue.url -or
                $comment.body -notmatch '<!--\s*fingvibe-historical-completion-v1\s*-->') { continue }
            $blocks = [regex]::Matches($comment.body, '(?s)```json\s*(.*?)\s*```')
            if ($blocks.Count -ne 1 -or
                [regex]::Matches($comment.body, '<!--\s*fingvibe-historical-completion-v1\s*-->').Count -ne 1) {
                throw "Malformed historical reconciliation notice: $($comment.html_url)."
            }
            $prior = ConvertFrom-Json -InputObject $blocks[0].Groups[1].Value -Depth 30 -DateKind String
            if ($comment.author_association -notin @("OWNER", "MEMBER", "COLLABORATOR") -or
                $prior.schema -ne $record.schema -or $prior.repository -cne $Repository -or
                $prior.task -ne $Issue.number -or $prior.targetBranch -cne $targetBranch -or
                $prior.pullRequests -isnot [array] -or $prior.pullRequests.Count -eq 0 -or
                $prior.evidence -isnot [array] -or $prior.evidence.Count -eq 0 -or
                @($prior.evidence | Where-Object { $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
                throw "Untrusted/incomplete historical reconciliation notice: $($comment.html_url)."
            }
            $checked = Read-CompletionTimestamp $prior.checkedUtc
            $priorClosed = Read-CompletionTimestamp $prior.issueClosedUtc
            $priorPrs = @(
                foreach ($pr in ($prior.pullRequests | Sort-Object url)) {
                    if (-not $pr.url) { throw "Missing PR URL in historical reconciliation: $($comment.html_url)." }
                    [ordered]@{
                        url = $pr.url
                        closedUtc = (Read-CompletionTimestamp $pr.closedUtc).ToUniversalTime().ToString("o")
                        mergedUtc = (Read-CompletionTimestamp $pr.mergedUtc).ToUniversalTime().ToString("o")
                    }
                }
            )
            if ($priorClosed -eq $closed -and
                (ConvertTo-Json -InputObject $priorPrs -Depth 10 -Compress) -ceq
                    (ConvertTo-Json -InputObject $prEvidence -Depth 10 -Compress) -and
                $checked -gt $eligibleAfter) {
                $notice = $comment.html_url
            }
        }
        [pscustomobject]@{
            eligibleAfterUtc = $eligibleAfter.ToUniversalTime().ToString("o")
            eligible = $Now -gt $eligibleAfter
            notice = $notice
            record = $record
        }
    }

    function Assert-DispatcherDependencyGraph([int] $Root) {
        $visiting = [Collections.Generic.HashSet[int]]::new()
        $visited = [Collections.Generic.HashSet[int]]::new()
        function Visit-DispatcherDependency([int] $Number) {
            if ($visiting.Contains($Number)) { throw "Cyclic native dependencies at #$Number." }
            if ($visited.Contains($Number)) { return }
            if ($visiting.Count -ge 256) { throw "Dependency graph exceeds the bounded review depth." }
            $visiting.Add($Number) | Out-Null
            $dependencies = @(Read-DispatcherEvidence "repos/$Repository/issues/$Number/dependencies/blocked_by?per_page=100" $true)
            if (@($dependencies.number | Select-Object -Unique).Count -ne $dependencies.Count) {
                throw "Duplicate native dependencies at #$Number."
            }
            foreach ($dependency in $dependencies) {
                if (-not $issueByNumber.ContainsKey([int] $dependency.number) -or
                    $dependency.state -ne $issueByNumber[[int] $dependency.number].state) {
                    throw "Dependency enumeration changed or references unknown work: #$Number."
                }
                if ($dependency.state -eq "open") { Visit-DispatcherDependency $dependency.number }
            }
            $visiting.Remove($Number) | Out-Null
            $visited.Add($Number) | Out-Null
        }
        Visit-DispatcherDependency $Root
    }

    try {
        $repo = Read-DispatcherEvidence "repos/$Repository"
        if ($repo.full_name -ine $Repository -or -not $repo.default_branch -or -not $repo.html_url -or -not $repo.url) {
            throw "Repository identity/default branch is unavailable."
        }
        $targetBranch = $repo.default_branch
        $epicIssue = Read-DispatcherEvidence "repos/$Repository/issues/$Epic"
        if ($epicIssue.number -ne $Epic -or "type:epic" -notin $epicIssue.labels.name) {
            throw "Configured Epic #$Epic is not a verified type:epic issue."
        }
        $pulls = @(Read-DispatcherEvidence "repos/$Repository/pulls?state=open&per_page=100" $true)
        $repositoryItems = @(Read-DispatcherEvidence "repos/$Repository/issues?state=all&per_page=100" $true)
        $issues = @($repositoryItems | Where-Object { -not $_.pull_request })
        $comments = @(Read-DispatcherEvidence "repos/$Repository/issues/comments?per_page=100" $true)
        $children = @(Read-DispatcherEvidence "repos/$Repository/issues/$Epic/sub_issues?per_page=100" $true)
        $issueByNumber = @{}
        $pullRequestByNumber = @{}
        foreach ($issue in $repositoryItems) {
            if (-not $issue.number -or $issueByNumber.ContainsKey([int] $issue.number) -or
                $pullRequestByNumber.ContainsKey([int] $issue.number) -or
                $issue.state -notin @("open", "closed") -or -not $issue.html_url) {
                throw "Invalid/duplicate issue in repository enumeration."
            }
            if ($issue.pull_request) {
                $pullRequestByNumber[[int] $issue.number] = $issue
            } else {
                $issueByNumber[[int] $issue.number] = $issue
            }
        }
        $childNumbers = @{}
        foreach ($child in $children) {
            if (-not $issueByNumber.ContainsKey([int] $child.number) -or $childNumbers.ContainsKey([int] $child.number)) {
                throw "Native child enumeration is inconsistent with repository issues."
            }
            $childNumbers[[int] $child.number] = $true
        }
        $claimsByTask = @{}
        $claimIds = @{}
        $commentIds = @{}
        foreach ($comment in $comments) {
            if (-not $comment.id -or $commentIds.ContainsKey([string] $comment.id) -or
                -not $comment.issue_url -or -not $comment.html_url -or $comment.body -isnot [string]) {
                throw "Incomplete/duplicate repository comment evidence."
            }
            $commentIds[[string] $comment.id] = $true
            if ($comment.body -notmatch '<!--\s*fingvibe-agent-claim-v1\s*-->') { continue }
            if ([regex]::Matches($comment.body, '<!--\s*fingvibe-agent-claim-v1\s*-->').Count -ne 1 -or
                [regex]::Matches($comment.body, '(?s)```json\s*(.*?)\s*```').Count -ne 1) {
                throw "Malformed coordination record: $($comment.html_url)."
            }
            $claimJson = [regex]::Match($comment.body, '(?s)```json\s*(.*?)\s*```').Groups[1].Value
            $claim = ConvertFrom-Json $claimJson -Depth 100
            $taskNumber = 0
            $claimId = [guid]::Empty
            $handoffId = [guid]::Empty
            $claimEpic = 0
            $claimedUtc = [DateTimeOffset]::MinValue
            $claimedTimestamp = [regex]::Match($claimJson, '"claimedUtc"\s*:\s*"([^"]+)"').Groups[1].Value
            $requiredFields = @(
                "schema", "repository", "epic", "task", "claimId", "claimedUtc", "authorization", "account",
                "targetBranch", "branch", "worktree", "pr", "head", "implementationCheckpoint", "repairCount", "state", "handoff"
            )
            if (@($requiredFields | Where-Object { $_ -notin $claim.PSObject.Properties.Name }).Count -gt 0 -or
                $claimedTimestamp -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$' -or
                -not [DateTimeOffset]::TryParse($claimedTimestamp, [ref] $claimedUtc) -or
                ($claim.repairCount -isnot [long] -and $claim.repairCount -isnot [int]) -or
                $claim.repairCount -notin @(0, 1, 2, 3) -or
                -not $claim.handoff -or
                -not [guid]::TryParse([string] $claim.handoff.id, [ref] $handoffId) -or $handoffId -eq [guid]::Empty -or
                $claim.handoff.action -notin @("implement", "repair", "finalize") -or
                $claim.handoff.stage -notin @("launch-requested", "launch-confirmed", "message-accepted", "acknowledged", "finished")) {
                throw "Incomplete/invalid coordination fields: $($comment.html_url)."
            }
            if ($claim.schema -ne "fingvibe-agent-claim-v1" -or $claim.repository -ine $Repository -or
                -not [int]::TryParse([string] $claim.task, [ref] $taskNumber) -or
                -not $issueByNumber.ContainsKey($taskNumber) -or
                $comment.issue_url -ne "$($repo.url)/issues/$taskNumber" -or
                -not [guid]::TryParse([string] $claim.claimId, [ref] $claimId) -or $claimId -eq [guid]::Empty -or
                -not [int]::TryParse([string] $claim.epic, [ref] $claimEpic) -or
                -not $issueByNumber.ContainsKey($claimEpic) -or "type:epic" -notin $issueByNumber[$claimEpic].labels.name -or
                -not $claim.authorization -or -not $claim.account -or
                $claim.targetBranch -ne $targetBranch -or
                $claim.state -notin @("claimed", "blocked", "completed", "released") -or
                $claimsByTask.ContainsKey($taskNumber) -or $claimIds.ContainsKey($claimId.ToString())) {
                throw "Invalid, foreign or duplicate coordination record: $($comment.html_url)."
            }
            $claimsByTask[$taskNumber] = $claim
            $claimIds[$claimId.ToString()] = $true
            if ($claim.state -notin @("completed", "released")) {
                Add-DispatcherFinding "retained-claim" $taskNumber $comment.html_url (
                    "State=$($claim.state); action=$($claim.handoff.action); stage=$($claim.handoff.stage); " +
                    "session=$($claim.handoff.sessionId). Verify actual host execution and matching results.")
            }
        }
        foreach ($pr in $pulls) {
            if (-not $pr.number -or $pr.state -ne "open" -or -not $pr.html_url) {
                throw "Invalid open PR evidence."
            }
            Add-DispatcherFinding "open-pr" $pr.number $pr.html_url "Repository slot occupied; draft=$($pr.draft)."
        }
        foreach ($issue in $issues) {
            if ($issue.state -eq "open" -and
                @($issue.labels.name | Where-Object { $_ -in @("active", "status:review") }).Count -gt 0) {
                Add-DispatcherFinding "open-active-or-review" $issue.number $issue.html_url "Repository slot occupied."
            }
        }
        $counts = [ordered]@{
            issues = $issues.Count
            comments = $comments.Count
            structuredClaims = $claimsByTask.Count
            nativeChildren = $children.Count
        }

        if ($findings.Count -gt 0) {
            $decision = "reconcile"
        } else {
            $manualEvidence = @{}
            foreach ($comment in $comments) {
                if ($comment.body -match "fingvibe-agent-(claim|result)-v1" -or
                    $comment.body -notmatch '(?i)\b(claiming|claimed|claim retained|retained claim|ownership)\b') { continue }
                if ($comment.issue_url -notmatch ('^' + [regex]::Escape($repo.url) + '/issues/(\d+)$')) {
                    throw "Uncorrelated ownership comment: $($comment.html_url)."
                }
                $number = [int] $Matches[1]
                if ($pullRequestByNumber.ContainsKey($number)) { continue }
                if (-not $issueByNumber.ContainsKey($number)) {
                    throw "Ownership comment has no enumerated issue (#$number): $($comment.html_url)."
                }
                if ("type:epic" -in $issueByNumber[$number].labels.name) {
                    $skipped.Add([pscustomobject]@{
                        issue = $number
                        reason = "Organizing Epic discussion is not a task claim; explicit claims and live work still block."
                        evidence = @($comment.html_url)
                    })
                    continue
                }
                if ($issueByNumber[$number].state -eq "closed" -and $claimsByTask.ContainsKey($number)) { continue }
                $manualEvidence[$number] = $comment.html_url
            }
            $historical = @($issues | Where-Object {
                $_.state -eq "closed" -and -not $claimsByTask.ContainsKey([int] $_.number) -and
                ($manualEvidence.ContainsKey([int] $_.number) -or
                    @($_.labels.name | Where-Object { $_ -in @("active", "status:review") }).Count -gt 0)
            })
            foreach ($issue in $historical) {
                $delivery = Get-DispatcherDelivery $issue.number
                if ($null -ne $delivery.parent -and "type:epic" -notin $delivery.parent.labels.nodes.name) {
                    Add-DispatcherFinding "historical-membership-unknown" $issue.number $issue.html_url "Native Epic membership is unverified."
                } elseif (-not $delivery.delivered) {
                    Add-DispatcherFinding "historical-delivery-unknown" $issue.number $issue.html_url "No complete merged closing-PR evidence; closure is not delivery."
                } elseif ($delivery.parent.number -eq $Epic) {
                    if (-not $HistoricalCompletionSelfHealing) {
                        Add-DispatcherFinding "historical-cleanup" $issue.number $issue.html_url "Within-Epic historical ownership/labels require human reconciliation."
                        continue
                    }
                    $realClaims = @($comments | Where-Object {
                        $_.issue_url -eq $issue.url -and $_.body -match '<!--\s*fingvibe-real-claim-v1\s*-->'
                    })
                    if ($realClaims.Count -gt 0) {
                        Add-DispatcherFinding "historical-cleanup" $issue.number $issue.html_url "Structured real-task history requires its owning workflow; manual self-healing cannot release it."
                        continue
                    }
                    $completion = Get-HistoricalCompletion $issue $delivery
                    if ($completion.notice) {
                        $skipped.Add([pscustomobject]@{
                            issue = $issue.number
                            reason = "Historical completion reconciled by policy, not proof of termination. Recheck current work and notice provenance."
                            evidence = @($completion.notice) + @($delivery.prs.url)
                        })
                    } else {
                        $kind = if ($completion.eligible) { "historical-self-heal" } else { "historical-grace-period" }
                        Add-DispatcherFinding $kind $issue.number $issue.html_url (
                            "Completion must be strictly older than 30 minutes (after $($completion.eligibleAfterUtc)). " +
                            "Check current work; then post/verify one self-healing notice, not an implementation claim. No historical termination proof required.")
                        $findings[$findings.Count - 1] | Add-Member -NotePropertyName completion -NotePropertyValue $completion
                    }
                } else {
                    $skipped.Add([pscustomobject]@{
                        issue = $issue.number
                        reason = if ($null -eq $delivery.parent) {
                            "Merged parentless historical record; reconcile missing Epic organization separately and verify host state."
                        } else {
                            "Out-of-Epic merged historical record; host must still rule out genuine unfinished work."
                        }
                        evidence = @($delivery.prs.url)
                    })
                }
            }
            foreach ($number in $manualEvidence.Keys) {
                if ($issueByNumber[$number].state -eq "open") {
                    Add-DispatcherFinding "manual-ownership-review" $number $manualEvidence[$number] "Prose ownership evidence needs Dispatcher reconciliation."
                }
            }
            if ($findings.Count -gt 0) {
                $decision = "reconcile"
            } else {
                $openTasks = @($children | Where-Object { $_.state -eq "open" -and "type:task" -in $_.labels.name })
                $counts.openTasks = $openTasks.Count
                if ($TaskOrder) {
                    $expectedPrefix = "$($epicIssue.html_url)#issuecomment-"
                    if ([string]::IsNullOrWhiteSpace($OrderEvidenceUrl) -or
                        ($OrderEvidenceUrl -ne $epicIssue.html_url -and -not $OrderEvidenceUrl.StartsWith($expectedPrefix))) {
                        throw "Explicit TaskOrder needs an evidence URL on the configured Epic."
                    }
                    if (@($TaskOrder | Select-Object -Unique).Count -ne $TaskOrder.Count -or
                        @($TaskOrder | Where-Object { -not $childNumbers.ContainsKey($_) }).Count -gt 0) {
                        throw "Explicit TaskOrder contains duplicate or non-native tasks."
                    }
                    $ordering = [ordered]@{ source = "dispatcher-verified"; evidence = $OrderEvidenceUrl; tasks = @($TaskOrder) }
                } else {
                    $orderLines = @($epicIssue.body -split "\r?\n" | Where-Object {
                        $_ -match '(?i)(delivery|execution|implementation)\s+order' -and $_ -match '#\d+\s*(->|\u2192)\s*#\d+'
                    })
                    if ($orderLines.Count -eq 1 -and
                        [regex]::Matches($orderLines[0], '#\d+(?:\s*(?:->|\u2192)\s*#\d+)+').Count -eq 1) {
                        $sequence = [regex]::Match($orderLines[0], '#\d+(?:\s*(?:->|\u2192)\s*#\d+)+').Value
                        $TaskOrder = @([regex]::Matches($sequence, '#(\d+)') | ForEach-Object { [int] $_.Groups[1].Value })
                        if (@($TaskOrder | Select-Object -Unique).Count -ne $TaskOrder.Count -or
                            @($TaskOrder | Where-Object { -not $childNumbers.ContainsKey($_) }).Count -gt 0) {
                            throw "Epic order contains duplicate or non-native tasks."
                        }
                        $ordering = [ordered]@{ source = "epic-arrow-order"; evidence = $epicIssue.html_url; tasks = $TaskOrder }
                    } elseif ($epicIssue.body -match '(?i)\b(delivery|execution|implementation|explicit|selection)\s+order\b' -or
                        @($comments | Where-Object {
                            $_.issue_url -eq $epicIssue.url -and
                            $_.body -match '(?i)\b(delivery|execution|implementation|explicit|selection)\s+order\b'
                        }).Count -gt 0) {
                        Add-DispatcherFinding "ordering-review" $Epic $epicIssue.html_url "Narrative/historical ordering needs verified TaskOrder and OrderEvidenceUrl."
                    } else {
                        $TaskOrder = @($openTasks.number | Sort-Object)
                        $ordering = [ordered]@{ source = "ascending-issue-number"; evidence = $epicIssue.html_url; tasks = $TaskOrder }
                    }
                }
                if ($findings.Count -eq 0) {
                    foreach ($number in $TaskOrder) {
                        $task = $issueByNumber[$number]
                        if ($task.state -ne "open" -or "type:task" -notin $task.labels.name) { continue }
                        if (@($task.labels.name | Where-Object { $_ -in @("human-task", "status:blocked") }).Count -gt 0 -or
                            $task.assignees.Count -gt 0 -or $claimsByTask.ContainsKey($number)) {
                            $skipped.Add([pscustomobject]@{ issue = $number; reason = "Human-task, blocked, assigned or previously claimed."; evidence = @($task.html_url) })
                            continue
                        }
                        $parent = Read-DispatcherEvidence "repos/$Repository/issues/$number/parent"
                        if ($parent.number -ne $Epic -or "type:epic" -notin $parent.labels.name) {
                            throw "Candidate native parent changed: #$number."
                        }
                        $native = @(Read-DispatcherEvidence "repos/$Repository/issues/$number/dependencies/blocked_by?per_page=100" $true)
                        Assert-DispatcherDependencyGraph $number
                        $nativeNumbers = @($native.number | Sort-Object -Unique)
                        $dependencySection = [regex]::Match([string] $task.body,
                            '(?ims)^## Dependencies[^\r\n]*\r?\n(.*?)(?=^## |\z)').Groups[1].Value
                        $bodyNumbers = @()
                        $declarations = @($dependencySection -split "\r?\n" | Where-Object {
                            $_ -match '(?i)^\s*(?:\*\*)?(?:native blockers|blocking prerequisites|blocking tasks|blockers|depends on|dependencies)\s*:'
                        })
                        foreach ($line in $declarations) {
                            $bodyNumbers += @([regex]::Matches($line, '#(\d+)') | ForEach-Object { [int] $_.Groups[1].Value })
                        }
                        $bodyNumbers = @($bodyNumbers | Sort-Object -Unique)
                        $hasNoDependencies = $dependencySection -match '(?i)\b(no blocking dependencies|no blocking implementation dependencies|no blocking dependency|blocking dependencies:\s*none|dependencies:\s*none)\b'
                        if ($dependencySection -match '(?i)\b(depend|block|prerequisit)' -and
                            $declarations.Count -eq 0 -and -not $hasNoDependencies) {
                            Add-DispatcherFinding "dependency-review" $number $task.html_url "Dependency prose is not a mechanical declaration; verify discussion and delivery."
                            break
                        }
                        if (-not $dependencySection -and $task.body -match '(?i)\b(depends on|blocked by|blocking prerequisites)\b') {
                            Add-DispatcherFinding "dependency-review" $number $task.html_url "Dependency declaration is outside the standard section; verify before selection."
                            break
                        }
                        if (($hasNoDependencies -and $nativeNumbers.Count -gt 0) -or
                            ($declarations.Count -gt 0 -and
                                @(@($nativeNumbers | Where-Object { $_ -notin $bodyNumbers }) +
                                    @($bodyNumbers | Where-Object { $_ -notin $nativeNumbers })).Count -gt 0)) {
                            Add-DispatcherFinding "dependency-inconsistent" $number $task.html_url "Native and declared body dependencies disagree."
                            break
                        }
                        $pending = $false
                        $deliveryEvidence = [Collections.Generic.List[object]]::new()
                        foreach ($dependency in $native) {
                            if (-not $issueByNumber.ContainsKey([int] $dependency.number) -or
                                $dependency.state -ne $issueByNumber[[int] $dependency.number].state) {
                                throw "Dependency enumeration changed or references unknown work: #$number."
                            }
                            if ($dependency.number -eq $number) {
                                throw "Task #$number depends on itself."
                            }
                            if ($dependency.state -eq "open") { $pending = $true; continue }
                            $delivery = Get-DispatcherDelivery $dependency.number
                            if (-not $delivery.delivered) {
                                Add-DispatcherFinding "dependency-delivery-review" $number $dependency.html_url (
                                    "Prerequisite #$($dependency.number) lacks complete merged delivery; inspect transferred/design acceptance.")
                            } else {
                                $deliveryEvidence.Add([pscustomobject]@{ issue = $dependency.number; prs = @($delivery.prs.url) })
                            }
                        }
                        if ($findings.Count -gt 0) { break }
                        if ($pending) {
                            $skipped.Add([pscustomobject]@{ issue = $number; reason = "Undelivered open native prerequisite."; evidence = @($native.html_url) })
                            continue
                        }
                        $candidate = [ordered]@{ issue = $number; url = $task.html_url; dependencies = @($deliveryEvidence) }
                        break
                    }
                    $decision = if ($findings.Count -gt 0) { "blocked" } elseif ($candidate) { "candidate" } else { "no-work" }
                }
            }
        }
    } catch {
        $failure = $_.Exception.Message
        Add-DispatcherFinding "evidence-error" $Epic "" $failure
        $decision = "blocked"
        $candidate = $null
    } finally {
        $watch.Stop()
    }
    [ordered]@{
        schema = "fingvibe-dispatcher-preflight-v1"
        repository = $Repository
        epic = $Epic
        targetBranch = $targetBranch
        collectedUtc = [DateTime]::UtcNow.ToString("o")
        decision = $decision
        candidate = $candidate
        findings = @($findings)
        skipped = @($skipped)
        ordering = $ordering
        counts = $counts
        requiresDispatcherVerification = @(
            "Actual host worker state, including genuine unfinished work behind historical records."
            "Authorization, current scope/discussion, body/native dependencies and acceptance evidence."
            "Fresh capacity/candidate/labels/dependencies before claiming; no mutations are authorized by this output."
        )
        elapsedSeconds = [math]::Round($watch.Elapsed.TotalSeconds, 3)
        collectionMetrics = @($metrics)
        collectionFailure = $failure
    }
}

function ConvertTo-DispatcherPreflightOutput {
    param(
        [Parameter(Mandatory)] $Result,
        [string] $DiagnosticsDirectory = ([IO.Path]::GetTempPath())
    )
    $json = ConvertTo-Json -InputObject $Result -Depth 30 -Compress
    $bytes = [Text.Encoding]::UTF8.GetByteCount($json)
    if ($bytes -le 8192) { return $json }
    if (-not [IO.Path]::IsPathFullyQualified($DiagnosticsDirectory) -or
        -not (Test-Path -LiteralPath $DiagnosticsDirectory -PathType Container)) {
        throw "Oversized preflight output needs an existing absolute DiagnosticsDirectory."
    }
    $path = Join-Path $DiagnosticsDirectory ("dispatcher-preflight-" + [guid]::NewGuid() + ".json")
    [IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))
    $summary = [ordered]@{
        schema = $Result.schema
        repository = $Result.repository
        epic = $Result.epic
        collectedUtc = $Result.collectedUtc
        decision = $Result.decision
        candidate = $null
        reviewRequired = "Read the complete diagnostic artifact before any selection or reconciliation."
        diagnosticPath = $path
        diagnosticBytes = $bytes
        findingCount = @($Result.findings).Count
        elapsedSeconds = $Result.elapsedSeconds
        collectionFailure = if ($Result.collectionFailure) { "See diagnostic artifact for the complete collection error." } else { $null }
    }
    $summaryJson = ConvertTo-Json -InputObject $summary -Depth 10 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($summaryJson) -gt 8192) {
        throw "Diagnostic pointer exceeds the 8 KiB output limit; full evidence is saved at '$path'."
    }
    $summaryJson
}

if ($MyInvocation.InvocationName -ne ".") {
    if (-not $Repository -or $Epic -lt 1) { throw "Repository and a positive Epic are required." }
    $result = Get-DispatcherPreflight -Repository $Repository -Epic $Epic -TaskOrder $TaskOrder -OrderEvidenceUrl $OrderEvidenceUrl -HistoricalCompletionSelfHealing:$HistoricalCompletionSelfHealing
    ConvertTo-DispatcherPreflightOutput -Result $result -DiagnosticsDirectory $DiagnosticsDirectory
    if ($result.collectionFailure) { exit 1 }
}
