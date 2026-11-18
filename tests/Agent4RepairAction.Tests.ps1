$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\.github\scripts\Invoke-Agent4RepairAction.ps1")
function Assert-True($Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Fails([scriptblock] $Action, [string] $Pattern) {
    try { & $Action | Out-Null }
    catch { if ($_.Exception.Message -notlike $Pattern) { throw }; return }
    throw "Expected failure matching $Pattern."
}
function New-Fixture {
    $script:fixture = @{
        comments = @(); requests = @(); reruns = 0; failTrigger = $false; failReadback = $false; newerRun = $false
        changeAfterReserve = $false; paginate = $false; cursorSequence = @(); replies = @{}
        issue = @{ number = 101; state = "open"; labels = @(@{ name = "type:task" }) }
        parent = @{ number = 92; state = "open"; labels = @(@{ name = "type:epic" }) }
        pull = @{ number = 201; state = "open"; mergeable = $true; base = @{ ref = "main" }
            head = @{ sha = "a" * 40; repo = @{ full_name = "TestOwner/TestRepo" } } }
        run = @{ id = 301; workflow_id = 501; run_attempt = 1; repository = @{ full_name = "TestOwner/TestRepo" }; head_sha = "a" * 40
            status = "completed"; conclusion = "failure"; event = "pull_request"; pull_requests = @(@{ number = 201 }) }
        discussion = @{ id = "D1"; url = "https://github.com/TestOwner/TestRepo/discussions/401"
            body = "<!-- fingvibe:task=101 -->"; category = @{ name = "Task conversations" } }
    }
    @{
        action = "rerun"; issue = 101; discussion = 401; repairs = 12; expectedRepairCount = 0
        allocation = @{
            schema = "fingvibe-loop4-allocation-input-v1"
            packet = @{
                schema = "fingvibe-loop4-packet-v1"; repository = "TestOwner/TestRepo"; epic = 92; targetBranch = "main"
                candidates = @(@{ issue = 101; category = "failed"; pr = $script:fixture.pull })
                developerOffers = @(
                    @{ developer = "developer-1"; candidates = @(@{ issue = 101 }) }
                    @{ developer = "developer-2"; candidates = @(@{ issue = 101 }) }
                )
                openAssignments = @()
            }
            offers = @(
                @{ developer = "developer-1"; offerId = "o1"; recipientId = "s1"; candidates = @(101) }
                @{ developer = "developer-2"; offerId = "o2"; recipientId = "s2"; candidates = @(101) }
            )
            responses = @(foreach ($n in 1, 2) {
                @{ developer = "developer-$n"; offerId = "o$n"; recipientId = "s$n"; status = "available"; preferred = @()
                    evaluations = @(@{ issue = 101; eligible = $false; reason = "Same assertion on unrelated tooling branches."
                        recommendedAction = "rerun-failed-checks"; rerun = @{ head = "a" * 40; runId = 301; runAttempt = 1 } }) }
            })
            existingWork = @(); sentStarts = @(); releasedAssignments = @(); compatibility = @()
        }
    }
}
function Add-Comment([string] $Body) {
    $id = "C$($script:fixture.comments.Count + 1)"
    $script:fixture.comments += @{ id = $id; body = $Body; createdAt = "2026-11-16T22:$('{0:d2}' -f $script:fixture.comments.Count):00Z" }
    $id
}
$api = {
    param($Method, $Endpoint, $Fields)
    $script:fixture.requests += @{ method = $Method; endpoint = $Endpoint; fields = $Fields }
    if ($Endpoint -eq "graphql") {
        if ($Fields.query.StartsWith("mutation")) {
            $id = Add-Comment $Fields.body
            if ($script:fixture.changeAfterReserve -and $Fields.body.Contains("repair-attempt=")) {
                $script:fixture.pull = $script:fixture.pull.Clone()
                $script:fixture.pull.head = @{ sha = "b" * 40; repo = @{ full_name = "TestOwner/TestRepo" } }
            }
            return @{ data = @{ addDiscussionComment = @{ comment = @{ id = $id } } } }
        }
        if ($Fields.query.Contains('repository(owner:')) {
            return @{ data = @{ repository = @{ nameWithOwner = "TestOwner/TestRepo"; discussion = $script:fixture.discussion } } }
        }
        if ($Fields.query.Contains('... on DiscussionComment{replies(')) {
            $nodes = @(if ($Fields.query.Contains('id:"C1"')) { $script:fixture.replies.Values })
            return @{ data = @{ node = @{ replies = @{ nodes = $nodes; pageInfo = @{ hasNextPage = $false } } } } }
        }
        $comments = if ($script:fixture.failReadback) { @() } else { $script:fixture.comments }
        $allComments = $comments
        $more = $false
        $endCursor = $null
        if ($script:fixture.cursorSequence.Count) {
            $afterMatch = [regex]::Match($Fields.query, 'after:"([^"]+)"')
            $pageIndex = 0
            if ($afterMatch.Success) {
                $pageIndex = -1
                for ($index = 0; $index -lt $script:fixture.cursorSequence.Count; $index++) {
                    if ($script:fixture.cursorSequence[$index] -ceq $afterMatch.Groups[1].Value) {
                        $pageIndex = $index + 1
                        break
                    }
                }
                Assert-True ($pageIndex -ge 0) "Unexpected repair history cursor."
            }
            Assert-True ($pageIndex -lt $allComments.Count) "Incomplete synthetic repair history page."
            $comments = if ($pageIndex -lt $script:fixture.cursorSequence.Count) {
                @($allComments[$pageIndex])
            } else {
                @($allComments | Select-Object -Skip $pageIndex)
            }
            $more = $pageIndex -lt $script:fixture.cursorSequence.Count
            $endCursor = if ($more) { $script:fixture.cursorSequence[$pageIndex] } else { $null }
        } elseif ($script:fixture.paginate -and $comments.Count -gt 1) {
            if ($Fields.query.Contains('after:"next"')) { $comments = @($comments | Select-Object -Skip 1) }
            else { $comments = @($comments[0]); $more = $true; $endCursor = "next" }
        }
        $nodes = @(foreach ($comment in $comments) {
            $entry = $comment.Clone()
            $replies = @(if ($entry.id -eq "C1") { $script:fixture.replies.Values })
            $entry.replies = @{ nodes = $replies; pageInfo = @{ hasNextPage = $false } }
            $entry
        })
        return @{ data = @{ node = @{ comments = @{ nodes = $nodes; pageInfo = @{ hasNextPage = $more; endCursor = $endCursor } } } } }
    }
    if ($Endpoint.StartsWith("repos/TestOwner/TestRepo/actions/workflows/501/runs?")) {
        return @{ workflow_runs = @(@{ id = $(if ($script:fixture.newerRun) { 302 } else { 301 }) }) }
    }
    switch ($Endpoint) {
        "repos/TestOwner/TestRepo/issues/101" { return $script:fixture.issue }
        "repos/TestOwner/TestRepo/issues/101/parent" { return $script:fixture.parent }
        "repos/TestOwner/TestRepo/pulls/201" { return $script:fixture.pull }
        "repos/TestOwner/TestRepo/actions/runs/301" { return $script:fixture.run }
        "repos/TestOwner/TestRepo/actions/runs/301/rerun-failed-jobs" {
            Assert-True ($Method -eq "POST") "Use the failed-jobs endpoint, never a full workflow rerun."
            Assert-True (@($script:fixture.comments | Where-Object { $_.body -match 'fingvibe:repair-attempt=\d+ kind=rerun' }).Count -gt 0) "Reserve and read back the budget before requesting CI."
            $script:fixture.reruns++
            if ($script:fixture.failTrigger) { throw "Request outcome uncertain." }
            return @{}
        }
        default { throw "Unexpected API request: $Method $Endpoint" }
    }
}

$request = New-Fixture
$result = Invoke-Agent4RepairAction $request $api
Assert-True ($result.status -eq "requested" -and $result.attempt -eq 1 -and $script:fixture.reruns -eq 1) "Request a single asynchronous failed-job rerun."
$trigger = @($script:fixture.requests | Where-Object endpoint -Like "*/rerun-failed-jobs")[0]
$afterTrigger = $false
foreach ($call in $script:fixture.requests) {
    if ([object]::ReferenceEquals($call, $trigger)) { $afterTrigger = $true; continue }
    if ($afterTrigger) { Assert-True ($call.endpoint -eq "graphql") "After triggering CI, only report/readback; never poll or wait for completion." }
}
$result = Invoke-Agent4RepairAction $request $api
Assert-True ($result.status -eq "already-recorded" -and $script:fixture.reruns -eq 1) "Repeated cycle/duplicate recommendation cannot rerun the same attempt."

$request = New-Fixture
$request.allocation.existingWork = @(@{ issue = 102; developer = "foreign"; assignmentId = "independent" })
$result = Invoke-Agent4RepairAction $request $api
Assert-True ($result.status -eq "requested" -and $result.attempt -eq 1 -and $script:fixture.reruns -eq 1) "Unknown compatibility with distinct held work does not veto an authorized rerun or bypass its budget."

$request = New-Fixture
$script:fixture.failTrigger = $true
Assert-Fails { Invoke-Agent4RepairAction $request $api } "*outcome uncertain*"
$null = Add-Comment $script:fixture.comments[0].body
$budget = Get-Agent4RepairBudget $script:fixture.comments
Assert-True ($budget.consumed -eq 1 -and $budget.uncertain.Count -eq 1) "An uncertain request is not refunded or resolved by a duplicate reservation reference."
$script:fixture.failTrigger = $false
Assert-True ((Invoke-Agent4RepairAction $request $api).status -eq "already-recorded") "A crash/uncertain trigger cannot cause duplicate delivery."
$script:fixture.run.run_attempt = 2
foreach ($response in $request.allocation.responses) { $response.evaluations[0].rerun.runAttempt = 2 }
$request.expectedRepairCount = 1
Assert-Fails { Invoke-Agent4RepairAction $request $api } "*Uncertain rerun reservation*"

$request = New-Fixture
$null = Add-Comment "<!-- fingvibe:assignment=legacy developer=developer-1 action=repair -->`n<!-- fingvibe:assignment-end=legacy -->"
Assert-Fails { Invoke-Agent4RepairAction $request $api } "*Missing repair history*"
$null = Add-Comment "Verified legacy task reports: 11 consumed code repairs; this checkpoint covers legacy.`n<!-- fingvibe:repair-baseline=11 assignments=legacy -->"
$request.expectedRepairCount = 11
$result = Invoke-Agent4RepairAction $request $api
Assert-True ($result.attempt -eq 12) "Eleven prior code repairs plus one rerun exhaust the default shared allowance."
$script:fixture.run.run_attempt = 2
foreach ($response in $request.allocation.responses) { $response.evaluations[0].rerun.runAttempt = 2 }
$request.expectedRepairCount = 12
Assert-Fails { Invoke-Agent4RepairAction $request $api } "*allowance exhausted*"
Assert-True ($script:fixture.reruns -eq 1) "A new workflow attempt does not reset the total."

$request = New-Fixture
$null = Add-Comment "Task history"
$script:fixture.replies["R1"] = @{ id = "R1"; createdAt = "2026-11-16T22:00:30Z"
    body = "<!-- fingvibe:repair-attempt=1 kind=code key=old-code -->" }
$null = Add-Comment "<!-- fingvibe:assignment=old-code developer=developer-1 action=repair -->`n<!-- fingvibe:assignment-end=old-code -->"
$script:fixture.paginate = $true
$request.expectedRepairCount = 1
Assert-True ((Invoke-Agent4RepairAction $request $api).attempt -eq 2) "Paginated comments and nested reply reservations contribute to the shared budget."

$request = New-Fixture
$script:fixture.comments = @(
    @{ id = "DC_kwDOVT1KL84BLKVK"; body = "Task history A"; createdAt = "2026-11-16T22:00:00Z" },
    @{ id = "DC_kwDOVT1KL84BLKvk"; body = "Task history B"; createdAt = "2026-11-16T22:01:00Z" }
)
Assert-True ((Invoke-Agent4RepairAction $request $api).attempt -eq 1) "GraphQL node IDs differing only by case are distinct."

$request = New-Fixture
$script:fixture.comments = @(
    @{ id = "DC_duplicate"; body = "Task history A"; createdAt = "2026-11-16T22:00:00Z" },
    @{ id = "DC_duplicate"; body = "Task history B"; createdAt = "2026-11-16T22:01:00Z" }
)
Assert-Fails { Invoke-Agent4RepairAction $request $api } "*Missing or duplicate repair history entries*"

$request = New-Fixture
$null = Add-Comment "Task history A"
$null = Add-Comment "Task history B"
$null = Add-Comment "Task history C"
$script:fixture.cursorSequence = @("CursorA", "cursora")
Assert-True ((Invoke-Agent4RepairAction $request $api).attempt -eq 1) "GraphQL pagination cursors differing only by case are distinct."

$request = New-Fixture
$null = Add-Comment "Task history A"
$null = Add-Comment "Task history B"
$script:fixture.cursorSequence = @("RepeatedCursor", "RepeatedCursor")
Assert-Fails { Invoke-Agent4RepairAction $request $api } "*Invalid repair history pagination*"

foreach ($repairCount in 1, 3) {
    $request = New-Fixture
    for ($attempt = 1; $attempt -le $repairCount; $attempt++) {
        $marker = "<!-- fingvibe:repair-attempt=$attempt kind=code key=old-code-$attempt -->"
        $null = Add-Comment "Repair reservation.`n$marker"
        $null = Add-Comment "Sending repair. Reservation: $marker`n<!-- fingvibe:assignment=old-code-$attempt developer=developer-1 action=repair -->`n<!-- fingvibe:assignment-end=old-code-$attempt -->"
    }
    $firstMarker = "<!-- fingvibe:repair-attempt=1 kind=code key=old-code-1 -->"
    $null = Add-Comment "Later diagnostic repeats an earlier reservation: $firstMarker $firstMarker"
    $script:fixture.replies["R1"] = @{ id = "R1"; createdAt = "2026-11-16T22:50:00Z"; body = $firstMarker }
    $script:fixture.paginate = $true
    $request.expectedRepairCount = $repairCount
    $result = Invoke-Agent4RepairAction $request $api
    Assert-True ($result.attempt -eq $repairCount + 1 -and $script:fixture.reruns -eq 1) "Copied Sending/diagnostic/reply markers consume one attempt per reservation and permit the next sequential repair."
    $null = Add-Comment "<!-- fingvibe:repair-attempt=$($result.attempt) kind=rerun key=$($result.key) -->"
    $budget = Get-Agent4RepairBudget $script:fixture.comments
    Assert-True ($budget.consumed -eq $repairCount + 1 -and $budget.uncertain.Count -eq 0) "Repeating a completed rerun reservation neither consumes another attempt nor makes its result uncertain."
    Assert-True ((Invoke-Agent4RepairAction $request $api).status -eq "already-recorded" -and $script:fixture.reruns -eq 1) "Duplicate ledger references never authorize another CI request."
}

$request = New-Fixture
$script:fixture.changeAfterReserve = $true
Assert-Fails { Invoke-Agent4RepairAction $request $api } "*identity/head changed*"
Assert-True ($script:fixture.reruns -eq 0 -and (Get-Agent4RepairBudget $script:fixture.comments).consumed -eq 1) "Head drift after reservation prevents a trigger without refunding the attempt."

$request = New-Fixture
$request.repairs = 1
$null = Invoke-Agent4RepairAction $request $api
$request.action = "code"; $request.assignmentId = "code-1"; $request.expectedRepairCount = 1
foreach ($response in $request.allocation.responses) {
    $response.evaluations[0].Remove("recommendedAction"); $response.evaluations[0].Remove("rerun")
}
$evaluation = $request.allocation.responses[0].evaluations[0]
$evaluation.eligible = $true
$request.allocation.responses[0].preferred = @(101)
Assert-Fails { Invoke-Agent4RepairAction $request $api } "*allowance exhausted*"
$request.repairs = 2
$result = Invoke-Agent4RepairAction $request $api
Assert-True ($result.status -eq "reserved" -and $result.attempt -eq 2 -and $script:fixture.reruns -eq 1) "Code repair consumes the same budget without triggering CI."
$script:fixture.pull.head.sha = "b" * 40
$request.assignmentId = "code-2"; $request.expectedRepairCount = 2
Assert-Fails { Invoke-Agent4RepairAction $request $api } "*allowance exhausted*"

foreach ($case in @(
    @{ change = { $script:fixture.run.run_attempt = 2 }; pattern = "*Run is stale*" }
    @{ change = { $script:fixture.run.status = "in_progress" }; pattern = "*Run is stale*" }
    @{ change = { $script:fixture.run.conclusion = "success" }; pattern = "*Run is stale*" }
    @{ change = { $script:fixture.run.head_sha = "b" * 40 }; pattern = "*Run is stale*" }
    @{ change = { $script:fixture.run.pull_requests = @() }; pattern = "*Run is stale*" }
    @{ change = { $script:fixture.run.repository.full_name = "Other/Repo" }; pattern = "*Run is stale*" }
    @{ change = { $script:fixture.newerRun = $true }; pattern = "*newer workflow run*" }
    @{ change = { $script:fixture.pull = $script:fixture.pull.Clone(); $script:fixture.pull.head = @{ sha = "b" * 40 } }; pattern = "*identity/head changed*" }
    @{ change = { $script:fixture.issue.labels += @{ name = "human-task" } }; pattern = "*identity/head changed*" }
    @{ change = { $script:fixture.parent.labels = @() }; pattern = "*identity/head changed*" }
    @{ change = { $script:fixture.discussion.body = "<!-- fingvibe:task=999 -->" }; pattern = "*identity mismatch*" }
    @{ change = { $null = Add-Comment "<!-- fingvibe:assignment=live developer=developer-1 action=implement -->" }; pattern = "*Open task assignment*" }
    @{ change = { $args[0].expectedRepairCount = 1 }; pattern = "*count changed*" }
    @{ change = { $args[0].repairs = 0 }; pattern = "*allowance exhausted*" }
    @{ change = { $script:fixture.failReadback = $true }; pattern = "*readback failed*" }
)) {
    $request = New-Fixture
    & $case.change $request
    Assert-Fails { Invoke-Agent4RepairAction $request $api } $case.pattern
    Assert-True ($script:fixture.reruns -eq 0) "Invalid evidence or failed reservation must not trigger CI."
}

foreach ($bodies in @(
    @("<!-- fingvibe:repair-attempt=2 kind=rerun key=r1 -->"),
    @("<!-- fingvibe:repair-attempt=1 kind=rerun key=r1 -->", "<!-- fingvibe:repair-attempt=2 kind=rerun key=r1 -->"),
    @("<!-- fingvibe:repair-attempt=1 kind=code key=r1 -->", "<!-- fingvibe:repair-attempt=1 kind=rerun key=r1 -->"),
    @("<!-- fingvibe:repair-attempt=1 kind=code key=r1 -->", "<!-- fingvibe:repair-attempt=1 kind=code key=r2 -->"),
    @("<!-- fingvibe:repair-attempt=1 kind=code key=r1 -->", "<!-- fingvibe:repair-attempt=1 kind=code key=R1 -->"),
    @("<!-- fingvibe:repair-attempt=1 kind=rerun key=r1 -->", "<!-- fingvibe:repair-baseline=0 assignments=none -->"),
    @("<!-- fingvibe:repair-baseline=0 assignments=future -->", "<!-- fingvibe:assignment=future developer=developer-1 action=repair -->"),
    @("<!-- fingvibe:repair-result=r1 state=requested -->"),
    @("<!-- fingvibe:repair-attempt=broken -->")
)) {
    Assert-Fails { Get-Agent4RepairBudget @($bodies | ForEach-Object { @{ body = $_ } }) } "*"
}

$path = Join-Path ([IO.Path]::GetTempPath()) ("fingvibe-repair-" + [guid]::NewGuid() + ".json")
try {
    '{"allocation":{"schema":"unsupported"}}' | Set-Content -LiteralPath $path
    $script = Join-Path $PSScriptRoot "..\.github\scripts\Invoke-Agent4RepairAction.ps1"
    $failure = & pwsh -NoProfile -File $script -InputPath $path 2>&1
    Assert-True ($LASTEXITCODE -ne 0 -and ($failure -join "`n") -like "*Unsupported schema*") "The actual CLI reads its JSON path and rejects invalid allocation before any GitHub request."
} finally {
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
}
Write-Output "Agent4 repair action checks passed."
