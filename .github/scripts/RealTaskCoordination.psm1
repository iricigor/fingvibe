#requires -Version 7.5
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Stages = @("prepared", "launch-requested", "correlated", "delivered",
    "acknowledged", "result-recorded", "stopped-verified", "reconciled")
$script:TaskStates = @("implementing", "validation", "repair-needed", "finalize-ready",
    "human-review", "blocked", "delivered")

function Assert-RealTaskFields($Record, [string[]] $Fields, [switch] $Closed) {
    if ($Record -isnot [System.Collections.IDictionary]) { throw "Expected a JSON object." }
    foreach ($field in $Fields) {
        if ($field -cnotin @($Record.Keys)) { throw "Missing field '$field'." }
    }
    if ($Closed) {
        foreach ($field in $Record.Keys) {
            if ($field -cnotin $Fields) { throw "Unknown field '$field'." }
        }
    }
}

function Assert-RealTaskText($Value, [string] $Name) {
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw "Expected nonempty $Name."
    }
}

function Assert-RealTaskUtc($Value) {
    Assert-RealTaskText $Value "UTC timestamp"
    if ($Value -notmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|\+00:00)$') {
        throw "Expected explicit UTC timestamp, not local or inferred time."
    }
    $null = [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture)
}

function Assert-RealTaskEvidence($Evidence) {
    if ($Evidence -isnot [array] -or $Evidence.Count -eq 0) { throw "Evidence references are required." }
    foreach ($reference in $Evidence) { Assert-RealTaskText $reference "evidence reference" }
}

function Get-RealTaskHash($Record) {
    # Sort object keys recursively so JSON field order is not event identity.
    function ConvertTo-Canonical($Value) {
        if ($Value -is [System.Collections.IDictionary]) {
            $ordered = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
            [string[]] $keys = @($Value.Keys)
            [Array]::Sort($keys, [StringComparer]::Ordinal)
            foreach ($key in $keys) {
                $ordered.Add($key, (ConvertTo-Canonical $Value[$key]))
            }
            return ,$ordered
        }
        if ($Value -is [array]) {
            $items = @($Value | ForEach-Object { ConvertTo-Canonical $_ })
            return ,$items
        }
        return $Value
    }
    $json = ConvertTo-Canonical $Record | ConvertTo-Json -Depth 100 -Compress
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json)))
}

function Get-RealTaskEvidenceHash([string[]] $Evidence) {
    Assert-RealTaskEvidence $Evidence
    $unique = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($reference in $Evidence) { $null = $unique.Add($reference) }
    [string[]] $references = @($unique)
    [Array]::Sort($references, [StringComparer]::Ordinal)
    Get-RealTaskHash @{ value = $references }
}

function Find-RealTask($State, [string] $ClaimId) {
    $matches = @($State.tasks | Where-Object claimId -CEQ $ClaimId)
    if ($matches.Count -ne 1) { throw "Expected exactly one task for claim '$ClaimId'." }
    return $matches[0]
}

function Find-RealTaskHandoff($State, [string] $ClaimId, [string] $HandoffId) {
    $task = Find-RealTask $State $ClaimId
    $matches = @($task.handoffs | Where-Object id -CEQ $HandoffId)
    if ($matches.Count -ne 1) { throw "Expected exactly one handoff '$HandoffId'." }
    return $matches[0]
}

function Test-RealTaskReplacement($Handoff) {
    $null -ne $Handoff -and $Handoff.action -ceq "implement" -and
        $Handoff.stage -ceq "reconciled" -and $Handoff.Contains("recovery") -and
        $Handoff.recovery.restartImplementation
}

function Assert-RealTaskRecovery($Handoff) {
    $recovery = $Handoff.recovery
    Assert-RealTaskFields $recovery @("mode", "priorStage", "authorization", "evidence", "utc", "restartImplementation") -Closed
    Assert-RealTaskText $recovery.authorization "human recovery authorization"
    Assert-RealTaskEvidence $recovery.evidence
    Assert-RealTaskUtc $recovery.utc
    if ($Handoff.stage -cne "reconciled" -or $recovery.restartImplementation -isnot [bool]) {
        throw "Recovery requires terminal reconciliation and explicit restart authority."
    }
    switch -CaseSensitive ($recovery.mode) {
        "no-launch" {
            if ($recovery.priorStage -cnotin @("prepared", "launch-requested") -or
                $null -ne $Handoff.runId -or $null -ne $Handoff.sessionId -or
                $null -ne $Handoff.ackEventId -or $null -ne $Handoff.resultEventId -or $null -ne $Handoff.result) {
                throw "No-launch recovery requires verified absence of execution."
            }
        }
        "stopped" {
            if ($recovery.priorStage -cnotin @("correlated", "delivered", "acknowledged") -or
                $null -ne $Handoff.resultEventId -or $null -ne $Handoff.result) {
                throw "Stopped recovery requires a session without a result."
            }
            Assert-RealTaskText $Handoff.runId "actual run ID"
            Assert-RealTaskText $Handoff.sessionId "actual session ID"
        }
        "pre-start-rejected" {
            if ($recovery.priorStage -cnotin @("stopped-verified", "reconciled") -or
                $null -ne $Handoff.ackEventId -or $null -eq $Handoff.result -or
                $Handoff.result.outcome -cne "blocked-before-start") {
                throw "Replacement requires verified stopped pre-start rejection."
            }
        }
        default { throw "Unknown recovery mode." }
    }
    if ($recovery.restartImplementation -and
        ($Handoff.action -cne "implement" -or $recovery.mode -cnotin @("no-launch", "pre-start-rejected"))) {
        throw "Only a verified unstarted implementation can be replaced."
    }
}

function Assert-RealTaskHumanDelivery($Delivery, [string] $TargetBranch) {
    Assert-RealTaskFields $Delivery @("head", "targetBranch", "evidence", "cleanupEvidence") -Closed
    Assert-RealTaskText $Delivery.head "delivered head"
    if ($Delivery.head -cnotmatch '^[0-9a-f]{40}$' -or $Delivery.targetBranch -cne $TargetBranch) {
        throw "Human delivery requires the verified head on the configured target branch."
    }
    Assert-RealTaskEvidence $Delivery.evidence
    Assert-RealTaskEvidence $Delivery.cleanupEvidence
}

function Assert-RealTaskState {
    param([Parameter(Mandatory)] $State)
    Assert-RealTaskFields $State @("schema", "repository", "epic", "targetBranch", "authorization",
        "workers", "revision", "updatedUtc", "tasks", "events", "incidents", "reports")
    if ($State.schema -cne "fingvibe-real-state-v1" -or
        $State.repository -cnotmatch '^[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9_.-]*$') {
        throw "Invalid state schema or normalized repository."
    }
    foreach ($number in @($State.epic, $State.revision)) {
        if (($number -isnot [int] -and $number -isnot [long]) -or $number -lt 1) {
            throw "Epic and revision must be positive integers."
        }
    }
    Assert-RealTaskText $State.targetBranch "target branch"
    Assert-RealTaskFields $State.authorization @("reference", "implementation", "merge")
    Assert-RealTaskText $State.authorization.reference "human authorization reference"
    if ($State.authorization.implementation -isnot [bool] -or
        $State.authorization.merge -isnot [bool]) { throw "Authorization capabilities must be explicit booleans." }
    Assert-RealTaskUtc $State.updatedUtc
    foreach ($field in @("workers", "tasks", "events", "incidents", "reports")) {
        if ($State[$field] -isnot [array]) { throw "'$field' must be an array." }
    }
    if ($State.workers.Count -ne 2) { throw "Exactly two Developer identities are required." }
    $workers = @{}
    foreach ($worker in $State.workers) {
        Assert-RealTaskFields $worker @("id", "name", "automationId")
        foreach ($field in @("id", "name", "automationId")) { Assert-RealTaskText $worker[$field] $field }
        if ($workers.ContainsKey($worker.id)) { throw "Duplicate worker identity." }
        $workers[$worker.id] = $true
    }
    if (@($State.workers.automationId | Select-Object -Unique).Count -ne 2) {
        throw "Developers must be distinct Automations."
    }
    if ("developer-1" -cnotin @($workers.Keys) -or "developer-2" -cnotin @($workers.Keys)) {
        throw "Stable worker IDs must be developer-1 and developer-2."
    }
    $claims = @{}
    $issues = @{}
    $handoffs = @{}
    $occupied = @{}
    foreach ($task in $State.tasks) {
        Assert-RealTaskFields $task @("claimId", "issue", "state", "repairCount", "handoffs",
            "branch", "worktree", "pr", "head", "checkpoint", "scopeEvidence", "dispositions", "changedUtc")
        Assert-RealTaskText $task.claimId "claim ID"
        if ($claims.ContainsKey($task.claimId) -or $issues.ContainsKey([string]$task.issue)) {
            throw "Duplicate task or claim."
        }
        $claims[$task.claimId] = $true
        $issues[[string]$task.issue] = $true
        if (($task.issue -isnot [int] -and $task.issue -isnot [long]) -or $task.issue -le 0 -or
            $task.state -cnotin $script:TaskStates) { throw "Invalid task issue or state." }
        if (($task.repairCount -isnot [int] -and $task.repairCount -isnot [long]) -or
            $task.repairCount -lt 0 -or $task.repairCount -gt 12) { throw "Repair count must be an integer from 0 to 12." }
        Assert-RealTaskEvidence $task.scopeEvidence
        Assert-RealTaskUtc $task.changedUtc
        if ($task.handoffs -isnot [array] -or $task.dispositions -isnot [array]) {
            throw "Task history must be arrays."
        }
        foreach ($disposition in $task.dispositions) {
            Assert-RealTaskFields $disposition @("state", "utc", "evidence")
            if ($disposition.state -cnotin $script:TaskStates) { throw "Unknown disposition state." }
            Assert-RealTaskUtc $disposition.utc
            Assert-RealTaskEvidence $disposition.evidence
            if ($disposition.Contains("independentEvidence")) {
                if ($disposition.state -cne "blocked") { throw "Independence evidence belongs to a blocked disposition." }
                Assert-RealTaskEvidence $disposition.independentEvidence
            }
            if ($disposition.Contains("humanDelivery")) {
                if ($disposition.state -cne "delivered") { throw "Human delivery belongs to a delivered disposition." }
                Assert-RealTaskHumanDelivery $disposition.humanDelivery $State.targetBranch
            }
        }
        $repairs = 0
        $implementations = 0
        $previous = $null
        foreach ($handoff in $task.handoffs) {
            Assert-RealTaskFields $handoff @("id", "action", "stage", "workerId", "runId", "sessionId",
                "expectedHead", "feedback", "priorRepairEvidence", "repairAttempt", "strategy",
                "transitions", "ackEventId", "resultEventId", "result")
            Assert-RealTaskText $handoff.id "handoff ID"
            if ($handoffs.ContainsKey($handoff.id)) { throw "Duplicate handoff ID." }
            $handoffs[$handoff.id] = $true
            if (-not $workers.ContainsKey($handoff.workerId) -or
                $handoff.action -cnotin @("implement", "repair", "finalize") -or
                $handoff.stage -cnotin $script:Stages) { throw "Invalid handoff worker, action or stage." }
            if ($handoff.repairAttempt -isnot [int] -and $handoff.repairAttempt -isnot [long]) {
                throw "Repair attempt must be an integer."
            }
            if ($null -ne $previous -and $previous.stage -cne "reconciled") {
                throw "A task cannot have overlapping handoffs."
            }
            if ($handoff.action -ceq "implement") {
                $implementations++
                if ($implementations -gt 1 -and -not (Test-RealTaskReplacement $previous)) {
                    throw "Replacement implementation requires human-reconciled pre-start failure."
                }
            } elseif ($implementations -lt 1) { throw "Repair/finalize requires initial implementation history." }
            if ($handoff.action -ceq "repair") {
                $repairs++
                $strategy = if ($repairs -eq 1) { "targeted" } else { "reassess" }
                if ($handoff.repairAttempt -ne $repairs -or $handoff.strategy -cne $strategy) {
                    throw "Repair history/strategy mismatch."
                }
                Assert-RealTaskEvidence $handoff.feedback
                if ($repairs -gt 1) { Assert-RealTaskEvidence $handoff.priorRepairEvidence }
            } elseif ($handoff.repairAttempt -ne 0) { throw "Only repairs consume repair attempts." }
            if ($handoff.action -cne "implement") {
                if ($handoff.expectedHead -cnotmatch '^[0-9a-f]{40}$') { throw "Expected full PR head SHA." }
                foreach ($field in @("branch", "worktree", "pr", "checkpoint")) {
                    Assert-RealTaskText $task[$field] $field
                }
                if (-not [IO.Path]::IsPathFullyQualified($task.worktree)) { throw "Worktree must be absolute." }
            }
            if ($handoff.transitions -isnot [array] -or $handoff.transitions.Count -eq 0) {
                throw "Missing handoff transition history."
            }
            $recovered = $handoff.Contains("recovery")
            if ($recovered) { Assert-RealTaskRecovery $handoff }
            $last = $null
            for ($transitionIndex = 0; $transitionIndex -lt $handoff.transitions.Count; $transitionIndex++) {
                $transition = $handoff.transitions[$transitionIndex]
                Assert-RealTaskFields $transition @("stage", "utc", "evidence")
                Assert-RealTaskUtc $transition.utc
                Assert-RealTaskEvidence $transition.evidence
                $allowed = switch ($last) {
                    $null { @("prepared") }
                    "prepared" { @("launch-requested") }
                    "launch-requested" { @("correlated") }
                    "correlated" { @("delivered", "result-recorded") }
                    "delivered" { @("acknowledged", "result-recorded") }
                    "acknowledged" { @("result-recorded") }
                    "result-recorded" { @("stopped-verified") }
                    "stopped-verified" { @("reconciled") }
                    default { @() }
                }
                $recoveryExit = $recovered -and $transitionIndex -eq $handoff.transitions.Count - 1 -and
                    $last -ceq $handoff.recovery.priorStage -and $transition.stage -ceq "reconciled" -and
                    $transition.utc -ceq $handoff.recovery.utc -and
                    (Get-RealTaskHash @{ value = $transition.evidence }) -ceq
                        (Get-RealTaskHash @{ value = $handoff.recovery.evidence })
                if ($recovered -and $transitionIndex -eq $handoff.transitions.Count - 1 -and -not $recoveryExit) {
                    throw "Recovery differs from terminal transition evidence."
                }
                if ($transition.stage -cnotin $allowed -and -not $recoveryExit) {
                    throw "Invalid stage transition '$last' -> '$($transition.stage)'."
                }
                $last = $transition.stage
            }
            if ($last -cne $handoff.stage) { throw "Stage differs from transition history." }
            if (@($handoff.transitions | Where-Object stage -CEQ "acknowledged").Count -gt 0) {
                Assert-RealTaskText $handoff.ackEventId "retained acknowledgment event ID"
            }
            if ($handoff.stage -cin @("correlated", "delivered", "acknowledged", "result-recorded", "stopped-verified", "reconciled") -and
                -not ($recovered -and $handoff.recovery.mode -ceq "no-launch")) {
                Assert-RealTaskText $handoff.runId "actual run ID"
                Assert-RealTaskText $handoff.sessionId "actual session ID"
            }
            if ($handoff.stage -cin @("acknowledged", "result-recorded", "stopped-verified", "reconciled") -and -not $recovered) {
                if ($null -eq $handoff.ackEventId -and
                    ($null -eq $handoff.result -or $handoff.result.outcome -cne "blocked-before-start")) {
                    throw "Execution requires an acknowledgment."
                }
            }
            if ($handoff.stage -cin @("result-recorded", "stopped-verified", "reconciled") -and
                (-not $recovered -or $null -ne $handoff.resultEventId)) {
                Assert-RealTaskText $handoff.resultEventId "result event ID"
                Assert-RealTaskFields $handoff.result @("outcome", "head", "checkpoint", "evidence")
                Assert-RealTaskEvidence $handoff.result.evidence
            }
            if ($handoff.stage -cne "reconciled") {
                if ($occupied.ContainsKey($handoff.workerId)) { throw "Worker has overlapping logical assignments." }
                $occupied[$handoff.workerId] = $true
            }
            $previous = $handoff
        }
        if ($repairs -ne $task.repairCount) { throw "Repair count cannot reset or diverge from history." }
        if ($task.state -ceq "delivered" -and
            ($null -eq $previous -or $previous.stage -cne "reconciled" -or
                $task.dispositions.Count -eq 0)) { throw "Delivered task requires reconciled execution and delivery evidence." }
    }
    if (@($State.tasks | Where-Object state -CIn @("validation", "finalize-ready", "human-review")).Count -gt 2) {
        throw "Validation/finalization backlog exceeds two."
    }
    $eventIds = @{}
    foreach ($event in $State.events) {
        Assert-RealTaskFields $event @("id", "hash", "claimId", "handoffId", "kind")
        if ($eventIds.ContainsKey($event.id)) { throw "Duplicate event index entry." }
        $eventIds[$event.id] = $true
        $handoff = Find-RealTaskHandoff $State $event.claimId $event.handoffId
        $field = if ($event.kind -ceq "ack") { "ackEventId" } elseif ($event.kind -ceq "result") {
            "resultEventId"
        } else { throw "Unknown event kind." }
        if ($handoff[$field] -cne $event.id) { throw "Event index disagrees with handoff." }
    }
    foreach ($task in $State.tasks) {
        foreach ($handoff in $task.handoffs) {
            foreach ($id in @($handoff.ackEventId, $handoff.resultEventId)) {
                if ($null -ne $id -and -not $eventIds.ContainsKey($id)) { throw "Missing immutable event index." }
            }
        }
    }
    foreach ($report in $State.reports) {
        Assert-RealTaskFields $report @("id", "claimId", "handoffId", "url", "utc", "nextOwner", "nextAction")
        foreach ($field in @("id", "url", "nextOwner", "nextAction")) { Assert-RealTaskText $report[$field] $field }
        Assert-RealTaskUtc $report.utc
        $null = Find-RealTaskHandoff $State $report.claimId $report.handoffId
    }
}

function New-RealTaskState {
    param([string] $Repository, [int] $Epic, [string] $TargetBranch, [hashtable] $Authorization, [array] $Workers)
    $state = @{
        schema = "fingvibe-real-state-v1"; repository = $Repository.ToLowerInvariant()
        epic = $Epic; targetBranch = $TargetBranch; authorization = $Authorization; workers = $Workers
        revision = 1; updatedUtc = [DateTime]::UtcNow.ToString("o")
        tasks = @(); events = @(); incidents = @(); reports = @()
    }
    Assert-RealTaskState $state
    return $state
}

function Get-RealTaskCapacity {
    param([Parameter(Mandatory)] $State)
    Assert-RealTaskState $State
    $occupied = @($State.tasks | ForEach-Object { $_.handoffs } | Where-Object stage -CNE "reconciled")
    $occupiedIds = @($occupied | ForEach-Object { $_.workerId })
    $waiting = @($State.tasks | Where-Object state -CIn @("validation", "finalize-ready", "human-review"))
    $unassigned = @($State.tasks | Where-Object {
        $_.state -cne "delivered" -and $_.handoffs.Count -eq 0 -and
            -not ($_.state -ceq "blocked" -and $_.dispositions.Count -gt 0 -and
                $_.dispositions[-1].Contains("independentEvidence"))
    })
    @{
        occupiedWorkers = $occupiedIds
        freeWorkers = @($State.workers.id | Where-Object { $_ -cnotin $occupiedIds })
        validationPending = $waiting.Count
        unassignedClaims = @($unassigned | ForEach-Object { $_.claimId })
        canStartImplementation = ($occupied.Count -lt 2 -and $waiting.Count -lt 2 -and $unassigned.Count -eq 0)
    }
}

function Add-RealTaskClaim {
    param($State, [int] $Issue, [string[]] $ScopeEvidence)
    Assert-RealTaskState $State
    if (-not $State.authorization.implementation) { throw "Implementation is not authorized." }
    Assert-RealTaskEvidence $ScopeEvidence
    if ($Issue -le 0 -or @($State.tasks | Where-Object issue -EQ $Issue).Count -ne 0) {
        throw "Invalid or already claimed issue."
    }
    if (-not (Get-RealTaskCapacity $State).canStartImplementation) { throw "No implementation capacity." }
    $task = @{
        claimId = [guid]::NewGuid().ToString(); issue = $Issue; state = "implementing"
        repairCount = 0; handoffs = @(); branch = $null; worktree = $null; pr = $null
        head = $null; checkpoint = $null; scopeEvidence = $ScopeEvidence; dispositions = @()
        changedUtc = [DateTime]::UtcNow.ToString("o")
    }
    $State.tasks += $task
    return $task
}

function Add-RealTaskHandoff {
    param($State, [string] $ClaimId, [string] $WorkerId,
        [ValidateSet("implement", "repair", "finalize")] [string] $Action,
        [string[]] $Feedback = @(), [string[]] $PriorRepairEvidence = @())
    Assert-RealTaskState $State
    $task = Find-RealTask $State $ClaimId
    $capacity = Get-RealTaskCapacity $State
    if (-not $State.authorization.implementation -or $WorkerId -cnotin $capacity.freeWorkers -or
        @($task.handoffs | Where-Object stage -CNE "reconciled").Count -ne 0) {
        throw "Worker/task unavailable or unauthorized."
    }
    if ($Action -ceq "implement") {
        if (($task.handoffs.Count -ne 0 -and -not (Test-RealTaskReplacement $task.handoffs[-1])) -or
            $task.state -cnotin @("implementing", "blocked") -or $capacity.occupiedWorkers.Count -ge 2 -or
            $capacity.validationPending -ge 2 -or
            @($capacity.unassignedClaims | Where-Object { $_ -cne $ClaimId }).Count -gt 0) {
            throw "Initial implementation already assigned or backlog full."
        }
    } elseif ($Action -ceq "repair") {
        if ($task.state -cne "repair-needed" -or $task.repairCount -ge 12) { throw "Repair unavailable or exhausted." }
        Assert-RealTaskEvidence $Feedback
        if ($task.repairCount -gt 0) { Assert-RealTaskEvidence $PriorRepairEvidence }
    } else {
        if ($task.state -cne "finalize-ready") { throw "Task is not finalize-ready." }
        Assert-RealTaskEvidence $Feedback
        foreach ($prior in $task.handoffs) {
            if ($prior.action -ceq "finalize" -and $prior.expectedHead -ceq $task.head -and
                (Get-RealTaskEvidenceHash $prior.feedback) -ceq (Get-RealTaskEvidenceHash $Feedback)) {
                throw "Duplicate finalize revision/evidence; require a meaningful evidence change."
            }
        }
    }
    if ($Action -cne "implement") {
        if ($task.head -cnotmatch '^[0-9a-f]{40}$') { throw "Expected full PR head SHA." }
        foreach ($field in @("branch", "worktree", "pr", "checkpoint")) { Assert-RealTaskText $task[$field] $field }
        if (-not [IO.Path]::IsPathFullyQualified($task.worktree)) { throw "Worktree must be absolute." }
    }
    $attempt = if ($Action -ceq "repair") { $task.repairCount + 1 } else { 0 }
    $handoff = @{
        id = [guid]::NewGuid().ToString(); action = $Action; stage = "prepared"; workerId = $WorkerId
        runId = $null; sessionId = $null; expectedHead = $task.head; feedback = $Feedback
        priorRepairEvidence = $PriorRepairEvidence; repairAttempt = $attempt
        strategy = $(if ($attempt -eq 1) { "targeted" } elseif ($attempt -gt 1) { "reassess" } else { $null })
        transitions = @(@{ stage = "prepared"; utc = [DateTime]::UtcNow.ToString("o"); evidence = $task.scopeEvidence })
        ackEventId = $null; resultEventId = $null; result = $null
    }
    $task.handoffs += $handoff
    if ($Action -ceq "repair") { $task.repairCount = $attempt }
    if ($Action -cne "finalize") { $task.state = "implementing" }
    $task.changedUtc = [DateTime]::UtcNow.ToString("o")
    Assert-RealTaskState $State
    return $handoff
}

function Set-RealTaskStage {
    param($State, [string] $ClaimId, [string] $HandoffId,
        [ValidateSet("launch-requested", "correlated", "delivered", "stopped-verified", "reconciled")] [string] $Stage,
        [string[]] $Evidence, [string] $RunId, [string] $SessionId)
    Assert-RealTaskState $State
    Assert-RealTaskEvidence $Evidence
    $handoff = Find-RealTaskHandoff $State $ClaimId $HandoffId
    $expected = @{
        "launch-requested" = "prepared"; correlated = "launch-requested"; delivered = "correlated"
        "stopped-verified" = "result-recorded"; reconciled = "stopped-verified"
    }
    if ($handoff.stage -cne $expected[$Stage]) { throw "Invalid stage transition to '$Stage'." }
    if ($Stage -ceq "correlated") {
        Assert-RealTaskText $RunId "actual run ID"
        Assert-RealTaskText $SessionId "actual session ID"
        $handoff.runId = $RunId
        $handoff.sessionId = $SessionId
    }
    if ($Stage -ceq "reconciled") {
        $task = Find-RealTask $State $ClaimId
        if ($task.state -ceq "implementing") { throw "Reconcile task disposition before freeing worker." }
    }
    $handoff.stage = $Stage
    $handoff.transitions += @{ stage = $Stage; utc = [DateTime]::UtcNow.ToString("o"); evidence = $Evidence }
    (Find-RealTask $State $ClaimId).changedUtc = [DateTime]::UtcNow.ToString("o")
    Assert-RealTaskState $State
}

function Resolve-RealTaskHandoff {
    param($State, [string] $ClaimId, [string] $HandoffId,
        [ValidateSet("no-launch", "stopped", "pre-start-rejected")] [string] $Mode,
        [string] $HumanAuthorization, [string[]] $Evidence, [switch] $RestartImplementation)
    Assert-RealTaskState $State
    Assert-RealTaskText $HumanAuthorization "human recovery authorization"
    Assert-RealTaskEvidence $Evidence
    $task = Find-RealTask $State $ClaimId
    $handoff = Find-RealTaskHandoff $State $ClaimId $HandoffId
    if ($handoff.id -cne $task.handoffs[-1].id -or $handoff.Contains("recovery")) {
        throw "Only the latest handoff can be recovered once."
    }
    $utc = [DateTime]::UtcNow.ToString("o")
    $recovery = @{ mode = $Mode; priorStage = $handoff.stage; authorization = $HumanAuthorization
        evidence = $Evidence; utc = $utc; restartImplementation = [bool]$RestartImplementation }
    $candidate = @{} + $handoff
    $candidate.stage = "reconciled"
    $candidate.recovery = $recovery
    Assert-RealTaskRecovery $candidate
    $handoff.recovery = $recovery
    $handoff.stage = "reconciled"
    $handoff.transitions += @{ stage = "reconciled"; utc = $utc; evidence = $Evidence }
    $task.state = "blocked"
    $task.changedUtc = $utc
    $task.dispositions += @{ state = "blocked"; utc = $utc; evidence = $Evidence }
    Assert-RealTaskState $State
}

function Test-RealTaskEvent {
    param($State, $Event, [switch] $AcknowledgmentVerified)
    Assert-RealTaskEvent $Event
    $hash = Get-RealTaskHash $Event
    $seen = @($State.events | Where-Object id -CEQ $Event.eventId)
    if ($seen.Count -gt 0) {
        if ($seen[0].hash -cne $hash) { Stop-RealTaskProtocol "conflicting-duplicate" "Conflicting duplicate event." }
        return @{ disposition = "duplicate"; hash = $hash; handoff = $null }
    }
    $handoff = Find-RealTaskHandoff $State $Event.claimId $Event.handoffId
    foreach ($field in @("action", "workerId", "runId", "sessionId")) {
        if ($null -eq $handoff[$field] -or $handoff[$field] -cne $Event[$field]) {
            throw "Event correlation mismatch: $field."
        }
    }
    if ($Event.kind -ceq "ack") {
        if ($handoff.stage -cnotin @("correlated", "delivered") -or $null -ne $Event.result) {
            throw "Invalid acknowledgment stage/result."
        }
    } else {
        if ($handoff.stage -cne "acknowledged" -and
            -not ($handoff.stage -cin @("correlated", "delivered") -and
                ($AcknowledgmentVerified -or $Event.result.outcome -ceq "blocked-before-start"))) {
            throw "Result requires acknowledgment or verified pre-start rejection."
        }
        if ($Event.result.outcome -ceq "implementation-ready") {
            if ($handoff.action -ceq "finalize" -or $Event.result.head -cnotmatch '^[0-9a-f]{40}$') {
                throw "Invalid implementation checkpoint."
            }
            Assert-RealTaskText $Event.result.checkpoint "implementation checkpoint"
        }
        if ($Event.result.outcome -cin @("pr-ready", "delivered")) {
            if ($handoff.action -cne "finalize" -or $Event.result.head -cne $handoff.expectedHead) {
                throw "Finalization must match assigned head without coding."
            }
            if ($Event.result.outcome -ceq "delivered" -and -not $State.authorization.merge) {
                throw "Merge delivery is not authorized."
            }
        }
    }
    return @{ disposition = "ready"; hash = $hash; handoff = $handoff }
}

function Add-RealTaskEvent {
    param($State, $Event)
    Assert-RealTaskState $State
    $check = Test-RealTaskEvent $State $Event
    if ($check.disposition -ceq "duplicate") { return "duplicate" }
    $handoff = $check.handoff
    if ($Event.kind -ceq "ack") {
        if ($handoff.stage -ceq "correlated") {
            # A verified matching acknowledgment also proves the assignment arrived.
            $handoff.transitions += @{ stage = "delivered"; utc = $Event.utc; evidence = $Event.evidence }
        }
        $stage = "acknowledged"
        $handoff.ackEventId = $Event.eventId
    } else {
        $stage = "result-recorded"
        $handoff.resultEventId = $Event.eventId
        $handoff.result = $Event.result
        $task = Find-RealTask $State $Event.claimId
        if ($Event.result.outcome -ceq "implementation-ready") {
            $task.head = $Event.result.head
            $task.checkpoint = $Event.result.checkpoint
        }
    }
    $handoff.stage = $stage
    $handoff.transitions += @{ stage = $stage; utc = $Event.utc; evidence = $Event.evidence }
    $State.events += @{ id = $Event.eventId; hash = $check.hash; claimId = $Event.claimId
        handoffId = $Event.handoffId; kind = $Event.kind }
    (Find-RealTask $State $Event.claimId).changedUtc = [DateTime]::UtcNow.ToString("o")
    Assert-RealTaskState $State
    return "applied"
}

function Assert-RealTaskEvent($Event) {
    Assert-RealTaskFields $Event @("schema", "eventId", "kind", "claimId", "handoffId", "action",
        "workerId", "runId", "sessionId", "utc", "actor", "originalReporter", "trigger",
        "elapsedSeconds", "result", "evidence") -Closed
    Assert-RealTaskText $Event.schema "event schema"
    if ($Event.schema -cne "fingvibe-real-event-v1" -or $Event.kind -cnotin @("ack", "result")) {
        throw "Unsupported event schema/kind; field aliases are not inferred."
    }
    foreach ($field in @("eventId", "claimId", "handoffId", "action", "workerId", "runId", "sessionId",
        "actor", "originalReporter", "trigger")) { Assert-RealTaskText $Event[$field] $field }
    if ($Event.action -cnotin @("implement", "repair", "finalize") -or
        $Event.workerId -cnotin @("developer-1", "developer-2")) { throw "Invalid event action/worker." }
    if ($Event.eventId -cne "$($Event.kind)-$($Event.handoffId)") {
        throw "Event ID must be reserved by kind and handoff."
    }
    if ($Event.trigger -cnotin @("scheduled", "manual", "worker-message", "unknown")) { throw "Invalid trigger provenance." }
    Assert-RealTaskUtc $Event.utc
    Assert-RealTaskEvidence $Event.evidence
    if ($null -ne $Event.elapsedSeconds -and
        ($Event.elapsedSeconds -isnot [ValueType] -or $Event.elapsedSeconds -is [bool] -or
            [double]::IsNaN([double]$Event.elapsedSeconds) -or
            [double]::IsInfinity([double]$Event.elapsedSeconds) -or [double]$Event.elapsedSeconds -lt 0)) {
        throw "Monotonic elapsedSeconds must be nonnegative or explicitly null."
    }
    if ($Event.kind -ceq "ack") {
        if ($null -ne $Event.result) { throw "Acknowledgment cannot contain a result." }
    } else {
        Assert-RealTaskFields $Event.result @("outcome", "head", "checkpoint", "evidence") -Closed
        Assert-RealTaskEvidence $Event.result.evidence
        if ($Event.result.outcome -cnotin @("implementation-ready", "blocked", "blocked-before-start", "pr-ready", "delivered")) {
            throw "Unknown result outcome."
        }
        foreach ($field in @("head", "checkpoint")) {
            if ($null -ne $Event.result[$field]) { Assert-RealTaskText $Event.result[$field] $field }
        }
        if ($null -ne $Event.result.head -and $Event.result.head -cnotmatch '^[0-9a-f]{40}$') {
            throw "Expected full result head SHA."
        }
        if ($Event.result.outcome -ceq "implementation-ready") {
            if ($Event.action -ceq "finalize" -or $Event.result.head -cnotmatch '^[0-9a-f]{40}$') {
                throw "Invalid implementation checkpoint."
            }
            Assert-RealTaskText $Event.result.checkpoint "implementation checkpoint"
        }
        if ($Event.result.outcome -cin @("pr-ready", "delivered") -and
            ($Event.action -cne "finalize" -or $Event.result.head -cnotmatch '^[0-9a-f]{40}$')) {
            throw "Invalid finalization result."
        }
    }
}

function Get-RealTaskAssignment {
    param($State, [string] $ClaimId, [string] $HandoffId)
    Assert-RealTaskState $State
    Get-RealTaskAssignmentCore $State $ClaimId $HandoffId
}

function Get-RealTaskAssignmentCore($State, [string] $ClaimId, [string] $HandoffId) {
    $task = Find-RealTask $State $ClaimId
    $handoff = Find-RealTaskHandoff $State $ClaimId $HandoffId
    if ($handoff.stage -cnotin @("correlated", "delivered")) { throw "Handoff is not deliverable." }
    @{
        schema = "fingvibe-real-assignment-v1"; repository = $State.repository; epic = $State.epic
        issue = $task.issue; claimId = $ClaimId; handoffId = $HandoffId; action = $handoff.action
        workerId = $handoff.workerId; runId = $handoff.runId; sessionId = $handoff.sessionId
        targetBranch = $State.targetBranch; authorization = $State.authorization
        branch = $task.branch; worktree = $task.worktree; pr = $task.pr; expectedHead = $handoff.expectedHead
        checkpoint = $task.checkpoint; repairAttempt = $handoff.repairAttempt
        strategy = $handoff.strategy; feedback = $handoff.feedback; priorRepairEvidence = $handoff.priorRepairEvidence
    }
}

function Assert-RealTaskAssignment {
    param($State, $Assignment, [string] $WorkerId, [string] $RunId, [string] $SessionId)
    Assert-RealTaskState $State
    Assert-RealTaskAssignmentCore $State $Assignment $WorkerId $RunId $SessionId
}

function Assert-RealTaskAssignmentCore($State, $Assignment, [string] $WorkerId, [string] $RunId, [string] $SessionId) {
    Assert-RealTaskFields $Assignment @("claimId", "handoffId")
    $expected = Get-RealTaskAssignmentCore $State $Assignment.claimId $Assignment.handoffId
    if (-not $State.authorization.implementation -or $expected.workerId -cne $WorkerId -or
        $expected.runId -cne $RunId -or $expected.sessionId -cne $SessionId -or
        (Get-RealTaskHash $Assignment) -cne (Get-RealTaskHash $expected)) {
        throw "Invalid/stale assignment or actual worker/run/session mismatch."
    }
    $handoff = Find-RealTaskHandoff $State $Assignment.claimId $Assignment.handoffId
    if ($handoff.stage -cnotin @("correlated", "delivered") -or $null -ne $handoff.ackEventId) {
        throw "Assignment is not correlated or was already acknowledged."
    }
}

function Publish-RealTaskAcknowledgment {
    param($State, $Assignment, [string] $WorkerId, [string] $RunId, [string] $SessionId,
        [string] $Directory, [string] $Actor, [string] $Trigger = "unknown", [string[]] $Evidence)
    Assert-RealTaskAssignment $State $Assignment $WorkerId $RunId $SessionId
    if (-not [IO.Path]::IsPathFullyQualified($Directory)) { throw "Event directory must be absolute." }
    if ($Assignment.handoffId -cnotmatch '^[a-zA-Z0-9-]+$') { throw "Invalid handoff filename identity." }
    $id = "ack-" + $Assignment.handoffId
    foreach ($prefix in @("ack-", "result-")) {
        $path = Join-Path $Directory ($prefix + $Assignment.handoffId + ".json")
        if ([IO.File]::Exists($path)) { throw "Handoff already acknowledged/reported; do not execute again: $path." }
    }
    $event = @{
        schema = "fingvibe-real-event-v1"; eventId = $id; kind = "ack"; claimId = $Assignment.claimId
        handoffId = $Assignment.handoffId; action = $Assignment.action; workerId = $WorkerId
        runId = $RunId; sessionId = $SessionId; utc = [DateTime]::UtcNow.ToString("o")
        actor = $Actor; originalReporter = $Actor; trigger = $Trigger; elapsedSeconds = $null
        result = $null; evidence = $Evidence
    }
    Assert-RealTaskEvent $event
    # Create-new publication arbitrates duplicate starts even before Dispatcher ingestion.
    Write-RealTaskAtomic $event (Join-Path $Directory "$id.json") -Immutable
    return $event
}

function Set-RealTaskDisposition {
    param($State, [string] $ClaimId,
        [ValidateSet("validation", "repair-needed", "finalize-ready", "human-review", "blocked", "delivered")] [string] $Disposition,
        [string[]] $Evidence, [string[]] $IndependentEvidence, $HumanDelivery)
    Assert-RealTaskState $State
    Assert-RealTaskEvidence $Evidence
    $task = Find-RealTask $State $ClaimId
    if ($null -ne $IndependentEvidence) {
        if ($Disposition -cne "blocked") { throw "Independence evidence requires a blocked disposition." }
        Assert-RealTaskEvidence $IndependentEvidence
    }
    if ($null -ne $HumanDelivery) {
        if ($Disposition -cne "delivered") { throw "Human delivery requires a delivered disposition." }
        Assert-RealTaskHumanDelivery $HumanDelivery $State.targetBranch
    }
    $handoff = if ($task.handoffs.Count -gt 0) { $task.handoffs[-1] } else { $null }
    if ($null -eq $handoff -and $Disposition -cne "blocked") { throw "Task has no execution evidence." }
    if ($Disposition -cne "blocked" -and $handoff.stage -cnotin @("stopped-verified", "reconciled")) {
        throw "Task disposition requires verified stopped session execution."
    }
    $allowed = switch ($Disposition) {
        "validation" {
            $successful = @($task.handoffs | Where-Object action -CIn @("implement", "repair"))[-1]
            $null -ne $successful.result -and $successful.result.outcome -ceq "implementation-ready" -and
                $task.head -ceq $successful.result.head -and $task.checkpoint -ceq $successful.result.checkpoint -and
                (($handoff.id -ceq $successful.id) -or
                    ($task.state -ceq "blocked" -and $handoff.action -ceq "finalize" -and
                        $handoff.expectedHead -ceq $task.head))
        }
        "repair-needed" { $task.state -cin @("validation", "finalize-ready", "human-review", "blocked") }
        "finalize-ready" { $task.state -ceq "validation" }
        "human-review" { $null -ne $handoff.result -and $handoff.result.outcome -ceq "pr-ready" }
        "delivered" { $handoff.stage -ceq "reconciled" -and
            ($null -ne $HumanDelivery -or
                ($null -ne $handoff.result -and $handoff.result.outcome -cin @("pr-ready", "delivered"))) }
        "blocked" { $true }
    }
    if (-not $allowed) { throw "Invalid task disposition '$($task.state)' -> '$Disposition'." }
    if ($Disposition -cin @("validation", "finalize-ready", "human-review") -and
        $task.state -cnotin @("validation", "finalize-ready", "human-review")) {
        $waiting = (Get-RealTaskCapacity $State).validationPending
        $outstanding = @($State.tasks | Where-Object {
            $_.claimId -cne $ClaimId -and $_.state -cnotin @("validation", "finalize-ready", "human-review") -and
                @($_.handoffs | Where-Object {
                    $_.stage -cne "reconciled" -and $_.action -cin @("implement", "repair")
                }).Count -gt 0
        }).Count
        if ($waiting -ge 2 -or ($handoff.stage -ceq "reconciled" -and $waiting + $outstanding -ge 2)) {
            throw "Validation backlog full or reserved for outstanding implementations; preserve checkpoint and execution."
        }
    }
    $task.state = $Disposition
    $task.changedUtc = [DateTime]::UtcNow.ToString("o")
    $record = @{ state = $Disposition; utc = $task.changedUtc; evidence = $Evidence }
    if ($null -ne $IndependentEvidence) { $record.independentEvidence = $IndependentEvidence }
    if ($null -ne $HumanDelivery) {
        $record.humanDelivery = $HumanDelivery
        $task.head = $HumanDelivery.head
    }
    $task.dispositions += $record
    Assert-RealTaskState $State
}

function Read-RealTaskJson {
    param([string] $Path)
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw "Record path must be absolute." }
    if (-not [IO.File]::Exists($Path)) { throw "Record absent: $Path. Never infer idle capacity." }
    $json = [IO.File]::ReadAllText($Path)
    ConvertFrom-RealTaskJson $json
}

function ConvertFrom-RealTaskJson([string] $Json) {
    $options = [System.Text.Json.JsonDocumentOptions]::new()
    $options.MaxDepth = 100
    $document = [System.Text.Json.JsonDocument]::Parse($Json, $options)
    try {
        function Assert-UniqueJsonKeys([System.Text.Json.JsonElement] $Element) {
            if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
                $keys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
                foreach ($property in $Element.EnumerateObject()) {
                    if (-not $keys.Add($property.Name)) { throw "Duplicate JSON key '$($property.Name)'." }
                    Assert-UniqueJsonKeys $property.Value
                }
            } elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
                foreach ($item in $Element.EnumerateArray()) { Assert-UniqueJsonKeys $item }
            }
        }
        if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            throw "Expected complete JSON object."
        }
        Assert-UniqueJsonKeys $document.RootElement
    } finally { $document.Dispose() }
    ConvertFrom-Json -InputObject $Json -AsHashtable -DateKind String -Depth 100 -ErrorAction Stop
}

function Write-RealTaskAtomic($Record, [string] $Path, [switch] $Immutable) {
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw "Record path must be absolute." }
    $json = $Record | ConvertTo-Json -Depth 100
    $parsed = ConvertFrom-RealTaskJson $json
    $expectedHash = Get-RealTaskHash $Record
    if ((Get-RealTaskHash $parsed) -cne $expectedHash) {
        throw "Serialized publication differs from the original record."
    }
    $directory = [IO.Path]::GetDirectoryName($Path)
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory (".publish-" + [guid]::NewGuid() + ".tmp")
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
        if ($Immutable) { [IO.File]::Move($temporary, $Path, $false) }
        elseif ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path, $false) }
        if ((Get-RealTaskHash (Read-RealTaskJson $Path)) -cne $expectedHash) {
            throw "Atomic publication readback mismatch: $Path."
        }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Publish-RealTaskEvent {
    param($Event, [string] $Directory)
    Assert-RealTaskEvent $Event
    if ($Event.schema -cne "fingvibe-real-event-v1" -or
        $Event.eventId -cnotmatch '^[a-zA-Z0-9-]+$') { throw "Invalid immutable event identity." }
    $path = Join-Path $Directory "$($Event.eventId).json"
    if ([IO.File]::Exists($path)) {
        if ((Get-RealTaskHash (Read-RealTaskJson $path)) -cne (Get-RealTaskHash $Event)) {
            throw "Conflicting immutable event publication."
        }
        return $path
    }
    Write-RealTaskAtomic $Event $path -Immutable
    return $path
}

function Publish-RealTaskState {
    param($State, [string] $Path, [guid] $GateOwner, [int] $ExpectedRevision,
        [string] $GateDirectory = (Join-Path $env:LOCALAPPDATA "FingVibe\AgentCoordination"))
    Assert-RealTaskState $State
    if ($GateOwner -eq [guid]::Empty) { throw "Gate owner must be nonempty." }
    $parts = $State.repository.Split("/")
    $gatePath = Join-Path $GateDirectory "$($parts[0])\$($parts[1]).dispatch.json"
    $gate = Read-RealTaskJson $gatePath
    if ($gate.schema -cne "fingvibe-dispatch-gate-v1" -or $gate.repository -cne $State.repository -or
        $gate.owner -cne $GateOwner.ToString()) { throw "State publication requires this tick's repository gate." }
    if ([IO.File]::Exists($Path)) {
        $previous = Read-RealTaskJson $Path
        Assert-RealTaskState $previous
        if ($previous.repository -cne $State.repository -or $previous.epic -ne $State.epic -or
            $previous.revision -ne $ExpectedRevision -or $State.revision -ne $ExpectedRevision + 1) {
            throw "Stale revision or changed environment identity."
        }
        foreach ($field in @("targetBranch", "authorization", "workers")) {
            if ((Get-RealTaskHash @{ value = $previous[$field] }) -cne (Get-RealTaskHash @{ value = $State[$field] })) {
                throw "Live environment configuration requires human reconciliation, not an in-flight rewrite."
            }
        }
        foreach ($oldTask in $previous.tasks) {
            $task = Find-RealTask $State $oldTask.claimId
            if ($task.issue -ne $oldTask.issue -or $task.repairCount -lt $oldTask.repairCount -or
                $task.handoffs.Count -lt $oldTask.handoffs.Count) { throw "Task/repair history cannot be removed or reset." }
            foreach ($field in @("branch", "worktree", "pr")) {
                if ($null -ne $oldTask[$field] -and $oldTask[$field] -cne $task[$field]) {
                    throw "Established task context cannot change."
                }
            }
            if ($task.dispositions.Count -lt $oldTask.dispositions.Count) { throw "Disposition history cannot shrink." }
            for ($i = 0; $i -lt $oldTask.dispositions.Count; $i++) {
                if ((Get-RealTaskHash $oldTask.dispositions[$i]) -cne (Get-RealTaskHash $task.dispositions[$i])) {
                    throw "Prior disposition evidence cannot change."
                }
            }
            for ($i = 0; $i -lt $oldTask.handoffs.Count; $i++) {
                $old = $oldTask.handoffs[$i]
                $current = $task.handoffs[$i]
                if ($old.Contains("recovery") -and
                    (-not $current.Contains("recovery") -or
                        (Get-RealTaskHash $old.recovery) -cne (Get-RealTaskHash $current.recovery))) {
                    throw "Human recovery evidence cannot change or disappear."
                }
                foreach ($field in @("id", "action", "workerId", "expectedHead", "repairAttempt", "strategy", "feedback", "priorRepairEvidence")) {
                    if ((Get-RealTaskHash @{ value = $old[$field] }) -cne (Get-RealTaskHash @{ value = $current[$field] })) {
                        throw "Existing handoff identity/repair history cannot change."
                    }
                    foreach ($field in @("runId", "sessionId", "ackEventId", "resultEventId", "result")) {
                        if ($null -ne $old[$field] -and
                            (Get-RealTaskHash @{ value = $old[$field] }) -cne (Get-RealTaskHash @{ value = $current[$field] })) {
                            throw "Recorded execution identity/result evidence cannot change."
                        }
                    }
                }
                if ($current.transitions.Count -lt $old.transitions.Count) { throw "Transition history cannot shrink." }
                for ($j = 0; $j -lt $old.transitions.Count; $j++) {
                    if ((Get-RealTaskHash $old.transitions[$j]) -cne (Get-RealTaskHash $current.transitions[$j])) {
                        throw "Prior transition evidence cannot change."
                    }
                }
            }
        }
        foreach ($field in @("events", "reports")) {
            $counts = @{}
            foreach ($entry in $State[$field]) {
                $hash = Get-RealTaskHash $entry
                if (-not $counts.ContainsKey($hash)) { $counts[$hash] = 0 }
                $counts[$hash]++
            }
            foreach ($old in $previous[$field]) {
                $hash = Get-RealTaskHash $old
                if (-not $counts.ContainsKey($hash) -or $counts[$hash] -ne 1) {
                    throw "Prior $field evidence cannot change or disappear."
                }
            }
        }
    } elseif ($ExpectedRevision -ne 0 -or $State.revision -ne 1) {
        throw "Initialization requires authoritative absence and revision one."
    }
    Write-RealTaskAtomic $State $Path
}

function Sync-RealTaskIncidents {
    param($State, [string] $Directory)
    Assert-RealTaskState $State
    if (-not [IO.Directory]::Exists($Directory)) { throw "Incident directory unavailable; not an empty inventory." }
    $records = @()
    $ids = @{}
    foreach ($file in Get-ChildItem -LiteralPath $Directory -Filter "*.json" -File) {
        $incident = Read-RealTaskJson $file.FullName
        Assert-RealTaskFields $incident @("id", "originalReporter", "recordingActor", "changedUtc", "nextOwner", "nextAction", "evidence")
        foreach ($field in @("id", "originalReporter", "recordingActor", "nextOwner", "nextAction")) {
            Assert-RealTaskText $incident[$field] $field
        }
        Assert-RealTaskUtc $incident.changedUtc
        Assert-RealTaskEvidence $incident.evidence
        if ($ids.ContainsKey($incident.id)) { throw "Duplicate canonical incident." }
        $ids[$incident.id] = $true
        $records += @{ id = $incident.id; path = $file.FullName; hash = Get-RealTaskHash $incident }
    }
    foreach ($old in $State.incidents) {
        if (-not $ids.ContainsKey($old.id)) { throw "Previously indexed incident is missing; retain evidence." }
    }
    $State.incidents = $records
}

. (Join-Path $PSScriptRoot "RealTaskProtocol.ps1")

Export-ModuleMember -Function Assert-RealTaskState, New-RealTaskState, Get-RealTaskCapacity,
    Add-RealTaskClaim, Add-RealTaskHandoff, Set-RealTaskStage, Add-RealTaskEvent,
    Set-RealTaskDisposition, Read-RealTaskJson, Publish-RealTaskEvent, Publish-RealTaskState,
    Sync-RealTaskIncidents, Get-RealTaskAssignment, Assert-RealTaskAssignment, Publish-RealTaskAcknowledgment,
    New-RealTaskMessage, Publish-RealTaskMessage, Receive-RealTaskMessage,
    Publish-RealTaskProtocolError, Confirm-RealTaskMessage,
    Resolve-RealTaskHandoff
