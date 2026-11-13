$script:MessageTypes = @("assignment", "acknowledgment", "result", "blocker",
    "clarification_request", "clarification_reply", "notification", "protocol_error")
$script:ProtocolCodes = @("invalid-json", "unsupported-schema", "invalid-message",
    "identity-mismatch", "correlation-mismatch", "authority-mismatch",
    "conflicting-duplicate", "publication-mismatch", "internal-error")

function Stop-Agent3Protocol([string] $Code, [string] $Explanation) {
    $error = [InvalidOperationException]::new($Explanation)
    $error.Data["protocolCode"] = $Code
    throw $error
}

function Assert-Agent3Uuid($Value) {
    if ($Value -isnot [string] -or $Value -cnotmatch '^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$' -or
        $Value -ceq [guid]::Empty.ToString()) { throw "Expected nonempty lowercase UUID." }
}

function Assert-Agent3Endpoint($Endpoint) {
    Assert-Agent3Fields $Endpoint @("agentId", "automationId", "runId", "sessionId") -Closed
    Assert-Agent3Text $Endpoint.agentId "agent ID"
    if ($Endpoint.agentId -cnotin @("dispatcher", "developer-1", "developer-2")) { throw "Unknown agent identity." }
    Assert-Agent3Text $Endpoint.sessionId "actual session ID"
    foreach ($field in @("automationId", "runId")) {
        if ($Endpoint.agentId -cne "dispatcher" -or $null -ne $Endpoint[$field]) {
            Assert-Agent3Text $Endpoint[$field] "actual $field"
        }
    }
}

function Assert-Agent3Context($Context) {
    Assert-Agent3Fields $Context @("repository", "epic", "issue", "claimId", "handoffId") -Closed
    if ($Context.repository -isnot [string] -or
        $Context.repository -cnotmatch '^[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9_.-]*$') {
        throw "Expected normalized repository."
    }
    foreach ($field in @("epic", "issue")) {
        if (($Context[$field] -isnot [int] -and $Context[$field] -isnot [long]) -or $Context[$field] -lt 1) {
            throw "Expected positive integer $field."
        }
    }
    Assert-Agent3Uuid $Context.claimId
    Assert-Agent3Uuid $Context.handoffId
}

function Assert-Agent3MessageShape($Message) {
    Assert-Agent3Fields $Message @("schema", "messageId", "type", "sender", "recipient",
        "context", "sentUtc", "inReplyTo", "record", "payload") -Closed
    Assert-Agent3Text $Message.schema "message schema"
    if ($Message.schema -cne "fingvibe-real-message-v1") {
        Stop-Agent3Protocol "unsupported-schema" "Unsupported message schema; no automatic migration."
    }
    Assert-Agent3Uuid $Message.messageId
    Assert-Agent3Text $Message.type "message type"
    if ($Message.type -cnotin $script:MessageTypes) { throw "Unsupported message type." }
    Assert-Agent3Endpoint $Message.sender
    Assert-Agent3Endpoint $Message.recipient
    if (($Message.sender.agentId -ceq "dispatcher") -eq ($Message.recipient.agentId -ceq "dispatcher")) {
        throw "Messages must cross the Dispatcher/Developer boundary."
    }
    Assert-Agent3Utc $Message.sentUtc
    if ($null -ne $Message.inReplyTo) { Assert-Agent3Uuid $Message.inReplyTo }
    if ($Message.type -cin @("clarification_reply", "protocol_error")) {
        if ($null -eq $Message.inReplyTo) { throw "Replies require inReplyTo." }
    } elseif ($null -ne $Message.inReplyTo) { throw "Only clarification replies and protocol errors use inReplyTo." }
    if ($null -eq $Message.context) {
        if ($Message.type -cne "protocol_error") { throw "Task context is required." }
    } else { Assert-Agent3Context $Message.context }
    Assert-Agent3Fields $Message.record @("id", "path", "hash") -Closed
    Assert-Agent3Text $Message.record.id "record ID"
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
            Assert-Agent3Fields $Message.payload @("schema", "repository", "epic", "issue", "claimId",
                "handoffId", "action", "workerId", "runId", "sessionId", "targetBranch", "authorization",
                "branch", "worktree", "pr", "expectedHead", "checkpoint", "repairAttempt", "strategy",
                "feedback", "priorRepairEvidence") -Closed
            Assert-Agent3Fields $Message.payload.authorization @("reference", "implementation", "merge") -Closed
            Assert-Agent3Text $Message.payload.schema "assignment schema"
            if ($Message.payload.schema -cne "fingvibe-real-assignment-v1") {
                Stop-Agent3Protocol "unsupported-schema" "Unsupported assignment schema."
            }
            $assignment = $Message.payload
            Assert-Agent3Context @{ repository = $assignment.repository; epic = $assignment.epic; issue = $assignment.issue
                claimId = $assignment.claimId; handoffId = $assignment.handoffId }
            foreach ($field in @("action", "workerId", "runId", "sessionId", "targetBranch")) {
                Assert-Agent3Text $assignment[$field] $field
            }
            Assert-Agent3Text $assignment.authorization.reference "human authorization reference"
            foreach ($field in @("implementation", "merge")) {
                if ($assignment.authorization[$field] -isnot [bool]) { throw "Authorization capabilities must be booleans." }
            }
            if ($assignment.action -cnotin @("implement", "repair", "finalize") -or
                $assignment.workerId -cnotin @("developer-1", "developer-2")) { throw "Invalid assignment action/worker." }
            foreach ($field in @("branch", "worktree", "pr", "checkpoint", "expectedHead")) {
                if ($null -ne $assignment[$field] -or $assignment.action -cne "implement") {
                    Assert-Agent3Text $assignment[$field] $field
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
                foreach ($reference in $assignment[$field]) { Assert-Agent3Text $reference "evidence reference" }
            }
            if ($assignment.repairAttempt -isnot [int] -and $assignment.repairAttempt -isnot [long]) {
                throw "Repair attempt must be an integer."
            }
            if ($assignment.action -ceq "repair") {
                Assert-Agent3Text $assignment.strategy "repair strategy"
                $strategy = if ($assignment.repairAttempt -eq 1) { "targeted" } else { "reassess" }
                if ($assignment.repairAttempt -lt 1 -or $assignment.repairAttempt -gt 12 -or
                    $assignment.strategy -cne $strategy) { throw "Invalid repair attempt/strategy." }
                Assert-Agent3Evidence $assignment.feedback
                if ($assignment.repairAttempt -gt 1) { Assert-Agent3Evidence $assignment.priorRepairEvidence }
            } elseif ($assignment.repairAttempt -ne 0 -or $null -ne $assignment.strategy) {
                throw "Only repairs use an attempt and strategy."
            }
            if ($assignment.action -ceq "finalize") { Assert-Agent3Evidence $assignment.feedback }
        }
        { $_ -cin @("acknowledgment", "result") } {
            if ($Message.recipient.agentId -cne "dispatcher") { throw "Worker events target Dispatcher." }
            Assert-Agent3Fields $Message.payload @("schema")
            Assert-Agent3Text $Message.payload.schema "event schema"
            if ($Message.payload.schema -cne "fingvibe-real-event-v1") {
                Stop-Agent3Protocol "unsupported-schema" "Unsupported event schema."
            }
            Assert-Agent3Event $Message.payload
            $kind = if ($Message.type -ceq "acknowledgment") { "ack" } else { "result" }
            if ($Message.payload.kind -cne $kind) { throw "Message type/event kind mismatch." }
        }
        "blocker" {
            Assert-Agent3Fields $Message.payload @("code", "explanation", "nextOwner", "nextAction", "evidence") -Closed
            Assert-Agent3Text $Message.payload.code "blocker code"
            if ($Message.payload.code -cnotin @("missing-evidence", "unavailable-capability", "scope-conflict",
                "publication-failed", "uncertain-delivery", "authorization", "other")) { throw "Unknown blocker code." }
            foreach ($field in @("explanation", "nextOwner", "nextAction")) {
                Assert-Agent3Text $Message.payload[$field] $field
            }
            Assert-Agent3Evidence $Message.payload.evidence
        }
        "clarification_request" {
            Assert-Agent3Fields $Message.payload @("question", "evidence") -Closed
            Assert-Agent3Text $Message.payload.question "question"
            Assert-Agent3Evidence $Message.payload.evidence
        }
        "clarification_reply" {
            Assert-Agent3Fields $Message.payload @("answer", "evidence") -Closed
            Assert-Agent3Text $Message.payload.answer "answer"
            Assert-Agent3Evidence $Message.payload.evidence
        }
        "notification" {
            Assert-Agent3Fields $Message.payload @("reason") -Closed
            Assert-Agent3Text $Message.payload.reason "notification reason"
            if ($Message.payload.reason -cne "record-available") { throw "Unknown notification reason." }
        }
        "protocol_error" {
            Assert-Agent3Fields $Message.payload @("code", "explanation", "evidence") -Closed
            Assert-Agent3Text $Message.payload.code "protocol error code"
            if ($Message.payload.code -cnotin $script:ProtocolCodes) { throw "Unknown protocol error code." }
            Assert-Agent3Text $Message.payload.explanation "protocol explanation"
            Assert-Agent3Evidence $Message.payload.evidence
        }
    }
}

function Get-Agent3ProtocolPath([string] $Directory, [string] $Area, [string] $Id) {
    if (-not [IO.Path]::IsPathFullyQualified($Directory)) { throw "Protocol directory must be absolute." }
    if ($Id -cnotmatch '^[a-zA-Z0-9-]+$') { throw "Unsafe record filename." }
    Join-Path (Join-Path $Directory $Area) "$Id.json"
}

function Assert-Agent3RecordPath($Message, [string] $Directory) {
    $area = if ($Message.type -cin @("acknowledgment", "result")) { "events" } else { "records" }
    $allowed = @(Get-Agent3ProtocolPath $Directory $area $Message.record.id)
    if ($Message.type -ceq "notification") {
        $allowed += Get-Agent3ProtocolPath $Directory "events" $Message.record.id
    }
    $actual = [IO.Path]::GetFullPath($Message.record.path)
    if (@($allowed | Where-Object { [string]::Equals($_, $actual, [StringComparison]::OrdinalIgnoreCase) }).Count -ne 1) {
        Stop-Agent3Protocol "publication-mismatch" "Record must be in the configured shared records/events directory."
    }
}

function Read-Agent3CanonicalEvent($State, [string] $ClaimId, $Handoff, [string] $Kind, [string] $Directory, [switch] $Required) {
    $id = "$Kind-$($Handoff.id)"
    $path = Get-Agent3ProtocolPath $Directory "events" $id
    $indexField = if ($Kind -ceq "ack") { "ackEventId" } else { "resultEventId" }
    if (-not [IO.File]::Exists($path)) {
        if ($Required -or $null -ne $Handoff[$indexField]) {
            Stop-Agent3Protocol "publication-mismatch" "Required canonical $Kind event is missing."
        }
        return $null
    }
    $event = Read-Agent3Json $path
    Assert-Agent3Event $event
    if ($event.eventId -cne $id -or $event.claimId -cne $ClaimId -or $event.handoffId -cne $Handoff.id) {
        Stop-Agent3Protocol "correlation-mismatch" "Canonical event differs from assigned claim/handoff."
    }
    foreach ($field in @("action", "workerId", "runId", "sessionId")) {
        if ($event[$field] -cne $Handoff[$field]) {
            Stop-Agent3Protocol "correlation-mismatch" "Canonical event differs from assigned handoff: $field."
        }
    }
    $indexed = @($State.events | Where-Object id -CEQ $event.eventId)
    if ($indexed.Count -gt 0 -and $indexed[0].hash -cne (Get-Agent3Hash $event)) {
        Stop-Agent3Protocol "conflicting-duplicate" "Canonical execution event differs from its retained hash."
    }
    return $event
}

function Assert-Agent3MessageBinding($Message, $State, $Sender, $Recipient, [string] $Directory, [switch] $Receiving) {
    Assert-Agent3MessageShape $Message
    Assert-Agent3Endpoint $Sender
    Assert-Agent3Endpoint $Recipient
    if ((Get-Agent3Hash $Message.sender) -cne (Get-Agent3Hash $Sender) -or
        (Get-Agent3Hash $Message.recipient) -cne (Get-Agent3Hash $Recipient)) {
        Stop-Agent3Protocol "identity-mismatch" "Message identities differ from independently observed host identities."
    }
    Assert-Agent3State $State
    foreach ($endpoint in @($Sender, $Recipient)) {
        if ($endpoint.agentId -cne "dispatcher") {
            $worker = @($State.workers | Where-Object id -CEQ $endpoint.agentId)[0]
            if ($worker.automationId -cne $endpoint.automationId) {
                Stop-Agent3Protocol "identity-mismatch" "Worker Automation differs from configured identity."
            }
        }
    }
    Assert-Agent3RecordPath $Message $Directory
    if ($null -eq $Message.context) { return }
    if ($Message.context.repository -cne $State.repository -or $Message.context.epic -ne $State.epic) {
        Stop-Agent3Protocol "correlation-mismatch" "Message targets a different repository/Epic."
    }
    $task = Find-Agent3 $State $Message.context.claimId
    $handoff = Find-Agent3Handoff $State $Message.context.claimId $Message.context.handoffId
    $developer = if ($Sender.agentId -ceq "dispatcher") { $Recipient } else { $Sender }
    if ($task.issue -ne $Message.context.issue -or $handoff.workerId -cne $developer.agentId -or
        $handoff.runId -cne $developer.runId -or $handoff.sessionId -cne $developer.sessionId) {
        Stop-Agent3Protocol "correlation-mismatch" "Message differs from actual assigned task/worker/run/session."
    }
    if ($Message.type -ceq "assignment") {
        foreach ($field in @("repository", "epic", "issue", "claimId", "handoffId")) {
            if ($Message.payload[$field] -cne $Message.context[$field]) {
                Stop-Agent3Protocol "correlation-mismatch" "Assignment envelope/payload mismatch: $field."
            }
        }
        $consumed = $handoff.stage -cin @("acknowledged", "result-recorded", "stopped-verified", "reconciled")
        foreach ($kind in @("ack", "result")) {
            $event = Read-Agent3CanonicalEvent $State $task.claimId $handoff $kind $Directory
            if ($null -ne $event) { $consumed = $true }
        }
        if (-not ($Receiving -and $consumed)) {
            if (-not $State.authorization.implementation) {
                Stop-Agent3Protocol "authority-mismatch" "Implementation is not authorized."
            }
            Assert-Agent3AssignmentCore $State $Message.payload $Recipient.agentId $Recipient.runId $Recipient.sessionId
        }
    } elseif ($Message.type -cin @("acknowledgment", "result")) {
        foreach ($field in @("claimId", "handoffId")) {
            if ($Message.payload[$field] -cne $Message.context[$field]) {
                Stop-Agent3Protocol "correlation-mismatch" "Event envelope/payload mismatch: $field."
            }
        }
        foreach ($field in @("workerId", "runId", "sessionId", "action")) {
            if ($Message.payload[$field] -cne $handoff[$field]) {
                Stop-Agent3Protocol "correlation-mismatch" "Worker event differs from assigned handoff: $field."
            }
        }
        if ($Message.payload.kind -ceq "result" -and $Message.payload.result.outcome -ceq "delivered" -and
            -not $State.authorization.merge) { Stop-Agent3Protocol "authority-mismatch" "Merge is not authorized." }
        $acknowledgmentVerified = $false
        if ($Message.type -ceq "result") {
            $required = $Message.payload.result.outcome -cne "blocked-before-start"
            $ack = Read-Agent3CanonicalEvent $State $task.claimId $handoff ack $Directory -Required:$required
            $acknowledgmentVerified = $null -ne $ack
        }
        $null = Test-Agent3Event $State $Message.payload -AcknowledgmentVerified:$acknowledgmentVerified
    }
    if ($Message.type -ceq "clarification_reply") {
        $requestPath = Get-Agent3ProtocolPath $Directory "messages" $Message.inReplyTo
        $request = Read-Agent3Json $requestPath
        Assert-Agent3MessageShape $request
        if ($request.messageId -cne $Message.inReplyTo -or $request.type -cne "clarification_request" -or
            (Get-Agent3Hash $request.context) -cne (Get-Agent3Hash $Message.context) -or
            (Get-Agent3Hash $request.sender) -cne (Get-Agent3Hash $Recipient) -or
            (Get-Agent3Hash $request.recipient) -cne (Get-Agent3Hash $Sender)) {
            Stop-Agent3Protocol "correlation-mismatch" "Clarification reply must answer the original request in the same handoff."
        }
        Assert-Agent3RecordPath $request $Directory
        $record = Read-Agent3Json $request.record.path
        if ((Get-Agent3Hash $record) -cne $request.record.hash -or
            (Get-Agent3Hash $request.payload) -cne $request.record.hash) {
            Stop-Agent3Protocol "publication-mismatch" "Original clarification request record differs from its envelope."
        }
    }
}

function New-Agent3Message {
    param([string] $Type, $Sender, $Recipient, $Context, $Payload, [string] $Directory,
        $InReplyTo = $null, $Record = $null,
        [string] $SentUtc = ([DateTime]::UtcNow.ToString("o")))
    $prior = $null
    if ($Type -cin @("assignment", "acknowledgment", "result")) {
        $identity = Get-Agent3Hash @{ type = $Type; claimId = $Context.claimId; handoffId = $Context.handoffId }
        $messageId = [guid]::ParseExact($identity.Substring(0, 32), "N").ToString()
        $path = Get-Agent3ProtocolPath $Directory "messages" $messageId
        if ([IO.File]::Exists($path)) {
            $prior = Read-Agent3Json $path
            $SentUtc = $prior.sentUtc
        }
    } else { $messageId = [guid]::NewGuid().ToString() }
    if ($null -eq $Record) {
        if ($Type -ceq "notification") { throw "Notification requires an existing immutable record reference." }
        $id = if ($Type -cin @("acknowledgment", "result")) { $Payload.eventId } else { $messageId }
        $area = if ($Type -cin @("acknowledgment", "result")) { "events" } else { "records" }
        $Record = @{ id = $id; path = Get-Agent3ProtocolPath $Directory $area $id; hash = Get-Agent3Hash $Payload }
    }
    $message = @{
        schema = "fingvibe-real-message-v1"; messageId = $messageId; type = $Type
        sender = $Sender; recipient = $Recipient; context = $Context; sentUtc = $SentUtc
        inReplyTo = $InReplyTo; record = $Record; payload = $Payload
    }
    Assert-Agent3MessageShape $message
    if ($null -ne $prior -and (Get-Agent3Hash $prior) -cne (Get-Agent3Hash $message)) {
        Stop-Agent3Protocol "conflicting-duplicate" "Handoff message already published with different content or identities."
    }
    return $message
}

function Write-Agent3ProtocolRecord($Record, [string] $Path) {
    if ([IO.File]::Exists($Path)) {
        if ((Get-Agent3Hash (Read-Agent3Json $Path)) -cne (Get-Agent3Hash $Record)) {
            Stop-Agent3Protocol "conflicting-duplicate" "Conflicting immutable protocol record: $Path."
        }
    } else { Write-Agent3Atomic $Record $Path -Immutable }
}

function Assert-Agent3NotificationRecord($Message, $Record, [string] $Directory) {
    $eventPath = Get-Agent3ProtocolPath $Directory "events" $Message.record.id
    if ([string]::Equals($eventPath, [IO.Path]::GetFullPath($Message.record.path), [StringComparison]::OrdinalIgnoreCase)) {
        Assert-Agent3Event $Record
        if ($Record.eventId -cne $Message.record.id -or $Record.claimId -cne $Message.context.claimId -or
            $Record.handoffId -cne $Message.context.handoffId) {
            Stop-Agent3Protocol "correlation-mismatch" "Notification event belongs to a different handoff."
        }
    } else {
        $source = Read-Agent3Json (Get-Agent3ProtocolPath $Directory "messages" $Message.record.id)
        Assert-Agent3MessageShape $source
        if ($source.type -ceq "notification" -or
            (Get-Agent3Hash $source.record) -cne (Get-Agent3Hash $Message.record) -or
            (Get-Agent3Hash $source.context) -cne (Get-Agent3Hash $Message.context) -or
            (Get-Agent3Hash $source.payload) -cne $Message.record.hash) {
            Stop-Agent3Protocol "correlation-mismatch" "Notification record belongs to a different message/handoff."
        }
    }
}

function Publish-Agent3Message {
    param($Message, $State, $Sender, $Recipient, [string] $Directory)
    Assert-Agent3MessageBinding $Message $State $Sender $Recipient $Directory
    if ($Message.type -ceq "protocol_error") {
        if ($null -eq $Message.inReplyTo) { throw "Uncorrelated protocol errors are diagnostic-only, not sent." }
        $reservation = Read-Agent3Json (Get-Agent3ProtocolPath $Directory "responses" $Message.inReplyTo)
        if ($reservation.messageId -cne $Message.messageId) {
            throw "Protocol errors require the unique Publish-Agent3ProtocolError reservation."
        }
    }
    if ($Message.type -ceq "notification") {
        $record = Read-Agent3Json $Message.record.path
        if ((Get-Agent3Hash $record) -cne $Message.record.hash) {
            Stop-Agent3Protocol "publication-mismatch" "Notification target hash differs from published record."
        }
        Assert-Agent3NotificationRecord $Message $record $Directory
    } else {
        if ((Get-Agent3Hash $Message.payload) -cne $Message.record.hash) {
            Stop-Agent3Protocol "publication-mismatch" "Payload hash differs from record reference."
        }
        if ($Message.type -cin @("acknowledgment", "result") -and $Message.record.id -cne $Message.payload.eventId) {
            throw "Event record ID mismatch."
        }
        if ($Message.type -ceq "acknowledgment" -and -not [IO.File]::Exists($Message.record.path)) {
            throw "Reserve acknowledgment with Publish-Agent3Acknowledgment before messaging; publication cannot reserve execution."
        }
        Write-Agent3ProtocolRecord $Message.payload $Message.record.path
    }
    $path = Get-Agent3ProtocolPath $Directory "messages" $Message.messageId
    Write-Agent3ProtocolRecord $Message $path
    return $path
}

function Get-Agent3Decision($Message, [string] $Disposition, [string] $Operation,
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
            if ($Message.type -ceq "result" -and $Message.payload.result.outcome -cne "blocked-before-start") {
                "ingest-canonical-acknowledgment-before-result"
            }
        } else { @() })
    }
}

function Assert-Agent3Receipt($Receipt, [string] $MessageId, [string] $Hash, [string] $Phase) {
    Assert-Agent3Fields $Receipt @("schema", "messageId", "messageHash", "phase", "utc", "evidence") -Closed
    if ($Receipt.schema -cne "fingvibe-real-receipt-v1" -or $Receipt.messageId -cne $MessageId -or
        $Receipt.messageHash -cne $Hash -or $Receipt.phase -cne $Phase) {
        Stop-Agent3Protocol "conflicting-duplicate" "Receipt refers to a conflicting message or processing phase."
    }
    Assert-Agent3Utc $Receipt.utc
    Assert-Agent3Evidence $Receipt.evidence
}

function Receive-Agent3Message {
    param([string] $Json, $State, $Sender, $Recipient, [string] $Directory, [string[]] $Evidence)
    Assert-Agent3Endpoint $Sender
    Assert-Agent3Endpoint $Recipient
    Assert-Agent3Evidence $Evidence
    $message = $null
    $parsed = $null
    $code = "invalid-json"
    try {
        $parsed = ConvertFrom-Agent3Json $Json
        $code = "invalid-message"
        Assert-Agent3MessageBinding $parsed $State $Sender $Recipient $Directory -Receiving
        $message = $parsed
        $code = "publication-mismatch"
        $stored = Read-Agent3Json (Get-Agent3ProtocolPath $Directory "messages" $message.messageId)
        $messageHash = Get-Agent3Hash $message
        if ((Get-Agent3Hash $stored) -cne $messageHash) {
            Stop-Agent3Protocol "conflicting-duplicate" "Wire message differs from its immutable published envelope."
        }
        $record = Read-Agent3Json $message.record.path
        $hash = Get-Agent3Hash $record
        if ($hash -cne $message.record.hash -or ($message.type -cne "notification" -and
            $hash -cne (Get-Agent3Hash $message.payload))) {
            Stop-Agent3Protocol "publication-mismatch" "Referenced immutable content differs from message."
        }
        if ($message.type -ceq "notification") { Assert-Agent3NotificationRecord $message $record $Directory }
        $code = "invalid-message"
        if ($message.type -ceq "assignment") {
            $handoff = Find-Agent3Handoff $State $message.context.claimId $message.context.handoffId
            if ($handoff.stage -cnotin @("correlated", "delivered")) {
                return Get-Agent3Decision $message "duplicate" "none" "handoff-already-consumed"
            }
            foreach ($prefix in @("ack-", "result-")) {
                if ([IO.File]::Exists((Get-Agent3ProtocolPath $Directory "events" "$prefix$($message.context.handoffId)"))) {
                    return Get-Agent3Decision $message "duplicate" "none" "execution-already-reserved"
                }
            }
            return Get-Agent3Decision $message "ready" "acknowledge-$($message.payload.action)" "assignment-validated"
        }
        if ($message.type -cin @("acknowledgment", "result")) {
            $seen = @($State.events | Where-Object id -CEQ $message.payload.eventId)
            if ($seen.Count -gt 0) { return Get-Agent3Decision $message "duplicate" "none" "event-already-ingested" }
            return Get-Agent3Decision $message "ready" "ingest-event" "event-validated"
        }
        $receiptPath = Get-Agent3ProtocolPath $Directory "receipts" $message.messageId
        if ([IO.File]::Exists($receiptPath)) {
            $receipt = Read-Agent3Json $receiptPath
            Assert-Agent3Receipt $receipt $message.messageId $messageHash "reserved"
            $processedPath = Get-Agent3ProtocolPath $Directory "receipts" "processed-$($message.messageId)"
            if ([IO.File]::Exists($processedPath)) {
                Assert-Agent3Receipt (Read-Agent3Json $processedPath) $message.messageId $messageHash "processed"
                return Get-Agent3Decision $message "duplicate" "none" "message-already-processed"
            }
            return Get-Agent3Decision $message "duplicate" "none" "message-processing-reserved"
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
        try { Write-Agent3Atomic $receipt $receiptPath -Immutable }
        catch [IO.IOException] {
            if (-not [IO.File]::Exists($receiptPath)) { throw }
            Assert-Agent3Receipt (Read-Agent3Json $receiptPath) $message.messageId $messageHash "reserved"
            return Get-Agent3Decision $message "duplicate" "none" "message-processing-reserved"
        }
        Get-Agent3Decision $message "ready" $operation "message-validated"
    } catch {
        if ($_.Exception.Data.Contains("protocolCode")) { $code = $_.Exception.Data["protocolCode"] }
        $rawHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Json)))
        $id = Get-Agent3Hash @{ rawHash = $rawHash; sender = $Sender; recipient = $Recipient }
        $path = Get-Agent3ProtocolPath $Directory "diagnostics" $id
        $replyAllowed = $null -ne $parsed -and $parsed.Contains("messageId") -and
            $parsed.messageId -is [string] -and $parsed.messageId -cmatch '^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$' -and
            $parsed.messageId -cne [guid]::Empty.ToString() -and $parsed.Contains("type") -and
            $parsed.type -is [string] -and $parsed.type -cne "protocol_error" -and $parsed.Contains("sender") -and
            (Get-Agent3Hash $parsed.sender) -ceq (Get-Agent3Hash $Sender)
        if (-not [IO.File]::Exists($path)) {
            $diagnostic = @{
                schema = "fingvibe-real-diagnostic-v1"; id = $id; rawHash = $rawHash; code = $code
                explanation = $_.Exception.Message; utc = [DateTime]::UtcNow.ToString("o")
                sender = $Sender; recipient = $Recipient; evidence = $Evidence
                inReplyTo = $(if ($replyAllowed) { $parsed.messageId } else { $null })
            }
            Write-Agent3Atomic $diagnostic $path -Immutable
        }
        $decision = Get-Agent3Decision $message "rejected" "none" $code $path $replyAllowed
        $decision.nextOwner = $Recipient.agentId
        return $decision
    }
}

function Confirm-Agent3Message {
    param($Message, $State, $Sender, $Recipient, [string] $Directory, [string[]] $Evidence)
    if ($Message.type -cin @("assignment", "acknowledgment", "result") -or
        -not [IO.File]::Exists((Get-Agent3ProtocolPath $Directory "receipts" $Message.messageId))) {
        throw "Only received informational messages can be confirmed; assignments/events use existing atomic guards."
    }
    $decision = Receive-Agent3Message ($Message | ConvertTo-Json -Depth 100 -Compress) $State $Sender $Recipient $Directory $Evidence
    if ($decision.disposition -ceq "rejected") {
        throw "Cannot confirm rejected message. Inspect $($decision.diagnosticPath)."
    }
    if ($decision.reasonCode -ceq "message-already-processed") { return }
    $receipt = @{
        schema = "fingvibe-real-receipt-v1"; messageId = $Message.messageId; messageHash = Get-Agent3Hash $Message
        phase = "processed"; utc = [DateTime]::UtcNow.ToString("o"); evidence = $Evidence
    }
    Write-Agent3Atomic $receipt (Get-Agent3ProtocolPath $Directory "receipts" "processed-$($Message.messageId)") -Immutable
}

function Publish-Agent3ProtocolError {
    param([string] $DiagnosticPath, $State, [string] $Directory)
    $diagnostic = Read-Agent3Json $DiagnosticPath
    if ($diagnostic.schema -cne "fingvibe-real-diagnostic-v1" -or $null -eq $diagnostic.inReplyTo) {
        throw "No safely correlated protocol response is available; preserve the diagnostic without replying."
    }
    $expectedPath = Get-Agent3ProtocolPath $Directory "diagnostics" $diagnostic.id
    if (-not [string]::Equals($expectedPath, [IO.Path]::GetFullPath($DiagnosticPath), [StringComparison]::OrdinalIgnoreCase)) {
        throw "Diagnostic must come from this environment."
    }
    $reservationPath = Get-Agent3ProtocolPath $Directory "responses" $diagnostic.inReplyTo
    if ([IO.File]::Exists($reservationPath)) { throw "Protocol error response already reserved; never resend an uncertain reply." }
    $message = New-Agent3Message -Type protocol_error -Sender $diagnostic.recipient -Recipient $diagnostic.sender `
        -Context $null -Payload @{ code = $diagnostic.code; explanation = $diagnostic.explanation
            evidence = @($DiagnosticPath) } -Directory $Directory -InReplyTo $diagnostic.inReplyTo
    Write-Agent3Atomic @{ diagnostic = $DiagnosticPath; messageId = $message.messageId; utc = $message.sentUtc } `
        $reservationPath -Immutable
    Publish-Agent3Message $message $State $diagnostic.recipient $diagnostic.sender $Directory
}
