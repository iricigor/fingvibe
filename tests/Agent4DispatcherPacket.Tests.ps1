$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\.github\scripts\Get-Agent4DispatcherPacket.ps1") -Directory ([IO.Path]::GetTempPath())
$root = Join-Path ([IO.Path]::GetTempPath()) ("fingvibe-loop4-packet-test-" + [guid]::NewGuid())
function Assert-True($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Assert-Fails([scriptblock] $Action, [string] $Pattern) {
    try { & $Action | Out-Null }
    catch { if ($_.Exception.Message -notlike $Pattern) { throw }; return }
    throw "Expected failure matching $Pattern."
}
$state = New-Agent4State @{
    repository = "TestOwner/TestRepo"; epic = 92; targetBranch = "main"; maxRepairAttempts = 0
    authorization = @{ reference = "fixture://owner"; implementation = $true; merge = $false }
    workers = @(@{ id = "developer-1"; name = "Developer 1"; automationId = "auto-1" },
        @{ id = "developer-2"; name = "Developer 2"; automationId = "auto-2" })
}
$children = @(101..106 | ForEach-Object { @{
    number = $_; state = "open"; html_url = "fixture://issues/$_"; body = "Task scope."
    labels = @(@{ name = "type:task" })
} })
$children[1].labels += @{ name = "human-task" }
$fixtureDependencies = @(@{ number = 107; state = "open" })
$closedDependency = @{ number = 108; state = "closed"; state_reason = "not_planned" }
$observedReads = [Collections.Generic.List[string]]::new()
$fixtureReader = {
    param($Endpoint, $Paginated, $Query)
    $observedReads.Add("$Endpoint|$Query")
    $value = switch -Regex ($Endpoint) {
        '^repos/TestOwner/TestRepo$' { @{ full_name = "TestOwner/TestRepo"; default_branch = "main" }; break }
        '/issues/92$' { @{ number = 92; state = "open"; labels = @(@{ name = "type:epic" }) }; break }
        '/issues\?state=all' { @($children) + @(@{ number = 107; state = "open" }, $closedDependency); break }
        '/issues/comments' { @(); break }
        '/sub_issues' { $children; break }
        '/pulls\?' { @(@{ number = 200; head = @{ sha = "a"*40 } }); break }
        '/pulls/200/files' { @(@{ filename = "shared.cs"; patch = "fixture diff" }); break }
        '/pulls/200/reviews' { @(@{ id = 201; state = "CHANGES_REQUESTED" }); break }
        '/statuses\?' { @(); break }
        '/parent$' { @{ number = 92; labels = @(@{ name = "type:epic" }) }; break }
        '/issues/105/dependencies/' { $fixtureDependencies; break }
        '/issues/106/dependencies/' { @($closedDependency); break }
        '/dependencies/' { @(); break }
        '/check-runs' { @{ total_count = 1; check_runs = @(@{ name = "CI"; head_sha = "a"*40 }) }; break }
        '/actions/runs\?' { @{ total_count = 1; workflow_runs = @(@{ id = 300; head_sha = "a"*40 }) }; break }
        '/actions/runs/300/jobs' {
            @{ total_count = 1; jobs = @(@{ name = "devices-baseline"; started_at = "2026-11-15T10:00:00Z"; completed_at = "2026-11-15T10:04:01Z" }) }
            break
        }
        '^graphql$' {
            if ($Query.Contains('discussions(first:')) {
                @{ data = @{ repository = @{ discussions = @{
                    nodes = @(@{ id = "D1"; number = 1; body = "Original human steering"; author = @{ login = "TestOwner" } })
                    pageInfo = @{ hasNextPage = $false; endCursor = $null }
                } } } }
            } elseif ($Query.Contains('comments(first:')) {
                $second = $Query.Contains('after:"comments-next"')
                @{ data = @{ node = @{ comments = @{
                    nodes = @(@{ id = $(if ($second) { "C2" } else { "C1" }); body = "Original comment"; author = @{ login = "TestOwner" } })
                    pageInfo = @{ hasNextPage = -not $second; endCursor = $(if ($second) { $null } else { "comments-next" }) }
                } } } }
            } elseif ($Query.Contains('replies(first:')) {
                $second = $Query.Contains('after:"replies-next"')
                @{ data = @{ node = @{ replies = @{
                    nodes = @(@{ id = $(if ($second) { "R2" } else { "R1" }); body = "Reply"; author = @{ login = "TestOwner" } })
                    pageInfo = @{ hasNextPage = -not $second; endCursor = $(if ($second) { $null } else { "replies-next" }) }
                } } } }
            } elseif ($Query.Contains('closedByPullRequestsReferences')) {
                @{ data = @{ repository = @{ issue = @{ state = "CLOSED"; stateReason = "NOT_PLANNED"
                    closedByPullRequestsReferences = @{ nodes = @(); pageInfo = @{ hasNextPage = $false; endCursor = $null } }
                } } } }
            } else { throw "Unexpected GraphQL query: $Query" }
            break
        }
        default { throw "Unexpected endpoint: $Endpoint" }
    }
    if ($Paginated) {
        # Distinct pages exercise complete flattening, including object-shaped CI pages.
        $pages = [Collections.Generic.List[object]]::new()
        if ($Endpoint -match '/issues\?state=all') {
            $pages.Add(@($children[0..2]))
            $pages.Add(@($children[3..5]) + @(@{ number = 107; state = "open" }, $closedDependency))
        } elseif ($Endpoint -match '/check-runs|/actions/') { $pages.Add($value) }
        else { $pages.Add(@($value)) }
        ConvertTo-Json -InputObject $pages.ToArray() -Depth 100 -Compress
    } else { ConvertTo-Json -InputObject $value -Depth 100 -Compress }
}
try {
    $path = Join-Path $root "packet.json"
    $packet = Get-Agent4WorkPacket $state $path $fixtureReader
    Assert-True (($packet.candidates.issue -join ",") -eq "101,103,104,106") "Blocked candidates must not hide later work."
    Assert-True ($packet.candidates.Count -eq 4 -and $packet.blocked.Count -eq 2) "Return four tasks and exact exclusions."
    $evidence = Read-Agent4Json $path
    Assert-True ($evidence.issues.Count -eq 8) "Issue pagination must preserve both pages."
    Assert-True (@($observedReads | Where-Object { $_ -like "*closedByPullRequestsReferences*" }).Count -eq 1) "Closed dependency disposition must remain available for semantic delivery assessment."
    Assert-True ($evidence.discussions[0].comments.Count -eq 2) "All Discussion comment pages required."
    Assert-True ($evidence.discussions[0].comments[0].replies.Count -eq 2) "All reply pages required."
    Assert-True (@($observedReads | Where-Object { $_ -like "*pulls/200/files*" }).Count -eq 1) "PR diffs required."
    Assert-True ($evidence.reads.'jobs/300'[0].jobs[0].completed_at -eq "2026-11-15T10:04:01Z") "Retain complete job timing."
    $ordered = Get-Agent4WorkPacket $state (Join-Path $root "ordered.json") $fixtureReader @(101,102,103,104,105,106) "fixture://human-order"
    Assert-True (($ordered.candidates.issue -join ",") -eq "101") "Explicit blocked predecessor must prevent later offers."
    Assert-Fails {
        Get-Agent4WorkPacket $state (Join-Path $root "failed.json") { throw "GitHub collection failed" }
    } "*collection failed*"
    Assert-True (-not [IO.File]::Exists((Join-Path $root "failed.json"))) "Collection failure must not publish success evidence."
    $malformed = {
        param($Endpoint, $Paginated, $Query)
        if ($Endpoint -match '/check-runs') { return '[{}]' }
        & $fixtureReader $Endpoint $Paginated $Query
    }
    Assert-Fails { Get-Agent4WorkPacket $state (Join-Path $root "missing-ci.json") $malformed } "*truncated CI*"
    $wrongParent = {
        param($Endpoint, $Paginated, $Query)
        if ($Endpoint -match '/parent$') { return '{"number":191,"labels":[{"name":"type:epic"}]}' }
        & $fixtureReader $Endpoint $Paginated $Query
    }
    Assert-Fails { Get-Agent4WorkPacket $state (Join-Path $root "wrong-parent.json") $wrongParent } "*parent changed*"
    Assert-Fails { Get-Agent4WorkPacket $state (Join-Path $root "order.json") $fixtureReader @(101) "fixture://order" } "*cover the open native queue*"
    Write-Host "Agent4 paginated evidence and queue checks passed."
} finally {
    if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
}
