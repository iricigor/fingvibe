[CmdletBinding()]
param([string] $InputPath)

$ErrorActionPreference = "Stop"
$repairInputPath = $InputPath
. (Join-Path $PSScriptRoot "Get-Agent4AssignmentPlan.ps1")
. (Join-Path $PSScriptRoot "Get-Agent4DispatcherPacket.ps1")

function Invoke-Agent4RepairApi([string] $Method, [string] $Endpoint, [hashtable] $Fields) {
    $arguments = @("api", "--method", $Method, $Endpoint)
    foreach ($key in $Fields.Keys) { $arguments += @("-f", "$key=$($Fields[$key])") }
    $output = gh @arguments
    if ($LASTEXITCODE -ne 0) { throw "GitHub repair request failed or is uncertain: $Method $Endpoint. Reconcile before retrying." }
    if (-not $output) { return @{} }
    $value = ($output -join "`n") | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    if ($value.errors) { throw "GitHub repair GraphQL request failed: $($value.errors | ConvertTo-Json -Compress)" }
    $value
}

function Get-Agent4RepairBudget($Entries) {
    $count = 0; $baseline = $false; $covered = @(); $reservations = @{}; $results = @{}; $assignments = @()
    foreach ($entry in $Entries) {
        $body = [string] $entry.body
        $patterns = @{
            "repair-baseline" = '<!-- fingvibe:repair-baseline=(\d+) assignments=([A-Za-z0-9._:,-]+) -->'
            "repair-attempt" = '<!-- fingvibe:repair-attempt=(\d+) kind=(code|rerun) key=([A-Za-z0-9._:-]+) -->'
            "repair-result" = '<!-- fingvibe:repair-result=([A-Za-z0-9._:-]+) state=(requested|failed|reconciled) -->'
        }
        foreach ($name in $patterns.Keys) {
            if ([regex]::Matches($body, "<!--\s*fingvibe:$name\b").Count -ne [regex]::Matches($body, $patterns[$name]).Count) {
                throw "Malformed $name history; reconcile the Discussion."
            }
        }
        foreach ($match in [regex]::Matches($body, $patterns["repair-baseline"])) {
            if ($baseline -or $reservations.Count) { throw "Duplicate or late repair baseline; history cannot reset." }
            $baseline = $true; $count = [int] $match.Groups[1].Value
            $covered = if ($match.Groups[2].Value -eq "none") { @() } else { @($match.Groups[2].Value.Split(",")) }
            if (@($covered | Select-Object -Unique).Count -ne $covered.Count) { throw "Duplicate baseline assignments." }
            if (@($covered | Where-Object { $_ -notin $assignments }).Count) {
                throw "Repair baseline must cover only preceding repair assignments."
            }
        }
        foreach ($match in [regex]::Matches($body, $patterns["repair-attempt"])) {
            $attempt = [int] $match.Groups[1].Value; $kind = $match.Groups[2].Value; $key = $match.Groups[3].Value
            if ($attempt -ne $count + 1 -or $reservations.ContainsKey($key)) { throw "Contradictory repair attempts; history must be cumulative and unique." }
            $count = $attempt
            $reservations[$key] = @{ attempt = $attempt; kind = $kind }
        }
        foreach ($match in [regex]::Matches($body, $patterns["repair-result"])) {
            $key = $match.Groups[1].Value
            if (-not $reservations.ContainsKey($key) -or $results.ContainsKey($key)) { throw "Contradictory repair result history." }
            $results[$key] = $match.Groups[2].Value
        }
        foreach ($match in [regex]::Matches($body,
            '<!--\s*fingvibe:assignment=([A-Za-z0-9._:-]+)\s+developer=developer-[12]\s+action=repair\s*-->')) {
            $assignments += $match.Groups[1].Value
        }
    }
    foreach ($id in $covered) {
        if ($id -notin $assignments) { throw "Repair baseline names an unknown assignment." }
    }
    foreach ($id in $assignments) {
        if ($id -notin $covered -and (-not $reservations.ContainsKey($id) -or $reservations[$id].kind -ne "code")) {
            throw "Missing repair history for $id; verify prior reports and record a baseline before continuing."
        }
    }
    @{
        consumed = $count; reservations = $reservations; results = $results
        uncertain = @($reservations.Keys | Where-Object { $reservations[$_].kind -eq "rerun" -and -not $results.ContainsKey($_) })
    }
}

function Invoke-Agent4RepairAction([System.Collections.IDictionary] $Request, [scriptblock] $Api) {
    $allocation = $Request.allocation
    $plan = Get-Agent4AssignmentPlan $allocation
    $repository = $plan.repository
    if ($repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
        $Request.action -cnotin @("code", "rerun") -or
        ($Request.repairs -isnot [int] -and $Request.repairs -isnot [long]) -or $Request.repairs -lt 0 -or
        ($Request.expectedRepairCount -isnot [int] -and $Request.expectedRepairCount -isnot [long]) -or $Request.expectedRepairCount -lt 0 -or
        ($Request.issue -isnot [int] -and $Request.issue -isnot [long]) -or $Request.issue -le 0 -or
        ($Request.discussion -isnot [int] -and $Request.discussion -isnot [long]) -or $Request.discussion -le 0) {
        throw "Explicit action, run repairs allowance, expected repair count and positive task/Discussion numbers required."
    }
    $issue = $Request.issue
    if ($Request.action -eq "rerun") {
        $selected = @($plan.proposedReruns | Where-Object issue -EQ $issue)
    } else {
        $selected = @($plan.proposedStarts | Where-Object { $_.issue -eq $issue -and $_.action -eq "repair" })
        if ($Request.assignmentId -isnot [string] -or $Request.assignmentId -cnotmatch '^[A-Za-z0-9._:-]+$') {
            throw "Code repair requires its unique assignmentId before sending the start."
        }
    }
    if ($selected.Count -ne 1) { throw "No unique planner-approved $($Request.action) action for #$issue." }
    $candidate = @($allocation.packet.candidates | Where-Object issue -EQ $issue)[0]
    if (($candidate.pr.number -isnot [int] -and $candidate.pr.number -isnot [long]) -or $candidate.pr.number -le 0 -or
        $candidate.pr.head.sha -isnot [string] -or $candidate.pr.head.sha -cnotmatch '^[0-9a-f]{40}$') {
        throw "Repair action requires the offered PR number and exact head."
    }
    $target = $selected[0]
    $key = if ($Request.action -eq "rerun") { "rerun:$issue`:$($target.head):$($target.runId):$($target.runAttempt)" } else { $Request.assignmentId }
    $owner, $name = $repository.Split("/")
    $prefix = 'repository(owner:"' + $owner + '",name:"' + $name + '"){nameWithOwner discussion(number:' + $Request.discussion + ')'

    function Read-Discussion {
        $context = (& $Api POST graphql @{ query = 'query{' + $prefix + '{id url body category{name}}}}' }).data.repository
        $discussion = $context.discussion
        $markers = [regex]::Matches([string] $discussion.body, '<!--\s*fingvibe:task=(\d+)\s*-->')
        if ($context.nameWithOwner -ine $repository -or -not $discussion.id -or
            $discussion.category.name -cnotin @("Task conversations", "🛠️ Task conversations") -or
            $markers.Count -ne 1 -or [int] $markers[0].Groups[1].Value -ne $issue) {
            throw "Discussion repository/category/task identity mismatch."
        }
        function Read-Comments([string] $Id, [string] $Type, [string] $Field) {
            $entries = @(); $cursor = $null; $seen = @{}
            do {
                $after = if ($cursor) { ',after:"' + $cursor + '"' } else { "" }
                $selection = "id body createdAt"
                if ($Field -eq "comments") {
                    $selection += " replies(first:100){nodes{id body createdAt} pageInfo{hasNextPage endCursor}}"
                }
                $query = 'query{node(id:"' + $Id + '"){... on ' + $Type + '{' + $Field +
                    '(first:100' + $after + '){nodes{' + $selection + '} pageInfo{hasNextPage endCursor}}}}}'
                $connection = (& $Api POST graphql @{ query = $query }).data.node[$Field]
                if ($connection.nodes -isnot [array] -or $connection.pageInfo.hasNextPage -isnot [bool]) {
                    throw "Incomplete repair Discussion history."
                }
                $entries += $connection.nodes
                $cursor = $connection.pageInfo.endCursor
                if ($connection.pageInfo.hasNextPage) {
                    if (-not $cursor -or $seen.ContainsKey($cursor)) { throw "Invalid repair history pagination." }
                    $seen[$cursor] = $true
                }
            } while ($connection.pageInfo.hasNextPage)
            return ,$entries
        }
        $comments = Read-Comments $discussion.id Discussion comments
        $entries = @(foreach ($comment in $comments) {
            @{ id = $comment.id; body = $comment.body; createdAt = $comment.createdAt }
            $replies = $comment.replies
            if ($replies.nodes -isnot [array] -or $replies.pageInfo.hasNextPage -isnot [bool]) {
                throw "Incomplete repair Discussion replies."
            }
            if ($replies.pageInfo.hasNextPage) {
                foreach ($reply in (Read-Comments $comment.id DiscussionComment replies)) { $reply }
            } else {
                foreach ($reply in $replies.nodes) { $reply }
            }
        })
        $seen = @{}
        foreach ($entry in $entries) {
            $timestamp = [DateTimeOffset]::MinValue
            if ($entry.id -isnot [string] -or -not $entry.id -or $seen.ContainsKey($entry.id) -or
                $entry.body -isnot [string] -or
                -not [DateTimeOffset]::TryParse([string] $entry.createdAt, [ref] $timestamp)) {
                throw "Missing or duplicate repair history entries."
            }
            $seen[$entry.id] = $true
        }
        $discussion.comments = @($entries | Sort-Object -Stable { $_.createdAt })
        $discussion
    }
    function Publish-Record([string] $Body) {
        $query = 'mutation($discussion:ID!,$body:String!){addDiscussionComment(input:{discussionId:$discussion,body:$body}){comment{id}}}'
        $data = & $Api POST graphql @{ query = $query; discussion = $discussion.id; body = $Body }
        $id = $data.data.addDiscussionComment.comment.id
        if (-not $id) { throw "Repair record publication uncertain; reconcile before retrying." }
        $readback = Read-Discussion
        if (@($readback.comments | Where-Object { $_.id -ceq $id -and $_.body -ceq $Body }).Count -ne 1) {
            throw "Repair record readback failed; reconcile before retrying."
        }
        return $readback
    }
    function Read-FreshTarget {
        $task = & $Api GET "repos/$repository/issues/$issue" @{}
        $parent = & $Api GET "repos/$repository/issues/$issue/parent" @{}
        $pull = & $Api GET "repos/$repository/pulls/$($candidate.pr.number)" @{}
        if ($task.number -ne $issue -or $task.state -cne "open" -or "type:task" -notin $task.labels.name -or
            @($task.labels.name | Where-Object { $_ -in @("human-task", "status:blocked") }).Count -or
            $parent.number -ne $plan.epic -or $parent.state -cne "open" -or "type:epic" -notin $parent.labels.name -or
            $pull.number -ne $candidate.pr.number -or $pull.state -cne "open" -or
            $pull.head.sha -cne $candidate.pr.head.sha -or $pull.head.repo.full_name -ine $repository -or
            $pull.base.ref -cne $allocation.packet.targetBranch) {
            throw "Task authority, parent or PR identity/head changed; reassess."
        }
        if ($Request.action -eq "rerun") {
            $run = & $Api GET "repos/$repository/actions/runs/$($target.runId)" @{}
            if ($pull.mergeable -ceq $false -or $run.id -ne $target.runId -or
                $run.repository.full_name -ine $repository -or $run.head_sha -cne $target.head -or
                -not $run.workflow_id -or
                $run.run_attempt -ne $target.runAttempt -or $run.status -cne "completed" -or
                $run.conclusion -cnotin @("failure", "timed_out") -or
                $run.event -cnotin @("pull_request", "pull_request_target") -or
                $candidate.pr.number -notin @($run.pull_requests.number)) {
                throw "Run is stale, pending, not failed, or not bound to the offered PR/head."
            }
            $latest = & $Api GET "repos/$repository/actions/workflows/$($run.workflow_id)/runs?head_sha=$($target.head)&event=$($run.event)&per_page=1" @{}
            if ($latest.workflow_runs -isnot [array] -or $latest.workflow_runs.Count -ne 1 -or
                $latest.workflow_runs[0].id -ne $target.runId) {
                throw "A newer workflow run exists or latest-run evidence is missing; reassess."
            }
        }
    }

    Read-FreshTarget
    $discussion = Read-Discussion
    $records = Get-Agent4TaskRecords @($discussion)
    if (@($records[[int] $issue].assignments | Where-Object state -EQ open).Count) {
        throw "Open task assignment prevents a repair action."
    }
    $budget = Get-Agent4RepairBudget $discussion.comments
    if ($budget.reservations.ContainsKey($key)) {
        if ($budget.reservations[$key].kind -cne $Request.action) { throw "Repair reservation key has a different action; reconcile history." }
        return @{ status = "already-recorded"; issue = $issue; key = $key; attempt = $budget.reservations[$key].attempt
            recovery = "No request repeated. Reconcile any uncertain outcome using GitHub run evidence." }
    }
    if ($budget.uncertain.Count) { throw "Uncertain rerun reservation requires reconciliation: $($budget.uncertain -join ', ')." }
    if ($budget.consumed -ne $Request.expectedRepairCount) { throw "Repair count changed or history is incomplete; reassess." }
    if ($budget.consumed -ge $Request.repairs) { throw "Shared repair allowance exhausted; record recovery and block the task." }
    $attempt = $budget.consumed + 1
    $evidence = $target | ConvertTo-Json -Depth 30 -Compress
    $marker = "<!-- fingvibe:repair-attempt=$attempt kind=$($Request.action) key=$key -->"
    $body = "Repair attempt $attempt/$($Request.repairs): $($Request.action). PR #$($candidate.pr.number), head $($candidate.pr.head.sha).`n`nEvidence: $evidence`n`n$marker"
    $discussion = Publish-Record $body
    $verified = Get-Agent4RepairBudget $discussion.comments
    if ($verified.consumed -ne $attempt -or $verified.reservations[$key].attempt -ne $attempt) {
        throw "Repair reservation verification failed; reconcile before any action."
    }
    $records = Get-Agent4TaskRecords @($discussion)
    if (@($records[[int] $issue].assignments | Where-Object state -EQ open).Count) {
        throw "An assignment appeared during reservation; reconcile before any action."
    }
    # A reservation survives crashes, failed requests and head changes; it is never refunded.
    Read-FreshTarget
    if ($Request.action -eq "code") {
        return @{ status = "reserved"; issue = $issue; key = $key; attempt = $attempt; marker = $marker; discussionUrl = $discussion.url }
    }
    $null = & $Api POST "repos/$repository/actions/runs/$($target.runId)/rerun-failed-jobs" @{}
    $null = Publish-Record "<!-- fingvibe:repair-result=$key state=requested -->`n`nFailed-job rerun requested; completion is unverified. Do not wait or poll; reassess on the next Dispatcher run."
    @{ status = "requested"; issue = $issue; key = $key; attempt = $attempt; runId = $target.runId
        head = $target.head; discussionUrl = $discussion.url }
}

if ($MyInvocation.InvocationName -ne ".") {
    if (-not $repairInputPath -or -not [IO.Path]::IsPathFullyQualified($repairInputPath)) { throw "Absolute InputPath required." }
    $request = Get-Content -LiteralPath $repairInputPath -Raw | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String -NoEnumerate
    Invoke-Agent4RepairAction $request ${function:Invoke-Agent4RepairApi} | ConvertTo-Json -Depth 100
}
