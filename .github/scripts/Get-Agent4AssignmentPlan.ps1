[CmdletBinding()]
param([string] $InputPath)

$ErrorActionPreference = "Stop"

function Get-Agent4AssignmentPlan([System.Collections.IDictionary] $Request) {
    function Require($Condition, [string] $Message) {
        if (-not $Condition) { throw "Invalid assignment input: $Message" }
    }
    function Require-Object($Value, [string] $Name) {
        Require ($Value -is [System.Collections.IDictionary]) "$Name must be an object."
    }
    function Require-Array($Value, [string] $Name) {
        Require ($Value -is [array]) "$Name must be an array."
    }
    function Require-Text($Value, [string] $Name) {
        Require ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value)) "$Name must be a nonempty string."
    }
    function Require-Issue($Value) {
        Require (($Value -is [int] -or $Value -is [long]) -and $Value -gt 0) "Issue numbers must be positive integers."
    }
    function Pair-Key($First, $Second) {
        (@([long] $First, [long] $Second) | Sort-Object) -join ":"
    }

    Require-Text $Request.schema "schema"
    Require ($Request.schema -ceq "fingvibe-loop4-allocation-input-v1") "Unsupported schema."
    $packet = $Request.packet
    Require-Object $packet "packet"
    Require-Text $packet.schema "packet.schema"
    Require ($packet.schema -ceq "fingvibe-loop4-packet-v1") "Unsupported packet schema."
    Require-Text $packet.repository "packet.repository"
    Require-Issue $packet.epic
    foreach ($field in @("candidates", "developerOffers", "openAssignments")) { Require-Array $packet[$field] "packet.$field" }
    foreach ($field in @("offers", "responses", "existingWork", "sentStarts", "releasedAssignments", "compatibility")) {
        Require-Array $Request[$field] $field
    }

    $developers = @("developer-1", "developer-2")
    $candidates = @{}; $ranks = @{}
    foreach ($candidate in $packet.candidates) {
        Require-Object $candidate "candidate"
        Require-Issue $candidate.issue
        $key = "$($candidate.issue)"
        Require (-not $candidates.ContainsKey($key)) "Duplicate candidate #$key."
        Require-Text $candidate.category "candidate category"
        Require ($candidate.category -cin @("success", "failed", "resume", "new")) "Unknown category for #$key."
        $ranks[$key] = $candidates.Count
        $candidates[$key] = $candidate
    }
    $baseOffers = @{}
    foreach ($offer in $packet.developerOffers) {
        Require-Object $offer "packet developer offer"
        Require-Text $offer.developer "packet offer developer"
        Require ($offer.developer -cin $developers -and -not $baseOffers.ContainsKey($offer.developer)) "Duplicate or unknown packet Developer."
        Require-Array $offer.candidates "packet offer candidates"
        Require ($offer.candidates.Count -le 2) "At most two candidates per Developer."
        $issues = @(foreach ($candidate in $offer.candidates) {
            Require-Object $candidate "packet offered candidate"
            Require-Issue $candidate.issue
            Require ($candidates.ContainsKey("$($candidate.issue)")) "Packet offers an unknown candidate."
            $candidate.issue
        })
        Require (@($issues | Select-Object -Unique).Count -eq $issues.Count) "Duplicate packet offered issue."
        $baseOffers[$offer.developer] = $issues
    }
    Require ($baseOffers.Count -eq 2) "Both packet Developer offers are required."

    $offers = @{}; $offerIds = @{}
    foreach ($offer in $Request.offers) {
        Require-Object $offer "offer"
        Require-Text $offer.developer "offer developer"
        Require ($offer.developer -cin $developers -and -not $offers.ContainsKey($offer.developer)) "Duplicate or unknown offer Developer."
        Require-Text $offer.offerId "offerId"
        Require-Text $offer.recipientId "recipientId"
        Require (-not $offerIds.ContainsKey($offer.offerId)) "Duplicate offerId."
        Require-Array $offer.candidates "offer candidates"
        foreach ($issue in $offer.candidates) { Require-Issue $issue }
        Require (($offer.candidates -join ",") -ceq ($baseOffers[$offer.developer] -join ",")) "Offer must match the packet's exact ordered candidate list."
        $offers[$offer.developer] = $offer
        $offerIds[$offer.offerId] = $true
    }
    Require ($offers.Count -eq 2) "Both correlated offers are required."
    Require ($offers["developer-1"].recipientId -cne $offers["developer-2"].recipientId) "Developer recipients must be distinct."

    $held = @(); $starts = @{}; $assignments = @{}
    foreach ($field in @("existingWork", "sentStarts")) {
        $seen = @{}
        foreach ($work in $Request[$field]) {
            Require-Object $work $field
            Require-Issue $work.issue
            Require-Text $work.assignmentId "assignmentId"
            Require-Text $work.developer "work developer"
            Require (-not $seen.ContainsKey($work.assignmentId)) "Duplicate assignment in $field."
            $seen[$work.assignmentId] = $true
            if ($assignments.ContainsKey($work.assignmentId)) {
                $prior = $assignments[$work.assignmentId]
                Require ($prior.issue -eq $work.issue -and $prior.developer -ceq $work.developer) "Contradictory assignment identity."
            }
            $assignments[$work.assignmentId] = $work
            if ($field -eq "sentStarts") {
                Require ($work.developer -cin $developers) "Unknown sent-start Developer."
                Require (-not $starts.ContainsKey($work.developer)) "Multiple starts for one Developer."
                $offer = $offers[$work.developer]
                Require-Text $work.offerId "sent-start offerId"
                Require ($work.offerId -ceq $offer.offerId -and $work.issue -in $offer.candidates) "Sent start does not match its offer."
                Require (@($starts.Values | Where-Object issue -EQ $work.issue).Count -eq 0) "A task was started twice."
                $starts[$work.developer] = $work
            }
            $held += $work
        }
    }
    $open = @{}
    foreach ($work in $packet.openAssignments) {
        Require-Object $work "packet open assignment"
        Require-Text $work.assignmentId "packet assignmentId"
        Require-Issue $work.issue
        Require-Text $work.developer "packet assignment developer"
        Require (-not $open.ContainsKey($work.assignmentId)) "Duplicate packet assignment."
        $open[$work.assignmentId] = $work
    }
    $released = @{}
    foreach ($release in $Request.releasedAssignments) {
        Require-Object $release "released assignment"
        Require-Text $release.assignmentId "released assignmentId"
        Require-Text $release.reason "verified release evidence"
        Require ($open.ContainsKey($release.assignmentId) -and -not $released.ContainsKey($release.assignmentId)) "Release must name a unique packet open assignment."
        Require (-not $assignments.ContainsKey($release.assignmentId)) "Released work cannot also be held or sent."
        $released[$release.assignmentId] = $true
    }
    foreach ($work in $packet.openAssignments) {
        if ($released.ContainsKey($work.assignmentId)) { continue }
        Require ($assignments.ContainsKey($work.assignmentId)) "Packet open assignments must remain in retained work."
        $retained = $assignments[$work.assignmentId]
        Require ($work.issue -eq $retained.issue -and $work.developer -ceq $retained.developer) "Packet assignment identity mismatch."
    }

    $responses = @{}; $accepted = @{}; $reruns = @{}
    foreach ($response in $Request.responses) {
        Require-Object $response "response"
        $developer = $response.developer
        Require-Text $developer "response developer"
        Require-Text $response.offerId "response offerId"
        Require-Text $response.recipientId "response recipientId"
        Require-Text $response.status "response status"
        Require ($developer -cin $developers -and -not $responses.ContainsKey($developer)) "Duplicate or unknown response Developer."
        $offer = $offers[$developer]
        Require ($response.offerId -ceq $offer.offerId -and $response.recipientId -ceq $offer.recipientId) "Response correlation mismatch."
        Require ($response.status -cin @("busy", "available")) "Unknown response status."
        if ($response.status -ceq "busy") {
            Require-Text $response.assignmentId "busy assignmentId"
            Require-Text $response.reason "busy reason"
            Require ($assignments.ContainsKey($response.assignmentId) -and
                $assignments[$response.assignmentId].developer -ceq $developer) "Busy assignment must be included in retained work."
            $accepted[$developer] = @()
        } else {
            Require-Array $response.evaluations "evaluations"
            Require-Array $response.preferred "preferred"
            $evaluated = @{}; $eligible = @()
            foreach ($evaluation in $response.evaluations) {
                Require-Object $evaluation "evaluation"
                Require-Issue $evaluation.issue
                $key = "$($evaluation.issue)"
                Require ($evaluation.issue -in $offer.candidates -and -not $evaluated.ContainsKey($key)) "Evaluation must name each offered candidate exactly once."
                Require ($evaluation.eligible -is [bool]) "eligible must be Boolean."
                Require-Text $evaluation.reason "evaluation reason/evidence"
                if ($evaluation.Contains("recommendedAction")) {
                    Require-Text $evaluation.recommendedAction "recommendedAction"
                    Require ($evaluation.recommendedAction -ceq "rerun-failed-checks" -and -not $evaluation.eligible) "A rerun recommendation requires a rejected candidate."
                    $candidate = $candidates[$key]
                    Require-Object $candidate.pr "rerun candidate PR"
                    Require-Issue $candidate.pr.number
                    Require ($candidate.category -ceq "failed" -and $candidate.pr.number -gt 0 -and
                        $candidate.pr.mergeable -cne $false -and -not $candidate.finalizeRejection) "Reruns require a failed CI candidate without a conflict or finalize rejection."
                    Require-Object $evaluation.rerun "rerun"
                    $rerun = $evaluation.rerun
                    Require-Text $rerun.head "rerun head"
                    Require ($rerun.head -cmatch '^[0-9a-f]{40}$' -and $rerun.head -ceq $candidate.pr.head.sha) "Rerun head must match the offered PR."
                    Require-Issue $rerun.runId
                    Require-Issue $rerun.runAttempt
                    if ($reruns.ContainsKey($key)) {
                        $prior = $reruns[$key]
                        Require ($prior.head -ceq $rerun.head -and $prior.runId -eq $rerun.runId -and
                            $prior.runAttempt -eq $rerun.runAttempt) "Contradictory rerun recommendations."
                    } else {
                        $reruns[$key] = @{ issue = $evaluation.issue; pr = $candidate.pr.number; head = $rerun.head
                            runId = $rerun.runId; runAttempt = $rerun.runAttempt; recommendations = @() }
                    }
                    $reruns[$key].recommendations += @{ developer = $developer; offerId = $response.offerId
                        recipientId = $response.recipientId; reason = $evaluation.reason }
                } elseif ($evaluation.Contains("rerun")) {
                    Require $false "Rerun evidence requires recommendedAction."
                }
                $evaluated[$key] = $true
                if ($evaluation.eligible) { $eligible += $evaluation.issue }
            }
            Require ($evaluated.Count -eq $offer.candidates.Count) "Every offered candidate needs an evaluation."
            foreach ($issue in $response.preferred) { Require-Issue $issue }
            Require (@($response.preferred | Select-Object -Unique).Count -eq $response.preferred.Count -and
                $response.preferred.Count -eq $eligible.Count -and
                @($response.preferred | Where-Object { $_ -notin $eligible }).Count -eq 0) "preferred must order exactly the eligible offered candidates."
            $accepted[$developer] = @($response.preferred)
        }
        $responses[$developer] = $response
    }

    $compatibility = @{}
    foreach ($assessment in $Request.compatibility) {
        Require-Object $assessment "compatibility assessment"
        Require-Array $assessment.issues "compatibility issues"
        Require ($assessment.issues.Count -eq 2) "Compatibility requires two issues."
        foreach ($issue in $assessment.issues) {
            Require-Issue $issue
            Require ($candidates.ContainsKey("$issue") -or $issue -in $held.issue -or
                $issue -in $packet.openAssignments.issue) "Compatibility names unknown work."
        }
        Require ($assessment.issues[0] -ne $assessment.issues[1]) "An issue cannot be compatible with itself."
        Require ($assessment.compatible -is [bool]) "compatible must be Boolean."
        Require-Text $assessment.reason "compatibility reason/evidence"
        $key = Pair-Key $assessment.issues[0] $assessment.issues[1]
        Require (-not $compatibility.ContainsKey($key)) "Duplicate or contradictory compatibility assessment."
        $compatibility[$key] = $assessment
    }
    function Get-Conflict($First, $Second) {
        if ($First -eq $Second) { return "Task #$First already has retained work." }
        $key = Pair-Key $First $Second
        if (-not $compatibility.ContainsKey($key)) { return "Compatibility unknown for #$First and #$Second." }
        if (-not $compatibility[$key].compatible) { return $compatibility[$key].reason }
    }

    $choices = @{}; $decisions = @{}
    foreach ($developer in $developers) {
        $other = $developers | Where-Object { $_ -cne $developer }
        $choices[$developer] = @(0)
        $decision = @{ developer = $developer; status = "idle"; reason = ""; deferred = @() }
        $decisions[$developer] = $decision
        if ($starts.ContainsKey($developer)) {
            $decision.status = "retained"; $decision.reason = "A start was already sent; do not resend or reshuffle."
            continue
        }
        if (@($held | Where-Object developer -CEQ $developer).Count) {
            $decision.status = "held"; $decision.reason = "Existing assignment remains held until separately reconciled."
            continue
        }
        if (-not $responses.ContainsKey($developer)) {
            $decision.status = "pending"; $decision.reason = "Awaiting a correlated Developer response."
            continue
        }
        if ($responses[$developer].status -ceq "busy") {
            $decision.status = "held"; $decision.reason = "Developer reports busy."
            continue
        }
        foreach ($issue in $accepted[$developer]) {
            $reasons = @(
                foreach ($work in $held) { Get-Conflict $issue $work.issue }
                if (-not $responses.ContainsKey($other) -and -not $starts.ContainsKey($other)) {
                    foreach ($unresolved in $offers[$other].candidates) {
                        # The same shared task is exclusive, not concurrent work.
                        if ($unresolved -ne $issue) { Get-Conflict $issue $unresolved }
                    }
                }
            )
            if ($reasons.Count) {
                $decision.deferred += @{ issue = $issue; reasons = @($reasons | Select-Object -Unique) }
            } else { $choices[$developer] += $issue }
        }
        $decision.reason = if (-not $accepted[$developer].Count) { "No eligible offered candidates." }
            else { "No new start selected; see deferred candidates and allocation ranking." }
    }

    # Enumerating at most nine pairs makes the ordering explicit and reproducible.
    $plans = @()
    foreach ($first in $choices["developer-1"]) {
        foreach ($second in $choices["developer-2"]) {
            if ($first -and $second) {
                if ($first -eq $second) { continue }
                $conflict = Get-Conflict $first $second
                if ($conflict) {
                    foreach ($developer in $developers) {
                        $decisions[$developer].deferred += @{ issue = $(if ($developer -eq "developer-1") { $first } else { $second }); reasons = @($conflict) }
                    }
                    continue
                }
            }
            $selected = @($first, $second | Where-Object { $_ -ne 0 })
            $priority = @($selected | ForEach-Object { $ranks["$_"] } | Sort-Object)
            $preference = 0
            if ($first) { $preference += [array]::IndexOf($accepted["developer-1"], $first) }
            if ($second) { $preference += [array]::IndexOf($accepted["developer-2"], $second) }
            $plans += @{
                first = $first; second = $second; count = $selected.Count
                priority1 = $(if ($priority.Count) { $priority[0] } else { [int]::MaxValue })
                priority2 = $(if ($priority.Count -gt 1) { $priority[1] } else { [int]::MaxValue })
                preference = $preference
                developer1Rank = $(if ($first) { $ranks["$first"] } else { [int]::MaxValue })
            }
        }
    }
    $best = $plans | Sort-Object @{ Expression = { $_.count }; Descending = $true },
        priority1, priority2, preference, developer1Rank | Select-Object -First 1
    $proposed = @()
    foreach ($developer in $developers) {
        $issue = if ($developer -eq "developer-1") { $best.first } else { $best.second }
        if (-not $issue) { continue }
        $candidate = $candidates["$issue"]
        $action = switch ($candidate.category) { success { "finalize" }; failed { "repair" }; default { "implement" } }
        $proposed += @{ developer = $developer; offerId = $offers[$developer].offerId
            recipientId = $offers[$developer].recipientId; issue = $issue; action = $action }
        $decisions[$developer].status = "proposed"
        $decisions[$developer].reason = "Selected by assignment count, packet priority, summed preference rank, then Developer 1 precedence."
    }
    $proposedReruns = @(); $deferredReruns = @()
    foreach ($candidate in $packet.candidates) {
        $key = "$($candidate.issue)"
        if (-not $reruns.ContainsKey($key)) { continue }
        $rerun = $reruns[$key]
        $reasons = @(
            foreach ($developer in $developers) {
                if ($rerun.issue -in $accepted[$developer]) { "A Developer accepted code repair for this task." }
                if (-not $responses.ContainsKey($developer) -and $rerun.issue -in $offers[$developer].candidates) {
                    "Awaiting the other assessment of this task."
                }
                if (-not $responses.ContainsKey($developer) -and -not $starts.ContainsKey($developer)) {
                    foreach ($unresolved in $offers[$developer].candidates) {
                        if ($unresolved -ne $rerun.issue) { Get-Conflict $rerun.issue $unresolved }
                    }
                }
            }
            foreach ($work in @($held) + @($proposed) + @($proposedReruns)) { Get-Conflict $rerun.issue $work.issue }
        )
        if ($reasons.Count) {
            $deferredReruns += @{ issue = $rerun.issue; reasons = @($reasons | Select-Object -Unique) }
        } else { $proposedReruns += $rerun }
    }
    @{
        schema = "fingvibe-loop4-allocation-plan-v1"; repository = $packet.repository; epic = $packet.epic
        proposedStarts = $proposed; retainedStarts = @($Request.sentStarts)
        proposedReruns = $proposedReruns; deferredReruns = $deferredReruns
        decisions = @($developers | ForEach-Object { $decisions[$_] })
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    if (-not $InputPath) { throw "InputPath is required." }
    $request = Get-Content -LiteralPath $InputPath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String -NoEnumerate
    if ($request -isnot [System.Collections.IDictionary]) { throw "Assignment input must be a JSON object." }
    Get-Agent4AssignmentPlan $request | ConvertTo-Json -Depth 100
}
