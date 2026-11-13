$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "..\.github\scripts\Agent3Coordination.psm1") -Force
$gateScript = Join-Path $PSScriptRoot "..\.github\scripts\Invoke-DispatcherGate.ps1"
$root = Join-Path ([IO.Path]::GetTempPath()) ("fingvibe-real-test-" + [guid]::NewGuid())
$null = [IO.Directory]::CreateDirectory($root)
$evidence = @("fixture://verified-evidence")
$head = "a" * 40

function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    try { & $Action | Out-Null }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected failure matching '$Pattern'."
}

function Copy-Record($Record) { $Record | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -DateKind String -Depth 100 }

function New-Fixture {
    New-Agent3State -Repository "TestOwner/TestRepo" -Epic 92 -TargetBranch main `
        -Authorization @{ reference = "fixture://human-approval"; implementation = $true; merge = $false } `
        -Workers @(@{ id = "developer-1"; name = "Developer 1"; automationId = "automation-1" },
            @{ id = "developer-2"; name = "Developer 2"; automationId = "automation-2" })
}

function Start-Handoff($State, $Task, $Handoff) {
    Set-Agent3Stage $State $Task.claimId $Handoff.id launch-requested -Evidence $evidence
    Set-Agent3Stage $State $Task.claimId $Handoff.id correlated -Evidence $evidence `
        -RunId ("run-" + $Handoff.id) -SessionId ("session-" + $Handoff.id)
    Set-Agent3Stage $State $Task.claimId $Handoff.id delivered -Evidence $evidence
}

function New-Event($Task, $Handoff, [string] $Kind, [string] $Outcome = "implementation-ready") {
    @{
        schema = "fingvibe-real-event-v1"; eventId = "$Kind-$($Handoff.id)"
        kind = $Kind; claimId = $Task.claimId; handoffId = $Handoff.id; action = $Handoff.action
        workerId = $Handoff.workerId; runId = $Handoff.runId; sessionId = $Handoff.sessionId
        utc = [DateTime]::UtcNow.ToString("o"); actor = $Handoff.workerId
        originalReporter = $Handoff.workerId; trigger = "unknown"; elapsedSeconds = 1.25
        evidence = $evidence
        result = $(if ($Kind -eq "result") {
            @{ outcome = $Outcome; head = $head; checkpoint = "fixture://checkpoint"; evidence = $evidence }
        } else { $null })
    }
}

function Complete-Implementation($State, $Task, $Handoff) {
    Start-Handoff $State $Task $Handoff
    $null = Add-Agent3Event $State (New-Event $Task $Handoff ack)
    $null = Add-Agent3Event $State (New-Event $Task $Handoff result)
    Set-Agent3Stage $State $Task.claimId $Handoff.id stopped-verified -Evidence @("fixture://actual-session-stopped")
    $Task.branch = "task-branch"; $Task.worktree = Join-Path $root "task-worktree"
    $Task.pr = "fixture://pr"
    if ($Task.head -cne $head -or $Task.checkpoint -cne "fixture://checkpoint") {
        throw "Accepted implementation must promote head/checkpoint without manual bookkeeping."
    }
    Set-Agent3Disposition $State $Task.claimId validation -Evidence $evidence
    Set-Agent3Stage $State $Task.claimId $Handoff.id reconciled -Evidence $evidence
}

function Reject-MessageHandoff($State, $Task, $Handoff, [string] $Directory) {
    Start-Handoff $State $Task $Handoff
    $manual = @{ agentId = "dispatcher"; automationId = $null; runId = $null; sessionId = "dispatcher-session" }
    $actual = @{ agentId = "dispatcher"; automationId = "dispatcher-automation"; runId = "dispatcher-run"; sessionId = "dispatcher-session" }
    $recipient = @{ agentId = $Handoff.workerId
        automationId = @($State.workers | Where-Object id -CEQ $Handoff.workerId)[0].automationId
        runId = $Handoff.runId; sessionId = $Handoff.sessionId }
    $context = @{ repository = $State.repository; epic = $State.epic; issue = $Task.issue
        claimId = $Task.claimId; handoffId = $Handoff.id }
    $message = New-Agent3Message assignment $manual $recipient $context `
        (Get-Agent3Assignment $State $Task.claimId $Handoff.id) $Directory
    $null = Publish-Agent3Message $message $State $manual $recipient $Directory
    $decision = Receive-Agent3Message ($message | ConvertTo-Json -Depth 100) `
        $State $actual $recipient $Directory $evidence
    if ($decision.reasonCode -cne "identity-mismatch" -or $decision.operation -cne "none" -or $decision.responseAllowed) {
        throw "Real identity mismatch must reject without execution or a protocol reply."
    }
    $event = New-Event $Task $Handoff result blocked-before-start
    $event.result.evidence += $decision.diagnosticPath
    $null = Publish-Agent3PreStartRejection $State $event $Handoff.workerId $Handoff.runId `
        $Handoff.sessionId (Join-Path $Directory "events")
    $null = Add-Agent3Event $State $event
    Set-Agent3Disposition $State $Task.claimId blocked -Evidence $evidence
    Set-Agent3Stage $State $Task.claimId $Handoff.id stopped-verified -Evidence @("fixture://actual-session-stopped")
    return $decision.diagnosticPath
}

function New-DispatchCandidate([int] $Issue, [string] $Action = "implement", $ClaimId = $null) {
    @{ issue = $Issue; action = $Action; claimId = $ClaimId
        feedback = $evidence; priorRepairEvidence = $evidence }
}

try {
    $approvalReference = "https://github.com/TestOwner/TestRepo/issues/92#issuecomment-123"
    $approvalComment = @{
        id = 123; html_url = $approvalReference
        issue_url = "https://api.github.com/repos/TestOwner/TestRepo/issues/92"
        user = @{ login = "TestOwner"; type = "User" }
        body = "Owner approval text retained verbatim for independent scope/permission review."
        updated_at = "2026-11-13T08:00:00Z"
    }
    $approvalReader = {
        param($endpoint)
        if ($endpoint -cne "repos/TestOwner/TestRepo/issues/comments/123") {
            throw "Unexpected owner approval endpoint."
        }
        $approvalComment | ConvertTo-Json -Depth 10 -Compress
    }
    $approvalParameters = @{
        Repository = "TestOwner/TestRepo"; Reference = $approvalReference
        OwnerLogin = "TestOwner"; ApiReader = $approvalReader
    }
    $approval = Get-Agent3AuthorizationEvidence @approvalParameters
    if ($approval.body -cne $approvalComment.body -or $approval.authorLogin -cne "TestOwner" -or
        $approval.Contains("implementation") -or $approval.Contains("merge") -or $approval.Contains("verified")) {
        throw "Approval evidence must preserve the original text without inventing human authority or permissions."
    }
    foreach ($reference in @(
        "Owner-authored kickoff retained in session dispatcher-1; implementation allowed",
        "https://github.com/OtherOwner/OtherRepo/issues/92#issuecomment-123",
        "https://github.com/TestOwner/TestRepo/issues/92#issuecomment-123?redirect=1"
    )) {
        $parameters = @{} + $approvalParameters
        $parameters.Reference = $reference
        $parameters.ApiReader = { throw "Invalid reference must fail before any API read." }
        Assert-Throws { Get-Agent3AuthorizationEvidence @parameters } "*Do not claim or launch*"
    }
    foreach ($mutate in @(
        { param($c) $c.user.login = "another-user" },
        { param($c) $c.user.type = "Bot" },
        { param($c) $c.id = 124 },
        { param($c) $c.html_url = "https://github.com/OtherOwner/OtherRepo/issues/92#issuecomment-123" },
        { param($c) $c.issue_url = "https://api.github.com/repos/TestOwner/TestRepo/issues/93" }
    )) {
        $original = Copy-Record $approvalComment
        try {
            & $mutate $approvalComment
            Assert-Throws { Get-Agent3AuthorizationEvidence @approvalParameters } "*Do not claim or launch*"
        } finally { $approvalComment = $original }
    }
    foreach ($reader in @(
        { throw "Approval is inaccessible." },
        { "" },
        { '{"id":123}' },
        { '{"id":' }
    )) {
        $parameters = @{} + $approvalParameters
        $parameters.ApiReader = $reader
        Assert-Throws { Get-Agent3AuthorizationEvidence @parameters } "*"
    }

    $module = Get-Module Agent3Coordination
    $hashRecord = '{"actor":"a","Actor":"b","nested":{"z":1,"a":2}}' | ConvertFrom-Json -AsHashtable
    $firstHash = & $module { param($r) Get-Agent3Hash $r } $hashRecord
    $hashRecord["actor"] = "changed"
    $secondHash = & $module { param($r) Get-Agent3Hash $r } $hashRecord
    if ($firstHash -ceq $secondHash) { throw "Canonical hashing must preserve case-distinct fields." }
    $reordered = '{"nested":{"a":2,"z":1},"Actor":"b","actor":"changed"}' | ConvertFrom-Json -AsHashtable
    if ((& $module { param($r) Get-Agent3Hash $r } $reordered) -cne $secondHash) {
        throw "Object order must not change canonical hashes."
    }
    $culture = [Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo("tr-TR")
        if ((& $module { param($r) Get-Agent3Hash $r } $hashRecord) -cne $secondHash) {
            throw "Culture must not change canonical hashes."
        }
    } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $culture }

    $orphaned = New-Fixture
    $orphaned.reports = @(@{ id = "orphan"; claimId = "missing"; handoffId = "missing"
        url = "fixture://report"; utc = [DateTime]::UtcNow.ToString("o"); nextOwner = "human"; nextAction = "inspect" })
    Assert-Throws { Assert-Agent3State $orphaned } "*exactly one task*"
    Assert-Throws { Get-Agent3Capacity $orphaned } "*exactly one task*"

    $state = New-Fixture
    $first = Add-Agent3Claim $state 100 $evidence
    $one = Add-Agent3Handoff $state $first.claimId developer-1 implement
    Assert-Throws { Add-Agent3Handoff $state $first.claimId developer-2 implement } "*unavailable*"
    $second = Add-Agent3Claim $state 101 $evidence
    Assert-Throws { Add-Agent3Handoff $state $second.claimId developer-1 implement } "*unavailable*"
    $two = Add-Agent3Handoff $state $second.claimId developer-2 implement
    if ((Get-Agent3Capacity $state).occupiedWorkers.Count -ne 2) { throw "Both independent workers must be occupied." }
    Assert-Throws { Set-Agent3Stage $state $first.claimId $one.id correlated -Evidence $evidence } "*Invalid stage*"
    Start-Handoff $state $first $one
    $assignment = Get-Agent3Assignment $state $first.claimId $one.id
    Assert-Agent3Assignment $state $assignment developer-1 $one.runId $one.sessionId
    $reservation = Publish-Agent3Acknowledgment $state $assignment developer-1 $one.runId $one.sessionId `
        (Join-Path $root "reservation") "actual-developer-1" -Evidence $evidence
    Assert-Throws {
        Publish-Agent3Acknowledgment $state $assignment developer-1 $one.runId $one.sessionId `
            (Join-Path $root "reservation") "actual-developer-1" -Evidence $evidence
    } "*already acknowledged*"
    $bad = Copy-Record $assignment; $bad.action = "finalize"
    Assert-Throws { Assert-Agent3Assignment $state $bad developer-1 $one.runId $one.sessionId } "*Invalid/stale*"
    Assert-Throws { Assert-Agent3Assignment $state $assignment developer-1 $one.runId $one.runId } "*mismatch*"
    $ack = New-Event $first $one ack
    $bad = Copy-Record $ack; $bad.Remove("elapsedSeconds"); $bad.elapsed = 1.25
    Assert-Throws { Add-Agent3Event $state $bad } "*Missing field 'elapsedSeconds'*"
    $bad = Copy-Record $ack; $bad.Remove("elapsedSeconds"); $bad.ElapsedSeconds = 1.25
    Assert-Throws { Add-Agent3Event $state $bad } "*Missing field 'elapsedSeconds'*"
    $bad = Copy-Record $ack; $bad.utc = "2026-11-11T12:00:00"
    Assert-Throws { Add-Agent3Event $state $bad } "*explicit UTC*"
    $bad = Copy-Record $ack; $bad.elapsedSeconds = -1
    Assert-Throws { Add-Agent3Event $state $bad } "*nonnegative*"
    $bad = Copy-Record $ack; $bad.sessionId = "bare-automation-run"
    Assert-Throws { Add-Agent3Event $state $bad } "*correlation mismatch*"
    if ((Add-Agent3Event $state $ack) -ne "applied" -or
        (Add-Agent3Event $state (Copy-Record $ack)) -ne "duplicate") { throw "Event idempotency failed." }
    $bad = Copy-Record $ack; $bad.actor = "different-recorder"
    Assert-Throws { Add-Agent3Event $state $bad } "*Conflicting duplicate*"
    Assert-Throws { Assert-Agent3Assignment $state $assignment developer-1 $one.runId $one.sessionId } "*not deliverable*"
    $result = New-Event $first $one result
    $null = Add-Agent3Event $state $result
    Assert-Throws { Set-Agent3Stage $state $first.claimId $one.id reconciled -Evidence $evidence } "*Invalid stage*"
    if ((Get-Agent3Capacity $state).occupiedWorkers.Count -ne 2) { throw "A completion event must not release execution." }
    Set-Agent3Disposition $state $first.claimId blocked -Evidence $evidence
    if ((Get-Agent3Capacity $state).occupiedWorkers.Count -ne 2) { throw "Blocked uncertain execution must occupy its worker." }
    Set-Agent3Stage $state $first.claimId $one.id stopped-verified -Evidence @("fixture://session-not-run-stopped")
    Set-Agent3Disposition $state $first.claimId validation -Evidence $evidence
    Set-Agent3Stage $state $first.claimId $one.id reconciled -Evidence $evidence
    $third = Add-Agent3Claim $state 102 $evidence
    $three = Add-Agent3Handoff $state $third.claimId developer-1 implement
    Complete-Implementation $state $second $two
    Start-Handoff $state $third $three
    $null = Add-Agent3Event $state (New-Event $third $three ack)
    $null = Add-Agent3Event $state (New-Event $third $three result)
    Set-Agent3Stage $state $third.claimId $three.id stopped-verified -Evidence $evidence
    Assert-Throws { Set-Agent3Disposition $state $third.claimId validation -Evidence $evidence } "*backlog full*"
    Assert-Throws { Set-Agent3Stage $state $third.claimId $three.id reconciled -Evidence $evidence } "*disposition*"
    if ((Get-Agent3Capacity $state).validationPending -ne 2) { throw "Backpressure must retain a result, not exceed the waiting bound." }

    $repairs = New-Fixture
    $task = Add-Agent3Claim $repairs 200 $evidence
    $handoff = Add-Agent3Handoff $repairs $task.claimId developer-1 implement
    Complete-Implementation $repairs $task $handoff
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        Set-Agent3Disposition $repairs $task.claimId repair-needed -Evidence $evidence
        $worker = if ($attempt % 2 -eq 0) { "developer-2" } else { "developer-1" }
        if ($attempt -gt 1) {
            Assert-Throws { Add-Agent3Handoff $repairs $task.claimId $worker repair -Feedback $evidence } "*Evidence*"
        }
        $handoff = Add-Agent3Handoff $repairs $task.claimId $worker repair -Feedback $evidence -PriorRepairEvidence $evidence
        if ($handoff.repairAttempt -ne $attempt -or $handoff.expectedHead -ne $task.head) {
            throw "Repair history/head must persist across worker handoffs and revisions."
        }
        $head = $attempt.ToString("x").PadLeft(40, "0")
        Complete-Implementation $repairs $task $handoff
    }
    Set-Agent3Disposition $repairs $task.claimId repair-needed -Evidence $evidence
    Assert-Throws { Add-Agent3Handoff $repairs $task.claimId developer-1 repair -Feedback $evidence -PriorRepairEvidence $evidence } "*exhausted*"
    $bad = Copy-Record $repairs; $bad.tasks[0].repairCount = 0
    Assert-Throws { Assert-Agent3State $bad } "*cannot reset*"
    $bad = Copy-Record $repairs; $bad.tasks[0].handoffs[1].repairAttempt = 1.0
    Assert-Throws { Assert-Agent3State $bad } "*Repair attempt must be an integer*"

    $final = New-Fixture
    $task = Add-Agent3Claim $final 300 $evidence
    $handoff = Add-Agent3Handoff $final $task.claimId developer-1 implement
    Complete-Implementation $final $task $handoff
    Set-Agent3Disposition $final $task.claimId finalize-ready -Evidence $evidence
    $handoff = Add-Agent3Handoff $final $task.claimId developer-2 finalize -Feedback $evidence
    Start-Handoff $final $task $handoff
    $null = Add-Agent3Event $final (New-Event $task $handoff ack)
    $result = New-Event $task $handoff result delivered
    Assert-Throws { Add-Agent3Event $final $result } "*not authorized*"
    $result.result.outcome = "pr-ready"; $result.result.head = "f" * 40
    Assert-Throws { Add-Agent3Event $final $result } "*without coding*"
    $result.result.head = $handoff.expectedHead
    $null = Add-Agent3Event $final $result
    Set-Agent3Stage $final $task.claimId $handoff.id stopped-verified -Evidence $evidence
    Set-Agent3Disposition $final $task.claimId human-review -Evidence $evidence
    Set-Agent3Stage $final $task.claimId $handoff.id reconciled -Evidence $evidence
    if ($task.state -ne "human-review") { throw "Publishing without merge authority must retain task ownership." }
    Set-Agent3Disposition $final $task.claimId repair-needed -Evidence @("fixture://fresh-review-request")
    $repair = Add-Agent3Handoff $final $task.claimId developer-1 repair -Feedback @("fixture://fresh-review-request")
    if ($repair.repairAttempt -ne 1 -or $task.claimId -cne $final.tasks[0].claimId) {
        throw "Human review repair must retain the claim and cumulative repair history."
    }

    $pending = New-Fixture
    $task = Add-Agent3Claim $pending 301 $evidence
    $handoff = Add-Agent3Handoff $pending $task.claimId developer-1 implement
    Complete-Implementation $pending $task $handoff
    Set-Agent3Disposition $pending $task.claimId finalize-ready -Evidence $evidence
    $finalizeEvidence = @("fixture://check", "fixture://review")
    $handoff = Add-Agent3Handoff $pending $task.claimId developer-2 finalize -Feedback $finalizeEvidence
    Start-Handoff $pending $task $handoff
    $null = Add-Agent3Event $pending (New-Event $task $handoff ack)
    $null = Add-Agent3Event $pending (New-Event $task $handoff result blocked)
    Set-Agent3Disposition $pending $task.claimId blocked -Evidence $evidence
    Set-Agent3Stage $pending $task.claimId $handoff.id stopped-verified -Evidence $evidence
    Set-Agent3Stage $pending $task.claimId $handoff.id reconciled -Evidence $evidence
    foreach ($field in @("head", "checkpoint")) {
        $bad = Copy-Record $pending
        $bad.tasks[0][$field] = $(if ($field -ceq "head") { "e" * 40 } else { "fixture://different-checkpoint" })
        Assert-Throws {
            Set-Agent3Disposition $bad $task.claimId validation -Evidence @("fixture://new-validation-observation")
        } "*Invalid task disposition*"
    }
    Set-Agent3Disposition $pending $task.claimId validation -Evidence @("fixture://new-validation-observation")
    Set-Agent3Disposition $pending $task.claimId finalize-ready -Evidence @("fixture://new-validation-observation")
    Assert-Throws {
        Add-Agent3Handoff $pending $task.claimId developer-1 finalize -Feedback $finalizeEvidence
    } "*Duplicate finalize*"
    Assert-Throws {
        Add-Agent3Handoff $pending $task.claimId developer-1 finalize `
            -Feedback @("fixture://review", "fixture://check", "fixture://review")
    } "*Duplicate finalize*"
    if ($task.handoffs.Count -ne 2) { throw "Equivalent evidence must not reserve another finalizer." }
    $null = Add-Agent3Handoff $pending $task.claimId developer-1 finalize -Feedback @("fixture://new-validation-observation")

    $failedRepair = New-Fixture
    $task = Add-Agent3Claim $failedRepair 302 $evidence
    $handoff = Add-Agent3Handoff $failedRepair $task.claimId developer-1 implement
    Complete-Implementation $failedRepair $task $handoff
    Set-Agent3Disposition $failedRepair $task.claimId repair-needed -Evidence $evidence
    $handoff = Add-Agent3Handoff $failedRepair $task.claimId developer-2 repair -Feedback $evidence
    Start-Handoff $failedRepair $task $handoff
    $null = Add-Agent3Event $failedRepair (New-Event $task $handoff ack)
    $failedResult = New-Event $task $handoff result blocked
    $failedResult.result.head = "b" * 40
    $null = Add-Agent3Event $failedRepair $failedResult
    Set-Agent3Stage $failedRepair $task.claimId $handoff.id stopped-verified -Evidence $evidence
    Set-Agent3Disposition $failedRepair $task.claimId blocked -Evidence $evidence
    Set-Agent3Stage $failedRepair $task.claimId $handoff.id reconciled -Evidence $evidence
    Assert-Throws { Set-Agent3Disposition $failedRepair $task.claimId validation -Evidence $evidence } "*Invalid task disposition*"
    if ($task.state -cne "blocked") { throw "Failed coding repair must not reuse historical implementation evidence." }

    $promoted = New-Fixture
    $task = Add-Agent3Claim $promoted 303 $evidence
    $handoff = Add-Agent3Handoff $promoted $task.claimId developer-1 implement
    Start-Handoff $promoted $task $handoff
    $null = Add-Agent3Event $promoted (New-Event $task $handoff ack)
    $initialResult = New-Event $task $handoff result
    $null = Publish-Agent3Event $initialResult (Join-Path $root "promotion")
    if ($null -ne $task.head -or $null -ne $task.checkpoint) { throw "Publication must not promote task evidence." }
    $null = Add-Agent3Event $promoted $initialResult
    if ($task.head -cne $initialResult.result.head -or $task.checkpoint -cne $initialResult.result.checkpoint -or
        (Get-Agent3Capacity $promoted).occupiedWorkers.Count -ne 1) {
        throw "Ingestion must promote evidence without releasing execution."
    }
    Set-Agent3Stage $promoted $task.claimId $handoff.id stopped-verified -Evidence $evidence
    $task.branch = "task-branch"; $task.worktree = Join-Path $root "promotion-worktree"; $task.pr = "fixture://pr"
    Set-Agent3Disposition $promoted $task.claimId validation -Evidence $evidence
    Set-Agent3Stage $promoted $task.claimId $handoff.id reconciled -Evidence $evidence
    Set-Agent3Disposition $promoted $task.claimId repair-needed -Evidence $evidence
    $handoff = Add-Agent3Handoff $promoted $task.claimId developer-2 repair -Feedback $evidence
    Start-Handoff $promoted $task $handoff
    $null = Add-Agent3Event $promoted (New-Event $task $handoff ack)
    $newResult = New-Event $task $handoff result
    $newResult.result.head = "c" * 40
    $newResult.result.checkpoint = "fixture://new-checkpoint"
    $null = Add-Agent3Event $promoted $newResult
    $null = Add-Agent3Event $promoted $initialResult
    if ($task.head -cne $newResult.result.head -or $task.checkpoint -cne $newResult.result.checkpoint) {
        throw "Historical duplicate must not roll task evidence back."
    }
    Set-Agent3Stage $promoted $task.claimId $handoff.id stopped-verified -Evidence $evidence
    Set-Agent3Disposition $promoted $task.claimId validation -Evidence $evidence
    Set-Agent3Stage $promoted $task.claimId $handoff.id reconciled -Evidence $evidence
    Set-Agent3Disposition $promoted $task.claimId finalize-ready -Evidence $evidence
    $handoff = Add-Agent3Handoff $promoted $task.claimId developer-1 finalize -Feedback $evidence
    Start-Handoff $promoted $task $handoff
    $assignment = Get-Agent3Assignment $promoted $task.claimId $handoff.id
    if ($assignment.expectedHead -cne $newResult.result.head -or $assignment.checkpoint -cne $newResult.result.checkpoint) {
        throw "Finalizer must receive the latest ingested checkpoint."
    }

    $preclaim = New-Fixture
    $task = Add-Agent3Claim $preclaim 304 $evidence
    Set-Agent3Disposition $preclaim $task.claimId blocked -Evidence @("fixture://pre-handoff-blocker")
    Assert-Throws { Add-Agent3Claim $preclaim 305 $evidence } "*No implementation capacity*"
    Set-Agent3Disposition $preclaim $task.claimId blocked -Evidence $evidence `
        -IndependentEvidence @("fixture://verified-independent-scope")
    $other = Add-Agent3Claim $preclaim 305 $evidence
    $null = Add-Agent3Handoff $preclaim $other.claimId developer-2 implement
    if ($task.state -cne "blocked" -or $task.handoffs.Count -ne 0 -or $preclaim.tasks.Count -ne 2) {
        throw "Independent blocked pre-handoff claim must retain ownership without freezing other work."
    }

    $backlog = New-Fixture
    $blockedTasks = @()
    foreach ($issue in @(306, 307)) {
        $task = Add-Agent3Claim $backlog $issue $evidence
        $handoff = Add-Agent3Handoff $backlog $task.claimId developer-1 implement
        Complete-Implementation $backlog $task $handoff
        Set-Agent3Disposition $backlog $task.claimId blocked -Evidence $evidence
        $blockedTasks += $task
    }
    $runningTasks = @()
    foreach ($worker in @("developer-1", "developer-2")) {
        $task = Add-Agent3Claim $backlog (308 + $runningTasks.Count) $evidence
        $handoff = Add-Agent3Handoff $backlog $task.claimId $worker implement
        $runningTasks += $task
    }
    foreach ($task in $blockedTasks) {
        Assert-Throws { Set-Agent3Disposition $backlog $task.claimId validation -Evidence $evidence } "*reserved for outstanding*"
    }
    foreach ($task in $runningTasks) { Complete-Implementation $backlog $task $task.handoffs[-1] }
    if ((Get-Agent3Capacity $backlog).freeWorkers.Count -ne 2 -or
        (Get-Agent3Capacity $backlog).validationPending -ne 2) {
        throw "Four-task recovery must leave workers free to drain the bounded backlog."
    }
    $task = $runningTasks[0]
    Set-Agent3Disposition $backlog $task.claimId finalize-ready -Evidence $evidence
    $handoff = Add-Agent3Handoff $backlog $task.claimId developer-1 finalize -Feedback $evidence
    Start-Handoff $backlog $task $handoff
    $null = Add-Agent3Event $backlog (New-Event $task $handoff ack)
    $null = Add-Agent3Event $backlog (New-Event $task $handoff result blocked)
    Set-Agent3Stage $backlog $task.claimId $handoff.id stopped-verified -Evidence $evidence
    Set-Agent3Disposition $backlog $task.claimId blocked -Evidence $evidence
    Set-Agent3Stage $backlog $task.claimId $handoff.id reconciled -Evidence $evidence
    Set-Agent3Disposition $backlog $blockedTasks[0].claimId validation -Evidence $evidence

    $stopped = New-Fixture
    $task = Add-Agent3Claim $stopped 400 $evidence
    $handoff = Add-Agent3Handoff $stopped $task.claimId developer-1 implement
    Start-Handoff $stopped $task $handoff
    $null = Add-Agent3Event $stopped (New-Event $task $handoff result blocked-before-start)
    Set-Agent3Disposition $stopped $task.claimId blocked -Evidence $evidence
    Set-Agent3Stage $stopped $task.claimId $handoff.id stopped-verified -Evidence $evidence
    Set-Agent3Stage $stopped $task.claimId $handoff.id reconciled -Evidence $evidence
    Assert-Throws { Add-Agent3Handoff $stopped $task.claimId developer-1 implement } "*already assigned*"
    Resolve-Agent3Handoff $stopped $task.claimId $handoff.id pre-start-rejected `
        -HumanAuthorization "fixture://explicit-recovery-and-restart" -Evidence $evidence -RestartImplementation
    $replacement = Add-Agent3Handoff $stopped $task.claimId developer-1 implement
    if ($replacement.id -ceq $handoff.id -or $task.handoffs.Count -ne 2 -or $task.repairCount -ne 0) {
        throw "Replacement must retain the rejected handoff and reserve a new identity without consuming repairs."
    }
    Assert-Agent3State $stopped
    $bad = Copy-Record $stopped
    $bad.tasks[0].handoffs[0].recovery.restartImplementation = $false
    Assert-Throws { Assert-Agent3State $bad } "*Replacement implementation requires*"
    Assert-Throws { Add-Agent3Event $stopped (New-Event $task $handoff ack) } "*acknowledgment stage*"
    Set-Agent3Disposition $stopped $task.claimId blocked -Evidence $evidence
    Resolve-Agent3Handoff $stopped $task.claimId $replacement.id no-launch `
        -HumanAuthorization "fixture://verified-never-launched" -Evidence $evidence
    $other = Add-Agent3Claim $stopped 401 $evidence
    $null = Add-Agent3Handoff $stopped $other.claimId developer-2 implement
    if ($task.state -ne "blocked") { throw "Isolated blocked task must retain its claim." }

    $automatic = New-Fixture
    $task = Add-Agent3Claim $automatic 402 $evidence
    $directory = Join-Path $root "automatic-recovery"
    foreach ($attempt in 1..3) {
        $handoff = Add-Agent3Handoff $automatic $task.claimId developer-1 implement
        $diagnostic = Reject-MessageHandoff $automatic $task $handoff $directory
        $parameters = @{ State = $automatic; ClaimId = $task.claimId; HandoffId = $handoff.id
            Directory = $directory; DiagnosticPath = $diagnostic; Authorization = $automatic.authorization
            ExpectedHead = $task.head; Evidence = @("fixture://fresh-stopped-authority-context-and-label-checks") }
        if ($attempt -eq 1) {
            $bad = @{} + $parameters; $bad.ExpectedHead = $head
            Assert-Throws { Repair-Agent3RejectedHandoff @bad } "*unchanged verified authority*"
            $bad = @{} + $parameters; $bad.Authorization = @{ reference = "changed"; implementation = $true; merge = $true }
            Assert-Throws { Repair-Agent3RejectedHandoff @bad } "*unchanged verified authority*"
            $badState = Copy-Record $automatic
            $badState.tasks[0].handoffs[0].stage = "result-recorded"
            $badState.tasks[0].handoffs[0].transitions = @($badState.tasks[0].handoffs[0].transitions | Where-Object stage -CNE "stopped-verified")
            $bad = @{} + $parameters; $bad.State = $badState
            Assert-Throws { Repair-Agent3RejectedHandoff @bad } "*latest verified stopped*"
            $ackPath = Join-Path $directory "events\ack-$($handoff.id).json"
            $null = Publish-Agent3Event (New-Event $task $handoff ack) (Join-Path $directory "events")
            Assert-Throws { Repair-Agent3RejectedHandoff @parameters } "*Canonical acknowledgment exists*"
            [IO.File]::Delete($ackPath)
            $unrelated = Read-Agent3Json $diagnostic
            $unrelated.recipient.sessionId = "unrelated-session"
            $unrelatedPath = Join-Path $directory "diagnostics\unrelated.json"
            $unrelated.id = & $module { param($d) Get-Agent3Hash @{rawHash=$d.rawHash;sender=$d.sender;recipient=$d.recipient} } $unrelated
            $unrelatedPath = Join-Path $directory "diagnostics\$($unrelated.id).json"
            $unrelated | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $unrelatedPath
            $bad = @{} + $parameters; $bad.DiagnosticPath = $unrelatedPath
            Assert-Throws { Repair-Agent3RejectedHandoff @bad } "*actual rejected worker*"
            $unrelated.recipient.sessionId = $handoff.sessionId
            $unrelated.rawHash = "B" * 64
            $unrelated.id = & $module { param($d) Get-Agent3Hash @{rawHash=$d.rawHash;sender=$d.sender;recipient=$d.recipient} } $unrelated
            $unrelatedPath = Join-Path $directory "diagnostics\$($unrelated.id).json"
            $bad.DiagnosticPath = $unrelatedPath
            $unrelated.code = "authority-mismatch"
            $unrelated | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $unrelatedPath
            Assert-Throws { Repair-Agent3RejectedHandoff @bad } "*canonical recoverable message diagnostic*"
            $unrelated.code = "identity-mismatch"
            $unrelated | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $unrelatedPath
            Assert-Throws { Repair-Agent3RejectedHandoff @bad } "*must reference its protocol diagnostic*"
            $truncated = Copy-Record (Read-Agent3Json $diagnostic)
            $truncated.Remove("rawHash")
            $truncated | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $unrelatedPath
            Assert-Throws { Repair-Agent3RejectedHandoff @bad } "*Missing field 'rawHash'*"
            $truncated = Copy-Record (Read-Agent3Json $diagnostic)
            $truncated.id = "arbitrary"
            $truncated | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $unrelatedPath
            Assert-Throws { Repair-Agent3RejectedHandoff @bad } "*canonical diagnostic identity*"
            Assert-Throws {
                Resolve-Agent3Handoff $automatic $task.claimId $handoff.id pre-start-rejected `
                    -HumanAuthorization "policy://agent3/pre-start-message-recovery-v1" -Evidence $evidence -RestartImplementation
            } "*not human authorization*"
        }
        if ($attempt -le 2) {
            if ((Repair-Agent3RejectedHandoff @parameters) -cne "applied" -or
                (Repair-Agent3RejectedHandoff @parameters) -cne "duplicate" -or
                $handoff.stage -cne "reconciled" -or $task.repairCount -ne 0 -or $task.state -cne "blocked") {
                throw "Automatic rejection recovery must be bounded, idempotent and retain task ownership/history."
            }
            Assert-Throws { Add-Agent3Event $automatic (New-Event $task $handoff ack) } "*acknowledgment stage*"
            if ($attempt -eq 1) {
                $resumed = New-Agent3DispatchBatch $automatic `
                    @(New-DispatchCandidate 402 implement $task.claimId; New-DispatchCandidate 407) {
                        param($candidate, $snapshot, $worker)
                        @{ eligible = $true; compatible = $true; reason = "fresh-recovery-and-independent-scope"; evidence = $evidence }
                    }
                if ($resumed.reservations.Count -ne 2 -or $resumed.reservations[0].claimId -cne $task.claimId -or
                    $resumed.state.tasks[0].handoffs.Count -ne 2 -or $task.handoffs.Count -ne 1) {
                    throw "Batch must resume a permitted unstarted initial handoff under the same claim without mutating its input."
                }
                $advanced = $resumed.state
                $advanced.tasks[0].head = $head
                $parameters.State = $advanced
                if ((Repair-Agent3RejectedHandoff @parameters) -cne "duplicate") {
                    throw "Retained recovery must remain a no-op after replacement and head advancement."
                }
                $parameters.State = $automatic
            }
        } else {
            Assert-Throws { Repair-Agent3RejectedHandoff @parameters } "*allowance exhausted*"
            if ($handoff.stage -cne "stopped-verified" -or (Get-Agent3Capacity $automatic).freeWorkers -ccontains "developer-1") {
                throw "Exhaustion must retain the affected reservation for human action."
            }
        }
    }
    $isolated = New-Agent3DispatchBatch $automatic @(New-DispatchCandidate 407) {
        param($candidate, $snapshot, $worker)
        @{ eligible = $true; compatible = $true; reason = "verified-independent-of-exhausted-rejection"; evidence = $evidence }
    }
    if ($isolated.reservations.Count -ne 1 -or $isolated.reservations[0].workerId -cne "developer-2") {
        throw "A blocked exhausted rejection cannot veto independently verified work for the other Developer."
    }

    $repairRecovery = New-Fixture
    $task = Add-Agent3Claim $repairRecovery 405 $evidence
    $initial = Add-Agent3Handoff $repairRecovery $task.claimId developer-1 implement
    Complete-Implementation $repairRecovery $task $initial
    Set-Agent3Disposition $repairRecovery $task.claimId repair-needed -Evidence $evidence
    $handoff = Add-Agent3Handoff $repairRecovery $task.claimId developer-1 repair -Feedback $evidence
    $directory = Join-Path $root "repair-recovery"
    $diagnostic = Reject-MessageHandoff $repairRecovery $task $handoff $directory
    $null = Repair-Agent3RejectedHandoff $repairRecovery $task.claimId $handoff.id $directory $diagnostic `
        $repairRecovery.authorization $task.head $evidence
    Set-Agent3Disposition $repairRecovery $task.claimId repair-needed -Evidence $evidence
    $nextRepair = Add-Agent3Handoff $repairRecovery $task.claimId developer-2 repair `
        -Feedback $evidence -PriorRepairEvidence $evidence
    if ($nextRepair.repairAttempt -ne 2 -or $task.repairCount -ne 2 -or $task.handoffs.Count -ne 3 -or
        $nextRepair.expectedHead -cne $head -or $task.branch -cne "task-branch") {
        throw "Rejected repair recovery must retain context/counts and reserve the next cumulative repair."
    }

    $batchState = New-Fixture
    $candidates = @(New-DispatchCandidate 600; New-DispatchCandidate 601; New-DispatchCandidate 602)
    $assess = {
        param($candidate, $snapshot, $worker)
        @{ eligible = $true; compatible = ($candidate.issue -ne 600)
            reason = $(if ($candidate.issue -eq 600) { "verified-overlap" } else { "verified-independent" })
            evidence = $evidence }
    }
    $batch = New-Agent3DispatchBatch $batchState $candidates $assess
    if ($batchState.tasks.Count -ne 0 -or $batchState.revision -ne 1 -or
        $batch.reservations.Count -ne 2 -or $batch.state.revision -ne 2 -or $batch.expectedRevision -ne 1 -or
        (@($batch.reservations.issue) -join ",") -cne "601,602" -or $batch.idleWorkers.Count -ne 0 -or
        @($batch.state.tasks.handoffs | Where-Object stage -CNE "launch-requested").Count -ne 0) {
        throw "Batch must skip the conflicting head and reserve both independent tasks before either launch."
    }
    $firstTask = $batch.state.tasks[0]; $firstHandoff = $firstTask.handoffs[0]
    Set-Agent3Disposition $batch.state $firstTask.claimId blocked -Evidence @("fixture://uncertain-first-launch")
    $secondTask = $batch.state.tasks[1]; $secondHandoff = $secondTask.handoffs[0]
    Set-Agent3Stage $batch.state $secondTask.claimId $secondHandoff.id correlated `
        -RunId independent-run -SessionId independent-session -Evidence $evidence
    if ((Get-Agent3Capacity $batch.state).occupiedWorkers.Count -ne 2 -or
        $firstHandoff.stage -cne "launch-requested" -or $secondHandoff.stage -cne "correlated") {
        throw "An uncertain first launch must retain its reservation without cancelling the independently safe second."
    }

    $mutual = New-Agent3DispatchBatch (New-Fixture) $candidates {
        param($candidate, $snapshot, $worker)
        @{ eligible = $true; compatible = ($snapshot.tasks.Count -eq 0)
            reason = "pairwise-scope-assessment"; evidence = $evidence }
    }
    if ($mutual.reservations.Count -ne 1 -or $mutual.idleWorkers.Count -ne 1 -or $mutual.skipped.Count -eq 0) {
        throw "Second assessment must see the first reservation and reject incompatible pairs."
    }
    $ineligible = New-Agent3DispatchBatch (New-Fixture) $candidates {
        param($candidate, $snapshot, $worker)
        @{ eligible = $false; compatible = $true; reason = "undelivered-dependency-or-explicit-order"; evidence = $evidence }
    }
    if ($ineligible.reservations.Count -ne 0 -or $ineligible.state.revision -ne 1) {
        throw "Batch must not bypass eligibility or publish an empty revision."
    }
    $unchanged = New-Fixture
    Assert-Throws {
        New-Agent3DispatchBatch $unchanged $candidates {
            param($candidate, $snapshot, $worker)
            if ($snapshot.tasks.Count -gt 0) { throw "Required scope evidence unavailable." }
            @{ eligible = $true; compatible = $true; reason = "independent"; evidence = $evidence }
        }
    } "*scope evidence unavailable*"
    if ($unchanged.tasks.Count -ne 0) { throw "Failed planning cannot leak a partial reservation into the input state." }
    $onlySecond = New-Fixture
    $held = Add-Agent3Claim $onlySecond 603 $evidence
    $null = Add-Agent3Handoff $onlySecond $held.claimId developer-1 implement
    $batch = New-Agent3DispatchBatch $onlySecond @(New-DispatchCandidate 604) $assess
    if ($batch.reservations.Count -ne 1 -or $batch.reservations[0].workerId -cne "developer-2") {
        throw "A retained Developer 1 reservation must not prevent safe selection for Developer 2."
    }
    $priority = New-Fixture
    $task = Add-Agent3Claim $priority 605 $evidence
    $handoff = Add-Agent3Handoff $priority $task.claimId developer-1 implement
    Complete-Implementation $priority $task $handoff
    Set-Agent3Disposition $priority $task.claimId repair-needed -Evidence $evidence
    $batch = New-Agent3DispatchBatch $priority @(New-DispatchCandidate 606; New-DispatchCandidate 605 repair $task.claimId) $assess
    if ($batch.reservations[0].action -cne "repair" -or $batch.reservations.Count -ne 2) {
        throw "Eligible repair must precede new implementation without suppressing the second worker."
    }
    $unassigned = New-Fixture
    $own = Add-Agent3Claim $unassigned 610 $evidence
    $batch = New-Agent3DispatchBatch $unassigned @(New-DispatchCandidate 610 implement $own.claimId) $assess
    if ($batch.reservations.Count -ne 1 -or $batch.reservations[0].claimId -cne $own.claimId) {
        throw "An existing unassigned claim cannot block its own admission."
    }
    $otherClaim = Add-Agent3Claim (New-Fixture) 614 $evidence
    $unassigned.tasks += $otherClaim
    Assert-Agent3State $unassigned
    $batch = New-Agent3DispatchBatch $unassigned @(New-DispatchCandidate 610 implement $own.claimId) $assess
    if ($batch.reservations.Count -ne 0) { throw "Another unassigned claim must still block admission." }
    $asymmetric = New-Fixture
    $retained = @()
    foreach ($number in 611,612) {
        $t = Add-Agent3Claim $asymmetric $number $evidence
        $h = Add-Agent3Handoff $asymmetric $t.claimId developer-1 implement
        Complete-Implementation $asymmetric $t $h
        Set-Agent3Disposition $asymmetric $t.claimId repair-needed -Evidence $evidence
        $retained += New-DispatchCandidate $number repair $t.claimId
    }
    $batch = New-Agent3DispatchBatch $asymmetric $retained {
        param($candidate, $snapshot, $worker)
        @{ eligible = $true; compatible = ($candidate.issue -eq 611 -or $worker -ceq "developer-1")
            reason = "verified-context-reuse"; evidence = $evidence }
    }
    if ($batch.reservations.Count -ne 2 -or $batch.reservations[0].workerId -cne "developer-2" -or
        $batch.reservations[1].workerId -cne "developer-1") {
        throw "Flexible repair must use Developer 2 so the context-constrained repair can use Developer 1."
    }
    $alreadyStarted = New-Fixture
    $t = Add-Agent3Claim $alreadyStarted 613 $evidence
    $h = Add-Agent3Handoff $alreadyStarted $t.claimId developer-1 implement
    Start-Handoff $alreadyStarted $t $h
    $event = New-Event $t $h result blocked-before-start
    $ackDirectory = Join-Path $root "already-started"
    $null = Publish-Agent3Event (New-Event $t $h ack) $ackDirectory
    Assert-Throws {
        Publish-Agent3PreStartRejection $alreadyStarted $event developer-1 $h.runId $h.sessionId $ackDirectory
    } "*Canonical acknowledgment/result exists*"
    $null = Add-Agent3Event $alreadyStarted (New-Event $t $h ack)
    Assert-Throws {
        Publish-Agent3PreStartRejection $alreadyStarted $event developer-1 $h.runId $h.sessionId $ackDirectory
    } "*actual unacknowledged*"
    if (Test-Path -LiteralPath (Join-Path $ackDirectory "result-$($h.id).json")) {
        throw "False pre-start rejection must not consume the actual result slot."
    }

    foreach ($stage in @("prepared", "launch-requested", "correlated", "delivered", "acknowledged")) {
        $recovered = New-Fixture
        $task = Add-Agent3Claim $recovered 403 $evidence
        $handoff = Add-Agent3Handoff $recovered $task.claimId developer-1 implement
        if ($stage -cne "prepared") {
            Set-Agent3Stage $recovered $task.claimId $handoff.id launch-requested -Evidence $evidence
        }
        if ($stage -cin @("correlated", "delivered", "acknowledged")) {
            Set-Agent3Stage $recovered $task.claimId $handoff.id correlated -Evidence $evidence -RunId actual-run -SessionId actual-session
        }
        if ($stage -cin @("delivered", "acknowledged")) {
            Set-Agent3Stage $recovered $task.claimId $handoff.id delivered -Evidence $evidence
        }
        if ($stage -ceq "acknowledged") { $null = Add-Agent3Event $recovered (New-Event $task $handoff ack) }
        $mode = if ($stage -cin @("prepared", "launch-requested")) { "no-launch" } else { "stopped" }
        Assert-Throws {
            Resolve-Agent3Handoff $recovered $task.claimId $handoff.id $mode -Evidence $evidence
        } "*human recovery authorization*"
        if ($stage -cin @("correlated", "delivered", "acknowledged")) {
            Assert-Throws {
                Resolve-Agent3Handoff $recovered $task.claimId $handoff.id no-launch `
                    -HumanAuthorization "fixture://approval" -Evidence $evidence
            } "*No-launch recovery requires*"
            Assert-Throws {
                Resolve-Agent3Handoff $recovered $task.claimId $handoff.id stopped `
                    -HumanAuthorization "fixture://approval" -Evidence $evidence -RestartImplementation
            } "*Only a verified unstarted*"
        }
        Resolve-Agent3Handoff $recovered $task.claimId $handoff.id $mode `
            -HumanAuthorization "fixture://human-reviewed-host-evidence" -Evidence $evidence
        if ((Get-Agent3Capacity $recovered).freeWorkers.Count -ne 2 -or $null -ne $handoff.result -or
            $null -ne $handoff.resultEventId -or $task.state -cne "blocked") {
            throw "Human recovery must free execution without inventing a worker result or releasing ownership."
        }
        Assert-Throws {
            Resolve-Agent3Handoff $recovered $task.claimId $handoff.id $mode `
                -HumanAuthorization "fixture://approval" -Evidence $evidence
        } "*recovered once*"
        if ($stage -cin @("correlated", "delivered", "acknowledged")) {
            Assert-Throws { Add-Agent3Event $recovered (New-Event $task $handoff result) } "*requires acknowledgment*"
        }
        Assert-Throws { Add-Agent3Handoff $recovered $task.claimId developer-1 implement } "*already assigned*"
    }

    foreach ($blockedFinalizer in @($false, $true)) {
        $human = New-Fixture
        $task = Add-Agent3Claim $human 404 $evidence
        $handoff = Add-Agent3Handoff $human $task.claimId developer-1 implement
        Complete-Implementation $human $task $handoff
        if ($blockedFinalizer) {
            Set-Agent3Disposition $human $task.claimId finalize-ready -Evidence $evidence
            $handoff = Add-Agent3Handoff $human $task.claimId developer-2 finalize -Feedback $evidence
            Start-Handoff $human $task $handoff
            $null = Add-Agent3Event $human (New-Event $task $handoff ack)
            Assert-Throws { Add-Agent3Event $human (New-Event $task $handoff result delivered) } "*not authorized*"
            $null = Add-Agent3Event $human (New-Event $task $handoff result blocked)
            Set-Agent3Disposition $human $task.claimId blocked -Evidence $evidence
            Set-Agent3Stage $human $task.claimId $handoff.id stopped-verified -Evidence $evidence
        }
        $delivery = @{ head = "d" * 40; targetBranch = "main"
            evidence = @("fixture://human-merge-verified-on-main"); cleanupEvidence = @("fixture://cleanup-verified") }
        if ($blockedFinalizer) {
            Assert-Throws {
                Set-Agent3Disposition $human $task.claimId delivered -Evidence $evidence -HumanDelivery $delivery
            } "*Invalid task disposition*"
            Set-Agent3Stage $human $task.claimId $handoff.id reconciled -Evidence $evidence
        }
        Assert-Throws { Set-Agent3Disposition $human $task.claimId delivered -Evidence $evidence } "*Invalid task disposition*"
        $badDelivery = Copy-Record $delivery; $badDelivery.targetBranch = "other"
        Assert-Throws {
            Set-Agent3Disposition $human $task.claimId delivered -Evidence $evidence -HumanDelivery $badDelivery
        } "*configured target branch*"
        $badDelivery = Copy-Record $delivery; $badDelivery.cleanupEvidence = @()
        Assert-Throws {
            Set-Agent3Disposition $human $task.claimId delivered -Evidence $evidence -HumanDelivery $badDelivery
        } "*Evidence references*"
        Set-Agent3Disposition $human $task.claimId delivered -Evidence $evidence -HumanDelivery $delivery
        if ($task.state -cne "delivered" -or $task.head -cne $delivery.head -or $human.authorization.merge) {
            throw "Human delivery must retain separate evidence without granting worker merge authority."
        }
    }

    $early = New-Fixture
    $task = Add-Agent3Claim $early 402 $evidence
    $handoff = Add-Agent3Handoff $early $task.claimId developer-1 implement
    Set-Agent3Stage $early $task.claimId $handoff.id launch-requested -Evidence $evidence
    Set-Agent3Stage $early $task.claimId $handoff.id correlated -Evidence $evidence -RunId actual-run -SessionId actual-session
    $assignment = Get-Agent3Assignment $early $task.claimId $handoff.id
    $earlyAck = Publish-Agent3Acknowledgment $early $assignment developer-1 actual-run actual-session `
        (Join-Path $root "early-ack") "actual-developer-1" -Evidence @("fixture://actual-assignment-message")
    $null = Add-Agent3Event $early $earlyAck
    if ($handoff.stage -ne "acknowledged" -or $handoff.transitions[-2].stage -ne "delivered") {
        throw "An early acknowledgment must reconcile proven delivery without skipping stages or restarting."
    }

    $eventDirectory = Join-Path $root "events"
    $publicationResult = New-Event $first $one result
    foreach ($mutate in @(
        { param($e) $e.elapsedSeconds = $null; $e.elapsed = 1.25 },
        { param($e) $e.elapsedSeconds = $null; $e["ElapsedSeconds"] = 1.25 },
        { param($e) $e.result.extra = $true },
        { param($e) $e.result.head = "bad" },
        { param($e) $e.result.head = $null },
        { param($e) $e.result.checkpoint = $null },
        { param($e) $e.result.checkpoint = "" },
        { param($e) $e.action = "finalize" },
        { param($e) $e.result.outcome = "pr-ready" },
        { param($e) $e.action = "unknown" }
    )) {
        $bad = Copy-Record $publicationResult
        & $mutate $bad
        Assert-Throws { Publish-Agent3Event $bad $eventDirectory } "*"
        if ([IO.File]::Exists((Join-Path $eventDirectory "$($publicationResult.eventId).json"))) {
            throw "Invalid result must not reserve its immutable event ID."
        }
    }
    $null = Publish-Agent3Event $publicationResult $eventDirectory
    $null = Publish-Agent3Event (Copy-Record $publicationResult) $eventDirectory
    $eventPath = Publish-Agent3Event $ack $eventDirectory
    $null = Publish-Agent3Event (Copy-Record $ack) $eventDirectory
    $bad = Copy-Record $ack; $bad.actor = "another"
    Assert-Throws { Publish-Agent3Event $bad $eventDirectory } "*Conflicting immutable*"
    Assert-Throws { Publish-Agent3Event @{ schema = "fingvibe-real-event-v1"; eventId = "partial" } $eventDirectory } "*Missing field*"
    [IO.File]::WriteAllText((Join-Path $eventDirectory "partial.json"), '{"schema":')
    Assert-Throws { Read-Agent3Json (Join-Path $eventDirectory "partial.json") } "*"
    Assert-Throws { Read-Agent3Json (Join-Path $root "missing.json") } "*Never infer idle*"

    $path = Join-Path $root "state.json"
    $gateRoot = Join-Path $root "gate"
    $owner = [guid]::NewGuid()
    $parameters = @{ Repository = "testowner/testrepo"; StateDirectory = $gateRoot; Owner = $owner }
    $null = & $gateScript -Action Acquire @parameters
    $published = New-Fixture
    Publish-Agent3State $published $path $owner 0 $gateRoot
    $published.revision = 2
    Publish-Agent3State $published $path $owner 1 $gateRoot
    Assert-Throws { Publish-Agent3State $published $path $owner 1 $gateRoot } "*Stale revision*"
    Assert-Throws { Publish-Agent3State $published $path ([guid]::NewGuid()) 2 $gateRoot } "*repository gate*"
    $published = Read-Agent3Json $path
    $published.revision++
    $task = Add-Agent3Claim $published 500 $evidence
    $handoff = Add-Agent3Handoff $published $task.claimId developer-1 implement
    Publish-Agent3State $published $path $owner 2 $gateRoot
    $bad = Copy-Record $published; $bad.revision++; $bad.tasks = @()
    Assert-Throws { Publish-Agent3State $bad $path $owner 3 $gateRoot } "*exactly one task*"
    $bad = Copy-Record $published; $bad.revision++; $bad.tasks[0].handoffs[0].transitions[0].evidence = @("rewritten")
    Assert-Throws { Publish-Agent3State $bad $path $owner 3 $gateRoot } "*Prior transition*"
    if ((Read-Agent3Json $path).revision -ne 3) { throw "Failed publication must leave previous valid state intact." }

    Complete-Implementation $published $task $handoff
    $published.reports = @(1..40 | ForEach-Object {
        @{ id = "report-$_"; claimId = $task.claimId; handoffId = $handoff.id; url = "fixture://report/$_"
            utc = [DateTime]::UtcNow.ToString("o"); nextOwner = "dispatcher"; nextAction = "validate" }
    })
    $published.revision++
    Publish-Agent3State $published $path $owner 3 $gateRoot
    $published.revision++
    & $module {
        param($s, $p, $o, $g)
        $original = ${function:Get-Agent3Hash}
        $script:reportHashCalls = 0
        try {
            function script:Get-Agent3Hash($Record) {
                if ($Record.Contains("url") -and $Record.Contains("handoffId")) { $script:reportHashCalls++ }
                & $original $Record
            }
            Publish-Agent3State $s $p $o 4 $g
            if ($script:reportHashCalls -ne 2 * $s.reports.Count) {
                throw "Retained reports must be hashed once per current/prior entry, not once per pair."
            }
        } finally {
            Set-Item Function:script:Get-Agent3Hash $original
            Remove-Variable reportHashCalls -Scope Script
        }
    } $published $path $owner $gateRoot
    foreach ($mutate in @(
        { param($s) $s.reports = @($s.reports | Select-Object -Skip 1) },
        { param($s) $s.reports[0].url = "fixture://altered" },
        { param($s) $s.reports += Copy-Record $s.reports[0] },
        { param($s) $s.events[0].hash = "changed" }
    )) {
        $bad = Copy-Record $published
        $bad.revision++
        & $mutate $bad
        Assert-Throws { Publish-Agent3State $bad $path $owner 5 $gateRoot } "*Prior * evidence cannot change or disappear*"
    }
    $bad = Copy-Record $published
    $bad.revision++
    $bad.events = @()
    $bad.tasks[0].handoffs = @()
    Assert-Throws { Publish-Agent3State $bad $path $owner 5 $gateRoot } "*exactly one handoff*"
    if ((Read-Agent3Json $path).revision -ne 5) { throw "Rejected history edits must preserve the published revision." }
    $recoveryTask = Add-Agent3Claim $published 501 $evidence
    $recoveryHandoff = Add-Agent3Handoff $published $recoveryTask.claimId developer-2 implement
    $published.revision++
    Publish-Agent3State $published $path $owner 5 $gateRoot
    Resolve-Agent3Handoff $published $recoveryTask.claimId $recoveryHandoff.id no-launch `
        -HumanAuthorization "fixture://explicit-recovery" -Evidence $evidence -RestartImplementation
    $published.revision++
    Publish-Agent3State $published $path $owner 6 $gateRoot
    $bad = Copy-Record $published; $bad.revision++
    $bad.tasks[1].handoffs[0].recovery.authorization = "rewritten"
    Assert-Throws { Publish-Agent3State $bad $path $owner 7 $gateRoot } "*Human recovery evidence cannot change*"
    $replacement = Add-Agent3Handoff $published $recoveryTask.claimId developer-2 implement
    $published.revision++
    Publish-Agent3State $published $path $owner 7 $gateRoot
    if ((Read-Agent3Json $path).tasks[1].handoffs.Count -ne 2) {
        throw "Recovered and replacement handoffs must survive revision publication."
    }
    $batchPath = Join-Path $root "batch-state.json"
    $empty = New-Fixture
    Publish-Agent3State $empty $batchPath $owner 0 $gateRoot
    $batch = New-Agent3DispatchBatch (Read-Agent3Json $batchPath) $candidates $assess
    Publish-Agent3State $batch.state $batchPath $owner $batch.expectedRevision $gateRoot
    $durableBatch = Read-Agent3Json $batchPath
    if ($durableBatch.revision -ne 2 -or $durableBatch.tasks.Count -ne 2 -or
        @($durableBatch.tasks.handoffs | Where-Object stage -CNE "launch-requested").Count -ne 0) {
        throw "Both launch intents must survive one guarded state publication before either worker starts."
    }
    Assert-Throws {
        Publish-Agent3State $batch.state $batchPath $owner $batch.expectedRevision $gateRoot
    } "*Stale revision*"
    $automaticPath = Join-Path $root "recovered-state.json"
    Publish-Agent3State $repairRecovery $automaticPath $owner 0 $gateRoot
    $bad = Read-Agent3Json $automaticPath
    $bad.revision++
    $bad.tasks[0].handoffs[1].recovery.authorization = "rewritten-policy"
    Assert-Throws { Publish-Agent3State $bad $automaticPath $owner 1 $gateRoot } "*Human recovery evidence cannot change*"
    $null = & $gateScript -Action Release @parameters

    $incidents = Join-Path $root "incidents"
    $null = [IO.Directory]::CreateDirectory($incidents)
    $incident = @{ id = "human-reported"; originalReporter = "human"; recordingActor = "dispatcher"
        changedUtc = [DateTime]::UtcNow.ToString("o"); nextOwner = "human"; nextAction = "inspect"; evidence = $evidence }
    [IO.File]::WriteAllText((Join-Path $incidents "unindexed.json"), ($incident | ConvertTo-Json))
    Sync-Agent3Incidents $published $incidents
    if ($published.incidents.Count -ne 1 -or $published.incidents[0].id -ne "human-reported") {
        throw "Incident discovery must not depend on index completeness."
    }
    [IO.File]::Delete((Join-Path $incidents "unindexed.json"))
    Assert-Throws { Sync-Agent3Incidents $published $incidents } "*Previously indexed incident is missing*"
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
Write-Output "Agent 3 coordination tests passed."
