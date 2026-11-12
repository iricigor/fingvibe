$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "..\.github\scripts\RealTaskCoordination.psm1") -Force
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
    New-RealTaskState -Repository "TestOwner/TestRepo" -Epic 92 -TargetBranch main `
        -Authorization @{ reference = "fixture://human-approval"; implementation = $true; merge = $false } `
        -Workers @(@{ id = "developer-1"; name = "Developer 1"; automationId = "automation-1" },
            @{ id = "developer-2"; name = "Developer 2"; automationId = "automation-2" })
}

function Start-Handoff($State, $Task, $Handoff) {
    Set-RealTaskStage $State $Task.claimId $Handoff.id launch-requested -Evidence $evidence
    Set-RealTaskStage $State $Task.claimId $Handoff.id correlated -Evidence $evidence `
        -RunId ("run-" + $Handoff.id) -SessionId ("session-" + $Handoff.id)
    Set-RealTaskStage $State $Task.claimId $Handoff.id delivered -Evidence $evidence
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
    $null = Add-RealTaskEvent $State (New-Event $Task $Handoff ack)
    $null = Add-RealTaskEvent $State (New-Event $Task $Handoff result)
    Set-RealTaskStage $State $Task.claimId $Handoff.id stopped-verified -Evidence @("fixture://actual-session-stopped")
    $Task.branch = "task-branch"; $Task.worktree = Join-Path $root "task-worktree"
    $Task.pr = "fixture://pr"; $Task.head = $head; $Task.checkpoint = "fixture://checkpoint"
    Set-RealTaskDisposition $State $Task.claimId validation -Evidence $evidence
    Set-RealTaskStage $State $Task.claimId $Handoff.id reconciled -Evidence $evidence
}

try {
    $state = New-Fixture
    $first = Add-RealTaskClaim $state 100 $evidence
    $one = Add-RealTaskHandoff $state $first.claimId developer-1 implement
    Assert-Throws { Add-RealTaskHandoff $state $first.claimId developer-2 implement } "*unavailable*"
    $second = Add-RealTaskClaim $state 101 $evidence
    Assert-Throws { Add-RealTaskHandoff $state $second.claimId developer-1 implement } "*unavailable*"
    $two = Add-RealTaskHandoff $state $second.claimId developer-2 implement
    if ((Get-RealTaskCapacity $state).occupiedWorkers.Count -ne 2) { throw "Both independent workers must be occupied." }
    Assert-Throws { Set-RealTaskStage $state $first.claimId $one.id correlated -Evidence $evidence } "*Invalid stage*"
    Start-Handoff $state $first $one
    $assignment = Get-RealTaskAssignment $state $first.claimId $one.id
    Assert-RealTaskAssignment $state $assignment developer-1 $one.runId $one.sessionId
    $reservation = Publish-RealTaskAcknowledgment $state $assignment developer-1 $one.runId $one.sessionId `
        (Join-Path $root "reservation") "actual-developer-1" -Evidence $evidence
    Assert-Throws {
        Publish-RealTaskAcknowledgment $state $assignment developer-1 $one.runId $one.sessionId `
            (Join-Path $root "reservation") "actual-developer-1" -Evidence $evidence
    } "*already acknowledged*"
    $bad = Copy-Record $assignment; $bad.action = "finalize"
    Assert-Throws { Assert-RealTaskAssignment $state $bad developer-1 $one.runId $one.sessionId } "*Invalid/stale*"
    Assert-Throws { Assert-RealTaskAssignment $state $assignment developer-1 $one.runId $one.runId } "*mismatch*"
    $ack = New-Event $first $one ack
    $bad = Copy-Record $ack; $bad.Remove("elapsedSeconds"); $bad.elapsed = 1.25
    Assert-Throws { Add-RealTaskEvent $state $bad } "*Missing field 'elapsedSeconds'*"
    $bad = Copy-Record $ack; $bad.Remove("elapsedSeconds"); $bad.ElapsedSeconds = 1.25
    Assert-Throws { Add-RealTaskEvent $state $bad } "*Missing field 'elapsedSeconds'*"
    $bad = Copy-Record $ack; $bad.utc = "2026-11-11T12:00:00"
    Assert-Throws { Add-RealTaskEvent $state $bad } "*explicit UTC*"
    $bad = Copy-Record $ack; $bad.elapsedSeconds = -1
    Assert-Throws { Add-RealTaskEvent $state $bad } "*nonnegative*"
    $bad = Copy-Record $ack; $bad.sessionId = "bare-automation-run"
    Assert-Throws { Add-RealTaskEvent $state $bad } "*correlation mismatch*"
    if ((Add-RealTaskEvent $state $ack) -ne "applied" -or
        (Add-RealTaskEvent $state (Copy-Record $ack)) -ne "duplicate") { throw "Event idempotency failed." }
    $bad = Copy-Record $ack; $bad.actor = "different-recorder"
    Assert-Throws { Add-RealTaskEvent $state $bad } "*Conflicting duplicate*"
    Assert-Throws { Assert-RealTaskAssignment $state $assignment developer-1 $one.runId $one.sessionId } "*not deliverable*"
    $result = New-Event $first $one result
    $null = Add-RealTaskEvent $state $result
    Assert-Throws { Set-RealTaskStage $state $first.claimId $one.id reconciled -Evidence $evidence } "*Invalid stage*"
    if ((Get-RealTaskCapacity $state).occupiedWorkers.Count -ne 2) { throw "A completion event must not release execution." }
    Set-RealTaskDisposition $state $first.claimId blocked -Evidence $evidence
    if ((Get-RealTaskCapacity $state).occupiedWorkers.Count -ne 2) { throw "Blocked uncertain execution must occupy its worker." }
    Set-RealTaskStage $state $first.claimId $one.id stopped-verified -Evidence @("fixture://session-not-run-stopped")
    Set-RealTaskDisposition $state $first.claimId validation -Evidence $evidence
    Set-RealTaskStage $state $first.claimId $one.id reconciled -Evidence $evidence
    $third = Add-RealTaskClaim $state 102 $evidence
    $three = Add-RealTaskHandoff $state $third.claimId developer-1 implement
    Complete-Implementation $state $second $two
    Start-Handoff $state $third $three
    $null = Add-RealTaskEvent $state (New-Event $third $three ack)
    $null = Add-RealTaskEvent $state (New-Event $third $three result)
    Set-RealTaskStage $state $third.claimId $three.id stopped-verified -Evidence $evidence
    Assert-Throws { Set-RealTaskDisposition $state $third.claimId validation -Evidence $evidence } "*backlog full*"
    Assert-Throws { Set-RealTaskStage $state $third.claimId $three.id reconciled -Evidence $evidence } "*disposition*"
    if ((Get-RealTaskCapacity $state).validationPending -ne 2) { throw "Backpressure must retain a result, not exceed the waiting bound." }

    $repairs = New-Fixture
    $task = Add-RealTaskClaim $repairs 200 $evidence
    $handoff = Add-RealTaskHandoff $repairs $task.claimId developer-1 implement
    Complete-Implementation $repairs $task $handoff
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        Set-RealTaskDisposition $repairs $task.claimId repair-needed -Evidence $evidence
        $worker = if ($attempt % 2 -eq 0) { "developer-2" } else { "developer-1" }
        if ($attempt -gt 1) {
            Assert-Throws { Add-RealTaskHandoff $repairs $task.claimId $worker repair -Feedback $evidence } "*Evidence*"
        }
        $handoff = Add-RealTaskHandoff $repairs $task.claimId $worker repair -Feedback $evidence -PriorRepairEvidence $evidence
        if ($handoff.repairAttempt -ne $attempt -or $handoff.expectedHead -ne $task.head) {
            throw "Repair history/head must persist across worker handoffs and revisions."
        }
        $head = $attempt.ToString("x").PadLeft(40, "0")
        Complete-Implementation $repairs $task $handoff
    }
    Set-RealTaskDisposition $repairs $task.claimId repair-needed -Evidence $evidence
    Assert-Throws { Add-RealTaskHandoff $repairs $task.claimId developer-1 repair -Feedback $evidence -PriorRepairEvidence $evidence } "*exhausted*"
    $bad = Copy-Record $repairs; $bad.tasks[0].repairCount = 0
    Assert-Throws { Assert-RealTaskState $bad } "*cannot reset*"
    $bad = Copy-Record $repairs; $bad.tasks[0].handoffs[1].repairAttempt = 1.0
    Assert-Throws { Assert-RealTaskState $bad } "*Repair attempt must be an integer*"

    $final = New-Fixture
    $task = Add-RealTaskClaim $final 300 $evidence
    $handoff = Add-RealTaskHandoff $final $task.claimId developer-1 implement
    Complete-Implementation $final $task $handoff
    Set-RealTaskDisposition $final $task.claimId finalize-ready -Evidence $evidence
    $handoff = Add-RealTaskHandoff $final $task.claimId developer-2 finalize -Feedback $evidence
    Start-Handoff $final $task $handoff
    $null = Add-RealTaskEvent $final (New-Event $task $handoff ack)
    $result = New-Event $task $handoff result delivered
    Assert-Throws { Add-RealTaskEvent $final $result } "*not authorized*"
    $result.result.outcome = "pr-ready"; $result.result.head = "f" * 40
    Assert-Throws { Add-RealTaskEvent $final $result } "*without coding*"
    $result.result.head = $handoff.expectedHead
    $null = Add-RealTaskEvent $final $result
    Set-RealTaskStage $final $task.claimId $handoff.id stopped-verified -Evidence $evidence
    Set-RealTaskDisposition $final $task.claimId human-review -Evidence $evidence
    Set-RealTaskStage $final $task.claimId $handoff.id reconciled -Evidence $evidence
    if ($task.state -ne "human-review") { throw "Publishing without merge authority must retain task ownership." }

    $pending = New-Fixture
    $task = Add-RealTaskClaim $pending 301 $evidence
    $handoff = Add-RealTaskHandoff $pending $task.claimId developer-1 implement
    Complete-Implementation $pending $task $handoff
    Set-RealTaskDisposition $pending $task.claimId finalize-ready -Evidence $evidence
    $handoff = Add-RealTaskHandoff $pending $task.claimId developer-2 finalize -Feedback $evidence
    Start-Handoff $pending $task $handoff
    $null = Add-RealTaskEvent $pending (New-Event $task $handoff ack)
    $null = Add-RealTaskEvent $pending (New-Event $task $handoff result blocked)
    Set-RealTaskDisposition $pending $task.claimId blocked -Evidence $evidence
    Set-RealTaskStage $pending $task.claimId $handoff.id stopped-verified -Evidence $evidence
    Set-RealTaskStage $pending $task.claimId $handoff.id reconciled -Evidence $evidence
    Set-RealTaskDisposition $pending $task.claimId validation -Evidence @("fixture://new-validation-observation")
    Set-RealTaskDisposition $pending $task.claimId finalize-ready -Evidence @("fixture://new-validation-observation")
    Assert-Throws {
        Add-RealTaskHandoff $pending $task.claimId developer-1 finalize -Feedback $evidence
    } "*Duplicate finalize*"
    $null = Add-RealTaskHandoff $pending $task.claimId developer-1 finalize -Feedback @("fixture://new-validation-observation")

    $stopped = New-Fixture
    $task = Add-RealTaskClaim $stopped 400 $evidence
    $handoff = Add-RealTaskHandoff $stopped $task.claimId developer-1 implement
    Start-Handoff $stopped $task $handoff
    $null = Add-RealTaskEvent $stopped (New-Event $task $handoff result blocked-before-start)
    Set-RealTaskDisposition $stopped $task.claimId blocked -Evidence $evidence
    Set-RealTaskStage $stopped $task.claimId $handoff.id stopped-verified -Evidence $evidence
    Set-RealTaskStage $stopped $task.claimId $handoff.id reconciled -Evidence $evidence
    $other = Add-RealTaskClaim $stopped 401 $evidence
    $null = Add-RealTaskHandoff $stopped $other.claimId developer-2 implement
    if ($task.state -ne "blocked") { throw "Isolated blocked task must retain its claim." }

    $early = New-Fixture
    $task = Add-RealTaskClaim $early 402 $evidence
    $handoff = Add-RealTaskHandoff $early $task.claimId developer-1 implement
    Set-RealTaskStage $early $task.claimId $handoff.id launch-requested -Evidence $evidence
    Set-RealTaskStage $early $task.claimId $handoff.id correlated -Evidence $evidence -RunId actual-run -SessionId actual-session
    $assignment = Get-RealTaskAssignment $early $task.claimId $handoff.id
    $earlyAck = Publish-RealTaskAcknowledgment $early $assignment developer-1 actual-run actual-session `
        (Join-Path $root "early-ack") "actual-developer-1" -Evidence @("fixture://actual-assignment-message")
    $null = Add-RealTaskEvent $early $earlyAck
    if ($handoff.stage -ne "acknowledged" -or $handoff.transitions[-2].stage -ne "delivered") {
        throw "An early acknowledgment must reconcile proven delivery without skipping stages or restarting."
    }

    $eventDirectory = Join-Path $root "events"
    $eventPath = Publish-RealTaskEvent $ack $eventDirectory
    $null = Publish-RealTaskEvent (Copy-Record $ack) $eventDirectory
    $bad = Copy-Record $ack; $bad.actor = "another"
    Assert-Throws { Publish-RealTaskEvent $bad $eventDirectory } "*Conflicting immutable*"
    Assert-Throws { Publish-RealTaskEvent @{ schema = "fingvibe-real-event-v1"; eventId = "partial" } $eventDirectory } "*Missing field*"
    [IO.File]::WriteAllText((Join-Path $eventDirectory "partial.json"), '{"schema":')
    Assert-Throws { Read-RealTaskJson (Join-Path $eventDirectory "partial.json") } "*"
    Assert-Throws { Read-RealTaskJson (Join-Path $root "missing.json") } "*Never infer idle*"

    $path = Join-Path $root "state.json"
    $gateRoot = Join-Path $root "gate"
    $owner = [guid]::NewGuid()
    $parameters = @{ Repository = "testowner/testrepo"; StateDirectory = $gateRoot; Owner = $owner }
    $null = & $gateScript -Action Acquire @parameters
    $published = New-Fixture
    Publish-RealTaskState $published $path $owner 0 $gateRoot
    $published.revision = 2
    Publish-RealTaskState $published $path $owner 1 $gateRoot
    Assert-Throws { Publish-RealTaskState $published $path $owner 1 $gateRoot } "*Stale revision*"
    Assert-Throws { Publish-RealTaskState $published $path ([guid]::NewGuid()) 2 $gateRoot } "*repository gate*"
    $published = Read-RealTaskJson $path
    $published.revision++
    $task = Add-RealTaskClaim $published 500 $evidence
    $handoff = Add-RealTaskHandoff $published $task.claimId developer-1 implement
    Publish-RealTaskState $published $path $owner 2 $gateRoot
    $bad = Copy-Record $published; $bad.revision++; $bad.tasks = @()
    Assert-Throws { Publish-RealTaskState $bad $path $owner 3 $gateRoot } "*exactly one task*"
    $bad = Copy-Record $published; $bad.revision++; $bad.tasks[0].handoffs[0].transitions[0].evidence = @("rewritten")
    Assert-Throws { Publish-RealTaskState $bad $path $owner 3 $gateRoot } "*Prior transition*"
    if ((Read-RealTaskJson $path).revision -ne 3) { throw "Failed publication must leave previous valid state intact." }
    $null = & $gateScript -Action Release @parameters

    $incidents = Join-Path $root "incidents"
    $null = [IO.Directory]::CreateDirectory($incidents)
    $incident = @{ id = "human-reported"; originalReporter = "human"; recordingActor = "dispatcher"
        changedUtc = [DateTime]::UtcNow.ToString("o"); nextOwner = "human"; nextAction = "inspect"; evidence = $evidence }
    [IO.File]::WriteAllText((Join-Path $incidents "unindexed.json"), ($incident | ConvertTo-Json))
    Sync-RealTaskIncidents $published $incidents
    if ($published.incidents.Count -ne 1 -or $published.incidents[0].id -ne "human-reported") {
        throw "Incident discovery must not depend on index completeness."
    }
    [IO.File]::Delete((Join-Path $incidents "unindexed.json"))
    Assert-Throws { Sync-RealTaskIncidents $published $incidents } "*Previously indexed incident is missing*"
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
Write-Output "Real-task coordination tests passed."
