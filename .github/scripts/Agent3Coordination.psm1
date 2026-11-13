#requires -Version 7.5
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:Stages = @("prepared", "launch-requested", "correlated", "delivered",
    "acknowledged", "result-recorded", "stopped-verified", "reconciled")
$script:TaskStates = @("implementing", "validation", "repair-needed", "finalize-ready",
    "human-review", "blocked", "delivered")

function Assert-Agent3Fields($Record, [string[]] $Fields, [switch] $Closed) {
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

function Assert-Agent3Text($Value, [string] $Name) {
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw "Expected nonempty $Name."
    }
}

function Assert-Agent3Utc($Value) {
    Assert-Agent3Text $Value "UTC timestamp"
    if ($Value -notmatch '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?(?:Z|\+00:00)$') {
        throw "Expected explicit UTC timestamp, not local or inferred time."
    }
    $null = [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture)
}

function Assert-Agent3Evidence($Evidence) {
    if ($Evidence -isnot [array] -or $Evidence.Count -eq 0) { throw "Evidence references are required." }
    foreach ($reference in $Evidence) { Assert-Agent3Text $reference "evidence reference" }
}

function Invoke-Agent3AuthorizationRead([string] $Endpoint) {
    $text = gh api -X GET $Endpoint
    if ($LASTEXITCODE -ne 0) {
        throw "Owner approval read failed: $Endpoint (exit $LASTEXITCODE). Do not claim or launch."
    }
    $text -join "`n"
}

function Get-Agent3AuthorizationEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$")]
        [string] $Repository,
        [Parameter(Mandatory)]
        [string] $Reference,
        [Parameter(Mandatory)]
        [ValidatePattern("^[A-Za-z0-9][A-Za-z0-9-]*$")]
        [string] $OwnerLogin,
        [scriptblock] $ApiReader = ${function:Invoke-Agent3AuthorizationRead}
    )

    $pattern = '^https://github\.com/(?<repository>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/issues/(?<issue>[1-9][0-9]*)#issuecomment-(?<comment>[1-9][0-9]*)$'
    if ($Reference -cnotmatch $pattern) {
        throw "Expected an independently inspectable GitHub issue-comment approval URL, not a session ID or authorization assertion. Do not claim or launch."
    }
    $source = @{} + $Matches
    if ($source.repository -ine $Repository) {
        throw "Owner approval reference belongs to another repository. Do not claim or launch."
    }
    $endpoint = "repos/$Repository/issues/comments/$($source.comment)"
    $json = & $ApiReader $endpoint
    if ($json -isnot [string] -or [string]::IsNullOrWhiteSpace($json)) {
        throw "Owner approval reader must return one nonempty JSON string. Do not claim or launch."
    }
    $comment = ConvertFrom-Json -InputObject $json -AsHashtable -DateKind String -Depth 100
    Assert-Agent3Fields $comment @("id", "html_url", "issue_url", "user", "body", "updated_at")
    Assert-Agent3Fields $comment.user @("login", "type")
    if ($comment.id -isnot [long] -and $comment.id -isnot [int]) {
        throw "Owner approval comment ID must be an integer."
    }
    if ($comment.id.ToString() -cne $source.comment -or $comment.html_url -ine $Reference -or
        $comment.issue_url -ine "https://api.github.com/repos/$Repository/issues/$($source.issue)") {
        throw "Owner approval response does not match the requested comment/repository. Do not claim or launch."
    }
    if ($comment.user.type -cne "User" -or $comment.user.login -ine $OwnerLogin) {
        throw "Owner approval author does not match the independently established human owner. Do not claim or launch."
    }
    Assert-Agent3Text $comment.body "owner approval text"
    Assert-Agent3Utc $comment.updated_at

    # Account authorship alone cannot distinguish a human from an agent using the same credentials.
    @{
        reference = $Reference
        authorLogin = $comment.user.login
        body = $comment.body
        updatedUtc = $comment.updated_at
    }
}

function Get-Agent3Hash($Record) {
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

function Get-Agent3EvidenceHash([string[]] $Evidence) {
    Assert-Agent3Evidence $Evidence
    $unique = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($reference in $Evidence) { $null = $unique.Add($reference) }
    [string[]] $references = @($unique)
    [Array]::Sort($references, [StringComparer]::Ordinal)
    Get-Agent3Hash @{ value = $references }
}

function Find-Agent3($State, [string] $ClaimId) {
    $matches = @($State.tasks | Where-Object claimId -CEQ $ClaimId)
    if ($matches.Count -ne 1) { throw "Expected exactly one task for claim '$ClaimId'." }
    return $matches[0]
}

function Find-Agent3Handoff($State, [string] $ClaimId, [string] $HandoffId) {
    $task = Find-Agent3 $State $ClaimId
    $matches = @($task.handoffs | Where-Object id -CEQ $HandoffId)
    if ($matches.Count -ne 1) { throw "Expected exactly one handoff '$HandoffId'." }
    return $matches[0]
}

function Test-Agent3Replacement($Handoff) {
    $null -ne $Handoff -and $Handoff.action -ceq "implement" -and
        $Handoff.stage -ceq "reconciled" -and $Handoff.Contains("recovery") -and
        $Handoff.recovery.restartImplementation
}

function Assert-Agent3Recovery($Handoff) {
    $recovery = $Handoff.recovery
    Assert-Agent3Fields $recovery @("mode", "priorStage", "authorization", "evidence", "utc", "restartImplementation") -Closed
    Assert-Agent3Text $recovery.authorization "human recovery authorization"
    Assert-Agent3Evidence $recovery.evidence
    Assert-Agent3Utc $recovery.utc
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
            Assert-Agent3Text $Handoff.runId "actual run ID"
            Assert-Agent3Text $Handoff.sessionId "actual session ID"
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

function Assert-Agent3HumanDelivery($Delivery, [string] $TargetBranch) {
    Assert-Agent3Fields $Delivery @("head", "targetBranch", "evidence", "cleanupEvidence") -Closed
    Assert-Agent3Text $Delivery.head "delivered head"
    if ($Delivery.head -cnotmatch '^[0-9a-f]{40}$' -or $Delivery.targetBranch -cne $TargetBranch) {
        throw "Human delivery requires the verified head on the configured target branch."
    }
    Assert-Agent3Evidence $Delivery.evidence
    Assert-Agent3Evidence $Delivery.cleanupEvidence
}

function Assert-Agent3State {
    param([Parameter(Mandatory)] $State)
    Assert-Agent3Fields $State @("schema", "repository", "epic", "targetBranch", "authorization",
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
    Assert-Agent3Text $State.targetBranch "target branch"
    Assert-Agent3Fields $State.authorization @("reference", "implementation", "merge")
    Assert-Agent3Text $State.authorization.reference "human authorization reference"
    if ($State.authorization.implementation -isnot [bool] -or
        $State.authorization.merge -isnot [bool]) { throw "Authorization capabilities must be explicit booleans." }
    Assert-Agent3Utc $State.updatedUtc
    foreach ($field in @("workers", "tasks", "events", "incidents", "reports")) {
        if ($State[$field] -isnot [array]) { throw "'$field' must be an array." }
    }
    if ($State.workers.Count -ne 2) { throw "Exactly two Developer identities are required." }
    $workers = @{}
    foreach ($worker in $State.workers) {
        Assert-Agent3Fields $worker @("id", "name", "automationId")
        foreach ($field in @("id", "name", "automationId")) { Assert-Agent3Text $worker[$field] $field }
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
        Assert-Agent3Fields $task @("claimId", "issue", "state", "repairCount", "handoffs",
            "branch", "worktree", "pr", "head", "checkpoint", "scopeEvidence", "dispositions", "changedUtc")
        Assert-Agent3Text $task.claimId "claim ID"
        if ($claims.ContainsKey($task.claimId) -or $issues.ContainsKey([string]$task.issue)) {
            throw "Duplicate task or claim."
        }
        $claims[$task.claimId] = $true
        $issues[[string]$task.issue] = $true
        if (($task.issue -isnot [int] -and $task.issue -isnot [long]) -or $task.issue -le 0 -or
            $task.state -cnotin $script:TaskStates) { throw "Invalid task issue or state." }
        if (($task.repairCount -isnot [int] -and $task.repairCount -isnot [long]) -or
            $task.repairCount -lt 0 -or $task.repairCount -gt 12) { throw "Repair count must be an integer from 0 to 12." }
        Assert-Agent3Evidence $task.scopeEvidence
        Assert-Agent3Utc $task.changedUtc
        if ($task.handoffs -isnot [array] -or $task.dispositions -isnot [array]) {
            throw "Task history must be arrays."
        }
        foreach ($disposition in $task.dispositions) {
            Assert-Agent3Fields $disposition @("state", "utc", "evidence")
            if ($disposition.state -cnotin $script:TaskStates) { throw "Unknown disposition state." }
            Assert-Agent3Utc $disposition.utc
            Assert-Agent3Evidence $disposition.evidence
            if ($disposition.Contains("independentEvidence")) {
                if ($disposition.state -cne "blocked") { throw "Independence evidence belongs to a blocked disposition." }
                Assert-Agent3Evidence $disposition.independentEvidence
            }
            if ($disposition.Contains("humanDelivery")) {
                if ($disposition.state -cne "delivered") { throw "Human delivery belongs to a delivered disposition." }
                Assert-Agent3HumanDelivery $disposition.humanDelivery $State.targetBranch
            }
        }
        $repairs = 0
        $implementations = 0
        $previous = $null
        foreach ($handoff in $task.handoffs) {
            Assert-Agent3Fields $handoff @("id", "action", "stage", "workerId", "runId", "sessionId",
                "expectedHead", "feedback", "priorRepairEvidence", "repairAttempt", "strategy",
                "transitions", "ackEventId", "resultEventId", "result")
            Assert-Agent3Text $handoff.id "handoff ID"
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
                if ($implementations -gt 1 -and -not (Test-Agent3Replacement $previous)) {
                    throw "Replacement implementation requires human-reconciled pre-start failure."
                }
            } elseif ($implementations -lt 1) { throw "Repair/finalize requires initial implementation history." }
            if ($handoff.action -ceq "repair") {
                $repairs++
                $strategy = if ($repairs -eq 1) { "targeted" } else { "reassess" }
                if ($handoff.repairAttempt -ne $repairs -or $handoff.strategy -cne $strategy) {
                    throw "Repair history/strategy mismatch."
                }
                Assert-Agent3Evidence $handoff.feedback
                if ($repairs -gt 1) { Assert-Agent3Evidence $handoff.priorRepairEvidence }
            } elseif ($handoff.repairAttempt -ne 0) { throw "Only repairs consume repair attempts." }
            if ($handoff.action -cne "implement") {
                if ($handoff.expectedHead -cnotmatch '^[0-9a-f]{40}$') { throw "Expected full PR head SHA." }
                foreach ($field in @("branch", "worktree", "pr", "checkpoint")) {
                    Assert-Agent3Text $task[$field] $field
                }
                if (-not [IO.Path]::IsPathFullyQualified($task.worktree)) { throw "Worktree must be absolute." }
            }
            if ($handoff.transitions -isnot [array] -or $handoff.transitions.Count -eq 0) {
                throw "Missing handoff transition history."
            }
            $recovered = $handoff.Contains("recovery")
            if ($recovered) { Assert-Agent3Recovery $handoff }
            $last = $null
            for ($transitionIndex = 0; $transitionIndex -lt $handoff.transitions.Count; $transitionIndex++) {
                $transition = $handoff.transitions[$transitionIndex]
                Assert-Agent3Fields $transition @("stage", "utc", "evidence")
                Assert-Agent3Utc $transition.utc
                Assert-Agent3Evidence $transition.evidence
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
                    (Get-Agent3Hash @{ value = $transition.evidence }) -ceq
                        (Get-Agent3Hash @{ value = $handoff.recovery.evidence })
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
                Assert-Agent3Text $handoff.ackEventId "retained acknowledgment event ID"
            }
            if ($handoff.stage -cin @("correlated", "delivered", "acknowledged", "result-recorded", "stopped-verified", "reconciled") -and
                -not ($recovered -and $handoff.recovery.mode -ceq "no-launch")) {
                Assert-Agent3Text $handoff.runId "actual run ID"
                Assert-Agent3Text $handoff.sessionId "actual session ID"
            }
            if ($handoff.stage -cin @("acknowledged", "result-recorded", "stopped-verified", "reconciled") -and -not $recovered) {
                if ($null -eq $handoff.ackEventId -and
                    ($null -eq $handoff.result -or $handoff.result.outcome -cne "blocked-before-start")) {
                    throw "Execution requires an acknowledgment."
                }
            }
            if ($handoff.stage -cin @("result-recorded", "stopped-verified", "reconciled") -and
                (-not $recovered -or $null -ne $handoff.resultEventId)) {
                Assert-Agent3Text $handoff.resultEventId "result event ID"
                Assert-Agent3Fields $handoff.result @("outcome", "head", "checkpoint", "evidence")
                Assert-Agent3Evidence $handoff.result.evidence
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
        Assert-Agent3Fields $event @("id", "hash", "claimId", "handoffId", "kind")
        if ($eventIds.ContainsKey($event.id)) { throw "Duplicate event index entry." }
        $eventIds[$event.id] = $true
        $handoff = Find-Agent3Handoff $State $event.claimId $event.handoffId
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
        Assert-Agent3Fields $report @("id", "claimId", "handoffId", "url", "utc", "nextOwner", "nextAction")
        foreach ($field in @("id", "url", "nextOwner", "nextAction")) { Assert-Agent3Text $report[$field] $field }
        Assert-Agent3Utc $report.utc
        $null = Find-Agent3Handoff $State $report.claimId $report.handoffId
    }
}

function New-Agent3State {
    param([string] $Repository, [int] $Epic, [string] $TargetBranch, [hashtable] $Authorization, [array] $Workers)
    $state = @{
        schema = "fingvibe-real-state-v1"; repository = $Repository.ToLowerInvariant()
        epic = $Epic; targetBranch = $TargetBranch; authorization = $Authorization; workers = $Workers
        revision = 1; updatedUtc = [DateTime]::UtcNow.ToString("o")
        tasks = @(); events = @(); incidents = @(); reports = @()
    }
    Assert-Agent3State $state
    return $state
}

function Get-Agent3Capacity {
    param([Parameter(Mandatory)] $State)
    Assert-Agent3State $State
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

function Add-Agent3Claim {
    param($State, [int] $Issue, [string[]] $ScopeEvidence)
    Assert-Agent3State $State
    if (-not $State.authorization.implementation) { throw "Implementation is not authorized." }
    Assert-Agent3Evidence $ScopeEvidence
    if ($Issue -le 0 -or @($State.tasks | Where-Object issue -EQ $Issue).Count -ne 0) {
        throw "Invalid or already claimed issue."
    }
    if (-not (Get-Agent3Capacity $State).canStartImplementation) { throw "No implementation capacity." }
    $task = @{
        claimId = [guid]::NewGuid().ToString(); issue = $Issue; state = "implementing"
        repairCount = 0; handoffs = @(); branch = $null; worktree = $null; pr = $null
        head = $null; checkpoint = $null; scopeEvidence = $ScopeEvidence; dispositions = @()
        changedUtc = [DateTime]::UtcNow.ToString("o")
    }
    $State.tasks += $task
    return $task
}

function Add-Agent3Handoff {
    param($State, [string] $ClaimId, [string] $WorkerId,
        [ValidateSet("implement", "repair", "finalize")] [string] $Action,
        [string[]] $Feedback = @(), [string[]] $PriorRepairEvidence = @())
    Assert-Agent3State $State
    $task = Find-Agent3 $State $ClaimId
    $capacity = Get-Agent3Capacity $State
    if (-not $State.authorization.implementation -or $WorkerId -cnotin $capacity.freeWorkers -or
        @($task.handoffs | Where-Object stage -CNE "reconciled").Count -ne 0) {
        throw "Worker/task unavailable or unauthorized."
    }
    if ($Action -ceq "implement") {
        if (($task.handoffs.Count -ne 0 -and -not (Test-Agent3Replacement $task.handoffs[-1])) -or
            $task.state -cnotin @("implementing", "blocked") -or $capacity.occupiedWorkers.Count -ge 2 -or
            $capacity.validationPending -ge 2 -or
            @($capacity.unassignedClaims | Where-Object { $_ -cne $ClaimId }).Count -gt 0) {
            throw "Initial implementation already assigned or backlog full."
        }
    } elseif ($Action -ceq "repair") {
        if ($task.state -cne "repair-needed" -or $task.repairCount -ge 12) { throw "Repair unavailable or exhausted." }
        Assert-Agent3Evidence $Feedback
        if ($task.repairCount -gt 0) { Assert-Agent3Evidence $PriorRepairEvidence }
    } else {
        if ($task.state -cne "finalize-ready") { throw "Task is not finalize-ready." }
        Assert-Agent3Evidence $Feedback
        foreach ($prior in $task.handoffs) {
            if ($prior.action -ceq "finalize" -and $prior.expectedHead -ceq $task.head -and
                (Get-Agent3EvidenceHash $prior.feedback) -ceq (Get-Agent3EvidenceHash $Feedback)) {
                throw "Duplicate finalize revision/evidence; require a meaningful evidence change."
            }
        }
    }
    if ($Action -cne "implement") {
        if ($task.head -cnotmatch '^[0-9a-f]{40}$') { throw "Expected full PR head SHA." }
        foreach ($field in @("branch", "worktree", "pr", "checkpoint")) { Assert-Agent3Text $task[$field] $field }
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
    Assert-Agent3State $State
    return $handoff
}

function Set-Agent3Stage {
    param($State, [string] $ClaimId, [string] $HandoffId,
        [ValidateSet("launch-requested", "correlated", "delivered", "stopped-verified", "reconciled")] [string] $Stage,
        [string[]] $Evidence, [string] $RunId, [string] $SessionId)
    Assert-Agent3State $State
    Assert-Agent3Evidence $Evidence
    $handoff = Find-Agent3Handoff $State $ClaimId $HandoffId
    $expected = @{
        "launch-requested" = "prepared"; correlated = "launch-requested"; delivered = "correlated"
        "stopped-verified" = "result-recorded"; reconciled = "stopped-verified"
    }
    if ($handoff.stage -cne $expected[$Stage]) { throw "Invalid stage transition to '$Stage'." }
    if ($Stage -ceq "correlated") {
        Assert-Agent3Text $RunId "actual run ID"
        Assert-Agent3Text $SessionId "actual session ID"
        $handoff.runId = $RunId
        $handoff.sessionId = $SessionId
    }
    if ($Stage -ceq "reconciled") {
        $task = Find-Agent3 $State $ClaimId
        if ($task.state -ceq "implementing") { throw "Reconcile task disposition before freeing worker." }
    }
    $handoff.stage = $Stage
    $handoff.transitions += @{ stage = $Stage; utc = [DateTime]::UtcNow.ToString("o"); evidence = $Evidence }
    (Find-Agent3 $State $ClaimId).changedUtc = [DateTime]::UtcNow.ToString("o")
    Assert-Agent3State $State
}

function Resolve-Agent3Handoff {
    param($State, [string] $ClaimId, [string] $HandoffId,
        [ValidateSet("no-launch", "stopped", "pre-start-rejected")] [string] $Mode,
        [string] $HumanAuthorization, [string[]] $Evidence, [switch] $RestartImplementation)
    Assert-Agent3State $State
    Assert-Agent3Text $HumanAuthorization "human recovery authorization"
    Assert-Agent3Evidence $Evidence
    $task = Find-Agent3 $State $ClaimId
    $handoff = Find-Agent3Handoff $State $ClaimId $HandoffId
    if ($handoff.id -cne $task.handoffs[-1].id -or $handoff.Contains("recovery")) {
        throw "Only the latest handoff can be recovered once."
    }
    $utc = [DateTime]::UtcNow.ToString("o")
    $recovery = @{ mode = $Mode; priorStage = $handoff.stage; authorization = $HumanAuthorization
        evidence = $Evidence; utc = $utc; restartImplementation = [bool]$RestartImplementation }
    $candidate = @{} + $handoff
    $candidate.stage = "reconciled"
    $candidate.recovery = $recovery
    Assert-Agent3Recovery $candidate
    $handoff.recovery = $recovery
    $handoff.stage = "reconciled"
    $handoff.transitions += @{ stage = "reconciled"; utc = $utc; evidence = $Evidence }
    $task.state = "blocked"
    $task.changedUtc = $utc
    $task.dispositions += @{ state = "blocked"; utc = $utc; evidence = $Evidence }
    Assert-Agent3State $State
}

function Test-Agent3Event {
    param($State, $Event, [switch] $AcknowledgmentVerified)
    Assert-Agent3Event $Event
    $hash = Get-Agent3Hash $Event
    $seen = @($State.events | Where-Object id -CEQ $Event.eventId)
    if ($seen.Count -gt 0) {
        if ($seen[0].hash -cne $hash) { Stop-Agent3Protocol "conflicting-duplicate" "Conflicting duplicate event." }
        return @{ disposition = "duplicate"; hash = $hash; handoff = $null }
    }
    $handoff = Find-Agent3Handoff $State $Event.claimId $Event.handoffId
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
            Assert-Agent3Text $Event.result.checkpoint "implementation checkpoint"
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

function Add-Agent3Event {
    param($State, $Event)
    Assert-Agent3State $State
    $check = Test-Agent3Event $State $Event
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
        $task = Find-Agent3 $State $Event.claimId
        if ($Event.result.outcome -ceq "implementation-ready") {
            $task.head = $Event.result.head
            $task.checkpoint = $Event.result.checkpoint
        }
    }
    $handoff.stage = $stage
    $handoff.transitions += @{ stage = $stage; utc = $Event.utc; evidence = $Event.evidence }
    $State.events += @{ id = $Event.eventId; hash = $check.hash; claimId = $Event.claimId
        handoffId = $Event.handoffId; kind = $Event.kind }
    (Find-Agent3 $State $Event.claimId).changedUtc = [DateTime]::UtcNow.ToString("o")
    Assert-Agent3State $State
    return "applied"
}

function Assert-Agent3Event($Event) {
    Assert-Agent3Fields $Event @("schema", "eventId", "kind", "claimId", "handoffId", "action",
        "workerId", "runId", "sessionId", "utc", "actor", "originalReporter", "trigger",
        "elapsedSeconds", "result", "evidence") -Closed
    Assert-Agent3Text $Event.schema "event schema"
    if ($Event.schema -cne "fingvibe-real-event-v1" -or $Event.kind -cnotin @("ack", "result")) {
        throw "Unsupported event schema/kind; field aliases are not inferred."
    }
    foreach ($field in @("eventId", "claimId", "handoffId", "action", "workerId", "runId", "sessionId",
        "actor", "originalReporter", "trigger")) { Assert-Agent3Text $Event[$field] $field }
    if ($Event.action -cnotin @("implement", "repair", "finalize") -or
        $Event.workerId -cnotin @("developer-1", "developer-2")) { throw "Invalid event action/worker." }
    if ($Event.eventId -cne "$($Event.kind)-$($Event.handoffId)") {
        throw "Event ID must be reserved by kind and handoff."
    }
    if ($Event.trigger -cnotin @("scheduled", "manual", "worker-message", "unknown")) { throw "Invalid trigger provenance." }
    Assert-Agent3Utc $Event.utc
    Assert-Agent3Evidence $Event.evidence
    if ($null -ne $Event.elapsedSeconds -and
        ($Event.elapsedSeconds -isnot [ValueType] -or $Event.elapsedSeconds -is [bool] -or
            [double]::IsNaN([double]$Event.elapsedSeconds) -or
            [double]::IsInfinity([double]$Event.elapsedSeconds) -or [double]$Event.elapsedSeconds -lt 0)) {
        throw "Monotonic elapsedSeconds must be nonnegative or explicitly null."
    }
    if ($Event.kind -ceq "ack") {
        if ($null -ne $Event.result) { throw "Acknowledgment cannot contain a result." }
    } else {
        Assert-Agent3Fields $Event.result @("outcome", "head", "checkpoint", "evidence") -Closed
        Assert-Agent3Evidence $Event.result.evidence
        if ($Event.result.outcome -cnotin @("implementation-ready", "blocked", "blocked-before-start", "pr-ready", "delivered")) {
            throw "Unknown result outcome."
        }
        foreach ($field in @("head", "checkpoint")) {
            if ($null -ne $Event.result[$field]) { Assert-Agent3Text $Event.result[$field] $field }
        }
        if ($null -ne $Event.result.head -and $Event.result.head -cnotmatch '^[0-9a-f]{40}$') {
            throw "Expected full result head SHA."
        }
        if ($Event.result.outcome -ceq "implementation-ready") {
            if ($Event.action -ceq "finalize" -or $Event.result.head -cnotmatch '^[0-9a-f]{40}$') {
                throw "Invalid implementation checkpoint."
            }
            Assert-Agent3Text $Event.result.checkpoint "implementation checkpoint"
        }
        if ($Event.result.outcome -cin @("pr-ready", "delivered") -and
            ($Event.action -cne "finalize" -or $Event.result.head -cnotmatch '^[0-9a-f]{40}$')) {
            throw "Invalid finalization result."
        }
    }
}

function Get-Agent3Assignment {
    param($State, [string] $ClaimId, [string] $HandoffId)
    Assert-Agent3State $State
    Get-Agent3AssignmentCore $State $ClaimId $HandoffId
}

function Get-Agent3AssignmentCore($State, [string] $ClaimId, [string] $HandoffId) {
    $task = Find-Agent3 $State $ClaimId
    $handoff = Find-Agent3Handoff $State $ClaimId $HandoffId
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

function Assert-Agent3Assignment {
    param($State, $Assignment, [string] $WorkerId, [string] $RunId, [string] $SessionId)
    Assert-Agent3State $State
    Assert-Agent3AssignmentCore $State $Assignment $WorkerId $RunId $SessionId
}

function Assert-Agent3AssignmentCore($State, $Assignment, [string] $WorkerId, [string] $RunId, [string] $SessionId) {
    Assert-Agent3Fields $Assignment @("claimId", "handoffId")
    $expected = Get-Agent3AssignmentCore $State $Assignment.claimId $Assignment.handoffId
    if (-not $State.authorization.implementation -or $expected.workerId -cne $WorkerId -or
        $expected.runId -cne $RunId -or $expected.sessionId -cne $SessionId -or
        (Get-Agent3Hash $Assignment) -cne (Get-Agent3Hash $expected)) {
        throw "Invalid/stale assignment or actual worker/run/session mismatch."
    }
    $handoff = Find-Agent3Handoff $State $Assignment.claimId $Assignment.handoffId
    if ($handoff.stage -cnotin @("correlated", "delivered") -or $null -ne $handoff.ackEventId) {
        throw "Assignment is not correlated or was already acknowledged."
    }
}

function Publish-Agent3Acknowledgment {
    param($State, $Assignment, [string] $WorkerId, [string] $RunId, [string] $SessionId,
        [string] $Directory, [string] $Actor, [string] $Trigger = "unknown", [string[]] $Evidence)
    Assert-Agent3Assignment $State $Assignment $WorkerId $RunId $SessionId
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
    Assert-Agent3Event $event
    # Create-new publication arbitrates duplicate starts even before Dispatcher ingestion.
    Write-Agent3Atomic $event (Join-Path $Directory "$id.json") -Immutable
    return $event
}

function Set-Agent3Disposition {
    param($State, [string] $ClaimId,
        [ValidateSet("validation", "repair-needed", "finalize-ready", "human-review", "blocked", "delivered")] [string] $Disposition,
        [string[]] $Evidence, [string[]] $IndependentEvidence, $HumanDelivery)
    Assert-Agent3State $State
    Assert-Agent3Evidence $Evidence
    $task = Find-Agent3 $State $ClaimId
    if ($null -ne $IndependentEvidence) {
        if ($Disposition -cne "blocked") { throw "Independence evidence requires a blocked disposition." }
        Assert-Agent3Evidence $IndependentEvidence
    }
    if ($null -ne $HumanDelivery) {
        if ($Disposition -cne "delivered") { throw "Human delivery requires a delivered disposition." }
        Assert-Agent3HumanDelivery $HumanDelivery $State.targetBranch
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
        $waiting = (Get-Agent3Capacity $State).validationPending
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
    Assert-Agent3State $State
}

function Read-Agent3Json {
    param([string] $Path)
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw "Record path must be absolute." }
    if (-not [IO.File]::Exists($Path)) { throw "Record absent: $Path. Never infer idle capacity." }
    $json = [IO.File]::ReadAllText($Path)
    ConvertFrom-Agent3Json $json
}

function ConvertFrom-Agent3Json([string] $Json) {
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

function Write-Agent3Atomic($Record, [string] $Path, [switch] $Immutable) {
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw "Record path must be absolute." }
    $json = $Record | ConvertTo-Json -Depth 100
    $parsed = ConvertFrom-Agent3Json $json
    $expectedHash = Get-Agent3Hash $Record
    if ((Get-Agent3Hash $parsed) -cne $expectedHash) {
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
        if ((Get-Agent3Hash (Read-Agent3Json $Path)) -cne $expectedHash) {
            throw "Atomic publication readback mismatch: $Path."
        }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Publish-Agent3Event {
    param($Event, [string] $Directory)
    Assert-Agent3Event $Event
    if ($Event.schema -cne "fingvibe-real-event-v1" -or
        $Event.eventId -cnotmatch '^[a-zA-Z0-9-]+$') { throw "Invalid immutable event identity." }
    $path = Join-Path $Directory "$($Event.eventId).json"
    if ([IO.File]::Exists($path)) {
        if ((Get-Agent3Hash (Read-Agent3Json $path)) -cne (Get-Agent3Hash $Event)) {
            throw "Conflicting immutable event publication."
        }
        return $path
    }
    Write-Agent3Atomic $Event $path -Immutable
    return $path
}

function Publish-Agent3State {
    param($State, [string] $Path, [guid] $GateOwner, [int] $ExpectedRevision,
        [string] $GateDirectory = (Join-Path $env:LOCALAPPDATA "FingVibe\AgentCoordination"))
    Assert-Agent3State $State
    if ($GateOwner -eq [guid]::Empty) { throw "Gate owner must be nonempty." }
    $parts = $State.repository.Split("/")
    $gatePath = Join-Path $GateDirectory "$($parts[0])\$($parts[1]).dispatch.json"
    $gate = Read-Agent3Json $gatePath
    if ($gate.schema -cne "fingvibe-dispatch-gate-v1" -or $gate.repository -cne $State.repository -or
        $gate.owner -cne $GateOwner.ToString()) { throw "State publication requires this tick's repository gate." }
    if ([IO.File]::Exists($Path)) {
        $previous = Read-Agent3Json $Path
        Assert-Agent3State $previous
        if ($previous.repository -cne $State.repository -or $previous.epic -ne $State.epic -or
            $previous.revision -ne $ExpectedRevision -or $State.revision -ne $ExpectedRevision + 1) {
            throw "Stale revision or changed environment identity."
        }
        foreach ($field in @("targetBranch", "authorization", "workers")) {
            if ((Get-Agent3Hash @{ value = $previous[$field] }) -cne (Get-Agent3Hash @{ value = $State[$field] })) {
                throw "Live environment configuration requires human reconciliation, not an in-flight rewrite."
            }
        }
        foreach ($oldTask in $previous.tasks) {
            $task = Find-Agent3 $State $oldTask.claimId
            if ($task.issue -ne $oldTask.issue -or $task.repairCount -lt $oldTask.repairCount -or
                $task.handoffs.Count -lt $oldTask.handoffs.Count) { throw "Task/repair history cannot be removed or reset." }
            foreach ($field in @("branch", "worktree", "pr")) {
                if ($null -ne $oldTask[$field] -and $oldTask[$field] -cne $task[$field]) {
                    throw "Established task context cannot change."
                }
            }
            if ($task.dispositions.Count -lt $oldTask.dispositions.Count) { throw "Disposition history cannot shrink." }
            for ($i = 0; $i -lt $oldTask.dispositions.Count; $i++) {
                if ((Get-Agent3Hash $oldTask.dispositions[$i]) -cne (Get-Agent3Hash $task.dispositions[$i])) {
                    throw "Prior disposition evidence cannot change."
                }
            }
            for ($i = 0; $i -lt $oldTask.handoffs.Count; $i++) {
                $old = $oldTask.handoffs[$i]
                $current = $task.handoffs[$i]
                if ($old.Contains("recovery") -and
                    (-not $current.Contains("recovery") -or
                        (Get-Agent3Hash $old.recovery) -cne (Get-Agent3Hash $current.recovery))) {
                    throw "Human recovery evidence cannot change or disappear."
                }
                foreach ($field in @("id", "action", "workerId", "expectedHead", "repairAttempt", "strategy", "feedback", "priorRepairEvidence")) {
                    if ((Get-Agent3Hash @{ value = $old[$field] }) -cne (Get-Agent3Hash @{ value = $current[$field] })) {
                        throw "Existing handoff identity/repair history cannot change."
                    }
                    foreach ($field in @("runId", "sessionId", "ackEventId", "resultEventId", "result")) {
                        if ($null -ne $old[$field] -and
                            (Get-Agent3Hash @{ value = $old[$field] }) -cne (Get-Agent3Hash @{ value = $current[$field] })) {
                            throw "Recorded execution identity/result evidence cannot change."
                        }
                    }
                }
                if ($current.transitions.Count -lt $old.transitions.Count) { throw "Transition history cannot shrink." }
                for ($j = 0; $j -lt $old.transitions.Count; $j++) {
                    if ((Get-Agent3Hash $old.transitions[$j]) -cne (Get-Agent3Hash $current.transitions[$j])) {
                        throw "Prior transition evidence cannot change."
                    }
                }
            }
        }
        foreach ($field in @("events", "reports")) {
            $counts = @{}
            foreach ($entry in $State[$field]) {
                $hash = Get-Agent3Hash $entry
                if (-not $counts.ContainsKey($hash)) { $counts[$hash] = 0 }
                $counts[$hash]++
            }
            foreach ($old in $previous[$field]) {
                $hash = Get-Agent3Hash $old
                if (-not $counts.ContainsKey($hash) -or $counts[$hash] -ne 1) {
                    throw "Prior $field evidence cannot change or disappear."
                }
            }
        }
    } elseif ($ExpectedRevision -ne 0 -or $State.revision -ne 1) {
        throw "Initialization requires authoritative absence and revision one."
    }
    Write-Agent3Atomic $State $Path
}

function Sync-Agent3Incidents {
    param($State, [string] $Directory)
    Assert-Agent3State $State
    if (-not [IO.Directory]::Exists($Directory)) { throw "Incident directory unavailable; not an empty inventory." }
    $records = @()
    $ids = @{}
    foreach ($file in Get-ChildItem -LiteralPath $Directory -Filter "*.json" -File) {
        $incident = Read-Agent3Json $file.FullName
        Assert-Agent3Fields $incident @("id", "originalReporter", "recordingActor", "changedUtc", "nextOwner", "nextAction", "evidence")
        foreach ($field in @("id", "originalReporter", "recordingActor", "nextOwner", "nextAction")) {
            Assert-Agent3Text $incident[$field] $field
        }
        Assert-Agent3Utc $incident.changedUtc
        Assert-Agent3Evidence $incident.evidence
        if ($ids.ContainsKey($incident.id)) { throw "Duplicate canonical incident." }
        $ids[$incident.id] = $true
        $records += @{ id = $incident.id; path = $file.FullName; hash = Get-Agent3Hash $incident }
    }
    foreach ($old in $State.incidents) {
        if (-not $ids.ContainsKey($old.id)) { throw "Previously indexed incident is missing; retain evidence." }
    }
    $State.incidents = $records
}

. (Join-Path $PSScriptRoot "Agent3Protocol.ps1")

Export-ModuleMember -Function Assert-Agent3State, New-Agent3State, Get-Agent3Capacity,
    Add-Agent3Claim, Add-Agent3Handoff, Set-Agent3Stage, Add-Agent3Event,
    Set-Agent3Disposition, Read-Agent3Json, Publish-Agent3Event, Publish-Agent3State,
    Sync-Agent3Incidents, Get-Agent3Assignment, Assert-Agent3Assignment, Publish-Agent3Acknowledgment,
    New-Agent3Message, Publish-Agent3Message, Receive-Agent3Message,
    Publish-Agent3ProtocolError, Confirm-Agent3Message,
    Resolve-Agent3Handoff, Get-Agent3AuthorizationEvidence
