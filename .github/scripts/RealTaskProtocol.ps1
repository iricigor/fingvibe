$script:MessageTypes = @("assignment", "acknowledgment", "result", "blocker",
    "clarification_request", "clarification_reply", "notification", "protocol_error")
$script:ProtocolCodes = @("invalid-json", "unsupported-schema", "invalid-message",
    "identity-mismatch", "correlation-mismatch", "authority-mismatch",
    "conflicting-duplicate", "publication-mismatch", "internal-error")

function Stop-RealTaskProtocol([string] $Code, [string] $Explanation) {
    $error = [InvalidOperationException]::new($Explanation)
    $error.Data["protocolCode"] = $Code
    throw $error
}

function Assert-RealTaskUuid($Value) {
    if ($Value -isnot [string] -or $Value -cnotmatch '^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$' -or
        $Value -ceq [guid]::Empty.ToString()) { throw "Expected nonempty lowercase UUID." }
}

function Assert-RealTaskEndpoint($Endpoint) {
    Assert-RealTaskFields $Endpoint @("agentId", "automationId", "runId", "sessionId") -Closed
    if ($Endpoint.agentId -cnotin @("dispatcher", "developer-1", "developer-2")) { throw "Unknown agent identity." }
    Assert-RealTaskText $Endpoint.sessionId "actual session ID"
    foreach ($field in @("automationId", "runId")) {
        if ($Endpoint.agentId -cne "dispatcher" -or $null -ne $Endpoint[$field]) {
            Assert-RealTaskText $Endpoint[$field] "actual $field"
        }
    }
}

function Assert-RealTaskContext($Context) {
    Assert-RealTaskFields $Context @("repository", "epic", "issue", "claimId", "handoffId") -Closed
    if ($Context.repository -isnot [string] -or
        $Context.repository -cnotmatch '^[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9_.-]*$') {
        throw "Expected normalized repository."
    }
    foreach ($field in @("epic", "issue")) {
        if (($Context[$field] -isnot [int] -and $Context[$field] -isnot [long]) -or $Context[$field] -lt 1) {
            throw "Expected positive integer $field."
        }
    }
    Assert-RealTaskUuid $Context.claimId
    Assert-RealTaskUuid $Context.handoffId
}

function Assert-RealTaskMessageShape($Message) {
    Assert-RealTaskFields $Message @("schema", "messageId", "type", "sender", "recipient",
        "context", "sentUtc", "inReplyTo", "record", "payload") -Closed
    if ($Message.schema -cne "fingvibe-real-message-v1") {
        Stop-RealTaskProtocol "unsupported-schema" "Unsupported message schema; no automatic migration."
    }
    Assert-RealTaskUuid $Message.messageId
    if ($Message.type -cnotin $script:MessageTypes) { throw "Unsupported message type." }
    Assert-RealTaskEndpoint $Message.sender
    Assert-RealTaskEndpoint $Message.recipient
    if (($Message.sender.agentId -ceq "dispatcher") -eq ($Message.recipient.agentId -ceq "dispatcher")) {
        throw "Messages must cross the Dispatcher/Developer boundary."
    }
    Assert-RealTaskUtc $Message.sentUtc
    if ($null -ne $Message.inReplyTo) { Assert-RealTaskUuid $Message.inReplyTo }
    if ($Message.type -cin @("clarification_reply", "protocol_error")) {
        if ($null -eq $Message.inReplyTo) { throw "Replies require inReplyTo." }
    } elseif ($null -ne $Message.inReplyTo) { throw "Only clarification replies and protocol errors use inReplyTo." }
    if ($null -eq $Message.context) {
        if ($Message.type -cne "protocol_error") { throw "Task context is required." }
    } else { Assert-RealTaskContext $Message.context }
    Assert-RealTaskFields $Message.record @("id", "path", "hash") -Closed
    Assert-RealTaskText $Message.record.id "record ID"
    if ($Message.record.id -cnotmatch '^[a-zA-Z0-9-]+$' -or
        $Message.record.path -isnot [string] -or -not [IO.Path]::IsPathFullyQualified($Message.record.path) -or
        $Message.record.hash -isnot [string] -or $Message.record.hash -cnotmatch '^[0-9A-F]{64}$') {
        throw "Invalid immutable record reference."
    }
    if ($Message.type -cin @("acknowledgment", "result")) {
        if ($Message.record.id -cne $Message.payload.eventId) { throw "Event record ID mismatch." }
    } elseif ($Message.type -cne "notification" -and $Message.record.id -cne $Message.messageId) {
        throw "Payload record ID must match its immutable message ID."
    }
    switch -CaseSensitive ($Message.type) {
        "assignment" {
            if ($Message.sender.agentId -cne "dispatcher") { throw "Only Dispatcher assigns work." }
            Assert-RealTaskFields $Message.payload @("schema", "repository", "epic", "issue", "claimId",
                "handoffId", "action", "workerId", "runId", "sessionId", "targetBranch", "authorization",
                "branch", "worktree", "pr", "expectedHead", "checkpoint", "repairAttempt", "strategy",
                "feedback", "priorRepairEvidence") -Closed
            Assert-RealTaskFields $Message.payload.authorization @("reference", "implementation", "merge") -Closed
            if ($Message.payload.schema -cne "fingvibe-real-assignment-v1") {
                Stop-RealTaskProtocol "unsupported-schema" "Unsupported assignment schema."
            }
            $assignment = $Message.payload
            Assert-RealTaskContext @{ repository = $assignment.repository; epic = $assignment.epic; issue = $assignment.issue
                claimId = $assignment.claimId; handoffId = $assignment.handoffId }
            foreach ($field in @("runId", "sessionId", "targetBranch")) { Assert-RealTaskText $assignment[$field] $field }
            Assert-RealTaskText $assignment.authorization.reference "human authorization reference"
            foreach ($field in @("implementation", "merge")) {
                if ($assignment.authorization[$field] -isnot [bool]) { throw "Authorization capabilities must be booleans." }
            }
            if ($assignment.action -cnotin @("implement", "repair", "finalize") -or
                $assignment.workerId -cnotin @("developer-1", "developer-2")) { throw "Invalid assignment action/worker." }
            foreach ($field in @("branch", "worktree", "pr", "checkpoint", "expectedHead")) {
                if ($null -ne $assignment[$field] -or $assignment.action -cne "implement") {
                    Assert-RealTaskText $assignment[$field] $field
                }
            }
            if ($null -ne $assignment.worktree -and -not [IO.Path]::IsPathFullyQualified($assignment.worktree)) {
                throw "Assignment worktree must be absolute."
            }
            if ($null -ne $assignment.expectedHead -and $assignment.expectedHead -cnotmatch '^[0-9a-f]{40}$') {
                throw "Expected full assignment head SHA."
            }
            foreach ($field in @("feedback", "priorRepairEvidence")) {
                if ($assignment[$field] -isnot [array]) { throw "Assignment $field must be an array." }
                foreach ($reference in $assignment[$field]) { Assert-RealTaskText $reference "evidence reference" }
            }
            if ($assignment.repairAttempt -isnot [int] -and $assignment.repairAttempt -isnot [long]) {
                throw "Repair attempt must be an integer."
            }
            if ($assignment.action -ceq "repair") {
                $strategy = if ($assignment.repairAttempt -eq 1) { "targeted" } else { "reassess" }
                if ($assignment.repairAttempt -lt 1 -or $assignment.repairAttempt -gt 12 -or
                    $assignment.strategy -cne $strategy) { throw "Invalid repair attempt/strategy." }
                Assert-RealTaskEvidence $assignment.feedback
                if ($assignment.repairAttempt -gt 1) { Assert-RealTaskEvidence $assignment.priorRepairEvidence }
            } elseif ($assignment.repairAttempt -ne 0 -or $null -ne $assignment.strategy) {
                throw "Only repairs use an attempt and strategy."
            }
            if ($assignment.action -ceq "finalize") { Assert-RealTaskEvidence $assignment.feedback }
        }
        { $_ -cin @("acknowledgment", "result") } {
            if ($Message.recipient.agentId -cne "dispatcher") { throw "Worker events target Dispatcher." }
            Assert-RealTaskFields $Message.payload @("schema")
            if ($Message.payload.schema -cne "fingvibe-real-event-v1") {
                Stop-RealTaskProtocol "unsupported-schema" "Unsupported event schema."
            }
            Assert-RealTaskEvent $Message.payload
            $kind = if ($Message.type -ceq "acknowledgment") { "ack" } else { "result" }
            if ($Message.payload.kind -cne $kind) { throw "Message type/event kind mismatch." }
        }
        "blocker" {
            Assert-RealTaskFields $Message.payload @("code", "explanation", "nextOwner", "nextAction", "evidence") -Closed
            if ($Message.payload.code -cnotin @("missing-evidence", "unavailable-capability", "scope-conflict",
                "publication-failed", "uncertain-delivery", "authorization", "other")) { throw "Unknown blocker code." }
            foreach ($field in @("explanation", "nextOwner", "nextAction")) {
                Assert-RealTaskText $Message.payload[$field] $field
            }
            Assert-RealTaskEvidence $Message.payload.evidence
        }
        "clarification_request" {
            Assert-RealTaskFields $Message.payload @("question", "evidence") -Closed
            Assert-RealTaskText $Message.payload.question "question"
            Assert-RealTaskEvidence $Message.payload.evidence
        }
        "clarification_reply" {
            Assert-RealTaskFields $Message.payload @("answer", "evidence") -Closed
            Assert-RealTaskText $Message.payload.answer "answer"
            Assert-RealTaskEvidence $Message.payload.evidence
        }
        "notification" {
            Assert-RealTaskFields $Message.payload @("reason") -Closed
            if ($Message.payload.reason -cne "record-available") { throw "Unknown notification reason." }
        }
        "protocol_error" {
            Assert-RealTaskFields $Message.payload @("code", "explanation", "evidence") -Closed
            if ($Message.payload.code -cnotin $script:ProtocolCodes) { throw "Unknown protocol error code." }
            Assert-RealTaskText $Message.payload.explanation "protocol explanation"
            Assert-RealTaskEvidence $Message.payload.evidence
        }
    }
}

function Get-RealTaskProtocolPath([string] $Directory, [string] $Area, [string] $Id) {
    if (-not [IO.Path]::IsPathFullyQualified($Directory)) { throw "Protocol directory must be absolute." }
    if ($Id -cnotmatch '^[a-zA-Z0-9-]+$') { throw "Unsafe record filename." }
    Join-Path (Join-Path $Directory $Area) "$Id.json"
}

function Assert-RealTaskRecordPath($Message, [string] $Directory) {
    $area = if ($Message.type -cin @("acknowledgment", "result")) { "events" } else { "records" }
    $allowed = @(Get-RealTaskProtocolPath $Directory $area $Message.record.id)
    if ($Message.type -ceq "notification") {
        $allowed += Get-RealTaskProtocolPath $Directory "events" $Message.record.id
    }
    $actual = [IO.Path]::GetFullPath($Message.record.path)
    if (@($allowed | Where-Object { [string]::Equals($_, $actual, [StringComparison]::OrdinalIgnoreCase) }).Count -ne 1) {
        Stop-RealTaskProtocol "publication-mismatch" "Record must be in the configured shared records/events directory."
    }
}

function Assert-RealTaskMessageBinding($Message, $State, $Sender, $Recipient, [string] $Directory, [switch] $Receiving) {
    Assert-RealTaskMessageShape $Message
    Assert-RealTaskEndpoint $Sender
    Assert-RealTaskEndpoint $Recipient
    if ((Get-RealTaskHash $Message.sender) -cne (Get-RealTaskHash $Sender) -or
        (Get-RealTaskHash $Message.recipient) -cne (Get-RealTaskHash $Recipient)) {
        Stop-RealTaskProtocol "identity-mismatch" "Message identities differ from independently observed host identities."
    }
    Assert-RealTaskState $State
    foreach ($endpoint in @($Sender, $Recipient)) {
        if ($endpoint.agentId -cne "dispatcher") {
            $worker = @($State.workers | Where-Object id -CEQ $endpoint.agentId)[0]
            if ($worker.automationId -cne $endpoint.automationId) {
                Stop-RealTaskProtocol "identity-mismatch" "Worker Automation differs from configured identity."
            }
        }
    }
    Assert-RealTaskRecordPath $Message $Directory
    if ($null -eq $Message.context) { return }
    if ($Message.context.repository -cne $State.repository -or $Message.context.epic -ne $State.epic) {
        Stop-RealTaskProtocol "correlation-mismatch" "Message targets a different repository/Epic."
    }
    $task = Find-RealTask $State $Message.context.claimId
    $handoff = Find-RealTaskHandoff $State $Message.context.claimId $Message.context.handoffId
    $developer = if ($Sender.agentId -ceq "dispatcher") { $Recipient } else { $Sender }
    if ($task.issue -ne $Message.context.issue -or $handoff.workerId -cne $developer.agentId -or
        $handoff.runId -cne $developer.runId -or $handoff.sessionId -cne $developer.sessionId) {
        Stop-RealTaskProtocol "correlation-mismatch" "Message differs from actual assigned task/worker/run/session."
    }
    if ($Message.type -ceq "assignment") {
        foreach ($field in @("repository", "epic", "issue", "claimId", "handoffId")) {
            if ($Message.payload[$field] -cne $Message.context[$field]) {
                Stop-RealTaskProtocol "correlation-mismatch" "Assignment envelope/payload mismatch: $field."
            }
        }
        $consumed = $handoff.stage -cin @("acknowledged", "result-recorded", "stopped-verified", "reconciled")
        foreach ($prefix in @("ack-", "result-")) {
            $path = Get-RealTaskProtocolPath $Directory "events" "$prefix$($handoff.id)"
            if ([IO.File]::Exists($path)) {
                $event = Read-RealTaskJson $path
                Assert-RealTaskEvent $event
                if ($event.eventId -cne "$prefix$($handoff.id)" -or $event.claimId -cne $task.claimId -or
                    $event.workerId -cne $handoff.workerId -or $event.runId -cne $handoff.runId -or
                    $event.sessionId -cne $handoff.sessionId) {
                    Stop-RealTaskProtocol "correlation-mismatch" "Canonical execution event differs from assigned handoff."
                }
                $indexed = @($State.events | Where-Object id -CEQ $event.eventId)
                if ($indexed.Count -gt 0 -and $indexed[0].hash -cne (Get-RealTaskHash $event)) {
                    Stop-RealTaskProtocol "conflicting-duplicate" "Canonical execution event differs from its retained hash."
                }
                $consumed = $true
            } elseif (($prefix -ceq "ack-" -and $null -ne $handoff.ackEventId) -or
                ($prefix -ceq "result-" -and $null -ne $handoff.resultEventId)) {
                Stop-RealTaskProtocol "publication-mismatch" "Previously indexed execution event is missing."
            }
        }
        if (-not ($Receiving -and $consumed)) {
            if (-not $State.authorization.implementation) {
                Stop-RealTaskProtocol "authority-mismatch" "Implementation is not authorized."
            }
            Assert-RealTaskAssignmentCore $State $Message.payload $Recipient.agentId $Recipient.runId $Recipient.sessionId
        }
    } elseif ($Message.type -cin @("acknowledgment", "result")) {
        foreach ($field in @("claimId", "handoffId")) {
            if ($Message.payload[$field] -cne $Message.context[$field]) {
                Stop-RealTaskProtocol "correlation-mismatch" "Event envelope/payload mismatch: $field."
            }
        }
        foreach ($field in @("workerId", "runId", "sessionId", "action")) {
            if ($Message.payload[$field] -cne $handoff[$field]) {
                Stop-RealTaskProtocol "correlation-mismatch" "Worker event differs from assigned handoff: $field."
            }
        }
        if ($Message.payload.kind -ceq "result" -and $Message.payload.result.outcome -ceq "delivered" -and
            -not $State.authorization.merge) { Stop-RealTaskProtocol "authority-mismatch" "Merge is not authorized." }
        $null = Test-RealTaskEvent $State $Message.payload
    }
    if ($Message.type -ceq "clarification_reply") {
        $requestPath = Get-RealTaskProtocolPath $Directory "messages" $Message.inReplyTo
        $request = Read-RealTaskJson $requestPath
        Assert-RealTaskMessageShape $request
        if ($request.type -cne "clarification_request" -or
            (Get-RealTaskHash $request.context) -cne (Get-RealTaskHash $Message.context) -or
            (Get-RealTaskHash $request.sender) -cne (Get-RealTaskHash $Recipient) -or
            (Get-RealTaskHash $request.recipient) -cne (Get-RealTaskHash $Sender)) {
            Stop-RealTaskProtocol "correlation-mismatch" "Clarification reply must answer the original request in the same handoff."
        }
    }
}

function New-RealTaskMessage {
    param([string] $Type, $Sender, $Recipient, $Context, $Payload, [string] $Directory,
        $InReplyTo = $null, $Record = $null,
        [string] $SentUtc = ([DateTime]::UtcNow.ToString("o")))
    $prior = $null
    if ($Type -cin @("assignment", "acknowledgment", "result")) {
        $identity = Get-RealTaskHash @{ type = $Type; claimId = $Context.claimId; handoffId = $Context.handoffId }
        $messageId = [guid]::ParseExact($identity.Substring(0, 32), "N").ToString()
        $path = Get-RealTaskProtocolPath $Directory "messages" $messageId
        if ([IO.File]::Exists($path)) {
            $prior = Read-RealTaskJson $path
            $SentUtc = $prior.sentUtc
        }
    } else { $messageId = [guid]::NewGuid().ToString() }
    if ($null -eq $Record) {
        if ($Type -ceq "notification") { throw "Notification requires an existing immutable record reference." }
        $id = if ($Type -cin @("acknowledgment", "result")) { $Payload.eventId } else { $messageId }
        $area = if ($Type -cin @("acknowledgment", "result")) { "events" } else { "records" }
        $Record = @{ id = $id; path = Get-RealTaskProtocolPath $Directory $area $id; hash = Get-RealTaskHash $Payload }
    }
    $message = @{
        schema = "fingvibe-real-message-v1"; messageId = $messageId; type = $Type
        sender = $Sender; recipient = $Recipient; context = $Context; sentUtc = $SentUtc
        inReplyTo = $InReplyTo; record = $Record; payload = $Payload
    }
    Assert-RealTaskMessageShape $message
    if ($null -ne $prior -and (Get-RealTaskHash $prior) -cne (Get-RealTaskHash $message)) {
        Stop-RealTaskProtocol "conflicting-duplicate" "Handoff message already published with different content or identities."
    }
    return $message
}

function Write-RealTaskProtocolRecord($Record, [string] $Path) {
    if ([IO.File]::Exists($Path)) {
        if ((Get-RealTaskHash (Read-RealTaskJson $Path)) -cne (Get-RealTaskHash $Record)) {
            Stop-RealTaskProtocol "conflicting-duplicate" "Conflicting immutable protocol record: $Path."
        }
    } else { Write-RealTaskAtomic $Record $Path -Immutable }
}

function Assert-RealTaskNotificationRecord($Message, $Record, [string] $Directory) {
    $eventPath = Get-RealTaskProtocolPath $Directory "events" $Message.record.id
    if ([string]::Equals($eventPath, [IO.Path]::GetFullPath($Message.record.path), [StringComparison]::OrdinalIgnoreCase)) {
        Assert-RealTaskEvent $Record
        if ($Record.eventId -cne $Message.record.id -or $Record.claimId -cne $Message.context.claimId -or
            $Record.handoffId -cne $Message.context.handoffId) {
            Stop-RealTaskProtocol "correlation-mismatch" "Notification event belongs to a different handoff."
        }
    } else {
        $source = Read-RealTaskJson (Get-RealTaskProtocolPath $Directory "messages" $Message.record.id)
        Assert-RealTaskMessageShape $source
        if ($source.type -ceq "notification" -or
            (Get-RealTaskHash $source.record) -cne (Get-RealTaskHash $Message.record) -or
            (Get-RealTaskHash $source.context) -cne (Get-RealTaskHash $Message.context) -or
            (Get-RealTaskHash $source.payload) -cne $Message.record.hash) {
            Stop-RealTaskProtocol "correlation-mismatch" "Notification record belongs to a different message/handoff."
        }
    }
}

function Publish-RealTaskMessage {
    param($Message, $State, $Sender, $Recipient, [string] $Directory)
    Assert-RealTaskMessageBinding $Message $State $Sender $Recipient $Directory
    if ($Message.type -ceq "protocol_error") {
        if ($null -eq $Message.inReplyTo) { throw "Uncorrelated protocol errors are diagnostic-only, not sent." }
        $reservation = Read-RealTaskJson (Get-RealTaskProtocolPath $Directory "responses" $Message.inReplyTo)
        if ($reservation.messageId -cne $Message.messageId) {
            throw "Protocol errors require the unique Publish-RealTaskProtocolError reservation."
        }
    }
    if ($Message.type -ceq "notification") {
        $record = Read-RealTaskJson $Message.record.path
        if ((Get-RealTaskHash $record) -cne $Message.record.hash) {
            Stop-RealTaskProtocol "publication-mismatch" "Notification target hash differs from published record."
        }
        Assert-RealTaskNotificationRecord $Message $record $Directory
    } else {
        if ((Get-RealTaskHash $Message.payload) -cne $Message.record.hash) {
            Stop-RealTaskProtocol "publication-mismatch" "Payload hash differs from record reference."
        }
        if ($Message.type -cin @("acknowledgment", "result") -and $Message.record.id -cne $Message.payload.eventId) {
            throw "Event record ID mismatch."
        }
        if ($Message.type -ceq "acknowledgment" -and -not [IO.File]::Exists($Message.record.path)) {
            throw "Reserve acknowledgment with Publish-RealTaskAcknowledgment before messaging; publication cannot reserve execution."
        }
        Write-RealTaskProtocolRecord $Message.payload $Message.record.path
    }
    $path = Get-RealTaskProtocolPath $Directory "messages" $Message.messageId
    Write-RealTaskProtocolRecord $Message $path
    return $path
}

function Get-RealTaskDecision($Message, [string] $Disposition, [string] $Operation,
    [string] $ReasonCode, $DiagnosticPath = $null, [bool] $ResponseAllowed = $false) {
    @{
        schema = "fingvibe-real-decision-v1"; disposition = $Disposition; operation = $Operation
        reasonCode = $ReasonCode; messageId = $(if ($null -eq $Message) { $null } else { $Message.messageId })
        payloadPath = $(if ($null -eq $Message -or $Disposition -ceq "rejected") { $null } else { $Message.record.path })
        diagnosticPath = $DiagnosticPath; responseAllowed = $ResponseAllowed
        nextOwner = $(if ($null -eq $Message) { "human" } else { $Message.recipient.agentId })
        requiredEvidence = @(if ($Operation -clike "acknowledge-*") {
            @("actual-host-and-sender", "human-authorization", "native-membership-and-claim",
                "current-labels-head-and-conflicts", "atomic-acknowledgment-before-execution")
        } elseif ($Operation -ceq "ingest-event") {
            @("actual-event-reporter", "owned-gate-and-fresh-state", "independent-stopped-session-before-release")
        } else { @() })
    }
}

function Assert-RealTaskReceipt($Receipt, [string] $MessageId, [string] $Hash, [string] $Phase) {
    Assert-RealTaskFields $Receipt @("schema", "messageId", "messageHash", "phase", "utc", "evidence") -Closed
    if ($Receipt.schema -cne "fingvibe-real-receipt-v1" -or $Receipt.messageId -cne $MessageId -or
        $Receipt.messageHash -cne $Hash -or $Receipt.phase -cne $Phase) {
        Stop-RealTaskProtocol "conflicting-duplicate" "Receipt refers to a conflicting message or processing phase."
    }
    Assert-RealTaskUtc $Receipt.utc
    Assert-RealTaskEvidence $Receipt.evidence
}

function Receive-RealTaskMessage {
    param([string] $Json, $State, $Sender, $Recipient, [string] $Directory, [string[]] $Evidence)
    Assert-RealTaskEndpoint $Sender
    Assert-RealTaskEndpoint $Recipient
    Assert-RealTaskEvidence $Evidence
    $message = $null
    $parsed = $null
    $code = "invalid-json"
    try {
        $parsed = ConvertFrom-RealTaskJson $Json
        $code = "invalid-message"
        Assert-RealTaskMessageBinding $parsed $State $Sender $Recipient $Directory -Receiving
        $message = $parsed
        $code = "publication-mismatch"
        $stored = Read-RealTaskJson (Get-RealTaskProtocolPath $Directory "messages" $message.messageId)
        $messageHash = Get-RealTaskHash $message
        if ((Get-RealTaskHash $stored) -cne $messageHash) {
            Stop-RealTaskProtocol "conflicting-duplicate" "Wire message differs from its immutable published envelope."
        }
        $record = Read-RealTaskJson $message.record.path
        $hash = Get-RealTaskHash $record
        if ($hash -cne $message.record.hash -or ($message.type -cne "notification" -and
            $hash -cne (Get-RealTaskHash $message.payload))) {
            Stop-RealTaskProtocol "publication-mismatch" "Referenced immutable content differs from message."
        }
        if ($message.type -ceq "notification") { Assert-RealTaskNotificationRecord $message $record $Directory }
        $code = "invalid-message"
        if ($message.type -ceq "assignment") {
            $handoff = Find-RealTaskHandoff $State $message.context.claimId $message.context.handoffId
            if ($handoff.stage -cnotin @("correlated", "delivered")) {
                return Get-RealTaskDecision $message "duplicate" "none" "handoff-already-consumed"
            }
            foreach ($prefix in @("ack-", "result-")) {
                if ([IO.File]::Exists((Get-RealTaskProtocolPath $Directory "events" "$prefix$($message.context.handoffId)"))) {
                    return Get-RealTaskDecision $message "duplicate" "none" "execution-already-reserved"
                }
            }
            return Get-RealTaskDecision $message "ready" "acknowledge-$($message.payload.action)" "assignment-validated"
        }
        if ($message.type -cin @("acknowledgment", "result")) {
            $seen = @($State.events | Where-Object id -CEQ $message.payload.eventId)
            if ($seen.Count -gt 0) { return Get-RealTaskDecision $message "duplicate" "none" "event-already-ingested" }
            return Get-RealTaskDecision $message "ready" "ingest-event" "event-validated"
        }
        $receiptPath = Get-RealTaskProtocolPath $Directory "receipts" $message.messageId
        if ([IO.File]::Exists($receiptPath)) {
            $receipt = Read-RealTaskJson $receiptPath
            Assert-RealTaskReceipt $receipt $message.messageId $messageHash "reserved"
            $processedPath = Get-RealTaskProtocolPath $Directory "receipts" "processed-$($message.messageId)"
            if ([IO.File]::Exists($processedPath)) {
                Assert-RealTaskReceipt (Read-RealTaskJson $processedPath) $message.messageId $messageHash "processed"
                return Get-RealTaskDecision $message "duplicate" "none" "message-already-processed"
            }
            return Get-RealTaskDecision $message "duplicate" "none" "message-processing-reserved"
        }
        $operation = switch -CaseSensitive ($message.type) {
            "blocker" { "inspect-blocker" }
            "clarification_request" { "answer-clarification" }
            "clarification_reply" { "read-clarification" }
            "notification" { "reconcile-record" }
            "protocol_error" { "inspect-protocol-error" }
        }
        $receipt = @{
            schema = "fingvibe-real-receipt-v1"; messageId = $message.messageId; messageHash = $messageHash
            phase = "reserved"; utc = [DateTime]::UtcNow.ToString("o"); evidence = $Evidence
        }
        try { Write-RealTaskAtomic $receipt $receiptPath -Immutable }
        catch [IO.IOException] {
            if (-not [IO.File]::Exists($receiptPath)) { throw }
            Assert-RealTaskReceipt (Read-RealTaskJson $receiptPath) $message.messageId $messageHash "reserved"
            return Get-RealTaskDecision $message "duplicate" "none" "message-processing-reserved"
        }
        Get-RealTaskDecision $message "ready" $operation "message-validated"
    } catch {
        if ($_.Exception.Data.Contains("protocolCode")) { $code = $_.Exception.Data["protocolCode"] }
        $rawHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Json)))
        $id = Get-RealTaskHash @{ rawHash = $rawHash; sender = $Sender; recipient = $Recipient }
        $path = Get-RealTaskProtocolPath $Directory "diagnostics" $id
        $replyAllowed = $null -ne $parsed -and $parsed.Contains("messageId") -and
            $parsed.messageId -is [string] -and $parsed.messageId -cmatch '^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$' -and
            $parsed.messageId -cne [guid]::Empty.ToString() -and $parsed.Contains("type") -and
            $parsed.type -is [string] -and $parsed.type -cne "protocol_error" -and $parsed.Contains("sender") -and
            (Get-RealTaskHash $parsed.sender) -ceq (Get-RealTaskHash $Sender)
        if (-not [IO.File]::Exists($path)) {
            $diagnostic = @{
                schema = "fingvibe-real-diagnostic-v1"; id = $id; rawHash = $rawHash; code = $code
                explanation = $_.Exception.Message; utc = [DateTime]::UtcNow.ToString("o")
                sender = $Sender; recipient = $Recipient; evidence = $Evidence
                inReplyTo = $(if ($replyAllowed) { $parsed.messageId } else { $null })
            }
            Write-RealTaskAtomic $diagnostic $path -Immutable
        }
        $decision = Get-RealTaskDecision $message "rejected" "none" $code $path $replyAllowed
        $decision.nextOwner = $Recipient.agentId
        return $decision
    }
}

function Confirm-RealTaskMessage {
    param($Message, $State, $Sender, $Recipient, [string] $Directory, [string[]] $Evidence)
    if ($Message.type -cin @("assignment", "acknowledgment", "result") -or
        -not [IO.File]::Exists((Get-RealTaskProtocolPath $Directory "receipts" $Message.messageId))) {
        throw "Only received informational messages can be confirmed; assignments/events use existing atomic guards."
    }
    $decision = Receive-RealTaskMessage ($Message | ConvertTo-Json -Depth 100 -Compress) $State $Sender $Recipient $Directory $Evidence
    if ($decision.disposition -ceq "rejected") {
        throw "Cannot confirm rejected message. Inspect $($decision.diagnosticPath)."
    }
    if ($decision.reasonCode -ceq "message-already-processed") { return }
    $receipt = @{
        schema = "fingvibe-real-receipt-v1"; messageId = $Message.messageId; messageHash = Get-RealTaskHash $Message
        phase = "processed"; utc = [DateTime]::UtcNow.ToString("o"); evidence = $Evidence
    }
    Write-RealTaskAtomic $receipt (Get-RealTaskProtocolPath $Directory "receipts" "processed-$($Message.messageId)") -Immutable
}

function Publish-RealTaskProtocolError {
    param([string] $DiagnosticPath, $State, [string] $Directory)
    $diagnostic = Read-RealTaskJson $DiagnosticPath
    if ($diagnostic.schema -cne "fingvibe-real-diagnostic-v1" -or $null -eq $diagnostic.inReplyTo) {
        throw "No safely correlated protocol response is available; preserve the diagnostic without replying."
    }
    $expectedPath = Get-RealTaskProtocolPath $Directory "diagnostics" $diagnostic.id
    if (-not [string]::Equals($expectedPath, [IO.Path]::GetFullPath($DiagnosticPath), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Diagnostic must come from this environment."
    }
    $reservationPath = Get-RealTaskProtocolPath $Directory "responses" $diagnostic.inReplyTo
    if ([IO.File]::Exists($reservationPath)) { throw "Protocol error response already reserved; never resend an uncertain reply." }
    $message = New-RealTaskMessage -Type protocol_error -Sender $diagnostic.recipient -Recipient $diagnostic.sender `
        -Context $null -Payload @{ code = $diagnostic.code; explanation = $diagnostic.explanation
            evidence = @($DiagnosticPath) } -Directory $Directory -InReplyTo $diagnostic.inReplyTo
    Write-RealTaskAtomic @{ diagnostic = $DiagnosticPath; messageId = $message.messageId; utc = $message.sentUtc } `
        $reservationPath -Immutable
    Publish-RealTaskMessage $message $State $diagnostic.recipient $diagnostic.sender $Directory
}
