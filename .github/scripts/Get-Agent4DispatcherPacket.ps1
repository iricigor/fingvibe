[CmdletBinding()]
param(
    [string] $Repository = "iricigor/fingvibe",
    [int] $Epic,
    [string] $Directory,
    [int[]] $TaskOrder,
    [string] $OrderEvidence
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "Agent4Coordination.psm1") -Force -DisableNameChecking

function Invoke-Agent4GitHubRead([string] $Endpoint, [bool] $Paginated, [string] $Query) {
    $text = if ($Query) {
        gh api graphql -f query=$Query
    } elseif ($Paginated) {
        gh api --paginate --slurp $Endpoint
    } else { gh api $Endpoint }
    if ($LASTEXITCODE -ne 0) { throw "GitHub evidence collection failed: $Endpoint." }
    $text -join "`n"
}

function Get-Agent4WorkPacket($State, [string] $EvidencePath, [scriptblock] $Reader,
    [int[]] $Order, [string] $OrderingEvidence) {
    Assert-Agent4State $State
    $config = $State.configuration
    $repository = $config.repository
    $cache = @{}
    function Read-Evidence([string] $Endpoint, [bool] $Paginated = $false, [string] $Query) {
        $key = "$Endpoint|$Paginated|$Query"
        if ($cache.ContainsKey($key)) { return ,$cache[$key] }
        $json = & $Reader $Endpoint $Paginated $Query
        if ($json -isnot [string] -or [string]::IsNullOrWhiteSpace($json)) { throw "Missing evidence: $Endpoint." }
        $parsed = $json | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String -NoEnumerate
        if ($Paginated) {
            if ($parsed -isnot [array] -or @($parsed | Where-Object { $_ -isnot [array] }).Count) {
                throw "Expected complete paginated pages: $Endpoint."
            }
            $value = @($parsed | ForEach-Object { foreach ($item in $_) { $item } })
        } else {
            if ($parsed -isnot [hashtable] -or $parsed.errors) { throw "Invalid GitHub evidence: $Endpoint." }
            $value = $parsed
        }
        $cache[$key] = $value
        return ,$value
    }
    function Read-Connection([string] $NodeId, [string] $Field) {
        $all = @(); $cursor = $null; $seen = @{}
        do {
            $after = if ($cursor) { ',after:"' + $cursor + '"' } else { "" }
            $selection = 'id body url author { login } createdAt updatedAt'
            $type = if ($Field -eq "comments") { "Discussion" } else { "DiscussionComment" }
            $query = 'query { node(id:"' + $NodeId + '") { ... on ' + $type + ' { ' +
                $Field + '(first:100' + $after + ') { nodes { ' + $selection +
                ' } pageInfo { hasNextPage endCursor } } } } }'
            $result = Read-Evidence graphql $false $query
            $connection = $result.data.node[$Field]
            if (-not $connection -or $null -eq $connection.pageInfo.hasNextPage -or
                $connection.nodes -isnot [array]) { throw "Incomplete Discussion $Field." }
            $all += $connection.nodes
            $cursor = $connection.pageInfo.endCursor
            if ($connection.pageInfo.hasNextPage) {
                if (-not $cursor -or $seen.ContainsKey($cursor)) { throw "Invalid Discussion pagination." }
                $seen[$cursor] = $true
            }
        } while ($connection.pageInfo.hasNextPage)
        return ,$all
    }

    $repo = Read-Evidence "repos/$repository"
    if ($repo.full_name -ine $repository -or $repo.default_branch -cne $config.targetBranch) {
        throw "Repository identity/default branch changed."
    }
    $epic = Read-Evidence "repos/$repository/issues/$($config.epic)"
    if ($epic.number -ne $config.epic -or "type:epic" -notin $epic.labels.name -or $epic.state -ne "open") {
        throw "Configured Epic is not an open type:epic issue."
    }
    $issues = Read-Evidence "repos/$repository/issues?state=all&per_page=100" $true
    $comments = Read-Evidence "repos/$repository/issues/comments?per_page=100" $true
    $children = Read-Evidence "repos/$repository/issues/$($config.epic)/sub_issues?per_page=100" $true
    $pulls = Read-Evidence "repos/$repository/pulls?state=open&per_page=100" $true
    foreach ($pr in $pulls) {
        if (-not $pr.number -or -not $pr.head.sha) { throw "Incomplete open PR." }
        $null = Read-Evidence "repos/$repository/pulls/$($pr.number)/files?per_page=100" $true
        $null = Read-Evidence "repos/$repository/pulls/$($pr.number)/reviews?per_page=100" $true
        $null = Read-Evidence "repos/$repository/commits/$($pr.head.sha)/statuses?per_page=100" $true
        # Check-runs and Actions are objects with nested arrays; paginate them explicitly.
        foreach ($route in @("commits/$($pr.head.sha)/check-runs", "actions/runs?head_sha=$($pr.head.sha)")) {
            $separator = if ($route.Contains("?")) { "&" } else { "?" }
            $pages = & $Reader "repos/$repository/$route${separator}per_page=100" $true $null
            $parsed = $pages | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String -NoEnumerate
            if ($parsed -isnot [array] -or @($parsed | Where-Object { $_ -isnot [hashtable] }).Count) {
                throw "Incomplete paginated CI evidence."
            }
            $field = if ($route.StartsWith("actions/")) { "workflow_runs" } else { "check_runs" }
            if (@($parsed).Count -eq 0 -or @($parsed | Where-Object {
                $_[$field] -isnot [array] -or $null -eq $_.total_count
            }).Count -or @($parsed | ForEach-Object { foreach ($item in $_[$field]) { $item } }).Count -ne $parsed[0].total_count) {
                throw "Missing/truncated CI inventory."
            }
            $cache[$route] = $parsed
            if ($route.StartsWith("actions/")) {
                foreach ($run in @($parsed | ForEach-Object { $_.workflow_runs })) {
                    $jobs = & $Reader "repos/$repository/actions/runs/$($run.id)/jobs?per_page=100" $true $null
                    $jobPages = $jobs | ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String -NoEnumerate
                    if ($jobPages -isnot [array] -or @($jobPages | Where-Object { $_ -isnot [hashtable] }).Count) {
                        throw "Incomplete regression job evidence."
                    }
                    if (@($jobPages).Count -eq 0 -or @($jobPages | Where-Object {
                        $_.jobs -isnot [array] -or $null -eq $_.total_count
                    }).Count -or @($jobPages | ForEach-Object { foreach ($job in $_.jobs) { $job } }).Count -ne $jobPages[0].total_count) {
                        throw "Missing/truncated regression job inventory."
                    }
                    $cache["jobs/$($run.id)"] = $jobPages
                }
            }
        }
    }
    $parts = $repository.Split("/")
    $discussions = @(); $cursor = $null; $seen = @{}
    do {
        $after = if ($cursor) { ',after:"' + $cursor + '"' } else { "" }
        $query = 'query { repository(owner:"' + $parts[0] + '",name:"' + $parts[1] +
            '") { discussions(first:100' + $after + ') { nodes { id number title body url author { login } ' +
            'category { name } createdAt updatedAt } pageInfo { hasNextPage endCursor } } } }'
        $result = Read-Evidence graphql $false $query
        $connection = $result.data.repository.discussions
        if (-not $connection -or $null -eq $connection.pageInfo.hasNextPage -or
            $connection.nodes -isnot [array]) { throw "Discussion collection is unavailable." }
        foreach ($discussion in $connection.nodes) {
            $discussion.comments = Read-Connection $discussion.id comments
            foreach ($comment in $discussion.comments) { $comment.replies = Read-Connection $comment.id replies }
            $discussions += $discussion
        }
        $cursor = $connection.pageInfo.endCursor
        if ($connection.pageInfo.hasNextPage) {
            if (-not $cursor -or $seen.ContainsKey($cursor)) { throw "Invalid Discussion inventory pagination." }
            $seen[$cursor] = $true
        }
    } while ($connection.pageInfo.hasNextPage)

    $byNumber = @{}
    foreach ($issue in $issues) {
        if (-not $issue.number -or $byNumber.ContainsKey([int] $issue.number)) { throw "Incomplete/duplicate issue inventory." }
        $byNumber[[int] $issue.number] = $issue
    }
    $open = @($children | Where-Object state -EQ open)
    if (@($children.number | Sort-Object -Unique).Count -ne @($children).Count) {
        throw "Duplicate native child inventory."
    }
    if ($Order) {
        if (-not $OrderingEvidence -or @($Order | Sort-Object -Unique).Count -ne $Order.Count -or
            @($Order | Where-Object { $_ -notin $children.number }).Count) { throw "Invalid explicit human ordering." }
        if (@($open | Where-Object { $_.number -notin $Order }).Count) { throw "Explicit order must cover the open native queue." }
        $open = @($open | Sort-Object { [array]::IndexOf($Order, [int] $_.number) })
    } else { $open = @($open | Sort-Object number) }
    $candidates = @(); $blocked = @(); $orderingBlocked = $false
    foreach ($child in $open) {
        if (-not $byNumber.ContainsKey([int] $child.number)) { throw "Native child inventory mismatch." }
        $parent = Read-Evidence "repos/$repository/issues/$($child.number)/parent"
        if ($parent.number -ne $config.epic -or "type:epic" -notin $parent.labels.name) { throw "Native parent changed." }
        $dependencies = Read-Evidence "repos/$repository/issues/$($child.number)/dependencies/blocked_by?per_page=100" $true
        if (@($dependencies.number | Sort-Object -Unique).Count -ne @($dependencies).Count) {
            throw "Duplicate native dependencies."
        }
        foreach ($dependency in $dependencies) {
            if (-not $byNumber.ContainsKey([int] $dependency.number)) { throw "Unknown dependency in repository inventory." }
            if ($dependency.state -eq "closed") {
                $deliveryCursor = $null; $deliverySeen = @{}
                do {
                    $after = if ($deliveryCursor) { ',after:"' + $deliveryCursor + '"' } else { "" }
                    $query = 'query { repository(owner:"' + $parts[0] + '",name:"' + $parts[1] +
                        '") { issue(number:' + $dependency.number + ') { state stateReason ' +
                        'closedByPullRequestsReferences(first:100' + $after +
                        ') { nodes { number url merged baseRefName mergedAt } pageInfo { hasNextPage endCursor } } } } }'
                    $delivery = Read-Evidence graphql $false $query
                    $connection = $delivery.data.repository.issue.closedByPullRequestsReferences
                    if (-not $connection -or $null -eq $connection.pageInfo.hasNextPage) {
                        throw "Unavailable dependency delivery evidence."
                    }
                    $deliveryCursor = $connection.pageInfo.endCursor
                    if ($connection.pageInfo.hasNextPage) {
                        if (-not $deliveryCursor -or $deliverySeen.ContainsKey($deliveryCursor)) { throw "Invalid delivery pagination." }
                        $deliverySeen[$deliveryCursor] = $true
                    }
                } while ($connection.pageInfo.hasNextPage)
            }
        }
        $reason = $null
        if ($child.pull_request -or "type:task" -notin $child.labels.name -or "type:epic" -in $child.labels.name) {
            $reason = "Not a native task child."
        } elseif ("human-task" -in $child.labels.name) { $reason = "Human intervention required." }
        elseif ($child.number -in @($State.claims | Where-Object stage -NE released).issue) { $reason = "Retained loop4 claim." }
        elseif ($child.number -in @($State.offers | Where-Object status -IN @("offered", "correlated") |
            ForEach-Object { $_.candidates.issue })) { $reason = "Pending offer/assessment; do not duplicate uncertain delivery." }
        elseif (@($dependencies | Where-Object state -NE closed).Count) { $reason = "Open native dependency." }
        elseif (@($child.labels.name | Where-Object { $_ -in @("active", "status:review", "status:blocked") }).Count) {
            $reason = "Retained lifecycle/blocked ownership requires reconciliation."
        } elseif ($orderingBlocked) { $reason = "Explicit human predecessor order is blocked." }
        if ($reason) {
            $blocked += @{ issue = $child.number; reason = $reason; url = $child.html_url }
            if ($Order) { $orderingBlocked = $true }
        } else {
            $candidates += @{ issue = $child.number; url = $child.html_url; labels = $child.labels.name
                dependencies = $dependencies; semanticAssessmentRequired = $true }
        }
    }
    Write-Agent4Json $EvidencePath @{
        schema = "fingvibe-loop4-evidence-v1"; utc = [DateTimeOffset]::UtcNow.ToString("o")
        repository = $repository; epic = $config.epic; revision = $State.revision
        reads = $cache; discussions = $discussions; issues = $issues; comments = $comments; pulls = $pulls
        order = $Order; orderEvidence = $OrderingEvidence
    }
    @{
        schema = "fingvibe-loop4-packet-v1"; repository = $repository; epic = $config.epic
        targetBranch = $config.targetBranch; revision = $State.revision; evidencePath = $EvidencePath
        candidates = @($candidates | Select-Object -First 4); blocked = $blocked
        retainedClaims = @($State.claims | Where-Object stage -NE released)
        pendingOffers = @($State.offers | Where-Object status -IN @("offered", "correlated"))
        assessment = "Review full evidence, original authority, native/body dependency delivery, foreign claims, diffs and all proposals before accepting."
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    $environment = Get-Agent4Environment $Repository $Epic $Directory
    $state = $environment.state
    $Directory = $environment.directory
    $path = Join-Path $Directory ("evidence\" + [guid]::NewGuid() + ".json")
    $packet = Get-Agent4WorkPacket $state $path ${function:Invoke-Agent4GitHubRead} $TaskOrder $OrderEvidence
    $packet.directory = $Directory
    $packet | ConvertTo-Json -Depth 100
}
