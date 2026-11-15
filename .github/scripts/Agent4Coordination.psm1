$ErrorActionPreference = "Stop"

function Assert-Agent4Id([string] $Id) {
    if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') { throw "Invalid local record identity." }
}

function Assert-Agent4Evidence($Evidence) {
    if (@($Evidence).Count -eq 0 -or @($Evidence | Where-Object {
        $_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_)
    }).Count) { throw "Nonempty traceable evidence is required." }
}

function Copy-Agent4Record($Record) {
    $Record | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
}

function Read-Agent4Json([string] $Path) {
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw "Use an absolute local record path." }
    $text = [IO.File]::ReadAllText($Path)
    if (-not $text.TrimStart().StartsWith("{")) { throw "Expected one JSON object: $Path." }
    $text | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
}

function Write-Agent4Json([string] $Path, $Record, [switch] $Replace) {
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw "Use an absolute local record path." }
    $json = $Record | ConvertTo-Json -Depth 100
    $directory = [IO.Path]::GetDirectoryName($Path)
    $null = [IO.Directory]::CreateDirectory($directory)
    $temporary = Join-Path $directory (".agent4-" + [guid]::NewGuid() + ".tmp")
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($json)
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        } finally { $stream.Dispose() }
        [IO.File]::Move($temporary, $Path, $Replace.IsPresent)
        if ([IO.File]::ReadAllText($Path) -cne $json) { throw "Record publication readback failed: $Path." }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function New-Agent4State($Configuration) {
    $state = @{
        schema = "fingvibe-loop4-state-v1"; revision = 0
        configuration = Copy-Agent4Record $Configuration
        offers = @(); claims = @()
    }
    Assert-Agent4State $state
    $state
}

function Get-Agent4Environment(
    [string] $Repository,
    [int] $Epic,
    [string] $Directory,
    [string] $LocalApplicationData = $env:LOCALAPPDATA
) {
    if ($Repository -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$' -or $Epic -le 0) {
        throw "A valid repository and positive requested Epic number are required."
    }
    if (-not $Directory) {
        if (-not $LocalApplicationData -or -not [IO.Path]::IsPathFullyQualified($LocalApplicationData)) {
            throw "The standard local application data directory is unavailable."
        }
        $parts = $Repository.ToLowerInvariant().Split("/")
        $Directory = Join-Path $LocalApplicationData "FingVibe\AgentCoordination\loop4\$($parts[0])\$($parts[1])"
    }
    if (-not [IO.Path]::IsPathFullyQualified($Directory)) { throw "Use an absolute loop4 directory." }
    $state = Read-Agent4Json (Join-Path $Directory "state.json")
    Assert-Agent4State $state
    if ($state.configuration.repository -ine $Repository -or $state.configuration.epic -ne $Epic) {
        throw "Requested repository/Epic does not match saved loop4 configuration; explicit setup/reconciliation is required."
    }
    @{ directory = $Directory; state = $state }
}

function Assert-Agent4State($State) {
    $config = $State.configuration
    if ($State.schema -cne "fingvibe-loop4-state-v1" -or $State.revision -isnot [long] -and
        $State.revision -isnot [int] -or $State.revision -lt 0 -or
        $config.repository -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$' -or
        $config.epic -isnot [int] -and $config.epic -isnot [long] -or $config.epic -le 0 -or -not $config.targetBranch -or
        $config.authorization.implementation -cne $true -or
        $config.authorization.merge -isnot [bool] -or -not $config.authorization.reference -or
        $config.maxRepairAttempts -isnot [int] -and $config.maxRepairAttempts -isnot [long] -or
        $config.maxRepairAttempts -lt 0 -or $config.maxRepairAttempts -gt 12) {
        throw "Invalid loop4 state/configuration; explicit authority and repair limit (0-12) are required."
    }
    if (@($config.workers).Count -ne 2 -or
        @($config.workers.id | Sort-Object -Unique).Count -ne 2 -or
        @($config.workers.automationId | Sort-Object -Unique).Count -ne 2 -or
        @($config.workers.id | Where-Object { $_ -notin @("developer-1", "developer-2") }).Count) {
        throw "Configure exactly developer-1 and developer-2 with distinct Automations."
    }
    foreach ($worker in $config.workers) {
        if (-not $worker.name -or -not $worker.automationId) { throw "Missing worker name or Automation identity." }
    }
    foreach ($collection in @("offers", "claims")) {
        if ($State[$collection] -isnot [array]) { throw "Missing $collection inventory." }
        $ids = @{}
        foreach ($item in $State[$collection]) {
            Assert-Agent4Id $item.id
            if ($ids.ContainsKey($item.id) -or $item.workerId -notin $config.workers.id) {
                throw "Duplicate record or unknown worker."
            }
            $ids[$item.id] = $true
        }
    }
    foreach ($offer in $State.offers) {
        if ($offer.status -notin @("offered", "correlated", "confirmed", "declined") -or
            @($offer.candidates).Count -lt 1 -or @($offer.candidates).Count -gt 2 -or
            @($offer.candidates.issue | Sort-Object -Unique).Count -ne @($offer.candidates).Count) {
            throw "Invalid offer."
        }
        foreach ($candidate in $offer.candidates) {
            if ($candidate.issue -le 0 -or -not $candidate.url) { throw "Invalid candidate." }
        }
        if ($offer.status -in @("correlated", "confirmed") -and (-not $offer.runId -or -not $offer.sessionId)) {
            throw "Missing correlated offer execution identity."
        }
    }
    foreach ($claim in $State.claims) {
        if ($claim.issue -le 0 -or $claim.stage -notin @("reserved", "working", "validation", "blocked", "released") -or
            $claim.repairCount -lt 0 -or $claim.repairCount -gt $config.maxRepairAttempts -or
            $claim.handoffs -isnot [array] -or @($claim.handoffs).Count -eq 0 -or
            $claim.offerId -notin $State.offers.id) { throw "Invalid retained claim." }
        foreach ($handoff in $claim.handoffs) {
            Assert-Agent4Id $handoff.id
            if ($handoff.action -notin @("implement", "repair", "finalize") -or
                -not $handoff.runId -or -not $handoff.sessionId -or $handoff.stoppedEvidence -isnot [array]) {
                throw "Incomplete retained execution identity/history."
            }
            $offer = @($State.offers | Where-Object id -CEQ $claim.offerId)[0]
            if ($offer.status -cne "confirmed" -or $offer.workerId -cne $claim.workerId -or
                $claim.issue -notin $offer.candidates.issue) { throw "Claim does not match its confirmed offer." }
        }
    }
    $live = @($State.claims | Where-Object stage -NE released)
    if ($live.Count -gt 2 -or @($live.workerId | Sort-Object -Unique).Count -ne $live.Count -or
        @($live.issue | Sort-Object -Unique).Count -ne $live.Count) { throw "Two-total-in-flight capacity violated." }
    foreach ($worker in $config.workers) {
        $pending = @($State.offers | Where-Object {
            $_.workerId -ceq $worker.id -and $_.status -in @("offered", "correlated")
        })
        if ($pending.Count -gt 1 -or $pending.Count -and $worker.id -in $live.workerId) {
            throw "Overlapping offer/claim for $($worker.id)."
        }
    }
}

function Save-Agent4State($State, [string] $Directory, [long] $ExpectedRevision,
    [guid] $GateOwner, [string] $GateDirectory) {
    Assert-Agent4State $State
    if ($GateOwner -eq [guid]::Empty) { throw "An owned repository gate is required." }
    $parts = $State.configuration.repository.ToLowerInvariant().Split("/")
    $gate = Read-Agent4Json (Join-Path $GateDirectory "$($parts[0])\$($parts[1]).dispatch.json")
    if ($gate.schema -cne "fingvibe-dispatch-gate-v1" -or
        $gate.owner -cne $GateOwner.ToString() -or
        $gate.repository -cne $State.configuration.repository.ToLowerInvariant()) { throw "Repository gate mismatch." }
    $path = Join-Path $Directory "state.json"
    if ($ExpectedRevision -eq -1) {
        if ([IO.File]::Exists($path) -or $State.revision -ne 0) { throw "State is not authoritatively absent." }
    } else {
        $current = Read-Agent4Json $path
        Assert-Agent4State $current
        if ($current.revision -ne $ExpectedRevision -or $State.revision -ne $ExpectedRevision + 1 -or
            ($current.configuration | ConvertTo-Json -Depth 100 -Compress) -cne
            ($State.configuration | ConvertTo-Json -Depth 100 -Compress)) {
            throw "Stale revision or changed configuration; reassessment required."
        }
        foreach ($oldOffer in $current.offers) {
            $offer = @($State.offers | Where-Object id -CEQ $oldOffer.id)
            if ($offer.Count -ne 1 -or $offer[0].workerId -cne $oldOffer.workerId -or
                ($offer[0].candidates | ConvertTo-Json -Depth 100 -Compress) -cne
                ($oldOffer.candidates | ConvertTo-Json -Depth 100 -Compress) -or
                $oldOffer.runId -and ($offer[0].runId -cne $oldOffer.runId -or $offer[0].sessionId -cne $oldOffer.sessionId) -or
                $oldOffer.status -in @("confirmed", "declined") -and $offer[0].status -cne $oldOffer.status) {
                throw "Cannot remove/reset an offer or its execution history."
            }
        }
        foreach ($oldClaim in $current.claims) {
            $claim = @($State.claims | Where-Object id -CEQ $oldClaim.id)
            if ($claim.Count -ne 1 -or $claim[0].workerId -cne $oldClaim.workerId -or
                $claim[0].issue -ne $oldClaim.issue -or $claim[0].repairCount -lt $oldClaim.repairCount -or
                $claim[0].handoffs.Count -lt $oldClaim.handoffs.Count -or
                $oldClaim.stage -eq "released" -and $claim[0].stage -ne "released") {
                throw "Cannot remove/reset a claim, counter or released disposition."
            }
            for ($index = 0; $index -lt $oldClaim.handoffs.Count; $index++) {
                $old = $oldClaim.handoffs[$index]; $new = $claim[0].handoffs[$index]
                if ($new.id -cne $old.id -or $new.action -cne $old.action -or $new.runId -cne $old.runId -or
                    $new.sessionId -cne $old.sessionId -or
                    $old.ack -and ($new.ack | ConvertTo-Json -Depth 100 -Compress) -cne ($old.ack | ConvertTo-Json -Depth 100 -Compress) -or
                    $old.result -and ($new.result | ConvertTo-Json -Depth 100 -Compress) -cne ($old.result | ConvertTo-Json -Depth 100 -Compress)) {
                    throw "Cannot rewrite retained handoff acknowledgments/results."
                }
            }
        }
    }
    Write-Agent4Json $path $State -Replace:($ExpectedRevision -ge 0)
}

function New-Agent4Offers($State, $Packet, $HostObservations) {
    Assert-Agent4State $State
    if ($Packet.schema -cne "fingvibe-loop4-packet-v1" -or $Packet.revision -ne $State.revision -or
        $Packet.repository -cne $State.configuration.repository -or
        $Packet.epic -ne $State.configuration.epic -or $Packet.targetBranch -cne $State.configuration.targetBranch) {
        throw "Stale or mismatched work packet."
    }
    if ($Packet.candidates -isnot [array] -or @($Packet.candidates).Count -gt 4 -or
        @($Packet.candidates.issue | Sort-Object -Unique).Count -ne @($Packet.candidates).Count) {
        throw "Invalid four-candidate queue."
    }
    $next = Copy-Agent4Record $State
    $free = @()
    foreach ($worker in $next.configuration.workers) {
        $observed = @($HostObservations | Where-Object workerId -CEQ $worker.id)
        if ($observed.Count -ne 1 -or $observed[0].automationId -cne $worker.automationId -or
            $observed[0].status -notin @("idle", "stopped", "running", "unknown")) {
            throw "Incomplete host availability evidence."
        }
        Assert-Agent4Evidence $observed[0].evidence
        if ($observed[0].status -notin @("idle", "stopped") -or
            @($next.claims | Where-Object { $_.workerId -ceq $worker.id -and $_.stage -ne "released" }).Count -or
            @($next.offers | Where-Object { $_.workerId -ceq $worker.id -and $_.status -in @("offered", "correlated") }).Count) {
            continue
        }
        $free += $worker
    }
    foreach ($worker in $free) {
        $observed = @($HostObservations | Where-Object workerId -CEQ $worker.id)
        $indices = if ($free.Count -eq 1 -and $State.revision -gt 0) { @(0, 1) }
            elseif ($worker.id -ceq "developer-1") { @(0, 2) } else { @(1, 3) }
        $candidates = @($indices | Where-Object { $_ -lt $Packet.candidates.Count } | ForEach-Object { $Packet.candidates[$_] })
        if ($candidates.Count) {
            $next.offers += @{
                id = [guid]::NewGuid().ToString(); workerId = $worker.id
                status = "offered"; candidates = $candidates; createdUtc = [DateTimeOffset]::UtcNow.ToString("o")
                packetEvidence = $Packet.evidencePath; availabilityEvidence = $observed[0].evidence
                runId = $null; sessionId = $null
            }
        }
    }
    $next.revision++
    Assert-Agent4State $next
    $next
}

function Set-Agent4OfferHost($State, [string] $OfferId, [string] $RunId, [string] $SessionId, $Evidence) {
    Assert-Agent4Evidence $Evidence
    if (-not $RunId -or -not $SessionId) { throw "Actual run/session correlation is required." }
    $next = Copy-Agent4Record $State
    $offer = @($next.offers | Where-Object id -CEQ $OfferId)
    if ($offer.Count -ne 1 -or $offer[0].status -cne "offered") { throw "Offer already correlated or unknown; never relaunch." }
    $offer[0].runId = $RunId; $offer[0].sessionId = $SessionId
    $offer[0].hostEvidence = $Evidence; $offer[0].status = "correlated"
    $next.revision++
    Assert-Agent4State $next
    $next
}

function Assert-Agent4WorkerRecord($State, $Record, $ObservedActor) {
    Assert-Agent4State $State
    Assert-Agent4Id $Record.id
    Assert-Agent4Evidence $Record.evidence
    if ($Record.schema -cne "fingvibe-loop4-worker-v1" -or
        $Record.kind -notin @("response", "status", "assessment", "ack", "checkpoint", "result") -or
        $Record.workerId -cne $ObservedActor.workerId -or
        $Record.automationId -cne $ObservedActor.automationId -or
        $Record.runId -cne $ObservedActor.runId -or $Record.sessionId -cne $ObservedActor.sessionId -or
        -not $Record.runId -or -not $Record.sessionId) { throw "Worker record/observed host identity mismatch." }
    $worker = @($State.configuration.workers | Where-Object id -CEQ $Record.workerId)
    if ($worker.Count -ne 1 -or $worker[0].automationId -cne $Record.automationId) { throw "Wrong worker Automation." }
    $instant = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Record.utc, [ref] $instant) -or $Record.utc -notmatch '(Z|[+-]\d\d:\d\d)$') {
        throw "Actual timezone-qualified record time required."
    }
}

function Publish-Agent4WorkerRecord($State, $Record, $ObservedActor, [string] $Directory) {
    Assert-Agent4WorkerRecord $State $Record $ObservedActor
    if ($Record.kind -eq "response") {
        $offer = @($State.offers | Where-Object id -CEQ $Record.offerId)
        if ($offer.Count -ne 1 -or $offer[0].status -cne "correlated" -or
            $offer[0].workerId -cne $Record.workerId -or $offer[0].runId -cne $Record.runId -or
            $offer[0].sessionId -cne $Record.sessionId) { throw "Response has no correlated offer." }
    } else {
        $claim = @($State.claims | Where-Object id -CEQ $Record.claimId)
        if ($claim.Count -ne 1 -or $claim[0].stage -eq "released" -or $claim[0].workerId -cne $Record.workerId) {
            throw "Worker has no retained confirmed claim."
        }
        $handoff = $claim[0].handoffs[-1]
        if ($handoff.id -cne $Record.handoffId -or $handoff.runId -cne $Record.runId -or
            $handoff.sessionId -cne $Record.sessionId) { throw "Stale handoff context." }
        if ($Record.kind -in @("checkpoint", "result")) {
            $ack = Read-Agent4Json (Join-Path $Directory "events\$($handoff.id).ack.json")
            if ($ack.kind -cne "ack" -or $ack.claimId -cne $Record.claimId -or
                $ack.handoffId -cne $Record.handoffId) { throw "Checkpoint/result requires the immutable acknowledgment." }
        }
    }
    $name = if ($Record.kind -eq "ack") { "$($Record.handoffId).ack" } else { $Record.id }
    Assert-Agent4Id $name
    $path = Join-Path $Directory "events\$name.json"
    Write-Agent4Json $path $Record
    $path
}

function Confirm-Agent4Response($State, $Response, $ObservedActor, $FreshEvidence) {
    Assert-Agent4WorkerRecord $State $Response $ObservedActor
    Assert-Agent4Evidence $FreshEvidence
    if ($Response.kind -cne "response" -or
        $Response.assessedRevision -isnot [int] -and $Response.assessedRevision -isnot [long] -or
        $Response.assessedRevision -ne $State.revision) {
        throw "Stale assessment; ask the same Developer to reassess, not restart."
    }
    $next = Copy-Agent4Record $State
    $found = @($next.offers | Where-Object id -CEQ $Response.offerId)
    if ($found.Count -ne 1) { throw "Unknown offer." }
    $offer = $found[0]
    if ($offer.status -cne "correlated" -or $offer.workerId -cne $Response.workerId -or
        $offer.runId -cne $Response.runId -or $offer.sessionId -cne $Response.sessionId) { throw "Offer context mismatch." }
    if ($Response.decision -notin @("propose", "busy", "reject")) { throw "Invalid response decision." }
    if ($Response.decision -eq "busy") {
        if (-not $Response.currentAssignment) { throw "Busy response requires the current assignment identity." }
        throw "Busy/contradictory availability retains the pending offer for human reconciliation."
    }
    if (@($Response.evaluations).Count -ne @($offer.candidates).Count -or
        @($Response.evaluations.issue | Sort-Object -Unique).Count -ne @($offer.candidates).Count) {
        throw "Evaluate every offered candidate exactly once."
    }
    foreach ($evaluation in $Response.evaluations) {
        if ($evaluation.issue -notin $offer.candidates.issue -or $evaluation.eligible -isnot [bool] -or
            $evaluation.overlap -isnot [int] -and $evaluation.overlap -isnot [long] -or
            $evaluation.overlap -lt 0 -or -not $evaluation.reason -or
            $evaluation.reasonCode -notin @("suitable", "context", "conflict", "task-blocked", "clarification")) {
            throw "Invalid candidate evaluation."
        }
        Assert-Agent4Evidence $evaluation.evidence
    }
    $eligible = @($offer.candidates | Where-Object {
        $number = $_.issue
        @($Response.evaluations | Where-Object { $_.issue -eq $number -and $_.eligible }).Count -eq 1
    } | Sort-Object -Stable { $number = $_.issue; ($Response.evaluations | Where-Object issue -EQ $number).overlap })
    if ($Response.decision -eq "reject") {
        if ($eligible.Count) { throw "Cannot reject suitable candidates." }
        $offer.status = "declined"; $offer.response = $Response
    } else {
        if (-not $eligible.Count -or $Response.issue -ne $eligible[0].issue) { throw "Choose lower overlap, then earlier offered order." }
        if (@($next.claims | Where-Object { $_.stage -ne "released" -and
            ($_.workerId -ceq $offer.workerId -or $_.issue -eq $Response.issue) }).Count) { throw "Task or worker is occupied." }
        $id = [guid]::NewGuid().ToString()
        $next.claims += @{
            id = $id; offerId = $offer.id; issue = $Response.issue; workerId = $offer.workerId
            stage = "reserved"; repairCount = 0; evidence = $FreshEvidence; context = $null
            handoffs = @(@{ id = [guid]::NewGuid().ToString(); action = "implement"
                runId = $offer.runId; sessionId = $offer.sessionId; result = $null; stoppedEvidence = @() })
        }
        $offer.status = "confirmed"; $offer.response = $Response
    }
    $next.revision++
    Assert-Agent4State $next
    $next
}

function Set-Agent4Progress($State, $Record, $ObservedActor) {
    Assert-Agent4WorkerRecord $State $Record $ObservedActor
    $next = Copy-Agent4Record $State
    $found = @($next.claims | Where-Object id -CEQ $Record.claimId)
    if ($found.Count -ne 1 -or $found[0].stage -eq "released") { throw "Unknown/released claim." }
    $claim = $found[0]; $handoff = $claim.handoffs[-1]
    if ($Record.kind -notin @("ack", "checkpoint", "result") -or $claim.workerId -cne $Record.workerId -or
        $handoff.id -cne $Record.handoffId -or $handoff.runId -cne $Record.runId -or
        $handoff.sessionId -cne $Record.sessionId) { throw "Wrong progress context." }
    if ($Record.id -in @($handoff.ack.id, $handoff.result.id) -or $handoff.result) { throw "Duplicate/late progress; do not execute again." }
    if ($Record.kind -eq "ack") {
        if ($handoff.ack -or $claim.stage -ne "reserved") { throw "Assignment already acknowledged." }
        $handoff.ack = $Record; $claim.stage = "working"
    } else {
        if (-not $handoff.ack) { throw "Unacknowledged assignment." }
        if ($Record.kind -eq "result" -and $Record.outcome -eq "blocked" -and -not $Record.context) {
            $claim.stage = "blocked"
        } else {
            if (-not $Record.context.branch -or -not $Record.context.pr -or
                -not [IO.Path]::IsPathFullyQualified($Record.context.worktree) -or
                $Record.context.head -notmatch '^[a-fA-F0-9]{40}$') { throw "Exact task branch/worktree/PR/head required." }
            if ($claim.context -and ($claim.context.branch -cne $Record.context.branch -or
                $claim.context.worktree -cne $Record.context.worktree -or $claim.context.pr -cne $Record.context.pr)) {
                throw "Cannot replace retained task context."
            }
            $claim.context = $Record.context
        }
        if ($Record.kind -eq "result") {
            if ($Record.outcome -notin @("implementation-ready", "delivered", "blocked")) { throw "Invalid result outcome." }
            if ($Record.outcome -eq "delivered" -and ($handoff.action -ne "finalize" -or
                -not $next.configuration.authorization.merge)) { throw "Delivery requires an authorized finalizer." }
            $handoff.result = $Record
            $claim.stage = if ($Record.outcome -eq "blocked") { "blocked" } else { "validation" }
        }
    }
    $next.revision++
    Assert-Agent4State $next
    $next
}

function New-Agent4Followup($State, [string] $ClaimId, [string] $Action, [string] $RunId,
    [string] $SessionId, $StoppedEvidence, $Feedback, [string] $ExpectedHead) {
    Assert-Agent4Evidence $StoppedEvidence
    Assert-Agent4Evidence $Feedback
    if ($Action -notin @("repair", "finalize") -or -not $RunId -or -not $SessionId) { throw "Invalid follow-up." }
    $next = Copy-Agent4Record $State
    $found = @($next.claims | Where-Object id -CEQ $ClaimId)
    if ($found.Count -ne 1) { throw "Unknown claim." }
    $claim = $found[0]; $prior = $claim.handoffs[-1]
    if ($claim.stage -ne "validation" -or -not $prior.result -or
        $prior.result.outcome -ne "implementation-ready" -or -not $claim.context -or
        $claim.context.head -cne $ExpectedHead) { throw "Follow-up requires current implementation checkpoint; blocked work needs human recovery." }
    if ($Action -eq "repair") {
        if ($claim.repairCount -ge $next.configuration.maxRepairAttempts) { throw "Explicit cumulative repair allowance exhausted." }
        $claim.repairCount++
    } elseif (@($claim.handoffs | Where-Object {
        $_.action -eq "finalize" -and $_.expectedHead -ceq $ExpectedHead -and
        ($_.feedback | ConvertTo-Json -Compress) -ceq ($Feedback | ConvertTo-Json -Compress)
    }).Count) {
        throw "Unchanged finalization evidence cannot start another handoff."
    }
    $prior.stoppedEvidence = $StoppedEvidence
    $claim.handoffs += @{ id = [guid]::NewGuid().ToString(); action = $Action; runId = $RunId
        sessionId = $SessionId; expectedHead = $ExpectedHead; feedback = $Feedback
        repairAttempt = $claim.repairCount; result = $null; stoppedEvidence = @() }
    $claim.stage = "reserved"; $next.revision++
    Assert-Agent4State $next
    $next
}

function Release-Agent4Claim($State, [string] $ClaimId, $StoppedEvidence, $DeliveryEvidence, $CleanupEvidence) {
    Assert-Agent4Evidence $StoppedEvidence
    Assert-Agent4Evidence $DeliveryEvidence
    Assert-Agent4Evidence $CleanupEvidence
    $next = Copy-Agent4Record $State
    $found = @($next.claims | Where-Object id -CEQ $ClaimId)
    if ($found.Count -ne 1 -or $found[0].stage -eq "released" -or
        $found[0].handoffs[-1].result.outcome -cne "delivered") { throw "Only delivered work can be released." }
    $found[0].stage = "released"
    $found[0].release = @{ stopped = $StoppedEvidence; delivery = $DeliveryEvidence; cleanup = $CleanupEvidence }
    $next.revision++
    Assert-Agent4State $next
    $next
}

Export-ModuleMember -Function *-Agent4*
