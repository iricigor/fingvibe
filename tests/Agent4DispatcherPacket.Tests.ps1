$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\.github\scripts\Get-Agent4DispatcherPacket.ps1") -Directory ([IO.Path]::GetTempPath())
$root = Join-Path ([IO.Path]::GetTempPath()) ("fingvibe-loop4-packet-test-" + [guid]::NewGuid())
function Assert-True($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Assert-Fails([scriptblock] $Action, [string] $Pattern) {
    try { & $Action | Out-Null }
    catch { if ($_.Exception.Message -notlike $Pattern) { throw }; return }
    throw "Expected failure matching $Pattern."
}
$configuration = @{ repository = "TestOwner/TestRepo"; epic = 92 }
$fixtureLinks = @{}
$fixtureCiStatus = "completed"
$fixtureConclusion = "success"
$fixtureSecondConclusion = "failure"
$fixtureStatuses = @()
$fixtureMergeable = $true
$fixtureNoCi = $false
$fixturePulls = @(@{ number = 200; node_id = "PR200"; head = @{ sha = "a"*40 } },
    @{ number = 201; node_id = "PR201"; head = @{ sha = "b"*40 } })
$children = @(101..106 | ForEach-Object { @{
    number = $_; state = "open"; html_url = "fixture://issues/$_"; body = "Task scope."
    labels = @(@{ name = "type:task" })
} })
$children[1].labels += @{ name = "human-task" }
$fixtureDependencies = @(@{ number = 107; state = "open" })
$closedDependency = @{ number = 108; state = "closed"; state_reason = "not_planned" }
$observedReads = [Collections.Generic.List[string]]::new()
$fixtureTaskDiscussions = @()
$fixtureTaskComments = @{}
function New-TaskComment([string] $Id, [string] $At, [string] $Body) {
    @{ id = $Id; body = $Body; createdAt = $At; author = @{ login = "agent" } }
}
$fixtureReader = {
    param($Endpoint, $Paginated, $Query)
    $observedReads.Add("$Endpoint|$Query")
    $value = switch -Regex ($Endpoint) {
        '^repos/TestOwner/TestRepo$' { @{ full_name = "TestOwner/TestRepo"; default_branch = "main" }; break }
        '/issues/92$' { @{ number = 92; state = "open"; labels = @(@{ name = "type:epic" }) }; break }
        '/issues\?state=all' { @($children) + @(@{ number = 107; state = "open" }, $closedDependency); break }
        '/issues/comments' { @(); break }
        '/sub_issues' { $children; break }
        '/pulls\?' { $fixturePulls; break }
        '/pulls/(\d+)$' {
            $pull = $fixturePulls | Where-Object number -EQ ([int] $Matches[1])
            @{ number = $pull.number; head = $pull.head; mergeable = $fixtureMergeable
                mergeable_state = $(if ($fixtureMergeable -eq $false) { "dirty" } else { "clean" })
                base = @{ sha = "d"*40; ref = "main" } }; break
        }
        '/pulls/\d+/files' { @(@{ filename = "shared.cs"; patch = "fixture diff" }); break }
        '/pulls/\d+/reviews' { @(@{ id = 201; state = "CHANGES_REQUESTED" }); break }
        '/statuses\?' { $fixtureStatuses; break }
        '/parent$' { @{ number = 92; labels = @(@{ name = "type:epic" }) }; break }
        '/issues/105/dependencies/' { $fixtureDependencies; break }
        '/issues/106/dependencies/' { @($closedDependency); break }
        '/dependencies/' { @(); break }
        '/check-runs' {
            if ($fixtureNoCi) { @{ total_count = 0; check_runs = @() }; break }
            $head = if ($Endpoint.Contains("a"*40)) { "a"*40 } else { "b"*40 }
            @{ total_count = 1; check_runs = @(@{ id = 1; name = "CI"; head_sha = $head
                status = $fixtureCiStatus; conclusion = $(if ($head.StartsWith("a")) { $fixtureConclusion } else { $fixtureSecondConclusion }) }) }; break
        }
        '/actions/runs\?' {
            if ($fixtureNoCi) { @{ total_count = 0; workflow_runs = @() }; break }
            if ($Endpoint.Contains("a"*40)) {
                @{ total_count = 1; workflow_runs = @(@{ id = 300; workflow_id = 8; name = "Validation"
                    head_sha = "a"*40; status = $fixtureCiStatus; conclusion = $fixtureConclusion }) }
            } else { @{ total_count = 0; workflow_runs = @() } }
            break
        }
        '/actions/runs/300/jobs' {
            @{ total_count = 1; jobs = @(@{ name = "devices-baseline"; started_at = "2026-11-15T10:00:00Z"; completed_at = "2026-11-15T10:04:01Z" }) }
            break
        }
        '^graphql$' {
            if ($Query.Contains('closingIssuesReferences')) {
                $node = if ($Query.Contains('PR200')) { "PR200" } else { "PR201" }
                @{ data = @{ node = @{ closingIssuesReferences = @{
                    nodes = @($fixtureLinks[$node] | Where-Object { $null -ne $_ } | ForEach-Object {
                        @{ number = $_; repository = @{ nameWithOwner = "TestOwner/TestRepo" } }
                    })
                    pageInfo = @{ hasNextPage = $false; endCursor = $null }
                } } } }
            } elseif ($Query.Contains('discussions(first:')) {
                @{ data = @{ repository = @{ discussions = @{
                    nodes = @(@{ id = "D1"; number = 1; body = "Original human steering"; author = @{ login = "TestOwner" } }) +
                        @($fixtureTaskDiscussions)
                    pageInfo = @{ hasNextPage = $false; endCursor = $null }
                } } } }
            } elseif ($Query -match 'node\(id:"(T\d+)"\) \{ \.\.\. on Discussion ') {
                @{ data = @{ node = @{ comments = @{
                    nodes = @($fixtureTaskComments[$Matches[1]])
                    pageInfo = @{ hasNextPage = $false; endCursor = $null }
                } } } }
            } elseif ($Query -match 'node\(id:"TC\d+"\)') {
                @{ data = @{ node = @{ replies = @{ nodes = @(); pageInfo = @{ hasNextPage = $false; endCursor = $null } } } } }
            } elseif ($Query.Contains('comments(first:')) {
                $second = $Query.Contains('after:"comments-next"')
                @{ data = @{ node = @{ comments = @{
                    nodes = @(@{ id = $(if ($second) { "C2" } else { "C1" }); body = "Original comment"; author = @{ login = "TestOwner" } })
                    pageInfo = @{ hasNextPage = -not $second; endCursor = $(if ($second) { $null } else { "comments-next" }) }
                } } } }
            } elseif ($Query.Contains('replies(first:')) {
                $second = $Query.Contains('after:"replies-next"')
                @{ data = @{ node = @{ replies = @{
                    nodes = @(@{ id = $(if ($second) { "R2" } else { "R1" }); body = "Reply"; author = @{ login = "TestOwner" } })
                    pageInfo = @{ hasNextPage = -not $second; endCursor = $(if ($second) { $null } else { "replies-next" }) }
                } } } }
            } elseif ($Query.Contains('closedByPullRequestsReferences')) {
                @{ data = @{ repository = @{ issue = @{ state = "CLOSED"; stateReason = "NOT_PLANNED"
                    closedByPullRequestsReferences = @{ nodes = @(); pageInfo = @{ hasNextPage = $false; endCursor = $null } }
                } } } }
            } else { throw "Unexpected GraphQL query: $Query" }
            break
        }
        default { throw "Unexpected endpoint: $Endpoint" }
    }
    if ($Paginated) {
        # Distinct pages exercise complete flattening, including object-shaped CI pages.
        $pages = [Collections.Generic.List[object]]::new()
        if ($Endpoint -match '/issues\?state=all') {
            $pages.Add(@($children[0..2]))
            $pages.Add(@($children[3..5]) + @(@{ number = 107; state = "open" }, $closedDependency))
        } elseif ($Endpoint -match '/check-runs|/actions/') { $pages.Add($value) }
        else { $pages.Add(@($value)) }
        ConvertTo-Json -InputObject $pages.ToArray() -Depth 100 -Compress
    } else { ConvertTo-Json -InputObject $value -Depth 100 -Compress }
}
try {
    $path = Join-Path $root "packet.json"
    $packet = Get-Agent4WorkPacket $configuration $path $fixtureReader
    Assert-True (($packet.candidates.issue -join ",") -eq "101,103,104,106") "Blocked candidates must not hide later work."
    Assert-True ($packet.candidates.Count -eq 4 -and $packet.blocked.Count -eq 2) "Return four tasks and exact exclusions."
    $evidence = Read-Agent4Json $path
    Assert-True ($evidence.issues.Count -eq 8) "Issue pagination must preserve both pages."
    Assert-True (@($observedReads | Where-Object { $_ -like "*closedByPullRequestsReferences*" }).Count -eq 1) "Closed dependency disposition must remain available for semantic delivery assessment."
    Assert-True ($evidence.discussions[0].comments.Count -eq 2) "All Discussion comment pages required."
    Assert-True ($evidence.discussions[0].comments[0].replies.Count -eq 2) "All reply pages required."
    Assert-True (@($observedReads | Where-Object { $_ -like "*pulls/200/files*" }).Count -eq 1) "PR diffs required."
    Assert-True ($evidence.reads.'jobs/300'[0].jobs[0].completed_at -eq "2026-11-15T10:04:01Z") "Retain complete job timing."
    Assert-True (-not $packet.ContainsKey("retainedClaims") -and -not $packet.ContainsKey("revision")) "No coordination state required."
    Assert-True (($packet.developerOffers.developer -join ",") -eq "developer-1,developer-2") "Offer packages identify both recipients."
    Assert-True (($packet.developerOffers[0].candidates.issue -join ",") -eq "101,104" -and
        ($packet.developerOffers[1].candidates.issue -join ",") -eq "103,106") "Four candidates are split at positions 1/3 and 2/4."
    $children[5].labels += @{ name = "active" }
    $three = Get-Agent4WorkPacket $configuration (Join-Path $root "three.json") $fixtureReader
    Assert-True (($three.developerOffers[0].candidates.issue -join ",") -eq "101,104" -and
        ($three.developerOffers[1].candidates.issue -join ",") -eq "103") "Three candidates keep the odd candidate with Developer 1."
    $children[5].labels = @(@{ name = "type:task" })
    $children[1].labels = @(@{ name = "type:task" })
    $five = Get-Agent4WorkPacket $configuration (Join-Path $root "five.json") $fixtureReader
    Assert-True (($five.candidates.issue -join ",") -eq "101,102,103,104,106" -and
        ($five.developerOffers[0].candidates.issue -join ",") -eq "101,103" -and
        ($five.developerOffers[1].candidates.issue -join ",") -eq "102,104") "Offer packages cap at the first four without dropping later packet candidates."
    $children[1].labels += @{ name = "human-task" }
    $fixtureLinks = @{ PR200 = 104; PR201 = 103 }
    $sorted = Get-Agent4WorkPacket $configuration (Join-Path $root "sorted.json") $fixtureReader
    Assert-True (($sorted.candidates.issue -join ",") -eq "104,103,101,106") "Successful CI precedes failed CI, then new work."
    Assert-True (($sorted.candidates.category -join ",") -eq "success,failed,new,new") "Return actionable categories."
    Assert-True (($sorted.developerOffers[0].candidates.issue -join ",") -eq "104,101" -and
        ($sorted.developerOffers[1].candidates.issue -join ",") -eq "104,103" -and
        $sorted.developerOffers[1].candidates[0].pr.number -eq 200 -and
        $sorted.developerOffers[1].candidates[0].pr.head.sha -eq ("a"*40)) "Share the sole finalization first, retain PR/head evidence and cap each offer at two."
    Assert-True (106 -in $sorted.candidates.issue -and 106 -notin $sorted.developerOffers.candidates.issue) "Displaced work remains in the full queue."
    $children[1].labels = @(@{ name = "type:task" })
    $mixedFive = Get-Agent4WorkPacket $configuration (Join-Path $root "mixed-five.json") $fixtureReader
    Assert-True (($mixedFive.candidates.issue -join ",") -eq "104,103,101,102,106" -and
        ($mixedFive.developerOffers[0].candidates.issue -join ",") -eq "104,101" -and
        ($mixedFive.developerOffers[1].candidates.issue -join ",") -eq "104,103") "Sharing preserves the full sorted queue and does not pull later candidates into offers."
    $children[1].labels += @{ name = "human-task" }
    $fixtureSecondConclusion = "success"
    $twoSuccesses = Get-Agent4WorkPacket $configuration (Join-Path $root "two-successes.json") $fixtureReader
    Assert-True (($twoSuccesses.developerOffers[0].candidates.issue -join ",") -eq "103,101" -and
        ($twoSuccesses.developerOffers[1].candidates.issue -join ",") -eq "104,106") "Multiple successful candidates retain disjoint alternating offers."
    $fixtureSecondConclusion = "failure"
    $fixtureLinks = @{ PR200 = 104 }
    $successAndNew = Get-Agent4WorkPacket $configuration (Join-Path $root "success-new.json") $fixtureReader
    Assert-True (($successAndNew.developerOffers[0].candidates.issue -join ",") -eq "104,103" -and
        ($successAndNew.developerOffers[1].candidates.issue -join ",") -eq "104,101") "A sole success is shared even when all other candidates are new."
    foreach ($index in 0,5) { $children[$index].labels += @{ name = "active" } }
    $successAndOne = Get-Agent4WorkPacket $configuration (Join-Path $root "success-one.json") $fixtureReader
    Assert-True (($successAndOne.developerOffers[0].candidates.issue -join ",") -eq "104" -and
        ($successAndOne.developerOffers[1].candidates.issue -join ",") -eq "104,103") "Two-candidate queues share success without duplicating it within either offer."
    $children[2].labels += @{ name = "active" }
    $successOnly = Get-Agent4WorkPacket $configuration (Join-Path $root "success-only.json") $fixtureReader
    $serializedSuccess = ($successOnly | ConvertTo-Json -Depth 100 | ConvertFrom-Json).developerOffers
    Assert-True ($serializedSuccess[0].candidates.Count -eq 1 -and $serializedSuccess[1].candidates.Count -eq 1 -and
        $serializedSuccess[0].candidates[0].issue -eq 104 -and $serializedSuccess[1].candidates[0].issue -eq 104) "A whole-queue success singleton remains shared as candidate arrays."
    foreach ($index in 0,2,5) { $children[$index].labels = @(@{ name = "type:task" }) }
    $fixtureLinks = @{ PR200 = 104; PR201 = 103 }
    $fixtureCiStatus = "in_progress"
    $pending = Get-Agent4WorkPacket $configuration (Join-Path $root "pending.json") $fixtureReader
    Assert-True (($pending.candidates.issue -join ",") -eq "101,106") "Running CI is not actionable."
    Assert-True (($pending.developerOffers[0].candidates.issue -join ",") -eq "101" -and
        ($pending.developerOffers[1].candidates.issue -join ",") -eq "106") "Two candidates are offered separately, not shared."
    $fixtureCiStatus = "completed"; $fixtureConclusion = $null
    $missing = Get-Agent4WorkPacket $configuration (Join-Path $root "unknown.json") $fixtureReader
    Assert-True (104 -notin $missing.candidates.issue -and $missing.blocked.reason -contains "Current-head CI is unknown.") "Missing conclusions must be explicit."
    $fixtureConclusion = "success"; $fixtureStatuses = @(@{ id = 9; context = "External"; state = "pending" })
    $external = Get-Agent4WorkPacket $configuration (Join-Path $root "external.json") $fixtureReader
    Assert-True (104 -notin $external.candidates.issue -and 103 -notin $external.candidates.issue) "Collector must include external pending statuses even without response sha."
    $fixtureStatuses = @()
    $fixtureNoCi = $true
    $noChecks = Get-Agent4WorkPacket $configuration (Join-Path $root "no-checks.json") $fixtureReader
    Assert-True (104 -notin $noChecks.candidates.issue) "Absent checks alone must not authorize repair."
    $fixtureMergeable = $false
    $conflicts = Get-Agent4WorkPacket $configuration (Join-Path $root "conflicts.json") $fixtureReader
    $conflicting = $conflicts.candidates | Where-Object issue -EQ 104
    Assert-True ($conflicting.category -eq "failed" -and $conflicting.rank -eq 1 -and
        $conflicting.pr.mergeable -ceq $false -and $conflicting.pr.mergeable_state -eq "dirty" -and
        $conflicting.pr.head.sha -eq ("a"*40) -and $conflicting.pr.base.sha -eq ("d"*40)) "Confirmed conflicts without CI must carry current PR/head/base evidence into repair offers."
    $conflictEvidence = Read-Agent4Json (Join-Path $root "conflicts.json")
    Assert-True ($conflictEvidence.reads.'repos/TestOwner/TestRepo/pulls/200|False|'.mergeable -ceq $false) "Retain the individual PR response as conflict evidence."
    $fixtureNoCi = $false
    $fixtureCiStatus = "in_progress"
    $conflictPending = Get-Agent4WorkPacket $configuration (Join-Path $root "conflict-pending.json") $fixtureReader
    Assert-True (($conflictPending.candidates | Where-Object issue -EQ 104).category -eq "failed") "Confirmed conflicts take priority over pending CI."
    $fixtureCiStatus = "completed"
    $conflictGreen = Get-Agent4WorkPacket $configuration (Join-Path $root "conflict-green.json") $fixtureReader
    Assert-True (($conflictGreen.candidates | Where-Object issue -EQ 104).category -eq "failed") "Green head checks cannot finalize a conflicting PR."
    $children[3].labels += @{ name = "status:blocked" }
    $conflictBlocked = Get-Agent4WorkPacket $configuration (Join-Path $root "conflict-blocked.json") $fixtureReader
    Assert-True (104 -notin $conflictBlocked.candidates.issue -and
        ($conflictBlocked.blocked | Where-Object issue -EQ 104).reason -eq "Explicit task blocker.") "Conflicts do not override existing task exclusions."
    $children[3].labels = @(@{ name = "type:task" })
    $fixtureMergeable = $null
    $mergeabilityUnknown = Get-Agent4WorkPacket $configuration (Join-Path $root "mergeability-unknown.json") $fixtureReader
    Assert-True (104 -notin $mergeabilityUnknown.candidates.issue -and
        ($mergeabilityUnknown.blocked | Where-Object issue -EQ 104).reason -eq "Current PR mergeability is unknown.") "Unknown mergeability is explicitly blocked, not inferred as a conflict or safe finalization."
    $fixtureMergeable = $true
    $conflictFree = Get-Agent4WorkPacket $configuration (Join-Path $root "conflict-free.json") $fixtureReader
    Assert-True (($conflictFree.candidates.issue -join ",") -eq ($sorted.candidates.issue -join ",") -and
        ($conflictFree.candidates.category -join ",") -eq ($sorted.candidates.category -join ",")) "Conflict-free PRs retain normal CI ordering and categories."
    $fixtureLinks = @{}; $fixtureConclusion = "success"
    $head = "a"*40
    $ciCache = @{
        repository = "TestOwner/TestRepo"
        "commits/$head/check-runs" = @(@{ check_runs = @(
            @{ id = 1; name = "CI"; head_sha = $head; status = "completed"; conclusion = "failure" },
            @{ id = 2; name = "CI"; head_sha = $head; status = "completed"; conclusion = "success" },
            @{ id = 3; name = "Other"; head_sha = "c"*40; status = "in_progress" }
        ) })
        "actions/runs?head_sha=$head" = @(@{ workflow_runs = @() })
    }
    Assert-True ((Get-Agent4CiStage $fixturePulls[0] $ciCache) -eq "success") "Latest rerun wins; old-head CI must not block current head."
    $ciCache["actions/runs?head_sha=$head"] = @(@{ workflow_runs = @(
        @{ id = 4; workflow_id = 7; name = "Validation"; head_sha = $head; status = "completed"; conclusion = "failure" },
        @{ id = 5; workflow_id = 7; name = "Validation"; head_sha = $head; status = "in_progress" }
    ) })
    Assert-True ((Get-Agent4CiStage $fixturePulls[0] $ciCache) -eq "pending") "Running latest workflow keeps task out of completed queue."
    $ciCache["actions/runs?head_sha=$head"][0].workflow_runs[1].status = "completed"
    $ciCache["actions/runs?head_sha=$head"][0].workflow_runs[1].conclusion = "success"
    Assert-True ((Get-Agent4CiStage $fixturePulls[0] $ciCache) -eq "success") "Successful workflow rerun supersedes failed run."
    $ciCache["statuses/$head"] = @(
        @{ id = 6; context = "External CI"; sha = $head; state = "pending" }
    )
    Assert-True ((Get-Agent4CiStage $fixturePulls[0] $ciCache) -eq "pending") "Legacy commit statuses participate in completed CI."
    $ciCache["statuses/$head"][0].state = "error"
    Assert-True ((Get-Agent4CiStage $fixturePulls[0] $ciCache) -eq "failed") "External CI errors are repair candidates."
    $ciCache = @{
        "commits/$head/check-runs" = @(@{ check_runs = @(
            @{ id = 1; name = "CI"; head_sha = $head; status = "completed"; conclusion = "skipped" }
        ) })
    }
    Assert-True ((Get-Agent4CiStage $fixturePulls[0] $ciCache) -eq "unknown") "Skipped-only checks are not successful CI."
    Assert-True ((Get-Agent4CiStage $fixturePulls[0] @{}) -eq "unknown") "Absent CI is not successful CI."
    $children[0].labels += @{ name = "active" }
    $active = Get-Agent4WorkPacket $configuration (Join-Path $root "active.json") $fixtureReader
    Assert-True (101 -notin $active.candidates.issue) "Active work without PR must not become new work."
    $children[0].labels = @(@{ name = "type:task" })
    $fixtureTaskDiscussions = @(@{ id = "T1"; number = 50; url = "fixture://discussions/50"
        body = "<!-- fingvibe:task=101 -->"; category = @{ name = "🛠️ Task conversations" }; author = @{ login = "agent" } })
    $send = "Sending #101 to Developer 1 <!-- fingvibe:assignment=A1 developer=developer-1 action=implement -->"
    $fixtureTaskComments = @{ T1 = @(New-TaskComment "TC1" "2026-11-15T10:00:00Z" $send) }
    $assigned = Get-Agent4WorkPacket $configuration (Join-Path $root "assigned.json") $fixtureReader
    Assert-True (101 -notin $assigned.candidates.issue -and ($assigned.blocked | Where-Object issue -EQ 101).reason -like "*A1 (developer-1)*") "Open assignment excludes the task even without the active label."
    Assert-True ($assigned.openAssignments.Count -eq 1 -and $assigned.openAssignments[0].developer -eq "developer-1" -and
        $assigned.openAssignments[0].action -eq "implement") "Open assignments are reported for crash detection."
    Assert-True $assigned.hasDeveloperOfferWork "An open assignment requires Developer contact even without an eligible candidate."
    $fixtureTaskComments.T1 += New-TaskComment "TC2" "2026-11-15T11:00:00Z" "Done <!-- fingvibe:assignment-end=A1 -->"
    $ended = Get-Agent4WorkPacket $configuration (Join-Path $root "ended.json") $fixtureReader
    Assert-True (101 -in $ended.candidates.issue -and $ended.openAssignments.Count -eq 0) "End-of-work closes the assignment."
    Assert-True $ended.hasDeveloperOfferWork "Eligible candidates require Developer offers."
    $fixtureTaskComments.T1 = @(New-TaskComment "TC1" "2026-11-15T10:00:00Z" $send
        New-TaskComment "TC3" "2026-11-15T12:00:00Z" "Released <!-- fingvibe:assignment-release=A1 -->")
    $released = Get-Agent4WorkPacket $configuration (Join-Path $root "released.json") $fixtureReader
    $releasedCandidate = $released.candidates | Where-Object issue -EQ 101
    Assert-True ($releasedCandidate.category -eq "new" -and $releasedCandidate.released.assignmentId -eq "A1") "Released work without a PR is offered again."
    $fixtureLinks = @{ PR200 = 101 }; $fixtureCiStatus = "in_progress"
    $resume = Get-Agent4WorkPacket $configuration (Join-Path $root "resume.json") $fixtureReader
    $resumeCandidate = $resume.candidates | Where-Object issue -EQ 101
    Assert-True ($resumeCandidate.category -eq "resume" -and $resumeCandidate.pr.number -eq 200) "Released implementation resumes its existing PR regardless of CI."
    $fixtureCiStatus = "completed"; $fixtureSecondConclusion = "success"
    $fixtureLinks = @{ PR200 = 101; PR201 = 103 }
    $successAndResume = Get-Agent4WorkPacket $configuration (Join-Path $root "success-resume.json") $fixtureReader
    Assert-True (($successAndResume.candidates.category -join ",") -eq "success,resume,new,new" -and
        ($successAndResume.developerOffers[0].candidates.issue -join ",") -eq "103,104" -and
        ($successAndResume.developerOffers[1].candidates.issue -join ",") -eq "103,101" -and
        $successAndResume.developerOffers[1].candidates[1].released.assignmentId -eq "A1") "Sharing success preserves resumed work and its release evidence as Developer 2's fallback."
    $fixtureSecondConclusion = "failure"
    $finalizeSend = "Sending #101 to Developer 2 <!-- fingvibe:assignment=F1 developer=developer-2 action=finalize -->"
    $finalizeEnd = "Rejected <!-- fingvibe:assignment-end=F1 -->"
    $fixtureTaskComments.T1 = @(New-TaskComment "TC1" "2026-11-15T10:00:00Z" $send
        New-TaskComment "TC2" "2026-11-15T11:00:00Z" "Done <!-- fingvibe:assignment-end=A1 -->"
        New-TaskComment "TC4" "2026-11-15T12:00:00Z" $finalizeSend
        New-TaskComment "TC5" "2026-11-15T13:00:00Z" "$finalizeEnd <!-- fingvibe:finalize-rejected=F1 head=$("A"*40) -->")
    $rejected = Get-Agent4WorkPacket $configuration (Join-Path $root "rejected.json") $fixtureReader
    $rejectedCandidate = $rejected.candidates | Where-Object issue -EQ 101
    Assert-True ($rejectedCandidate.category -eq "failed" -and $rejectedCandidate.finalizeRejection.assignmentId -eq "F1" -and
        $rejectedCandidate.finalizeRejection.head -eq ("a"*40) -and $rejectedCandidate.pr.number -eq 200 -and
        -not $rejectedCandidate.released) "A rejected finalize on the current green head is offered for repair, not finalize again."
    $fixtureTaskComments.T1[3] = New-TaskComment "TC5" "2026-11-15T13:00:00Z" "$finalizeEnd <!-- fingvibe:finalize-rejected=F1 head=$("c"*40) -->"
    $newHead = Get-Agent4WorkPacket $configuration (Join-Path $root "rejected-new-head.json") $fixtureReader
    $newHeadCandidate = $newHead.candidates | Where-Object issue -EQ 101
    Assert-True ($newHeadCandidate.category -eq "success" -and -not $newHeadCandidate.finalizeRejection) "A new PR head returns to normal CI classification."
    $fixtureTaskComments.T1[3] = New-TaskComment "TC5" "2026-11-15T13:00:00Z" "$finalizeEnd <!-- fingvibe:finalize-rejected=A1 head=$("a"*40) -->"
    $notFinalize = Get-Agent4WorkPacket $configuration (Join-Path $root "rejected-not-finalize.json") $fixtureReader
    Assert-True (($notFinalize.candidates | Where-Object issue -EQ 101).category -eq "success") "Rejection markers must reference a finalize assignment in the task Discussion."
    $fixtureLinks = @{}; $fixtureCiStatus = "completed"; $fixtureTaskDiscussions = @(); $fixtureTaskComments = @{}
    foreach ($child in $children) { $child.labels = @(@{ name = "active" }) }
    $noOfferWork = Get-Agent4WorkPacket $configuration (Join-Path $root "no-offer-work.json") $fixtureReader
    Assert-True (-not $noOfferWork.hasDeveloperOfferWork -and $noOfferWork.candidates.Count -eq 0 -and
        $noOfferWork.openAssignments.Count -eq 0) "No candidates and no open assignments skip new Developer calls."
    $emptyOffers = ($noOfferWork | ConvertTo-Json -Depth 100 | ConvertFrom-Json).developerOffers
    Assert-True ($emptyOffers.Count -eq 2 -and $emptyOffers[0].candidates -is [array] -and
        $emptyOffers[1].candidates -is [array] -and $emptyOffers[0].candidates.Count -eq 0 -and
        $emptyOffers[1].candidates.Count -eq 0) "Empty offers serialize as two explicit empty candidate arrays."
    foreach ($child in $children) { $child.labels = @(@{ name = "type:task" }) }
    $children[1].labels += @{ name = "human-task" }
    $ordered = Get-Agent4WorkPacket $configuration (Join-Path $root "ordered.json") $fixtureReader @(101,102,103,104,105,106) "fixture://human-order"
    Assert-True (($ordered.candidates.issue -join ",") -eq "101") "Explicit blocked predecessor must prevent later offers."
    $sharedOffers = ($ordered | ConvertTo-Json -Depth 100 | ConvertFrom-Json).developerOffers
    Assert-True ($sharedOffers[0].candidates -is [array] -and $sharedOffers[1].candidates -is [array] -and
        $sharedOffers[0].candidates.Count -eq 1 -and $sharedOffers[1].candidates.Count -eq 1 -and
        $sharedOffers[0].candidates[0].issue -eq 101 -and $sharedOffers[1].candidates[0].issue -eq 101) "A singleton is offered to both Developers as candidate arrays."
    Assert-Fails {
        Get-Agent4WorkPacket $configuration (Join-Path $root "failed.json") { throw "GitHub collection failed" }
    } "*collection failed*"
    Assert-True (-not [IO.File]::Exists((Join-Path $root "failed.json"))) "Collection failure must not publish success evidence."
    $stalePull = {
        param($Endpoint, $Paginated, $Query)
        if ($Endpoint -match '/pulls/200$') { return '{"number":200,"head":{"sha":"changed"},"mergeable":false}' }
        & $fixtureReader $Endpoint $Paginated $Query
    }
    Assert-Fails { Get-Agent4WorkPacket $configuration (Join-Path $root "stale-pr.json") $stalePull } "*PR identity/head changed*"
    Assert-True (-not [IO.File]::Exists((Join-Path $root "stale-pr.json"))) "PR head drift must not publish actionable evidence."
    $missingMergeability = {
        param($Endpoint, $Paginated, $Query)
        if ($Endpoint -match '/pulls/200$') { return '{"number":200,"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}' }
        & $fixtureReader $Endpoint $Paginated $Query
    }
    Assert-Fails { Get-Agent4WorkPacket $configuration (Join-Path $root "missing-mergeability.json") $missingMergeability } "*Incomplete PR mergeability*"
    $malformed = {
        param($Endpoint, $Paginated, $Query)
        if ($Endpoint -match '/check-runs') { return '[{}]' }
        & $fixtureReader $Endpoint $Paginated $Query
    }
    Assert-Fails { Get-Agent4WorkPacket $configuration (Join-Path $root "missing-ci.json") $malformed } "*truncated CI*"
    $wrongParent = {
        param($Endpoint, $Paginated, $Query)
        if ($Endpoint -match '/parent$') { return '{"number":191,"labels":[{"name":"type:epic"}]}' }
        & $fixtureReader $Endpoint $Paginated $Query
    }
    Assert-Fails { Get-Agent4WorkPacket $configuration (Join-Path $root "wrong-parent.json") $wrongParent } "*parent changed*"
    Assert-Fails { Get-Agent4WorkPacket $configuration (Join-Path $root "order.json") $fixtureReader @(101) "fixture://order" } "*cover the open native queue*"
    . (Join-Path $PSScriptRoot "..\.github\scripts\Set-Agent4TaskClaim.ps1")
    $ghCalls = [Collections.Generic.List[string]]::new()
    $fixtureVerifiedStatus = "In Progress"; $fixtureVerifiedLabels = @(@{ name = "active" })
    function Invoke-Agent4Gh([string[]] $Arguments) {
        $ghCalls.Add($Arguments -join " ")
        switch ("$($Arguments[0]) $($Arguments[1])") {
            "project view" { '{"id":"P5","title":"Backlog"}' }
            "project item-add" { '{"id":"ITEM"}' }
            "project field-list" { '{"fields":[{"id":"F","name":"Status","options":[{"id":"o1","name":"Todo"},{"id":"o2","name":"In Progress"}]}]}' }
            "issue view" { ConvertTo-Json -Depth 5 -Compress @{ labels = $fixtureVerifiedLabels
                projectItems = @(@{ title = "Backlog"; status = @{ name = $fixtureVerifiedStatus } }) } }
            default { "" }
        }
    }
    $claim = Set-Agent4TaskClaim 101 claim "TestOwner/TestRepo" "TestOwner" 5
    Assert-True ($claim.active -and $claim.status -eq "In Progress") "Claim reports verified active label and In Progress."
    Assert-True (@($ghCalls | Where-Object { $_ -like "issue edit 101*--add-label active" }).Count -eq 1 -and
        @($ghCalls | Where-Object { $_ -like "project item-edit*--single-select-option-id o2" }).Count -eq 1) "Claim writes label and Status."
    Assert-Fails { Set-Agent4TaskClaim 101 release "TestOwner/TestRepo" "TestOwner" 5 } "*verification failed*"
    $fixtureVerifiedStatus = "Todo"; $fixtureVerifiedLabels = @()
    $release = Set-Agent4TaskClaim 101 release "TestOwner/TestRepo" "TestOwner" 5
    Assert-True (-not $release.active -and $release.status -eq "Todo") "Release removes active and returns Status to Todo."
    . (Join-Path $PSScriptRoot "..\.github\scripts\Set-Agent4DiscussionParticipant.ps1")
    $discussionLabels = @("documentation", "4️⃣dev2")
    $discussionMutations = [Collections.Generic.List[string]]::new()
    $discussionBody = "<!-- fingvibe:task=101 -->"
    $discussionCategory = "🛠️ Task conversations"
    $discussionRepository = "TestOwner/TestRepo"
    $discussionHasNextPage = $false
    $discussionLabelMissing = $false
    $discussionWriteIgnored = $false
    $discussionDropExisting = $false
    $discussionReadFailed = $false
    function Invoke-Agent4DiscussionGraphQl([string] $Query, [hashtable] $Variables) {
        if ($Query.StartsWith("mutation")) {
            $discussionMutations.Add($Variables.label)
            if (-not $discussionWriteIgnored) { $script:discussionLabels += $Variables.label }
            if ($discussionDropExisting) { $script:discussionLabels = @($Variables.label) }
            return @{ addLabelsToLabelable = @{ clientMutationId = $null } }
        }
        if ($discussionReadFailed) { throw "Fixture Discussion API failed." }
        @{ repository = @{
            nameWithOwner = $discussionRepository
            label = $(if (-not $discussionLabelMissing) { @{ id = $Variables.label; name = $Variables.label } })
            discussion = @{ id = "DISC101"; url = "fixture://discussions/201"
                body = $discussionBody; category = @{ name = $discussionCategory }
                labels = @{ nodes = @($discussionLabels | ForEach-Object { @{ id = $_; name = $_ } })
                    pageInfo = @{ hasNextPage = $discussionHasNextPage } } }
        } }
    }
    $participant = Set-Agent4DiscussionParticipant "TestOwner/TestRepo" 201 101 developer-1
    Assert-True ($participant.label -ceq "4️⃣dev1" -and $discussionMutations.Count -eq 1 -and
        $discussionMutations[0] -ceq "4️⃣dev1" -and "documentation" -cin $discussionLabels -and
        "4️⃣dev2" -cin $discussionLabels) "Participation adds only the actual worker label and preserves existing history."
    $null = Set-Agent4DiscussionParticipant "TestOwner/TestRepo" 201 101 developer-1
    Assert-True ($discussionMutations.Count -eq 1) "Repeated participation does not mutate labels again."
    $discussionLabels = @("documentation", "4️⃣dev1")
    $null = Set-Agent4DiscussionParticipant "TestOwner/TestRepo" 201 101 developer-2
    Assert-True ($discussionMutations[1] -ceq "4️⃣dev2" -and "4️⃣dev1" -cin $discussionLabels) "Developer 2 uses its own label."
    $writesBeforeFailure = $discussionMutations.Count
    Assert-Fails { Set-Agent4DiscussionParticipant "TestOwner/TestRepo" 201 102 developer-1 } "*assigned repository*"
    $discussionBody += "`n<!-- fingvibe:task=102 -->"
    Assert-Fails { Set-Agent4DiscussionParticipant "TestOwner/TestRepo" 201 101 developer-1 } "*assigned repository*"
    $discussionBody = "<!-- fingvibe:task=101 -->"; $discussionCategory = "Agent logs"
    Assert-Fails { Set-Agent4DiscussionParticipant "TestOwner/TestRepo" 201 101 developer-1 } "*assigned repository*"
    $discussionCategory = "Task conversations"; $discussionRepository = "Foreign/Repo"
    Assert-Fails { Set-Agent4DiscussionParticipant "TestOwner/TestRepo" 201 101 developer-1 } "*assigned repository*"
    $discussionRepository = "TestOwner/TestRepo"; $discussionLabelMissing = $true
    Assert-Fails { Set-Agent4DiscussionParticipant "TestOwner/TestRepo" 201 101 developer-1 } "*label*unavailable*"
    $discussionLabelMissing = $false; $discussionHasNextPage = $true
    Assert-Fails { Set-Agent4DiscussionParticipant "TestOwner/TestRepo" 201 101 developer-1 } "*Incomplete Discussion labels*"
    $discussionHasNextPage = $false; $discussionReadFailed = $true
    Assert-Fails { Set-Agent4DiscussionParticipant "TestOwner/TestRepo" 201 101 developer-1 } "*API failed*"
    $discussionReadFailed = $false
    Assert-Fails { Set-Agent4DiscussionParticipant "TestOwner/TestRepo" 201 101 dispatcher } "*identity required*"
    Assert-True ($discussionMutations.Count -eq $writesBeforeFailure) "Invalid context and unavailable evidence never mutate labels."
    $discussionLabels = @("documentation"); $discussionWriteIgnored = $true
    Assert-Fails { Set-Agent4DiscussionParticipant "TestOwner/TestRepo" 201 101 developer-1 } "*participation verification failed*"
    $discussionWriteIgnored = $false; $discussionDropExisting = $true
    Assert-Fails { Set-Agent4DiscussionParticipant "TestOwner/TestRepo" 201 101 developer-1 } "*participation verification failed*"
    Write-Host "Agent4 paginated evidence and queue checks passed."
} finally {
    if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
}
