$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\.github\scripts\Get-Agent4AssignmentPlan.ps1")
function Assert-True($Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Fails([scriptblock] $Action, [string] $Pattern) {
    try { & $Action | Out-Null }
    catch { if ($_.Exception.Message -notlike $Pattern) { throw }; return }
    throw "Expected failure matching $Pattern."
}
function New-Request {
    @{
        schema = "fingvibe-loop4-allocation-input-v1"
        packet = @{
            schema = "fingvibe-loop4-packet-v1"; repository = "TestOwner/TestRepo"; epic = 92
            candidates = @(@{ issue = 101; category = "success" }, @{ issue = 102; category = "new" }, @{ issue = 103; category = "new" })
            developerOffers = @(
                @{ developer = "developer-1"; candidates = @(@{ issue = 101 }, @{ issue = 102 }) }
                @{ developer = "developer-2"; candidates = @(@{ issue = 101 }, @{ issue = 103 }) }
            )
            openAssignments = @()
        }
        offers = @(
            @{ developer = "developer-1"; offerId = "offer-1"; recipientId = "session-1"; candidates = @(101, 102) }
            @{ developer = "developer-2"; offerId = "offer-2"; recipientId = "session-2"; candidates = @(101, 103) }
        )
        responses = @(
            @{ developer = "developer-1"; offerId = "offer-1"; recipientId = "session-1"; status = "available"
                evaluations = @(@{ issue = 101; eligible = $true; reason = "Verified head and scope." },
                    @{ issue = 102; eligible = $true; reason = "Independent scope." }); preferred = @(101, 102) }
            @{ developer = "developer-2"; offerId = "offer-2"; recipientId = "session-2"; status = "available"
                evaluations = @(@{ issue = 101; eligible = $true; reason = "Verified head and scope." },
                    @{ issue = 103; eligible = $false; reason = "Missing prerequisite." }); preferred = @(101) }
        )
        compatibility = @(
            @{ issues = @(101, 102); compatible = $true; reason = "Reviewed diffs and contracts; independent." }
            @{ issues = @(101, 103); compatible = $true; reason = "Reviewed scopes; independent." }
            @{ issues = @(102, 103); compatible = $true; reason = "Reviewed scopes; independent." }
        )
        existingWork = @(); sentStarts = @(); releasedAssignments = @()
    }
}
function Get-Mapping($Plan) {
    (@($Plan.proposedStarts | ForEach-Object { "$($_.developer):$($_.issue):$($_.action)" }) -join ",")
}
function New-FollowUpRequest($Previous, $Fresh) {
    $next = New-Request
    $next.packet = Get-Agent4FollowUpPacket $Previous $Fresh
    $next.responses = @()
    $next.existingWork = @($Previous.existingWork)
    $next.sentStarts = @($Previous.sentStarts)
    $next.compatibility = @()
    foreach ($index in 0,1) {
        $next.offers[$index].offerId = "follow-$index"
        $next.offers[$index].candidates = @($next.packet.developerOffers[$index].candidates | ForEach-Object issue)
    }
    $next
}

$request = New-Request
$before = $request | ConvertTo-Json -Depth 100 -Compress
$plan = Get-Agent4AssignmentPlan $request
Assert-True ((Get-Mapping $plan) -eq "developer-1:102:implement,developer-2:101:finalize") "Fill both slots instead of giving shared A to Developer 1."
Assert-True (($request | ConvertTo-Json -Depth 100 -Compress) -ceq $before) "Planning must not mutate its input."
Assert-True ($plan.schema -eq "fingvibe-loop4-allocation-plan-v1" -and $plan.decisions.Count -eq 2) "Return explicit plan schema and both decisions."
$request.responses = @($request.responses[1], $request.responses[0])
Assert-True ((Get-Mapping (Get-Agent4AssignmentPlan $request)) -eq (Get-Mapping $plan)) "Response array order cannot change allocation."

$request = New-Request
$request.responses[1].evaluations[1].eligible = $true
$request.responses[1].preferred = @(103, 101)
$plan = Get-Agent4AssignmentPlan $request
Assert-True ((Get-Mapping $plan) -eq "developer-1:102:implement,developer-2:101:finalize") "Packet priority wins before preferences: choose A/B, not A/C."
$request.compatibility[0].compatible = $false
$request.compatibility[1].compatible = $false
Assert-True ((Get-Mapping (Get-Agent4AssignmentPlan $request)) -eq "developer-1:102:implement,developer-2:103:implement") "Two compatible lower-priority tasks beat a singleton highest-priority task."

# Identical candidate sets exercise preferences and the final Developer 1 tie-break.
$request = New-Request
$request.packet.developerOffers[1].candidates = $request.packet.developerOffers[0].candidates
$request.offers[1].candidates = @(101, 102)
$request.responses[1].evaluations[1] = @{ issue = 102; eligible = $true; reason = "Independent." }
$request.responses[1].preferred = @(101, 102)
Assert-True ((Get-Mapping (Get-Agent4AssignmentPlan $request)) -eq "developer-1:101:finalize,developer-2:102:implement") "Equal solutions give Developer 1 the higher-priority shared task."
$request.responses[0].preferred = @(102, 101)
Assert-True ((Get-Mapping (Get-Agent4AssignmentPlan $request)) -eq "developer-1:102:implement,developer-2:101:finalize") "Preferences win before Developer 1 precedence."

$request = New-Request
$request.compatibility[0].compatible = $false
$request.compatibility[0].reason = "Shared contract changes."
$plan = Get-Agent4AssignmentPlan $request
Assert-True ((Get-Mapping $plan) -eq "developer-1:101:finalize") "Incompatible accepted tasks cannot start together."
Assert-True ("Shared contract changes." -in $plan.decisions[1].deferred.reasons) "Explain incompatible pair."
$request.compatibility = @()
$plan = Get-Agent4AssignmentPlan $request
Assert-True ($plan.proposedStarts.Count -eq 2) "Missing compatibility evidence is not a conflict."

$request = New-Request
$request.responses = @($request.responses[0])
$plan = Get-Agent4AssignmentPlan $request
Assert-True ((Get-Mapping $plan) -eq "developer-1:101:finalize" -and $plan.decisions[1].status -eq "pending") "Independent shared start is safe when all other unresolved work is compatible."
$request.compatibility = @()
Assert-True ((Get-Agent4AssignmentPlan $request).proposedStarts.Count -eq 1) "A missing response does not veto the independent accepted start."
$request = New-Request
$request.responses = @($request.responses[1])
Assert-True ((Get-Mapping (Get-Agent4AssignmentPlan $request)) -eq "developer-2:101:finalize") "No fixed Developer 1 precedence before its reply."

$request = New-Request
$request.sentStarts = @(@{ assignmentId = "sent-1"; developer = "developer-1"; offerId = "offer-1"; issue = 101 })
$plan = Get-Agent4AssignmentPlan $request
Assert-True ($plan.proposedStarts.Count -eq 0 -and $plan.retainedStarts.Count -eq 1 -and $plan.decisions[0].status -eq "retained") "Uncertain sent A is not reshuffled to B or duplicated for Developer 2."
$request.responses[1].evaluations[1].eligible = $true
$request.responses[1].preferred = @(101, 103)
Assert-True ((Get-Mapping (Get-Agent4AssignmentPlan $request)) -eq "developer-2:103:implement") "A late response can start a compatible alternative beside a retained start."
$request.compatibility = @()
Assert-True ((Get-Agent4AssignmentPlan $request).proposedStarts.Count -eq 1) "Unknown compatibility with distinct sent work is non-blocking."

$request = New-Request
$work = @{ assignmentId = "old-1"; developer = "developer-1"; issue = 110 }
$request.existingWork = @($work)
$request.packet.openAssignments = @($work)
$request.responses[0] = @{ developer = "developer-1"; offerId = "offer-1"; recipientId = "session-1"; status = "busy"; assignmentId = "old-1"; reason = "Executing old-1." }
Assert-True ((Get-Agent4AssignmentPlan $request).proposedStarts.Count -eq 1) "Held work blocks its owner, not independent accepted work."
$request.compatibility += @{ issues = @(101, 110); compatible = $true; reason = "Reviewed existing work." }
Assert-True ((Get-Mapping (Get-Agent4AssignmentPlan $request)) -eq "developer-2:101:finalize") "Busy Developer does not block verified independent work."
$request.responses[0] = (New-Request).responses[0]
Assert-True ((Get-Agent4AssignmentPlan $request).decisions[0].status -eq "held") "An available reply does not silently release retained work."
$request.existingWork = @()
Assert-Fails { Get-Agent4AssignmentPlan $request } "*Packet open assignments must remain*"
$request.releasedAssignments = @(@{ assignmentId = "old-1"; reason = "Developer confirmed stopped; release marker and claim release read back." })
Assert-True ((Get-Mapping (Get-Agent4AssignmentPlan $request)) -eq "developer-1:102:implement,developer-2:101:finalize") "Verified crash release permits the Developer to take other offered work this cycle."
$request.existingWork = @($work)
Assert-Fails { Get-Agent4AssignmentPlan $request } "*Released work cannot also be held*"

$request = New-Request
foreach ($response in $request.responses) {
    foreach ($evaluation in $response.evaluations) { $evaluation.eligible = $false }
    $response.preferred = @()
}
$plan = Get-Agent4AssignmentPlan $request
Assert-True ($plan.proposedStarts.Count -eq 0 -and $plan.proposedReruns.Count -eq 0) "Ordinary rejection means no starts or reruns."
$request = New-Request
$request.responses = @()
Assert-True ((Get-Agent4AssignmentPlan $request).decisions.status -join "," -eq "pending,pending") "No responses leaves both pending."
$request = New-Request
$request.packet.candidates = @()
$request.compatibility = @()
foreach ($offer in $request.packet.developerOffers) { $offer.candidates = @() }
foreach ($offer in $request.offers) { $offer.candidates = @() }
foreach ($response in $request.responses) { $response.evaluations = @(); $response.preferred = @() }
Assert-True ((Get-Agent4AssignmentPlan $request).proposedStarts.Count -eq 0) "Empty offers never transfer work."

foreach ($case in @(
    @{ change = { $args[0].schema = "wrong" }; pattern = "*Unsupported schema*" }
    @{ change = { $args[0].packet.candidates[0].category = @("success", "failed") }; pattern = "*candidate category must be a nonempty string*" }
    @{ isolated = $true; change = { $args[0].responses[0].offerId = @("offer-1", "other") }; pattern = "*response offerId must be a nonempty string*" }
    @{ change = { $args[0].offers[0].candidates = @(102, 101) }; pattern = "*exact ordered candidate list*" }
    @{ isolated = $true; change = { $args[0].responses[0].offerId = "stale" }; pattern = "*correlation mismatch*" }
    @{ isolated = $true; change = { $args[0].responses[0].recipientId = "foreign" }; pattern = "*correlation mismatch*" }
    @{ change = { $args[0].responses += $args[0].responses[0] }; pattern = "*Duplicate or unknown response*" }
    @{ isolated = $true; change = { $args[0].responses[0].preferred = @(103) }; pattern = "*preferred must order exactly*" }
    @{ isolated = $true; change = { $args[0].responses[0].evaluations = @() }; pattern = "*Every offered candidate*" }
    @{ isolated = $true; change = { $args[0].responses[0].evaluations[0].eligible = "true" }; pattern = "*eligible must be Boolean*" }
    @{ change = { $args[0].releasedAssignments = @(@{ assignmentId = "invented"; reason = "Not in packet." }) }; pattern = "*unique packet open assignment*" }
    @{ change = { $args[0].compatibility[0].compatible = "true" }; pattern = "*compatible must be Boolean*" }
    @{ change = { $args[0].compatibility += @{ issues = @(102, 101); compatible = $false; reason = "Contradiction." } }; pattern = "*Duplicate or contradictory compatibility*" }
    @{ change = { $args[0].offers[0].candidates = @("101", 102) }; pattern = "*positive integers*" }
    @{ isolated = $true; change = { $args[0].responses[0] = @{ developer = "developer-1"; offerId = "offer-1"; recipientId = "session-1"; status = "busy"; assignmentId = "unknown"; reason = "Executing unknown." } }; pattern = "*Busy assignment must be included*" }
    @{ change = { $args[0].sentStarts = @(@{ assignmentId = "x"; developer = "developer-1"; issue = 103; offerId = "offer-1" }) }; pattern = "*Sent start does not match*" }
)) {
    $request = New-Request
    & $case.change $request
    if ($case.isolated) {
        $plan = Get-Agent4AssignmentPlan $request
        Assert-True ($plan.responseErrors.Count -eq 1 -and $plan.responseErrors[0].reason -like $case.pattern -and
            (Get-Mapping $plan) -eq "developer-2:101:finalize" -and $plan.decisions[0].status -eq "pending") "Malformed response is explicit and unresolved; valid independent work progresses."
    } else { Assert-Fails { Get-Agent4AssignmentPlan $request } $case.pattern }
}

function Add-RerunRecommendation($Request, [int] $Developer = 0) {
    $Request.packet.candidates[0].category = "failed"
    $Request.packet.candidates[0].pr = @{ number = 201; head = @{ sha = "a" * 40 }; mergeable = $true }
    $evaluation = $Request.responses[$Developer].evaluations[0]
    $evaluation.eligible = $false
    $evaluation.recommendedAction = "rerun-failed-checks"
    $evaluation.rerun = @{ head = "a" * 40; runId = 301; runAttempt = 1 }
    $Request.responses[$Developer].preferred = @($Request.responses[$Developer].preferred | Where-Object { $_ -ne 101 })
}
$request = New-Request
Add-RerunRecommendation $request
Add-RerunRecommendation $request 1
$plan = Get-Agent4AssignmentPlan $request
Assert-True ((Get-Mapping $plan) -eq "developer-1:102:implement" -and $plan.proposedReruns.Count -eq 1) "Rejected rerun candidates stay out of Developer starts; compatible other work still starts."
Assert-True ($plan.proposedReruns[0].recommendations.Count -eq 2) "Both Developer recommendations become one rerun proposal."
$request.compatibility = @()
Assert-True ((Get-Agent4AssignmentPlan $request).proposedReruns.Count -eq 1) "Unrelated compatibility uncertainty cannot veto an authorized rerun."
$request.responses = @($request.responses[0])
$plan = Get-Agent4AssignmentPlan $request
Assert-True ($plan.proposedReruns.Count -eq 0 -and $plan.deferredReruns.Count -eq 1) "A missing shared assessment cannot race a rerun against code repair."
$request = New-Request
Add-RerunRecommendation $request
Assert-True ((Get-Agent4AssignmentPlan $request).proposedReruns.Count -eq 0) "Another Developer accepting repair prevents a rerun."
$request = New-Request
Add-RerunRecommendation $request
Add-RerunRecommendation $request 1
$request.compatibility[0].compatible = $false
Assert-True ((Get-Agent4AssignmentPlan $request).proposedReruns.Count -eq 0) "Reruns need compatibility with selected code work."
$request.existingWork = @(@{ issue = 101; developer = "foreign"; assignmentId = "held" })
Assert-True ((Get-Agent4AssignmentPlan $request).proposedReruns.Count -eq 0) "Held work blocks a same-task rerun."
foreach ($case in @(
    @{ change = { $args[0].responses[0].evaluations[0].eligible = $true }; pattern = "*requires a rejected candidate*" }
    @{ change = { $args[0].responses[0].evaluations[0].recommendedAction = "retry" }; pattern = "*requires a rejected candidate*" }
    @{ change = { $args[0].responses[0].evaluations[0].rerun.head = "b" * 40 }; pattern = "*head must match*" }
    @{ change = { $args[0].responses[0].evaluations[0].rerun.runAttempt = 0 }; pattern = "*positive integers*" }
    @{ change = { $args[0].responses[0].evaluations[0].Remove("recommendedAction") }; pattern = "*requires recommendedAction*" }
    @{ change = { $args[0].packet.candidates[0].pr.mergeable = $false }; pattern = "*without a conflict*" }
    @{ change = { $args[0].packet.candidates[0].finalizeRejection = @{ head = "a" * 40 } }; pattern = "*without a conflict*" }
    @{ change = { $args[0].responses[1].evaluations[0].rerun.runId = 302 }; pattern = "*Contradictory rerun*" }
)) {
    $request = New-Request
    Add-RerunRecommendation $request
    Add-RerunRecommendation $request 1
    & $case.change $request
    if ($case.pattern -like "*Contradictory rerun*") {
        Assert-Fails { Get-Agent4AssignmentPlan $request } $case.pattern
    } else {
        $plan = Get-Agent4AssignmentPlan $request
        Assert-True (@($plan.responseErrors | Where-Object reason -Like $case.pattern).Count -gt 0) "Invalid rerun evidence is rejected explicitly, not synthesized."
    }
}

$request = New-Request
$request.compatibility = @()
$request.packet.candidates[1].category = "diagnose"
$plan = Get-Agent4AssignmentPlan $request
Assert-True ((Get-Mapping $plan) -eq "developer-1:102:diagnose,developer-2:101:finalize") "Diagnostic acceptance authorizes diagnosis only, not repair/finalize."

# Reproduce the reported disjoint offers, including an alternative conflicting preferred task.
$request = New-Request
$request.packet.candidates = @(@{ issue = 298; category = "failed" }, @{ issue = 344; category = "new" },
    @{ issue = 384; category = "new" }, @{ issue = 497; category = "new" })
foreach ($index in 0,1) {
    $issues = if ($index -eq 0) { @(298,384) } else { @(344,497) }
    $request.packet.developerOffers[$index].candidates = @($issues | ForEach-Object { @{ issue = $_ } })
    $request.offers[$index].candidates = $issues
    $request.responses[$index].evaluations = @($issues | ForEach-Object { @{ issue = $_; eligible = ($_ -ne 344); reason = "Assessed scope." } })
    $request.responses[$index].preferred = @($issues | Where-Object { $_ -ne 344 })
}
$request.compatibility = @()
Assert-True ((Get-Mapping (Get-Agent4AssignmentPlan $request)) -eq "developer-1:298:repair,developer-2:497:implement") "Reported case fills both slots with unknown compatibility."
$request.compatibility = @(@{ issues = @(298,497); compatible = $false; reason = "Concrete conflicting contract edits." })
Assert-True ((Get-Mapping (Get-Agent4AssignmentPlan $request)) -eq "developer-1:384:implement,developer-2:497:implement") "Concrete preferred-pair conflict selects the accepted alternative."

$request = New-Request
foreach ($response in $request.responses) {
    foreach ($evaluation in $response.evaluations) { $evaluation.eligible = $false }
    $response.preferred = @()
}
$fresh = ($request.packet | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable)
$fresh.candidates += @(@{ issue = 104; category = "new" }, @{ issue = 105; category = "new" })
$next = Get-Agent4FollowUpPacket $request $fresh
Assert-True (($next.developerOffers[0].candidates.issue -join ",") -eq "103,104" -and
    ($next.developerOffers[1].candidates.issue -join ",") -eq "102,105") "Follow-up deterministically refills from resolved alternatives and later queue entries, without repeating rejected pairs."
$follow = New-Request
$follow.packet = $next
foreach ($index in 0,1) {
    $follow.offers[$index].offerId = "follow-$index"
    $follow.offers[$index].candidates = @($next.developerOffers[$index].candidates.issue)
    $follow.responses[$index].offerId = "follow-$index"
    $follow.responses[$index].evaluations = @($follow.offers[$index].candidates | ForEach-Object { @{ issue = $_; eligible = $true; reason = "Fresh follow-up assessment." } })
    $follow.responses[$index].preferred = @($follow.offers[$index].candidates)
}
Assert-True ((Get-Agent4AssignmentPlan $follow).proposedStarts.Count -eq 2) "Fresh correlated follow-up assessments can start work."
Assert-Fails { Get-Agent4FollowUpPacket $follow $fresh } "*Only one follow-up*"
$follow.packet.developerOffers[0].candidates = @(@{ issue = 105 })
Assert-Fails { Get-Agent4AssignmentPlan $follow } "*deterministic selection*"
$request.responses = @($request.responses[0])
$next = Get-Agent4FollowUpPacket $request $fresh
Assert-True (($next.developerOffers[0].candidates.issue -join ",") -eq "104,105" -and
    $next.developerOffers[1].candidates.Count -eq 0) "Unanswered offers remain held, not redistributed or assumed idle."
$request = New-Request
$request.sentStarts = @(@{ assignmentId = "sent"; developer = "developer-2"; issue = 101; offerId = "offer-2" })
Assert-Fails { Get-Agent4FollowUpPacket $request $request.packet } "*Handle proposed starts*"
$request.startFailures = @(@{ developer = "developer-1"; issue = 102; reason = "Fresh preparation failed before Sending; task remains unstarted." })
$fresh = $request.packet.Clone()
$fresh.candidates += @{ issue = 110; category = "resume" }
$next = Get-Agent4FollowUpPacket $request $fresh
Assert-True (($next.developerOffers[0].candidates.issue -join ",") -eq "103,110" -and
    $next.developerOffers[1].candidates.Count -eq 0) "Pre-send failure can refill the idle slot while the other start stays fixed."

# Verified crash release feeds a refreshed packet and the same bounded follow-up path.
$request = New-Request
$work = @{ assignmentId = "crashed"; developer = "developer-1"; issue = 110 }
$request.packet.openAssignments = @($work)
$request.releasedAssignments = @(@{ assignmentId = "crashed"; reason = "Stopped reply, release marker and claim release verified." })
foreach ($response in $request.responses) {
    foreach ($evaluation in $response.evaluations) { $evaluation.eligible = $false }
    $response.preferred = @()
}
$fresh = $request.packet.Clone()
$fresh.openAssignments = @()
$fresh.candidates = @(@{ issue = 110; category = "resume"; released = $work })
$next = Get-Agent4FollowUpPacket $request $fresh
Assert-True (($next.developerOffers[0].candidates.issue -join ",") -eq "110") "Verified release can be reoffered in the same cycle from a fresh packet."
$follow = New-FollowUpRequest $request $fresh
$follow.responses = @(@{ developer = "developer-1"; offerId = "follow-0"; recipientId = "session-1"; status = "available"
    evaluations = @(@{ issue = 110; eligible = $true; reason = "Freshly assessed released PR/head." }); preferred = @(110) })
Assert-True ((Get-Mapping (Get-Agent4AssignmentPlan $follow)) -eq "developer-1:110:implement") "A verified release progresses only after fresh correlated follow-up acceptance."

$fresh.candidates += @{ issue = 111; category = "new" }
$next = Get-Agent4FollowUpPacket $request $fresh
Assert-True (($next.developerOffers[0].candidates.issue -join ",") -eq "110" -and
    ($next.developerOffers[1].candidates.issue -join ",") -eq "111") "Two queued alternatives fill two recipients instead of both being consumed by the first offer."
$request.responses[0].preferred = @(101,102)
foreach ($evaluation in $request.responses[0].evaluations) { $evaluation.eligible = $true }
$request.sentStarts = @(@{ assignmentId = "fixed"; developer = "developer-1"; issue = 101; offerId = "offer-1" })
$follow = New-FollowUpRequest $request $fresh
$follow.responses = @(@{ developer = "developer-2"; offerId = "follow-1"; recipientId = "session-2"; status = "available"
    evaluations = @(@{ issue = 110; eligible = $true; reason = "Freshly assessed." }, @{ issue = 111; eligible = $true; reason = "Freshly assessed." })
    preferred = @(110,111) })
Assert-True ((Get-Mapping (Get-Agent4AssignmentPlan $follow)) -eq "developer-2:110:implement") "Follow-up preserves prior start identity while filling the other Developer."
$follow.sentStarts = @()
Assert-Fails { Get-Agent4AssignmentPlan $follow } "*retain every prior sent start*"
$follow = New-FollowUpRequest $request $fresh
$follow.offers[1].recipientId = "replacement-session"
Assert-Fails { Get-Agent4AssignmentPlan $follow } "*same recipients and fresh offer IDs*"

$request = New-Request
foreach ($response in $request.responses) {
    foreach ($evaluation in $response.evaluations) { $evaluation.eligible = $false }
    $response.preferred = @()
}
$work = @{ assignmentId = "busy"; developer = "developer-1"; issue = 120 }
$request.existingWork = @($work)
$request.responses[0] = @{ developer = "developer-1"; offerId = "offer-1"; recipientId = "session-1"
    status = "busy"; assignmentId = "busy"; reason = "Executing retained work." }
$fresh = $request.packet.Clone()
$fresh.candidates += @{ issue = 110; category = "new" }
$follow = New-FollowUpRequest $request $fresh
Assert-True ($follow.packet.developerOffers[0].candidates.Count -eq 0 -and
    ($follow.packet.developerOffers[1].candidates.issue -join ",") -eq "102,110") "Busy recipient stays held; its resolved unstarted offers may reach the available recipient."
$follow.existingWork = @()
Assert-Fails { Get-Agent4AssignmentPlan $follow } "*retain existing work*"

# Round-trip the actual CLI JSON boundary, not just the dot-sourced function.
$path = Join-Path ([IO.Path]::GetTempPath()) ("fingvibe-allocation-" + [guid]::NewGuid() + ".json")
$packetPath = "$path.packet"
try {
    $script = Join-Path $PSScriptRoot "..\.github\scripts\Get-Agent4AssignmentPlan.ps1"
    '{"schema":"unsupported"}' | Set-Content -LiteralPath $path
    $failure = & pwsh -NoProfile -File $script -InputPath $path 2>&1
    Assert-True ($LASTEXITCODE -ne 0 -and ($failure -join "`n") -like "*Unsupported schema*") "Invalid CLI input must exit unsuccessfully with an explicit error."
    New-Request | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $path
    $json = & pwsh -NoProfile -File $script -InputPath $path
    Assert-True ($LASTEXITCODE -eq 0) "Valid CLI request must exit successfully."
    $plan = $json | ConvertFrom-Json -AsHashtable
    Assert-True ((Get-Mapping $plan) -eq "developer-1:102:implement,developer-2:101:finalize") "CLI accepts JSON and emits the same deterministic plan."
    $previous = New-Request
    foreach ($response in $previous.responses) {
        foreach ($evaluation in $response.evaluations) { $evaluation.eligible = $false }
        $response.preferred = @()
    }
    $fresh = $previous.packet.Clone()
    $fresh.candidates += @(@{ issue = 110; category = "new" }, @{ issue = 111; category = "new" })
    $previous | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $path
    $fresh | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $packetPath
    $json = & pwsh -NoProfile -File $script -InputPath $path -FollowUpPacketPath $packetPath
    Assert-True ($LASTEXITCODE -eq 0) "Follow-up CLI accepts a fresh packet and emits JSON."
    $packet = $json | ConvertFrom-Json -AsHashtable
    $follow = New-FollowUpRequest $previous $fresh
    Assert-True ($packet.followUpOf.schema -ceq "fingvibe-loop4-allocation-input-v1" -and
        $packet.developerOffers[0].candidates -is [array] -and
        ($packet.developerOffers[0].candidates.issue -join ",") -eq ($follow.packet.developerOffers[0].candidates.issue -join ",")) "Follow-up JSON preserves provenance, array shapes and deterministic offers."
} finally {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    if (Test-Path -LiteralPath $packetPath) { Remove-Item -LiteralPath $packetPath }
}
Write-Output "Agent4 assignment planner checks passed."
