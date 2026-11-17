[CmdletBinding()]
param(
    [string] $Repository = "iricigor/fingvibe",
    [int] $Epic,
    [string] $Directory,
    [int[]] $TaskOrder,
    [string] $OrderEvidence
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "Agent4Coordination.psm1") -Force -DisableNameChecking

function Invoke-Agent4GitHubRead([string] $Endpoint, [bool] $Paginated, [string] $Query) {
    $text = if ($Query) {
        gh api graphql -f query=$Query
    } elseif ($Paginated) {
        gh api --paginate --slurp $Endpoint
    } else { gh api $Endpoint }
    if ($LASTEXITCODE -ne 0) { throw [IO.IOException]::new("GitHub evidence collection failed: $Endpoint.") }
    $text -join "`n"
}

function Get-Agent4CiStage($Pull, $Cache, [bool] $ReadinessOnly = $false) {
    $head = $Pull.head.sha
    $checks = @($Cache["commits/$head/check-runs"] | ForEach-Object { $_.check_runs } |
        Where-Object head_sha -EQ $head | Group-Object { "$($_.app.id):$($_.name)" } |
        ForEach-Object { $_.Group | Sort-Object id -Descending | Select-Object -First 1 })
    $allRuns = @($Cache["actions/runs?head_sha=$head"] | ForEach-Object { $_.workflow_runs } |
        Where-Object head_sha -EQ $head)
    $runs = @($allRuns | Group-Object workflow_id |
        ForEach-Object { $_.Group | Sort-Object id -Descending | Select-Object -First 1 })
    $supersededSuites = @($allRuns | Where-Object {
        $_.id -notin $runs.id -and $_.check_suite_id -and $_.check_suite_id -notin $runs.check_suite_id
    } | ForEach-Object check_suite_id)
    $checks = @($checks | Where-Object { $_.check_suite.id -notin $supersededSuites })
    $statuses = @($Cache["statuses/$head"] |
        Group-Object context | ForEach-Object { $_.Group | Sort-Object id -Descending | Select-Object -First 1 })
    if (-not ($checks.Count + $runs.Count + $statuses.Count)) { return "unknown" }
    $pending = $false; $failed = $false; $unknown = $false; $successful = $false
    if (@($runs | Where-Object { -not $_.workflow_id }).Count) { $unknown = $true }
    foreach ($item in @($checks) + @($runs)) {
        if (-not $item.name -or ($item.ContainsKey("workflow_id") -and -not $item.workflow_id)) { $unknown = $true }
        if ($item.status -in @("queued", "in_progress", "waiting", "requested", "pending")) { $pending = $true; continue }
        if ($item.status -ne "completed") { $unknown = $true; continue }
        switch ($item.conclusion) {
            success { $successful = $true }
            { $_ -in @("neutral", "skipped") } {}
            { $_ -in @("failure", "timed_out", "cancelled", "action_required", "startup_failure", "stale") } { $failed = $true }
            default { $unknown = $true }
        }
    }
    foreach ($item in $statuses) {
        if (-not $item.context -or ($item.sha -and $item.sha -cne $head)) { $unknown = $true }
        switch ($item.state) {
            success { $successful = $true }
            pending { $pending = $true }
            { $_ -in @("failure", "error") } { $failed = $true }
            default { $unknown = $true }
        }
    }
    if ($failed -and -not $ReadinessOnly) { return "failed" }
    if ($unknown) { return "unknown" }
    if ($pending) { return "pending" }
    if ($failed) { return "failed" }
    if ($successful) { return "success" }
    "unknown"
}

function Get-Agent4TaskRecords($Discussions) {
    # Assignment markers in Task conversations Discussions are the loop4 ownership record.
    $records = @{}
    foreach ($discussion in @($Discussions | Where-Object { $_.category.name -cin @("Task conversations", "🛠️ Task conversations") })) {
        if ("$($discussion.body)" -notmatch '<!--\s*fingvibe:task=(\d+)\s*-->') { continue }
        $task = [int] $Matches[1]
        if ($records.ContainsKey($task)) { $records[$task].duplicate = $true; continue }
        $entries = @(foreach ($comment in @($discussion.comments)) {
            $comment
            foreach ($reply in @($comment.replies)) { $reply }
        })
        $entries = @($entries | Where-Object { $null -ne $_ } | Sort-Object -Stable { "$($_.createdAt)" })
        $assignments = [ordered]@{}; $rejection = $null
        foreach ($entry in $entries) {
            $body = "$($entry.body)"
            foreach ($match in [regex]::Matches($body,
                '<!--\s*fingvibe:assignment=([A-Za-z0-9._:-]+)\s+developer=(developer-[12])\s+action=([a-z-]+)\s*-->')) {
                $id = $match.Groups[1].Value
                if (-not $assignments.Contains($id)) {
                    $assignments[$id] = @{ issue = $task; assignmentId = $id; developer = $match.Groups[2].Value
                        action = $match.Groups[3].Value; state = "open"; discussionUrl = $discussion.url; sentAt = $entry.createdAt }
                }
            }
            foreach ($match in [regex]::Matches($body, '<!--\s*fingvibe:assignment-(end|release)=([A-Za-z0-9._:-]+)\s*-->')) {
                $id = $match.Groups[2].Value
                if ($assignments.Contains($id) -and $assignments[$id].state -eq "open") {
                    $assignments[$id].state = if ($match.Groups[1].Value -eq "end") { "ended" } else { "released" }
                }
            }
            # A rejected finalize pins its PR head to repair until a new head is pushed.
            foreach ($match in [regex]::Matches($body,
                '<!--\s*fingvibe:finalize-rejected=([A-Za-z0-9._:-]+)\s+head=([0-9a-fA-F]{40})\s*-->')) {
                $id = $match.Groups[1].Value
                if ($assignments.Contains($id) -and $assignments[$id].action -eq "finalize") {
                    $rejection = @{ assignmentId = $id; developer = $assignments[$id].developer
                        head = $match.Groups[2].Value.ToLowerInvariant(); discussionUrl = $discussion.url; rejectedAt = $entry.createdAt }
                }
            }
        }
        $records[$task] = @{ duplicate = $false; assignments = @($assignments.Values); finalizeRejection = $rejection }
    }
    $records
}

function Get-Agent4WorkPacket($Configuration, [string] $EvidencePath, [scriptblock] $Reader,
    [int[]] $Order, [string] $OrderingEvidence) {
    $config = $Configuration
    $repository = $config.repository
    if ($repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $config.epic -le 0) {
        throw "Repository and positive Epic number required."
    }
    $cache = @{}
    $rereadSeconds = if ($config.ContainsKey("mergeabilityRereadSeconds")) { $config.mergeabilityRereadSeconds } else { 3 }
    function Read-Evidence([string] $Endpoint, [bool] $Paginated = $false, [string] $Query, [string] $CacheKey) {
        $key = if ($CacheKey) { $CacheKey } else { "$Endpoint|$Paginated|$Query" }
        if ($cache.ContainsKey($key)) { return ,$cache[$key] }
        $json = & $Reader $Endpoint $Paginated $Query
        if ($json -isnot [string] -or [string]::IsNullOrWhiteSpace($json)) { throw [IO.InvalidDataException]::new("Missing evidence: $Endpoint.") }
        $parsed = $json | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String -NoEnumerate
        if ($Paginated) {
            if ($parsed -isnot [array] -or @($parsed | Where-Object { $_ -isnot [array] }).Count) {
                throw [IO.InvalidDataException]::new("Expected complete paginated pages: $Endpoint.")
            }
            $value = @($parsed | ForEach-Object { foreach ($item in $_) { $item } })
        } else {
            if ($parsed -isnot [hashtable] -or $parsed.errors) { throw [IO.InvalidDataException]::new("Invalid GitHub evidence: $Endpoint.") }
            $value = $parsed
        }
        $cache[$key] = $value
        return ,$value
    }
    function Read-Connection([string] $NodeId, [string] $Field) {
        $all = @(); $cursor = $null; $seen = @{}
        do {
            $after = if ($cursor) { ',after:"' + $cursor + '"' } else { "" }
            $selection = if ($Field -eq "closingIssuesReferences") { 'number repository { nameWithOwner }' } else {
                'id body url author { login } createdAt updatedAt'
            }
            $type = switch ($Field) { comments { "Discussion" }; replies { "DiscussionComment" }; closingIssuesReferences { "PullRequest" } }
            $query = 'query { node(id:"' + $NodeId + '") { ... on ' + $type + ' { ' +
                $Field + '(first:100' + $after + ') { nodes { ' + $selection +
                ' } pageInfo { hasNextPage endCursor } } } } }'
            $result = Read-Evidence graphql $false $query
            $connection = $result.data.node[$Field]
            if (-not $connection -or $null -eq $connection.pageInfo.hasNextPage -or
                $connection.nodes -isnot [array]) { throw "Incomplete Discussion $Field." }
            $all += $connection.nodes
            $cursor = $connection.pageInfo.endCursor
            if ($connection.pageInfo.hasNextPage) {
                if (-not $cursor -or $seen.ContainsKey($cursor)) { throw "Invalid Discussion pagination." }
                $seen[$cursor] = $true
            }
        } while ($connection.pageInfo.hasNextPage)
        return ,$all
    }

    $repo = Read-Evidence "repos/$repository"
    if ($repo.full_name -ine $repository -or -not $repo.default_branch) {
        throw "Repository identity/default branch unavailable."
    }
    $epic = Read-Evidence "repos/$repository/issues/$($config.epic)"
    if ($epic.number -ne $config.epic -or "type:epic" -notin $epic.labels.name -or $epic.state -ne "open") {
        throw "Configured Epic is not an open type:epic issue."
    }
    $issues = Read-Evidence "repos/$repository/issues?state=all&per_page=100" $true
    $comments = Read-Evidence "repos/$repository/issues/comments?per_page=100" $true
    $children = Read-Evidence "repos/$repository/issues/$($config.epic)/sub_issues?per_page=100" $true
    $pulls = Read-Evidence "repos/$repository/pulls?state=open&per_page=100" $true
    $collectionErrors = @()
    foreach ($pr in $pulls) {
        if (-not $pr.number -or -not $pr.head.sha -or -not $pr.node_id) { throw "Incomplete open PR." }
        # Association is required to isolate later PR-local errors without hiding ownership.
        $pr.linkedIssues = Read-Connection $pr.node_id closingIssuesReferences
        $pr.collectionErrors = @()
        try {
            $detailEndpoint = "repos/$repository/pulls/$($pr.number)"
            $detail = Read-Evidence $detailEndpoint
            $attempt = 1
            while ($true) {
                if ($detail.number -ne $pr.number -or $detail.head.sha -cne $pr.head.sha) {
                    throw [IO.InvalidDataException]::new("PR identity/head changed during evidence collection: #$($pr.number).")
                }
                if (-not $detail.ContainsKey("mergeable") -or
                    ($null -ne $detail.mergeable -and $detail.mergeable -isnot [bool])) {
                    throw [IO.InvalidDataException]::new("Incomplete PR mergeability evidence: #$($pr.number).")
                }
                if ($null -ne $detail.mergeable -or $attempt -ge 2) { break }
                # GitHub computes mergeability asynchronously; the first read often only starts it.
                Start-Sleep -Seconds $rereadSeconds
                $detail = Read-Evidence $detailEndpoint $false $null "$detailEndpoint|reread"
                $attempt++
            }
            $pr.mergeable = $detail.mergeable
            $pr.mergeable_state = $detail.mergeable_state
            $pr.base = $detail.base
            $null = Read-Evidence "repos/$repository/pulls/$($pr.number)/files?per_page=100" $true
            $null = Read-Evidence "repos/$repository/pulls/$($pr.number)/reviews?per_page=100" $true
            $cache["statuses/$($pr.head.sha)"] = Read-Evidence "repos/$repository/commits/$($pr.head.sha)/statuses?per_page=100" $true
            # Check-runs and Actions are objects with nested arrays; paginate them explicitly.
            foreach ($route in @("commits/$($pr.head.sha)/check-runs", "actions/runs?head_sha=$($pr.head.sha)")) {
                $separator = if ($route.Contains("?")) { "&" } else { "?" }
                $pages = & $Reader "repos/$repository/$route${separator}per_page=100" $true $null
                $parsed = $pages | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String -NoEnumerate
                if ($parsed -isnot [array] -or @($parsed | Where-Object { $_ -isnot [hashtable] }).Count) {
                    throw [IO.InvalidDataException]::new("Incomplete paginated CI evidence.")
                }
                $field = if ($route.StartsWith("actions/")) { "workflow_runs" } else { "check_runs" }
                if (@($parsed).Count -eq 0 -or @($parsed | Where-Object {
                    $_[$field] -isnot [array] -or $null -eq $_.total_count
                }).Count -or @($parsed | ForEach-Object { foreach ($item in $_[$field]) { $item } }).Count -ne $parsed[0].total_count) {
                    throw [IO.InvalidDataException]::new("Missing/truncated CI inventory.")
                }
                $cache[$route] = $parsed
                if ($route.StartsWith("actions/")) {
                    foreach ($run in @($parsed | ForEach-Object { $_.workflow_runs })) {
                        $jobs = & $Reader "repos/$repository/actions/runs/$($run.id)/jobs?per_page=100" $true $null
                        $jobPages = $jobs | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String -NoEnumerate
                        if ($jobPages -isnot [array] -or @($jobPages | Where-Object { $_ -isnot [hashtable] }).Count) {
                            throw [IO.InvalidDataException]::new("Incomplete regression job evidence.")
                        }
                        if (@($jobPages).Count -eq 0 -or @($jobPages | Where-Object {
                            $_.jobs -isnot [array] -or $null -eq $_.total_count
                        }).Count -or @($jobPages | ForEach-Object { foreach ($job in $_.jobs) { $job } }).Count -ne $jobPages[0].total_count) {
                            throw [IO.InvalidDataException]::new("Missing/truncated regression job inventory.")
                        }
                        $cache["jobs/$($run.id)"] = $jobPages
                    }
                }
            }
        } catch [IO.IOException], [IO.InvalidDataException], [ArgumentException] {
            $diagnostic = @{ pr = $pr.number; head = $pr.head.sha; reason = $_.Exception.Message
                issues = @($pr.linkedIssues | Where-Object { $_.repository.nameWithOwner -ieq $repository }).number }
            $pr.collectionErrors += $diagnostic
            $collectionErrors += $diagnostic
        }
        $pr.ci = @{
            stage = Get-Agent4CiStage $pr $cache
            readiness = $(if ($pr.collectionErrors.Count) { "unknown" } else { Get-Agent4CiStage $pr $cache $true })
        }
    }
    $parts = $repository.Split("/")
    $discussions = @(); $cursor = $null; $seen = @{}
    do {
        $after = if ($cursor) { ',after:"' + $cursor + '"' } else { "" }
        $query = 'query { repository(owner:"' + $parts[0] + '",name:"' + $parts[1] +
            '") { discussions(first:100' + $after + ') { nodes { id number title body url author { login } ' +
            'category { name } createdAt updatedAt } pageInfo { hasNextPage endCursor } } } }'
        $result = Read-Evidence graphql $false $query
        $connection = $result.data.repository.discussions
        if (-not $connection -or $null -eq $connection.pageInfo.hasNextPage -or
            $connection.nodes -isnot [array]) { throw "Discussion collection is unavailable." }
        $discussions += $connection.nodes
        $cursor = $connection.pageInfo.endCursor
        if ($connection.pageInfo.hasNextPage) {
            if (-not $cursor -or $seen.ContainsKey($cursor)) { throw "Invalid Discussion inventory pagination." }
            $seen[$cursor] = $true
        }
    } while ($connection.pageInfo.hasNextPage)
    # Only open children's task records affect offers; expand just those conversations, in batches.
    $openNumbers = @($children | Where-Object state -EQ open | ForEach-Object { [int] $_.number })
    $relevant = @($discussions | Where-Object {
        $_.category.name -cin @("Task conversations", "🛠️ Task conversations") -and
        "$($_.body)" -match '<!--\s*fingvibe:task=(\d+)\s*-->' -and [int] $Matches[1] -in $openNumbers
    })
    $entryFields = 'id body url author { login } createdAt updatedAt'
    for ($offset = 0; $offset -lt $relevant.Count; $offset += 20) {
        $batch = @($relevant[$offset..([Math]::Min($offset + 20, $relevant.Count) - 1)])
        $ids = ($batch | ForEach-Object { '"' + $_.id + '"' }) -join ","
        $query = 'query { nodes(ids:[' + $ids + ']) { ... on Discussion { id comments(first:100) { nodes { ' + $entryFields +
            ' replies(first:50) { nodes { ' + $entryFields + ' } pageInfo { hasNextPage endCursor } } }' +
            ' pageInfo { hasNextPage endCursor } } } } }'
        $result = Read-Evidence graphql $false $query
        if ($result.data.nodes -isnot [array] -or $result.data.nodes.Count -ne $batch.Count) {
            throw "Incomplete Discussion conversation batch."
        }
        for ($index = 0; $index -lt $batch.Count; $index++) {
            $discussion = $batch[$index]; $node = $result.data.nodes[$index]
            $comments = if ($node) { $node.comments }
            if (-not $node -or $node.id -cne $discussion.id -or -not $comments -or
                $null -eq $comments.pageInfo.hasNextPage -or $comments.nodes -isnot [array]) {
                throw "Incomplete Discussion comments."
            }
            if ($comments.pageInfo.hasNextPage) {
                $discussion.comments = Read-Connection $discussion.id comments
                foreach ($comment in $discussion.comments) { $comment.replies = Read-Connection $comment.id replies }
                continue
            }
            foreach ($comment in $comments.nodes) {
                $replies = $comment.replies
                if (-not $replies -or $null -eq $replies.pageInfo.hasNextPage -or $replies.nodes -isnot [array]) {
                    throw "Incomplete Discussion replies."
                }
                $comment.replies = if ($replies.pageInfo.hasNextPage) { Read-Connection $comment.id replies } else { $replies.nodes }
            }
            $discussion.comments = $comments.nodes
        }
    }

    $byNumber = @{}
    foreach ($issue in $issues) {
        if (-not $issue.number -or $byNumber.ContainsKey([int] $issue.number)) { throw "Incomplete/duplicate issue inventory." }
        $byNumber[[int] $issue.number] = $issue
    }
    $open = @($children | Where-Object state -EQ open)
    if (@($children.number | Sort-Object -Unique).Count -ne @($children).Count) {
        throw "Duplicate native child inventory."
    }
    if ($Order) {
        if (-not $OrderingEvidence -or @($Order | Sort-Object -Unique).Count -ne $Order.Count -or
            @($Order | Where-Object { $_ -notin $children.number }).Count) { throw "Invalid explicit human ordering." }
        if (@($open | Where-Object { $_.number -notin $Order }).Count) { throw "Explicit order must cover the open native queue." }
        $open = @($open | Sort-Object { [array]::IndexOf($Order, [int] $_.number) })
    } else { $open = @($open | Sort-Object number) }
    $taskRecords = Get-Agent4TaskRecords $discussions
    $candidates = @(); $blocked = @(); $openAssignments = @(); $orderingBlocked = $false
    foreach ($child in $open) {
        $record = $taskRecords[[int] $child.number]
        $assigned = @(); $released = $null; $rejection = $null
        if ($record) {
            $assigned = @($record.assignments | Where-Object { $_.state -eq "open" })
            $latest = @($record.assignments)[-1]
            if ($latest -and $latest.state -eq "released") { $released = $latest }
        }
        $openAssignments += $assigned
        if (-not $byNumber.ContainsKey([int] $child.number)) { throw "Native child inventory mismatch." }
        $parent = Read-Evidence "repos/$repository/issues/$($child.number)/parent"
        if ($parent.number -ne $config.epic -or "type:epic" -notin $parent.labels.name) { throw "Native parent changed." }
        $dependencies = Read-Evidence "repos/$repository/issues/$($child.number)/dependencies/blocked_by?per_page=100" $true
        if (@($dependencies.number | Sort-Object -Unique).Count -ne @($dependencies).Count) {
            throw "Duplicate native dependencies."
        }
        foreach ($dependency in $dependencies) {
            if (-not $byNumber.ContainsKey([int] $dependency.number)) { throw "Unknown dependency in repository inventory." }
            if ($dependency.state -eq "closed") {
                $deliveryCursor = $null; $deliverySeen = @{}
                do {
                    $after = if ($deliveryCursor) { ',after:"' + $deliveryCursor + '"' } else { "" }
                    $query = 'query { repository(owner:"' + $parts[0] + '",name:"' + $parts[1] +
                        '") { issue(number:' + $dependency.number + ') { state stateReason ' +
                        'closedByPullRequestsReferences(first:100' + $after +
                        ') { nodes { number url merged baseRefName mergedAt } pageInfo { hasNextPage endCursor } } } } }'
                    $delivery = Read-Evidence graphql $false $query
                    $connection = $delivery.data.repository.issue.closedByPullRequestsReferences
                    if (-not $connection -or $null -eq $connection.pageInfo.hasNextPage) {
                        throw "Unavailable dependency delivery evidence."
                    }
                    $deliveryCursor = $connection.pageInfo.endCursor
                    if ($connection.pageInfo.hasNextPage) {
                        if (-not $deliveryCursor -or $deliverySeen.ContainsKey($deliveryCursor)) { throw "Invalid delivery pagination." }
                        $deliverySeen[$deliveryCursor] = $true
                    }
                } while ($connection.pageInfo.hasNextPage)
            }
        }
        $reason = $null
        if ($child.pull_request -or "type:task" -notin $child.labels.name -or "type:epic" -in $child.labels.name) {
            $reason = "Not a native task child."
        } elseif ("human-task" -in $child.labels.name) { $reason = "Human intervention required." }
        elseif (@($dependencies | Where-Object state -NE closed).Count) { $reason = "Open native dependency." }
        elseif ("status:blocked" -in $child.labels.name) {
            $reason = "Explicit task blocker."
        } elseif ($orderingBlocked) { $reason = "Explicit human predecessor order is blocked." }
        elseif ($record -and $record.duplicate) { $reason = "Multiple task Discussions; reconcile before offering." }
        elseif ($assigned.Count) {
            $reason = "Open assignment " + (($assigned | ForEach-Object { "$($_.assignmentId) ($($_.developer))" }) -join ", ") +
                "; awaiting end-of-work or release."
        }
        $linked = @($pulls | Where-Object {
            $child.number -in @($_.linkedIssues | Where-Object { $_.repository.nameWithOwner -ieq $repository }).number
        })
        $category = "new"; $rank = 4; $pull = $null; $diagnosis = $null
        if (-not $reason) {
            if ($linked.Count -gt 1) {
                $category = "diagnose"; $rank = 3
                $diagnosis = "Establish the authoritative continuation PR; do not edit, rerun CI or finalize an arbitrary PR."
            }
            elseif ($linked.Count -eq 1) {
                $pull = $linked[0]
                if ($pull.collectionErrors.Count) {
                    $category = if ($pull.ci.stage -eq "failed") { "failed" } else { "diagnose" }
                    $rank = if ($category -eq "failed") { 1 } else { 3 }
                    $diagnosis = "Refresh incomplete/stale PR evidence before deciding an authorized action."
                } elseif ($released -and $released.action -eq "implement") {
                    # Released implementation continues its existing PR; that PR's CI does not prove completion.
                    $category = "resume"; $rank = 2
                } elseif ($record -and $record.finalizeRejection -and $record.finalizeRejection.head -ieq $pull.head.sha) {
                    # Green CI on a rejected head would re-offer finalize forever; repair it instead.
                    $category = "failed"; $rank = 1; $rejection = $record.finalizeRejection
                } elseif ($pull.mergeable -ceq $false) {
                    # Conflicts prevent pull_request workflows from starting, leaving CI unknown.
                    $category = "failed"; $rank = 1
                } else {
                    # Mergeability still unknown after one re-read is presumed conflict-free:
                    # finalize re-verifies base freshness and GitHub refuses conflicting merges.
                    $ci = Get-Agent4CiStage $pull $cache
                    if ($ci -eq "pending") { $reason = "Current-head CI is pending." }
                    elseif ($ci -eq "unknown") {
                        $category = "diagnose"; $rank = 3
                        $diagnosis = "Investigate missing/unrecognized CI evidence; unknown is neither failure nor finalization readiness."
                    }
                    else { $category = $ci; $rank = if ($ci -eq "success") { 0 } else { 1 } }
                }
            } elseif (@($child.labels.name | Where-Object { $_ -in @("active", "status:review") }).Count) {
                $reason = "Existing work without an open linked PR; do not offer as new."
            }
        }
        if ($reason) {
            $blocked += @{ issue = $child.number; reason = $reason; url = $child.html_url }
            if ($Order) { $orderingBlocked = $true }
        } else {
            $candidates += @{ issue = $child.number; url = $child.html_url; labels = $child.labels.name
                dependencies = $dependencies; category = $category; rank = $rank
                pr = $pull; linkedPrs = $linked; diagnosis = $diagnosis
                released = $released; finalizeRejection = $rejection; semanticAssessmentRequired = $true }
        }
    }
    $candidates = @($candidates | Sort-Object -Stable rank)
    $developerOffers = @(
        @{ developer = "developer-1"; candidates = @() }
        @{ developer = "developer-2"; candidates = @() }
    )
    for ($index = 0; $index -lt [Math]::Min(4, $candidates.Count); $index++) {
        $developerOffers[$index % 2].candidates += $candidates[$index]
    }
    if ($candidates.Count -eq 1) { $developerOffers[1].candidates = @($candidates[0]) }
    elseif (@($candidates | Where-Object category -EQ success).Count -eq 1) {
        $developerOffers[1].candidates = @($candidates[0]) +
            @($developerOffers[1].candidates | Select-Object -First 1)
    }
    Write-Agent4Json $EvidencePath @{
        schema = "fingvibe-loop4-evidence-v1"; utc = [DateTimeOffset]::UtcNow.ToString("o")
        repository = $repository; epic = $config.epic
        reads = $cache; discussions = $discussions; issues = $issues; comments = $comments; pulls = $pulls
        collectionErrors = $collectionErrors
        order = $Order; orderEvidence = $OrderingEvidence
    }
    @{
        schema = "fingvibe-loop4-packet-v1"; repository = $repository; epic = $config.epic
        targetBranch = $repo.default_branch; evidencePath = $EvidencePath
        candidates = $candidates; blocked = $blocked; openAssignments = $openAssignments
        collectionErrors = $collectionErrors
        developerOffers = $developerOffers
        hasDeveloperOfferWork = ($candidates.Count -gt 0 -or $openAssignments.Count -gt 0)
        assessment = "When hasDeveloperOfferWork is false, make no new Developer calls unless retained context has unresolved offers or starts to continue. Review dependencies, foreign ownership, diffs and candidate compatibility before recommending work."
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    if (-not $Directory) { $Directory = Join-Path ([IO.Path]::GetTempPath()) "FingVibe-loop4-evidence" }
    $path = Join-Path $Directory ("evidence\" + [guid]::NewGuid() + ".json")
    $packet = Get-Agent4WorkPacket @{ repository = $Repository; epic = $Epic } $path ${function:Invoke-Agent4GitHubRead} $TaskOrder $OrderEvidence
    $packet | ConvertTo-Json -Depth 100
}
