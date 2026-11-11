$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\.github\scripts\Get-DispatcherPreflight.ps1")

function Assert-Preflight([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function New-PreflightIssue([int] $Number, [string] $State = "open", [string[]] $Labels = @("type:task")) {
    [pscustomobject]@{
        number = $Number
        state = $State
        labels = @($Labels | ForEach-Object { [pscustomobject]@{ name = $_ } })
        assignees = @()
        html_url = "https://github.com/test/repo/issues/$Number"
        url = "https://api.github.com/repos/test/repo/issues/$Number"
        body = "## Dependencies and parent Epic`nDependencies: None`nParent: #164"
    }
}

function New-PreflightFixture {
    $epic = New-PreflightIssue 164 "open" @("type:epic")
    $epic.body = "## Child tasks`n- [ ] #200 - First task`n- [ ] #201 - Second task"
    $state = [pscustomobject]@{
        epic = $epic
        issues = @($epic, (New-PreflightIssue 200), (New-PreflightIssue 201))
        children = @(200, 201)
        pulls = @()
        comments = @()
        dependencies = @{}
        deliveries = @{}
        calls = [Collections.Generic.List[string]]::new()
        failEndpoint = $null
        malformedEndpoint = $null
        multiPage = $false
    }
    $reader = {
        param($Endpoint, $Paginated, $Query)
        $state.calls.Add("$Endpoint|$Query")
        if ($Endpoint -eq $state.failEndpoint) { throw "Simulated inaccessible API: $Endpoint" }
        if ($Endpoint -eq $state.malformedEndpoint) { return "not-json" }
        $items = @()
        $object = $null
        switch -Regex ($Endpoint) {
            '^repos/test/repo$' {
                $object = @{ full_name = "test/repo"; default_branch = "main"; html_url = "https://github.com/test/repo"; url = "https://api.github.com/repos/test/repo" }
                break
            }
            '^repos/test/repo/issues/164$' { $object = $state.epic; break }
            '/pulls\?' { $items = @($state.pulls); break }
            '/issues\?' { $items = @($state.issues); break }
            '/issues/comments\?' { $items = @($state.comments); break }
            '/sub_issues\?' { $items = @($state.issues | Where-Object { $_.number -in $state.children }); break }
            '/issues/(\d+)/parent$' { $object = $state.epic; break }
            '/issues/(\d+)/dependencies/blocked_by\?' {
                $items = @($state.issues | Where-Object { $_.number -in $state.dependencies[[int] $Matches[1]] })
                break
            }
            '^graphql$' {
                if ($Query -notmatch 'issue\(number:(\d+)\)') { throw "Unexpected query: $Query" }
                $number = [int] $Matches[1]
                $delivery = $state.deliveries[$number]
                $pageIndex = if ($Query -match 'after:"page-(\d+)"') { [int] $Matches[1] } else { 0 }
                $pageCount = if ($delivery.pages) { $delivery.pages.Count } else { 1 }
                $nodes = if ($delivery.pages) { @($delivery.pages[$pageIndex].nodes) } elseif ($delivery) { @($delivery.prs) } else { @() }
                $parent = if ($delivery -and $null -eq $delivery.parent) { $null } else {
                    @{
                        number = if ($delivery) { $delivery.parent } else { 164 }
                        labels = @{ nodes = @(@{ name = "type:epic" }); pageInfo = @{ hasNextPage = $false } }
                    }
                }
                $object = @{
                    data = @{ repository = @{ issue = @{
                        number = $number
                        parent = $parent
                        closedByPullRequestsReferences = @{
                            nodes = $nodes
                            pageInfo = @{ hasNextPage = $pageIndex -lt ($pageCount - 1); endCursor = "page-$($pageIndex + 1)" }
                        }
                    } } }
                }
                switch ($delivery.membershipMutation) {
                    "missing" { $object.data.repository.issue.Remove("parent") }
                    "empty" { $object.data.repository.issue.parent = @{} }
                    "incomplete-labels" { $parent.labels.pageInfo.hasNextPage = $true }
                    "non-epic" { $parent.labels.nodes = @(@{ name = "type:task" }) }
                    "changed-page" { if ($pageIndex -gt 0) { $object.data.repository.issue.parent = $null } }
                }
                break
            }
            default { throw "Unexpected read: $Endpoint" }
        }
        if ($Paginated) {
            if ($state.multiPage -and $items.Count -gt 1) {
                return "[" + (ConvertTo-Json -InputObject @($items[0]) -Depth 30 -Compress) + "," +
                    (ConvertTo-Json -InputObject @($items | Select-Object -Skip 1) -Depth 30 -Compress) + "]"
            }
            return "[" + (ConvertTo-Json -InputObject @($items) -Depth 30 -Compress) + "]"
        }
        ConvertTo-Json -InputObject $object -Depth 30 -Compress
    }.GetNewClosure()
    [pscustomobject]@{ state = $state; reader = $reader }
}

function Invoke-PreflightFixture($Fixture, [int[]] $Order, [string] $Evidence) {
    Get-DispatcherPreflight -Repository "test/repo" -Epic 164 -ApiReader $Fixture.reader -TaskOrder $Order -OrderEvidenceUrl $Evidence
}

function Add-PreflightClaim($Fixture, [int] $Number, [string] $State = "claimed") {
    $claim = @{
        schema = "fingvibe-agent-claim-v1"; repository = "test/repo"; epic = 164; task = $Number
        claimId = [guid]::NewGuid().ToString(); claimedUtc = [DateTime]::UtcNow.ToString("o")
        authorization = "https://github.com/test/repo/issues/222"; account = "test"; targetBranch = "main"
        branch = $null; worktree = $null; pr = $null; head = $null; implementationCheckpoint = $null; repairCount = 0
        state = $State; handoff = @{ id = [guid]::NewGuid().ToString(); action = "implement"; stage = "launch-requested"; sessionId = $null }
    }
    $Fixture.state.comments += [pscustomobject]@{
        id = $Fixture.state.comments.Count + 1
        html_url = "https://github.com/test/repo/issues/$Number#issuecomment-1"
        issue_url = "https://api.github.com/repos/test/repo/issues/$Number"
        body = "<!-- fingvibe-agent-claim-v1 -->`n`n" + '```json' + "`n" +
            (ConvertTo-Json -InputObject $claim -Depth 15) + "`n" + '```'
    }
}

function Add-PreflightDelivery($Fixture, [int] $Number, [Nullable[int]] $Parent = 164, [bool] $Merged = $true) {
    $Fixture.state.deliveries[$Number] = @{
        parent = $Parent
        prs = @(@{ number = 900 + $Number; url = "https://github.com/test/repo/pull/$(900 + $Number)"; merged = $Merged; baseRefName = "main"; state = "CLOSED" })
    }
}

$fixture = New-PreflightFixture
$fixture.state.multiPage = $true
$result = Invoke-PreflightFixture $fixture
Assert-Preflight ($result.decision -eq "candidate" -and $result.candidate.issue -eq 200) "Empty capacity must select the first mechanically eligible task."
Assert-Preflight ($result.counts.issues -eq 3 -and $result.counts.nativeChildren -eq 2) "All pages must be flattened without losing records."
Assert-Preflight (@($fixture.state.calls | Group-Object | Where-Object Count -GT 1).Count -eq 0) "Each shared source must be collected once."
Assert-Preflight ($result.requiresDispatcherVerification.Count -gt 0) "Candidate guidance must preserve host/authorization/fresh-write checks."

$fixture = New-PreflightFixture
$fixture.state.pulls = @(@{ number = 300; state = "open"; draft = $true; html_url = "https://github.com/test/repo/pull/300" })
$result = Invoke-PreflightFixture $fixture
Assert-Preflight ($result.decision -eq "reconcile" -and -not $result.candidate) "Draft PRs must consume capacity."

$fixture = New-PreflightFixture
$fixture.state.issues[1].labels += @{ name = "status:review" }
Assert-Preflight ((Invoke-PreflightFixture $fixture).decision -eq "reconcile") "Open review work must consume capacity."

foreach ($state in @("claimed", "blocked")) {
    $fixture = New-PreflightFixture
    $fixture.state.issues[1].state = "closed"
    Add-PreflightClaim $fixture 200 $state
    $result = Invoke-PreflightFixture $fixture
    Assert-Preflight ($result.decision -eq "reconcile" -and $result.findings[0].kind -eq "retained-claim") "Closed retained claims still hold the slot."
}

$fixture = New-PreflightFixture
Add-PreflightClaim $fixture 200 "released"
$fixture.state.issues[1].state = "closed"
Assert-Preflight ((Invoke-PreflightFixture $fixture).candidate.issue -eq 201) "Released closed claims must not prevent mechanical selection."

$fixture = New-PreflightFixture
Add-PreflightClaim $fixture 200
$fixture.state.comments[0].body = $fixture.state.comments[0].body -replace '"claimedUtc": "[^"]+"', '"claimedUtc": "2026-11-08T14:05:17.6249281+01:00"'
Assert-Preflight ((Invoke-PreflightFixture $fixture).decision -eq "reconcile") "Legacy explicit-offset timestamps must preserve real retained claims without guessing a timezone."
$fixture.state.comments[0].body = $fixture.state.comments[0].body.Replace('+01:00', '')
Assert-Preflight ([bool] (Invoke-PreflightFixture $fixture).collectionFailure) "Timezone-less claim timestamps must fail."

foreach ($mutation in @("malformed", "duplicate", "foreign", "invalid-state", "wrong-task", "incomplete")) {
    $fixture = New-PreflightFixture
    Add-PreflightClaim $fixture 200
    switch ($mutation) {
        "malformed" { $fixture.state.comments[0].body = "<!-- fingvibe-agent-claim-v1 --> no JSON" }
        "duplicate" { Add-PreflightClaim $fixture 200 }
        "foreign" { $fixture.state.comments[0].body = $fixture.state.comments[0].body.Replace('"test/repo"', '"other/repo"') }
        "invalid-state" { $fixture.state.comments[0].body = $fixture.state.comments[0].body.Replace('"claimed"', '"unknown"') }
        "wrong-task" { $fixture.state.comments[0].issue_url = "https://api.github.com/repos/test/repo/issues/201" }
        "incomplete" {
            $json = [regex]::Match($fixture.state.comments[0].body, '(?s)```json\s*(.*?)\s*```').Groups[1].Value
            $claim = ConvertFrom-Json -InputObject $json -AsHashtable
            $null = $claim.Remove("repairCount")
            $fixture.state.comments[0].body = $fixture.state.comments[0].body.Replace(
                $json, (ConvertTo-Json -InputObject $claim -Depth 15))
        }
    }
    $result = Invoke-PreflightFixture $fixture
    Assert-Preflight ($result.decision -eq "blocked" -and $result.collectionFailure -and -not $result.candidate) "$mutation claims must fail closed explicitly."
}

foreach ($mode in @("failure", "malformed")) {
    $fixture = New-PreflightFixture
    if ($mode -eq "failure") { $fixture.state.failEndpoint = "repos/test/repo/issues/comments?per_page=100" }
    else { $fixture.state.malformedEndpoint = "repos/test/repo/issues/comments?per_page=100" }
    $result = Invoke-PreflightFixture $fixture
    Assert-Preflight ($result.decision -eq "blocked" -and $result.collectionFailure) "Unavailable/malformed collection is never empty capacity."
}

foreach ($restriction in @("human-task", "status:blocked", "assigned")) {
    $fixture = New-PreflightFixture
    if ($restriction -eq "assigned") { $fixture.state.issues[1].assignees = @(@{ login = "other-worker" }) }
    else { $fixture.state.issues[1].labels += @{ name = $restriction } }
    Assert-Preflight ((Invoke-PreflightFixture $fixture).candidate.issue -eq 201) "$restriction tasks must be skipped."
}

$fixture = New-PreflightFixture
$fixture.state.children = @()
Assert-Preflight ((Invoke-PreflightFixture $fixture).decision -eq "no-work") "No native tasks must yield no-work."

$fixture = New-PreflightFixture
$fixture.state.epic.body = "Delivery order: #201 -> #200"
Assert-Preflight ((Invoke-PreflightFixture $fixture).candidate.issue -eq 201) "Explicit Epic order must override issue number."
$fixture.state.epic.body = "Implementation order is described in discussion."
Assert-Preflight ((Invoke-PreflightFixture $fixture).findings[0].kind -eq "ordering-review") "Unparsed explicit ordering must not fall back to ascending."
Assert-Preflight ((Invoke-PreflightFixture $fixture @(201, 200) $fixture.state.epic.html_url).candidate.issue -eq 201) "Dispatcher-verified order must be usable with evidence."
Assert-Preflight ([bool] (Invoke-PreflightFixture $fixture @(201, 201) $fixture.state.epic.html_url).collectionFailure) "Duplicate explicit order must fail."
Assert-Preflight ([bool] (Invoke-PreflightFixture $fixture @(999) $fixture.state.epic.html_url).collectionFailure) "Non-native explicit order must fail."
Assert-Preflight ([bool] (Invoke-PreflightFixture $fixture @(201) "https://other.example/order").collectionFailure) "Order provenance must belong to the Epic."

$fixture = New-PreflightFixture
$fixture.state.issues += New-PreflightIssue 190 "closed"
$fixture.state.dependencies[200] = @(190)
$fixture.state.issues[1].body = "## Dependencies and parent Epic`nNative blockers: #190`nParent: #164"
Add-PreflightDelivery $fixture 190 111
$result = Invoke-PreflightFixture $fixture
Assert-Preflight ($result.candidate.issue -eq 200 -and $result.candidate.dependencies[0].issue -eq 190) "Merged native prerequisites must carry delivery evidence."
$fixture.state.deliveries[190].pages = @(@{ nodes = @() }, @{ nodes = $fixture.state.deliveries[190].prs })
$result = Invoke-PreflightFixture $fixture
Assert-Preflight ($result.candidate.issue -eq 200 -and $result.candidate.dependencies[0].prs.Count -eq 1) "GraphQL delivery pages must all be inspected."
$fixture.state.deliveries[190].Remove("pages")
$fixture.state.deliveries[190].prs[0].merged = $false
Assert-Preflight ((Invoke-PreflightFixture $fixture).findings[0].kind -eq "dependency-delivery-review") "Closed-unmerged prerequisites are not delivery."
$fixture.state.deliveries[190].prs = @()
Assert-Preflight ((Invoke-PreflightFixture $fixture).findings[0].kind -eq "dependency-delivery-review") "Design/transferred acceptance without PR evidence needs review."
$fixture.state.issues[3].state = "open"
Assert-Preflight ((Invoke-PreflightFixture $fixture).candidate.issue -eq 201) "Open prerequisites make a task ineligible, not delivered."
$fixture.state.issues[1].body = "## Dependencies and parent Epic`nNative blockers: #191"
Assert-Preflight ((Invoke-PreflightFixture $fixture).findings[0].kind -eq "dependency-inconsistent") "Body/native mismatch must stop selection."
$fixture.state.issues[1].body = "## Dependencies and parent Epic`nThis depends on reviewed F1 acceptance, see #190."
Assert-Preflight ((Invoke-PreflightFixture $fixture).findings[0].kind -eq "dependency-review") "Ambiguous dependency prose must remain explicit."
$fixture.state.issues[1].body = "## Dependencies and parent Epic`nNative blockers: #200"
$fixture.state.dependencies[200] = @(200)
Assert-Preflight ([bool] (Invoke-PreflightFixture $fixture).collectionFailure) "Self-dependencies must fail."
$fixture.state.issues[1].body = "## Dependencies and parent Epic`nNative blockers: #201"
$fixture.state.dependencies[200] = @(201)
$fixture.state.dependencies[201] = @(200)
Assert-Preflight ([bool] (Invoke-PreflightFixture $fixture).collectionFailure) "Indirect open dependency cycles must fail, not appear as no-work."

foreach ($parent in @(164, 111, $null)) {
    $fixture = New-PreflightFixture
    $fixture.state.issues += New-PreflightIssue 190 "closed" @("type:task", "active")
    if ($parent -eq 164) { $fixture.state.children += 190 }
    Add-PreflightDelivery $fixture 190 $parent
    $result = Invoke-PreflightFixture $fixture
    if ($parent -eq 164) {
        Assert-Preflight ($result.decision -eq "reconcile" -and $result.findings[0].kind -eq "historical-cleanup") "Within-Epic historical cleanup must block."
    } else {
        Assert-Preflight ($result.decision -eq "candidate" -and $result.skipped[0].issue -eq 190) "Verified out-of-Epic historical label-only work must not occupy capacity."
        if ($null -eq $parent) {
            Assert-Preflight ($result.skipped[0].reason -match "missing Epic organization") "Parentless history must visibly retain the separate organization requirement."
        }
        $fixture.state.deliveries[190].prs[0].merged = $false
        Assert-Preflight ((Invoke-PreflightFixture $fixture).decision -eq "reconcile") "Out-of-Epic unknown/unmerged history does not qualify for the exception."
        $fixture.state.deliveries[190].prs[0].merged = $true
        $fixture.state.deliveries[190].prs[0].baseRefName = "other-branch"
        Assert-Preflight ((Invoke-PreflightFixture $fixture).findings[0].kind -eq "historical-delivery-unknown") "Merged history targeting another branch is not default-branch delivery."
    }
}

foreach ($mutation in @("missing", "empty", "incomplete-labels", "non-epic", "changed-page", "contradictory-child")) {
    $fixture = New-PreflightFixture
    $fixture.state.issues += New-PreflightIssue 190 "closed" @("type:task", "status:review")
    Add-PreflightDelivery $fixture 190 111
    $fixture.state.deliveries[190].membershipMutation = $mutation
    if ($mutation -eq "changed-page") {
        $fixture.state.deliveries[190].pages = @(@{ nodes = @() }, @{ nodes = $fixture.state.deliveries[190].prs })
    }
    if ($mutation -eq "contradictory-child") { $fixture.state.children += 190 }
    $result = Invoke-PreflightFixture $fixture
    Assert-Preflight ($result.decision -in @("blocked", "reconcile") -and -not $result.candidate) "$mutation membership must not qualify for the historical exception."
    if ($mutation -ne "non-epic") {
        Assert-Preflight ([bool] $result.collectionFailure) "$mutation membership must report an explicit collection failure."
    }
}

$fixture = New-PreflightFixture
$fixture.state.issues += New-PreflightIssue 190 "closed" @("type:task", "status:review")
Add-PreflightDelivery $fixture 190 $null
$fixture.state.failEndpoint = "graphql"
$result = Invoke-PreflightFixture $fixture
Assert-Preflight ($result.collectionFailure -and -not $result.candidate) "Inaccessible membership must not be interpreted as a verified null parent."
$fixture.state.failEndpoint = $null
$fixture.state.deliveries[190].prs = @()
Assert-Preflight ((Invoke-PreflightFixture $fixture).findings[0].kind -eq "historical-delivery-unknown") "Parentless closure without merged PRs still requires delivery review."
Add-PreflightClaim $fixture 190
Assert-Preflight ((Invoke-PreflightFixture $fixture).findings[0].kind -eq "retained-claim") "Parentless history must never hide an unresolved structured claim."

foreach ($state in @("open", "closed")) {
    $fixture = New-PreflightFixture
    $organizingEpic = New-PreflightIssue 111 $state @("type:epic")
    $fixture.state.issues += $organizingEpic
    $fixture.state.comments = @(@{
        id = 9
        issue_url = $organizingEpic.url
        html_url = "$($organizingEpic.html_url)#issuecomment-9"
        body = "Historical task ownership and claimed work are discussed here; this is an organizing Epic."
    })
    $result = Invoke-PreflightFixture $fixture
    Assert-Preflight ($result.candidate.issue -eq 200 -and $result.skipped[0].issue -eq 111) "Organizing Epic prose must not be treated as task ownership."
    if ($state -eq "open") {
        $organizingEpic.labels += @{ name = "active" }
        Assert-Preflight ((Invoke-PreflightFixture $fixture).findings[0].kind -eq "open-active-or-review") "Epic prose filtering must not hide live lifecycle evidence."
    }
}

$fixture = New-PreflightFixture
Add-PreflightClaim $fixture 164
Assert-Preflight ((Invoke-PreflightFixture $fixture).findings[0].kind -eq "retained-claim") "An explicit coordination record on an Epic must still block, not be discarded as discussion."

$fixture = New-PreflightFixture
$fixture.state.comments = @(@{
    id = 9
    issue_url = "https://api.github.com/repos/test/repo/issues/200"
    html_url = "https://github.com/test/repo/issues/200#issuecomment-9"
    body = "Claiming this task in another manual session."
})
Assert-Preflight ((Invoke-PreflightFixture $fixture).findings[0].kind -eq "manual-ownership-review") "Manual claims without lifecycle labels need reconciliation."

foreach ($state in @("open", "closed")) {
    $fixture = New-PreflightFixture
    $fixture.state.multiPage = $true
    $pr = New-PreflightIssue 300 $state
    $pr.html_url = "https://github.com/test/repo/pull/300"
    $pr | Add-Member -NotePropertyName pull_request -NotePropertyValue @{
        url = "https://api.github.com/repos/test/repo/pulls/300"
    }
    $fixture.state.issues += $pr
    $fixture.state.comments = @(@{
        id = 9
        issue_url = "https://api.github.com/repos/test/repo/issues/300"
        html_url = "https://github.com/test/repo/pull/300#issuecomment-9"
        body = "Retrospective: ownership remains with the task worker."
    })
    if ($state -eq "open") { $fixture.state.pulls = @($pr) }
    $result = Invoke-PreflightFixture $fixture
    Assert-Preflight (-not $result.collectionFailure -and $result.counts.issues -eq 3) "PR discussion comments must correlate without becoming task issues."
    if ($state -eq "open") {
        Assert-Preflight ($result.decision -eq "reconcile" -and $result.findings[0].kind -eq "open-pr") "PR comment handling must preserve open-PR capacity blockers."
    } else {
        Assert-Preflight ($result.decision -eq "candidate" -and $result.candidate.issue -eq 200) "Closed PR prose alone must not become task ownership evidence, regardless of merge status."
        $fixture.state.comments[0].issue_url = "https://api.github.com/repos/other/repo/issues/300"
        $result = Invoke-PreflightFixture $fixture
        Assert-Preflight ($result.decision -eq "blocked" -and $result.collectionFailure -match "Uncorrelated ownership comment") "Foreign PR comment URLs must fail closed."
        $fixture.state.comments = @()
        Add-PreflightClaim $fixture 300
        $result = Invoke-PreflightFixture $fixture
        Assert-Preflight ($result.decision -eq "blocked" -and $result.collectionFailure -match "coordination record") "Structured claims on PRs must not be silently ignored."
    }
}

$fixture = New-PreflightFixture
$fixture.state.comments = @(@{
    id = 9
    issue_url = "https://api.github.com/repos/test/repo/issues/999"
    html_url = "https://github.com/test/repo/issues/999#issuecomment-9"
    body = "Claiming this task."
})
$result = Invoke-PreflightFixture $fixture
Assert-Preflight ($result.decision -eq "blocked" -and -not $result.candidate -and
    $result.collectionFailure.Contains("#999") -and $result.collectionFailure.Contains($fixture.state.comments[0].html_url)) "Unknown ownership evidence must fail closed with the offending issue and comment URL."

$fixture = New-PreflightFixture
$fixture.state.issues += New-PreflightIssue 190 "closed"
$fixture.state.comments += @{
    id = 9
    issue_url = "https://api.github.com/repos/test/repo/issues/190"
    html_url = "https://github.com/test/repo/issues/190#issuecomment-9"
    body = "Historical worker claimed this task."
}
Add-PreflightDelivery $fixture 190 111
$result = Invoke-PreflightFixture $fixture
Assert-Preflight ($result.decision -eq "candidate" -and $result.skipped[0].issue -eq 190) "Missing historical manual session alone is not live-worker evidence."

$fixture = New-PreflightFixture
$fixture.state.pulls = @(1..150 | ForEach-Object { @{ number = $_; state = "open"; draft = $true; html_url = "https://github.com/test/repo/pull/$_" } })
$result = Invoke-PreflightFixture $fixture
$directory = Join-Path ([IO.Path]::GetTempPath()) ("dispatcher-preflight-test-" + [guid]::NewGuid())
[IO.Directory]::CreateDirectory($directory) | Out-Null
$artifact = $null
try {
    $json = ConvertTo-DispatcherPreflightOutput $result $directory
    $summary = $json | ConvertFrom-Json
    Assert-Preflight ([Text.Encoding]::UTF8.GetByteCount($json) -le 8192) "Representative stdout must be at most 8 KiB."
    $artifact = $summary.diagnosticPath
    $full = Get-Content -LiteralPath $artifact -Raw | ConvertFrom-Json -Depth 100
    Assert-Preflight ($full.findings.Count -eq 150 -and $summary.findingCount -eq 150) "Oversized findings must be preserved completely, not silently truncated."
    Assert-Preflight (-not $summary.candidate -and $summary.reviewRequired) "Artifact review must precede selection."
} finally {
    if ($artifact -and (Test-Path -LiteralPath $artifact)) { Remove-Item -LiteralPath $artifact }
    Remove-Item -LiteralPath $directory
}

$scriptPath = Join-Path $PSScriptRoot "..\.github\scripts\Get-DispatcherPreflight.ps1"
$command = "function gh { `$global:LASTEXITCODE = 1; '{}' }; & '" + $scriptPath.Replace("'", "''") + "' -Repository test/repo -Epic 164"
$previousExitCode = $LASTEXITCODE
try {
    $childOutput = & (Get-Process -Id $PID).Path -NoProfile -Command $command
    $childExitCode = $LASTEXITCODE
    $childResult = ($childOutput -join "`n") | ConvertFrom-Json
    Assert-Preflight ($childExitCode -eq 1 -and $childResult.decision -eq "blocked" -and $childResult.collectionFailure) "CLI collection failure must emit explicit JSON and exit nonzero."
} finally {
    $global:LASTEXITCODE = $previousExitCode
}

Write-Output "Dispatcher preflight tests passed."
