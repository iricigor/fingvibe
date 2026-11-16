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
Assert-True ($plan.proposedStarts.Count -eq 1 -and ($plan.decisions.deferred.reasons -join " ") -like "*Compatibility unknown*") "Unknown compatibility never implies safety."

$request = New-Request
$request.responses = @($request.responses[0])
$plan = Get-Agent4AssignmentPlan $request
Assert-True ((Get-Mapping $plan) -eq "developer-1:101:finalize" -and $plan.decisions[1].status -eq "pending") "Independent shared start is safe when all other unresolved work is compatible."
$request.compatibility = @()
Assert-True ((Get-Agent4AssignmentPlan $request).proposedStarts.Count -eq 0) "Missing response retains its other potentially starting candidates."
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
Assert-True ((Get-Agent4AssignmentPlan $request).proposedStarts.Count -eq 0) "A late response must recheck compatibility with sent work."

$request = New-Request
$work = @{ assignmentId = "old-1"; developer = "developer-1"; issue = 110 }
$request.existingWork = @($work)
$request.packet.openAssignments = @($work)
$request.responses[0] = @{ developer = "developer-1"; offerId = "offer-1"; recipientId = "session-1"; status = "busy"; assignmentId = "old-1"; reason = "Executing old-1." }
Assert-True ((Get-Agent4AssignmentPlan $request).proposedStarts.Count -eq 0) "Held work blocks its Developer and requires compatibility for the other."
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
    @{ change = { $args[0].responses[0].offerId = @("offer-1", "other") }; pattern = "*response offerId must be a nonempty string*" }
    @{ change = { $args[0].offers[0].candidates = @(102, 101) }; pattern = "*exact ordered candidate list*" }
    @{ change = { $args[0].responses[0].offerId = "stale" }; pattern = "*correlation mismatch*" }
    @{ change = { $args[0].responses[0].recipientId = "foreign" }; pattern = "*correlation mismatch*" }
    @{ change = { $args[0].responses += $args[0].responses[0] }; pattern = "*Duplicate or unknown response*" }
    @{ change = { $args[0].responses[0].preferred = @(103) }; pattern = "*preferred must order exactly*" }
    @{ change = { $args[0].responses[0].evaluations = @() }; pattern = "*Every offered candidate*" }
    @{ change = { $args[0].responses[0].evaluations[0].eligible = "true" }; pattern = "*eligible must be Boolean*" }
    @{ change = { $args[0].releasedAssignments = @(@{ assignmentId = "invented"; reason = "Not in packet." }) }; pattern = "*unique packet open assignment*" }
    @{ change = { $args[0].compatibility[0].compatible = "true" }; pattern = "*compatible must be Boolean*" }
    @{ change = { $args[0].compatibility += @{ issues = @(102, 101); compatible = $false; reason = "Contradiction." } }; pattern = "*Duplicate or contradictory compatibility*" }
    @{ change = { $args[0].offers[0].candidates = @("101", 102) }; pattern = "*positive integers*" }
    @{ change = { $args[0].responses[0] = @{ developer = "developer-1"; offerId = "offer-1"; recipientId = "session-1"; status = "busy"; assignmentId = "unknown"; reason = "Executing unknown." } }; pattern = "*Busy assignment must be included*" }
    @{ change = { $args[0].sentStarts = @(@{ assignmentId = "x"; developer = "developer-1"; issue = 103; offerId = "offer-1" }) }; pattern = "*Sent start does not match*" }
)) {
    $request = New-Request
    & $case.change $request
    Assert-Fails { Get-Agent4AssignmentPlan $request } $case.pattern
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
    Assert-Fails { Get-Agent4AssignmentPlan $request } $case.pattern
}

# Round-trip the actual CLI JSON boundary, not just the dot-sourced function.
$path = Join-Path ([IO.Path]::GetTempPath()) ("fingvibe-allocation-" + [guid]::NewGuid() + ".json")
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
} finally {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
}
Write-Output "Agent4 assignment planner checks passed."
