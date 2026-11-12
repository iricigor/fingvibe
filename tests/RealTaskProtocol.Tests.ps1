$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "..\.github\scripts\RealTaskCoordination.psm1") -Force
$entryPoint = Join-Path $PSScriptRoot "..\.github\scripts\Invoke-RealTaskMessage.ps1"
$root = Join-Path ([IO.Path]::GetTempPath()) ("fingvibe-protocol-test-" + [guid]::NewGuid())
$null = [IO.Directory]::CreateDirectory($root)
$evidence = @("fixture://independently-observed-host-and-human-evidence")
$dispatcher = @{ agentId = "dispatcher"; automationId = $null; runId = $null; sessionId = "dispatcher-session" }
$worker = @{ agentId = "developer-1"; automationId = "automation-1"; runId = "actual-run"; sessionId = "actual-session" }

function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    try { & $Action | Out-Null }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected failure matching '$Pattern'."
}

function Copy-Record($Record) { $Record | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -DateKind String -Depth 100 }

function Receive($Message, $Sender = $dispatcher, $Recipient = $worker) {
    Receive-RealTaskMessage ($Message | ConvertTo-Json -Depth 100 -Compress) $state $Sender $Recipient $root $evidence
}

function Assert-Rejected($Decision, [string] $Code = "*") {
    if ($Decision.disposition -cne "rejected" -or $Decision.operation -cne "none" -or
        $Decision.reasonCode -notlike $Code -or -not [IO.File]::Exists($Decision.diagnosticPath)) {
        throw "Expected rejected action and durable diagnostic: $($Decision | ConvertTo-Json -Compress)"
    }
}

function New-Message([string] $Type, $Payload, $Sender = $dispatcher, $Recipient = $worker, $Reply = $null, $Record = $null) {
    New-RealTaskMessage -Type $Type -Sender $Sender -Recipient $Recipient -Context $context `
        -Payload $Payload -Directory $root -InReplyTo $Reply -Record $Record
}

try {
    $state = New-RealTaskState -Repository "testowner/testrepo" -Epic 92 -TargetBranch main `
        -Authorization @{ reference = "fixture://human-approval"; implementation = $true; merge = $false } `
        -Workers @(@{ id = "developer-1"; name = "Developer 1"; automationId = "automation-1" },
            @{ id = "developer-2"; name = "Developer 2"; automationId = "automation-2" })
    $task = Add-RealTaskClaim $state 100 $evidence
    $handoff = Add-RealTaskHandoff $state $task.claimId developer-1 implement
    Set-RealTaskStage $state $task.claimId $handoff.id launch-requested -Evidence $evidence
    Set-RealTaskStage $state $task.claimId $handoff.id correlated -Evidence $evidence -RunId $worker.runId -SessionId $worker.sessionId
    $context = @{ repository = $state.repository; epic = 92; issue = 100; claimId = $task.claimId; handoffId = $handoff.id }
    $module = Get-Module RealTaskCoordination
    $atomicPath = Join-Path $root "atomic-state.json"
    & $module { param($r, $p) Write-RealTaskAtomic $r $p } $state $atomicPath
    $originalBytes = [IO.File]::ReadAllBytes($atomicPath)
    $badState = Copy-Record $state
    $badState.tasks[0]["PR"] = "case-variant"
    Assert-RealTaskState $badState
    Assert-Throws { & $module { param($r, $p) Write-RealTaskAtomic $r $p } $badState $atomicPath } "*Duplicate JSON key*"
    if ([Convert]::ToHexString([IO.File]::ReadAllBytes($atomicPath)) -cne [Convert]::ToHexString($originalBytes)) {
        throw "Rejected serialization must preserve the prior state byte for byte."
    }
    $null = Read-RealTaskJson $atomicPath
    $newAtomicPath = Join-Path $root "invalid-initial-state.json"
    Assert-Throws { & $module { param($r, $p) Write-RealTaskAtomic $r $p -Immutable } $badState $newAtomicPath } "*Duplicate JSON key*"
    if ([IO.File]::Exists($newAtomicPath)) { throw "Invalid initial publication must not create its target." }
    $assignment = New-Message assignment (Get-RealTaskAssignment $state $task.claimId $handoff.id)
    Assert-Rejected (Receive $assignment) "publication-mismatch"
    $path = Publish-RealTaskMessage $assignment $state $dispatcher $worker $root
    $recreated = New-Message assignment (Get-RealTaskAssignment $state $task.claimId $handoff.id)
    if ($recreated.messageId -cne $assignment.messageId -or $recreated.sentUtc -cne $assignment.sentUtc) {
        throw "Preparation must retain the original one-time handoff message identity and timestamp, not create another assignment."
    }
    $decision = Receive $assignment
    if ($decision.operation -cne "acknowledge-implement" -or $handoff.stage -cne "correlated") {
        throw "Receive must route, not acknowledge, execute or change delivery state."
    }
    $before = [Text.Encoding]::UTF8.GetByteCount(($assignment | ConvertTo-Json -Depth 100 -Compress))
    $after = [Text.Encoding]::UTF8.GetByteCount(($decision | ConvertTo-Json -Depth 100 -Compress))
    if ($after -ge $before) { throw "Decision must be smaller than the full assignment envelope." }

    foreach ($mutate in @(
        { param($m) $m.extra = "unknown" },
        { param($m) $m.sender.extra = "unknown" },
        { param($m) $m.record.extra = "unknown" },
        { param($m) $m.context.epic = "92" },
        { param($m) $m.payload.authorization.extra = $true },
        { param($m) $m.payload.elapsed = 1 },
        { param($m) $m.payload.branch = $true },
        { param($m) $m.payload.feedback = "not-an-array" },
        { param($m) $m.payload.repairAttempt = 0.0 },
        { param($m) $m.Remove("sentUtc"); $m.SentUtc = "2026-11-12T08:00:00Z" },
        { param($m) $m.payload.action = "finalize" },
        { param($m) $m.payload.authorization.merge = $true },
        { param($m) $m.payload.expectedHead = "f" * 40 },
        { param($m) $m.context.issue = 101 },
        { param($m) $m.recipient.sessionId = $m.recipient.runId },
        { param($m) $m.recipient.automationId = "wrong" }
    )) {
        $bad = Copy-Record $assignment
        & $mutate $bad
        Assert-Rejected (Receive $bad)
    }
    foreach ($field in @("schema", "payload.schema")) {
        foreach ($value in @(@(), @($(if ($field -ceq "schema") { "fingvibe-real-message-v1" } else { "fingvibe-real-assignment-v1" })))) {
            $bad = Copy-Record $assignment
            if ($field -ceq "schema") { $bad.schema = $value } else { $bad.payload.schema = $value }
            Assert-Rejected (Receive $bad)
            Assert-Throws { Publish-RealTaskMessage $bad $state $dispatcher $worker $root } "*schema*"
        }
    }
    $bad = Copy-Record $assignment; $bad.schema = "fingvibe-real-message-v2"
    $unsupported = Receive $bad
    Assert-Rejected $unsupported "unsupported-schema"
    $errorPath = Publish-RealTaskProtocolError $unsupported.diagnosticPath $state $root
    $errorMessage = Read-RealTaskJson $errorPath
    if ($errorMessage.type -cne "protocol_error" -or $errorMessage.inReplyTo -cne $assignment.messageId -or
        (Receive $errorMessage $worker $dispatcher).operation -cne "inspect-protocol-error") {
        throw "Expected one correlated error routed to the verified original sender."
    }
    Assert-Throws { Publish-RealTaskProtocolError $unsupported.diagnosticPath $state $root } "*already reserved*"
    $badError = Copy-Record $errorMessage; $badError.payload.extra = "wrong"
    $rejectedError = Receive $badError $worker $dispatcher
    Assert-Rejected $rejectedError
    if ($rejectedError.responseAllowed) { throw "Protocol errors must never cause error-response loops." }
    Assert-Throws { Publish-RealTaskProtocolError $rejectedError.diagnosticPath $state $root } "*without replying*"
    $anotherInvalid = Copy-Record $assignment
    $anotherInvalid.messageId = [guid]::NewGuid().ToString()
    $anotherInvalid.schema = "fingvibe-real-message-v2"
    $partialReply = Receive $anotherInvalid
    $invalidState = Copy-Record $state; $invalidState.workers = @($invalidState.workers[0])
    Assert-Throws { Publish-RealTaskProtocolError $partialReply.diagnosticPath $invalidState $root } "*Exactly two Developer*"
    Assert-Throws { Publish-RealTaskProtocolError $partialReply.diagnosticPath $state $root } "*already reserved*"

    $json = $assignment | ConvertTo-Json -Depth 100 -Compress
    foreach ($raw in @('{"schema":', "[]", "true", "//comment`n$json", "$json prose",
        ('```json' + "`n$json`n" + '```'), ($json -replace '"epic":92', '"epic":92,"epic":93'),
        ($json -replace '"epic":92', '"epic":92,"Epic":93'), ($json -replace '"epic":92', '"epic":92,'))) {
        Assert-Rejected (Receive-RealTaskMessage $raw $state $dispatcher $worker $root $evidence) "invalid-json"
    }
    $duplicatePath = Join-Path $root "duplicate.json"
    [IO.File]::WriteAllText($duplicatePath, '{"key":1,"key":2}')
    Assert-Throws { Read-RealTaskJson $duplicatePath } "*Duplicate JSON key*"
    $bad = Copy-Record $assignment; $bad.sender.sessionId = "unverified"
    $spoofed = Receive $bad
    Assert-Rejected $spoofed "identity-mismatch"
    if ($spoofed.responseAllowed) { throw "Do not reply to a spoofed claimed sender." }

    $changedAuthority = Copy-Record $state
    $changedAuthority.authorization.implementation = $false
    Assert-Rejected (Receive-RealTaskMessage $json $changedAuthority $dispatcher $worker $root $evidence) "authority-mismatch"
    $bad = Copy-Record $assignment; $bad.record.path = Join-Path $root "outside.json"
    Assert-Rejected (Receive $bad) "publication-mismatch"
    $bad = Copy-Record $assignment; $bad.record.hash = "F" * 64
    Assert-Rejected (Receive $bad)
    $bad = Copy-Record $assignment; $bad.sentUtc = "2026-11-12T08:01:00Z"
    Assert-Rejected (Receive $bad) "conflicting-duplicate"

    $blocker = New-Message blocker @{ code = "missing-evidence"; explanation = "Actual stopped-session evidence unavailable."
        nextOwner = "dispatcher"; nextAction = "Inspect actual session without relaunching."; evidence = $evidence } $worker $dispatcher
    $null = Publish-RealTaskMessage $blocker $state $worker $dispatcher $root
    if ((Receive $blocker $worker $dispatcher).operation -cne "inspect-blocker") { throw "Blocker routing failed." }
    if ((Receive $blocker $worker $dispatcher).reasonCode -cne "message-processing-reserved") {
        throw "A duplicate before confirmation must not repeat informational handling."
    }
    Confirm-RealTaskMessage $blocker $state $worker $dispatcher $root $evidence
    if ((Receive $blocker $worker $dispatcher).disposition -cne "duplicate" -or $handoff.stage -cne "correlated") {
        throw "Informational receipt must deduplicate without changing execution/ownership."
    }
    $request = New-Message clarification_request @{ question = "Which existing requirement applies?"; evidence = $evidence } $worker $dispatcher
    $null = Publish-RealTaskMessage $request $state $worker $dispatcher $root
    if ((Receive $request $worker $dispatcher).operation -cne "answer-clarification") { throw "Request routing failed." }
    $reply = New-Message clarification_reply @{ answer = "Use the existing approved requirement."; evidence = $evidence } `
        $dispatcher $worker $request.messageId
    $null = Publish-RealTaskMessage $reply $state $dispatcher $worker $root
    if ((Receive $reply).operation -cne "read-clarification") { throw "Reply routing failed." }
    foreach ($content in @($null, '{"partial":', '{"question":"altered","evidence":["fixture://changed"]}')) {
        if ($null -eq $content) { [IO.File]::Delete($request.record.path) }
        else { [IO.File]::WriteAllText($request.record.path, $content) }
        Assert-Rejected (Receive $reply)
        Assert-Throws { Publish-RealTaskMessage $reply $state $dispatcher $worker $root } "*"
    }
    [IO.File]::WriteAllText($request.record.path, ($request.payload | ConvertTo-Json -Compress))
    $requestEnvelopePath = Join-Path $root "messages\$($request.messageId).json"
    $badRequest = Copy-Record $request; $badRequest.messageId = [guid]::NewGuid().ToString()
    $badRequest.record.id = $badRequest.messageId
    [IO.File]::WriteAllText($requestEnvelopePath, ($badRequest | ConvertTo-Json -Depth 100 -Compress))
    Assert-Rejected (Receive $reply) "correlation-mismatch"
    $badRequest = Copy-Record $request; $badRequest.record.path = Join-Path $root "outside-request.json"
    [IO.File]::WriteAllText($requestEnvelopePath, ($badRequest | ConvertTo-Json -Depth 100 -Compress))
    Assert-Rejected (Receive $reply) "publication-mismatch"
    [IO.File]::WriteAllText($requestEnvelopePath, ($request | ConvertTo-Json -Depth 100 -Compress))
    $bad = Copy-Record $reply; $bad.payload.expectedHead = "f" * 40
    Assert-Rejected (Receive $bad)
    $bad = Copy-Record $reply; $bad.inReplyTo = $blocker.messageId
    Assert-Rejected (Receive $bad) "correlation-mismatch"
    $notification = New-Message notification @{ reason = "record-available" } $worker $dispatcher $null $blocker.record
    $null = Publish-RealTaskMessage $notification $state $worker $dispatcher $root
    if ((Receive $notification $worker $dispatcher).operation -cne "reconcile-record") { throw "Notification routing failed." }
    $bad = Copy-Record $notification; $bad.payload.action = "implement"
    Assert-Rejected (Receive $bad)
    foreach ($value in @(@(), @("record-available"))) {
        $bad = Copy-Record $notification; $bad.payload.reason = $value
        Assert-Rejected (Receive $bad $worker $dispatcher)
        Assert-Throws { Publish-RealTaskMessage $bad $state $worker $dispatcher $root } "*notification reason*"
    }
    [IO.File]::WriteAllText($blocker.record.path, '{"partial":')
    Assert-Rejected (Receive $notification $worker $dispatcher)
    [IO.File]::WriteAllText($blocker.record.path, ($blocker.payload | ConvertTo-Json -Compress))

    $unreservedAck = @{
        schema = "fingvibe-real-event-v1"; eventId = "ack-$($handoff.id)"; kind = "ack"
        claimId = $task.claimId; handoffId = $handoff.id; action = "implement"; workerId = "developer-1"
        runId = $worker.runId; sessionId = $worker.sessionId; utc = [DateTime]::UtcNow.ToString("o")
        actor = "actual-worker"; originalReporter = "actual-worker"; trigger = "manual"; elapsedSeconds = $null
        result = $null; evidence = $evidence
    }
    $ackMessage = New-Message acknowledgment $unreservedAck $worker $dispatcher
    Assert-Throws { Publish-RealTaskMessage $ackMessage $state $worker $dispatcher $root } "*Reserve acknowledgment*"
    $prestartRoot = Join-Path $root "prestart"
    $prestart = Copy-Record $unreservedAck
    $prestart.kind = "result"; $prestart.eventId = "result-$($handoff.id)"
    $prestart.result = @{ outcome = "blocked-before-start"; head = $null; checkpoint = $null; evidence = $evidence }
    $prestartMessage = New-RealTaskMessage -Type result -Sender $worker -Recipient $dispatcher -Context $context `
        -Payload $prestart -Directory $prestartRoot
    $null = Publish-RealTaskMessage $prestartMessage $state $worker $dispatcher $prestartRoot
    $prestartDecision = Receive-RealTaskMessage ($prestartMessage | ConvertTo-Json -Depth 100 -Compress) `
        $state $worker $dispatcher $prestartRoot $evidence
    if ($prestartDecision.operation -cne "ingest-event") { throw "Verified pre-start rejection must not require acknowledgment." }
    $prestartState = Copy-Record $state
    $null = Add-RealTaskEvent $prestartState $prestart
    $ack = Publish-RealTaskAcknowledgment $state $assignment.payload developer-1 $worker.runId $worker.sessionId `
        (Join-Path $root "events") "actual-worker" -Trigger manual -Evidence $evidence
    $ackPath = Join-Path $root "events\$($ack.eventId).json"
    $badAck = Copy-Record $ack; $badAck.action = "repair"
    [IO.File]::WriteAllText($ackPath, ($badAck | ConvertTo-Json -Depth 100 -Compress))
    Assert-Rejected (Receive $assignment) "correlation-mismatch"
    [IO.File]::WriteAllText($ackPath, ($ack | ConvertTo-Json -Depth 100 -Compress))
    if ((Receive $assignment).disposition -cne "duplicate") { throw "Unindexed atomic acknowledgment must prevent duplicate execution." }
    $ackMessage = New-Message acknowledgment $ack $worker $dispatcher
    $null = Publish-RealTaskMessage $ackMessage $state $worker $dispatcher $root
    if ((Receive $ackMessage $worker $dispatcher).operation -cne "ingest-event") { throw "Ack routing failed." }
    $event = Copy-Record $ack
    $event.kind = "result"; $event.eventId = "result-$($handoff.id)"
    $event.elapsedSeconds = 1.25
    $event.result = @{ outcome = "implementation-ready"; head = "a" * 40; checkpoint = "fixture://checkpoint"; evidence = $evidence }
    $resultMessage = New-Message result $event $worker $dispatcher
    $null = Publish-RealTaskMessage $resultMessage $state $worker $dispatcher $root
    if ((Receive $resultMessage $worker $dispatcher).operation -cne "ingest-event" -or $handoff.stage -cne "correlated") {
        throw "A fast worker must publish/preflight its result from durable acknowledgment without mutating Dispatcher state."
    }
    Assert-Throws { Add-RealTaskEvent $state $event } "*Result requires acknowledgment*"
    foreach ($field in @("action", "claimId", "handoffId", "workerId", "runId", "sessionId")) {
        $badAck = Copy-Record $ack
        $badAck[$field] = switch ($field) {
            "action" { "repair" }
            "workerId" { "developer-2" }
            "claimId" { [guid]::NewGuid().ToString() }
            "handoffId" { [guid]::NewGuid().ToString() }
            default { "other-identity" }
        }
        [IO.File]::WriteAllText($ackPath, ($badAck | ConvertTo-Json -Depth 100 -Compress))
        Assert-Rejected (Receive $resultMessage $worker $dispatcher)
        Assert-Throws { Publish-RealTaskMessage $resultMessage $state $worker $dispatcher $root } "*"
    }
    [IO.File]::Delete($ackPath)
    Assert-Rejected (Receive $resultMessage $worker $dispatcher) "publication-mismatch"
    [IO.File]::WriteAllText($ackPath, '{"partial":')
    Assert-Rejected (Receive $resultMessage $worker $dispatcher)
    [IO.File]::WriteAllText($ackPath, ($ack | ConvertTo-Json -Depth 100 -Compress))
    foreach ($value in @(@(), @("fingvibe-real-event-v1"))) {
        $bad = Copy-Record $event; $bad.schema = $value
        Assert-Throws { Publish-RealTaskEvent $bad (Join-Path $root "events") } "*event schema*"
        $badMessage = Copy-Record $resultMessage; $badMessage.payload.schema = $value
        Assert-Rejected (Receive $badMessage $worker $dispatcher)
    }
    $null = Add-RealTaskEvent $state $ack
    if ((Receive $assignment).disposition -cne "duplicate" -or
        (Receive $ackMessage $worker $dispatcher).disposition -cne "duplicate") { throw "Indexed duplicates must be harmless." }
    $ackPath = Join-Path $root "events\$($ack.eventId).json"
    [IO.File]::Delete($ackPath)
    Assert-Rejected (Receive $assignment) "publication-mismatch"
    Assert-Rejected (Receive $resultMessage $worker $dispatcher) "publication-mismatch"
    Assert-Throws { Publish-RealTaskMessage $resultMessage $state $worker $dispatcher $root } "*canonical ack event is missing*"
    $badAck = Copy-Record $ack; $badAck.actor = "changed"
    [IO.File]::WriteAllText($ackPath, ($badAck | ConvertTo-Json -Depth 100 -Compress))
    Assert-Rejected (Receive $assignment) "conflicting-duplicate"
    Assert-Rejected (Receive $resultMessage $worker $dispatcher) "conflicting-duplicate"
    Assert-Throws { Publish-RealTaskMessage $resultMessage $state $worker $dispatcher $root } "*retained hash*"
    [IO.File]::WriteAllText($ackPath, ($ack | ConvertTo-Json -Depth 100 -Compress))

    foreach ($mutate in @(
        { param($e) $e.elapsed = 1.25 },
        { param($e) $e.ElapsedSeconds = 1.25; $e.Remove("elapsedSeconds") },
        { param($e) $e.result.extra = $true },
        { param($e) $e.result.head = "bad" },
        { param($e) $e.result.checkpoint = $null }
    )) {
        $bad = Copy-Record $event; & $mutate $bad
        Assert-Throws { Publish-RealTaskEvent $bad (Join-Path $root "events") } "*"
        $saved = Read-RealTaskJson (Join-Path $root "events\$($event.eventId).json")
        if (($saved | ConvertTo-Json -Depth 100 -Compress) -cne ($event | ConvertTo-Json -Depth 100 -Compress)) {
            throw "Rejected result changed the existing immutable publication."
        }
    }
    $resultMessage = New-Message result $event $worker $dispatcher
    $null = Publish-RealTaskMessage $resultMessage $state $worker $dispatcher $root
    if ((Receive $resultMessage $worker $dispatcher).operation -cne "ingest-event") { throw "Result routing failed." }
    $null = Add-RealTaskEvent $state $event
    if ($handoff.stage -cne "result-recorded" -or (Receive $resultMessage $worker $dispatcher).disposition -cne "duplicate") {
        throw "Result must not prove stopping or release occupancy."
    }
    $bad = Copy-Record $resultMessage; $bad.payload.actor = "different"
    Assert-Rejected (Receive $bad $worker $dispatcher) "conflicting-duplicate"

    $specPath = Join-Path $root "spec.json"
    $statePath = Join-Path $root "state.json"
    $observationPath = Join-Path $root "observation.json"
    @{ type = "clarification_request"; context = $context; payload = @{ question = "CLI fixture?"; evidence = $evidence }
        inReplyTo = $null; record = $null } | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $specPath
    $state | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $statePath
    @{ sender = $worker; recipient = $dispatcher; evidence = $evidence } | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $observationPath
    $cliJson = & $entryPoint -Action Prepare -InputPath $specPath -StatePath $statePath -Directory $root -ObservationPath $observationPath
    $cliMessage = $cliJson | ConvertFrom-Json -AsHashtable -DateKind String
    $cliPath = Join-Path $root "wire.json"
    [IO.File]::WriteAllText($cliPath, ($cliJson -join "`n"))
    $cliDecision = & $entryPoint -Action Receive -InputPath $cliPath -StatePath $statePath -Directory $root `
        -ObservationPath $observationPath | ConvertFrom-Json -AsHashtable
    if ($cliDecision.operation -cne "answer-clarification" -or $cliMessage.type -cne "clarification_request") {
        throw "Script entry point must produce strict JSON and fixed-operation packets."
    }
    & $entryPoint -Action Confirm -InputPath $cliPath -StatePath $statePath -Directory $root -ObservationPath $observationPath
    $malformedWire = Join-Path $root "malformed-wire.json"
    [IO.File]::WriteAllText($malformedWire, '{"schema":')
    $cliRejected = & $entryPoint -Action Receive -InputPath $malformedWire -StatePath $statePath -Directory $root `
        -ObservationPath $observationPath | ConvertFrom-Json -AsHashtable
    Assert-Rejected $cliRejected "invalid-json"
    foreach ($action in @("prepare", "receive", "confirm", "protocolerror")) {
        Assert-Throws {
            & $entryPoint -Action $action -InputPath $cliPath -StatePath $statePath -Directory $root -ObservationPath $observationPath
        } "*does not belong to the set*"
    }

    $concurrent = New-Message clarification_request @{ question = "Exactly one handler?"; evidence = $evidence } $worker $dispatcher
    $concurrentPath = Publish-RealTaskMessage $concurrent $state $worker $dispatcher $root
    $jobs = @()
    try {
        foreach ($attempt in 1..2) {
            $jobs += Start-Job -ScriptBlock {
                param($Entry, $InputFile, $StateFile, $Root, $Observations)
                $ErrorActionPreference = "Stop"
                & $Entry -Action Receive -InputPath $InputFile -StatePath $StateFile -Directory $Root `
                    -ObservationPath $Observations | ConvertFrom-Json
            } -ArgumentList $entryPoint, $concurrentPath, $statePath, $root, $observationPath
        }
        $jobs | Wait-Job -Timeout 30 | Out-Null
        if (@($jobs | Where-Object State -CNE "Completed").Count -ne 0) { throw "Concurrent receive did not complete." }
        $results = @($jobs | Receive-Job)
        if (@($results | Where-Object disposition -CEQ "ready").Count -ne 1 -or
            @($results | Where-Object disposition -CEQ "duplicate").Count -ne 1) {
            throw "Exactly one concurrent receiver may reserve informational handling."
        }
    } finally {
        foreach ($job in $jobs) {
            if ($job.State -notin @("Completed", "Failed", "Stopped")) { Stop-Job -Id $job.Id }
            Remove-Job -Id $job.Id
        }
    }

    $hashRecord = '{"actor":"a","Actor":"b","nested":{"z":1,"a":2}}' | ConvertFrom-Json -AsHashtable
    $module = Get-Module RealTaskCoordination
    $firstHash = & $module { param($r) Get-RealTaskHash $r } $hashRecord
    $hashRecord["actor"] = "changed"
    $secondHash = & $module { param($r) Get-RealTaskHash $r } $hashRecord
    if ($firstHash -ceq $secondHash) { throw "Canonical hashing must never collapse case-distinct fields." }
    $reordered = '{"nested":{"a":2,"z":1},"Actor":"b","actor":"changed"}' | ConvertFrom-Json -AsHashtable
    if ((& $module { param($r) Get-RealTaskHash $r } $reordered) -cne $secondHash) {
        throw "Object order must not change canonical hashes."
    }
    $culture = [Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo("tr-TR")
        if ((& $module { param($r) Get-RealTaskHash $r } $reordered) -cne $secondHash) {
            throw "Hash order must not depend on Windows culture."
        }
    } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $culture }

    Set-RealTaskStage $state $task.claimId $handoff.id stopped-verified -Evidence @("fixture://actual-session-stopped")
    $task.branch = "fixture-branch"; $task.worktree = Join-Path $root "task-worktree"; $task.pr = "fixture://pr"
    $task.head = $event.result.head; $task.checkpoint = $event.result.checkpoint
    Set-RealTaskDisposition $state $task.claimId validation -Evidence $evidence
    Set-RealTaskStage $state $task.claimId $handoff.id reconciled -Evidence $evidence
    $finalizeFixture = Copy-Record $state
    Set-RealTaskDisposition $state $task.claimId repair-needed -Evidence $evidence
    $repair = Add-RealTaskHandoff $state $task.claimId developer-1 repair -Feedback $evidence
    Set-RealTaskStage $state $task.claimId $repair.id launch-requested -Evidence $evidence
    Set-RealTaskStage $state $task.claimId $repair.id correlated -Evidence $evidence -RunId $worker.runId -SessionId $worker.sessionId
    $context = Copy-Record $context; $context.handoffId = $repair.id
    $repairMessage = New-Message assignment (Get-RealTaskAssignment $state $task.claimId $repair.id)
    $null = Publish-RealTaskMessage $repairMessage $state $dispatcher $worker $root
    if ((Receive $repairMessage).operation -cne "acknowledge-repair") { throw "Repair routing failed." }
    $bad = Copy-Record $repairMessage; $bad.payload.expectedHead = "b" * 40
    Assert-Rejected (Receive $bad)
    $state = $finalizeFixture
    Set-RealTaskDisposition $state $task.claimId finalize-ready -Evidence $evidence
    $finalize = Add-RealTaskHandoff $state $task.claimId developer-1 finalize -Feedback $evidence
    Set-RealTaskStage $state $task.claimId $finalize.id launch-requested -Evidence $evidence
    Set-RealTaskStage $state $task.claimId $finalize.id correlated -Evidence $evidence -RunId $worker.runId -SessionId $worker.sessionId
    $context = Copy-Record $context; $context.handoffId = $finalize.id
    $finalizeMessage = New-Message assignment (Get-RealTaskAssignment $state $task.claimId $finalize.id)
    $null = Publish-RealTaskMessage $finalizeMessage $state $dispatcher $worker $root
    if ((Receive $finalizeMessage).operation -cne "acknowledge-finalize") { throw "Non-coding finalization routing failed." }
    $finalizeAck = Publish-RealTaskAcknowledgment $state $finalizeMessage.payload developer-1 $worker.runId $worker.sessionId `
        (Join-Path $root "events") "actual-worker" -Evidence $evidence
    $staleFinalize = Copy-Record $event
    $staleFinalize.handoffId = $finalize.id; $staleFinalize.eventId = "result-$($finalize.id)"
    $staleFinalize.action = "finalize"; $staleFinalize.result.outcome = "pr-ready"; $staleFinalize.result.head = "b" * 40
    $staleMessage = New-Message result $staleFinalize $worker $dispatcher
    Assert-Rejected (Receive $staleMessage $worker $dispatcher)
    Assert-Throws { Publish-RealTaskMessage $staleMessage $state $worker $dispatcher $root } "*assigned head*"
    $deniedMerge = Copy-Record $event
    $deniedMerge.handoffId = $finalize.id; $deniedMerge.eventId = "result-$($finalize.id)"
    $deniedMerge.action = "finalize"; $deniedMerge.result.outcome = "delivered"
    $deniedMessage = New-Message result $deniedMerge $worker $dispatcher
    Assert-Rejected (Receive $deniedMessage $worker $dispatcher) "authority-mismatch"
    $context.handoffId = $handoff.id
    $timer = [Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt 10; $i++) { $null = Receive $notification $worker $dispatcher }
    $timer.Stop()
    Write-Output ("Offline sample: full assignment {0} UTF-8 bytes; decision {1} bytes; 10 warm notification receives {2:N2} ms. No host calls or runtime latency claim." -f
        $before, $after, $timer.Elapsed.TotalMilliseconds)
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force
}
Write-Output "Real-task protocol tests passed."
