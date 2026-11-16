#Requires -Version 7.5
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EvidencePath,
    [string] $TimeZoneId = [TimeZoneInfo]::Local.Id,
    [string] $Directory = (Join-Path ([IO.Path]::GetTempPath()) "FingVibe-loop4-charts")
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "EpicChart.psm1") -Force

function Invoke-ChartGraphQl([string] $Query, [hashtable] $Variables) {
    $inputJson = @{ query = $Query; variables = $Variables } | ConvertTo-Json -Depth 20 -Compress
    $text = $inputJson | gh api --hostname github.com graphql --input -
    if ($LASTEXITCODE -ne 0) { throw "Chart Discussion GraphQL operation failed; do not blindly retry a write." }
    $response = ($text -join "`n") | ConvertFrom-Json -AsHashtable -DateKind String -Depth 100
    if ($response.errors -or -not $response.data) {
        throw "Chart Discussion GraphQL returned errors: $($response.errors.message -join '; ')"
    }
    $response.data
}

function Read-ChartRest([string] $Endpoint, [switch] $Paginated) {
    $text = if ($Paginated) { gh api --hostname github.com --paginate --slurp $Endpoint } else {
        gh api --hostname github.com $Endpoint
    }
    if ($LASTEXITCODE -ne 0) { throw "Chart evidence read failed: $Endpoint." }
    $value = ($text -join "`n") | ConvertFrom-Json -AsHashtable -DateKind String -Depth 100 -NoEnumerate
    if ($Paginated) {
        if ($value -isnot [array] -or @($value | Where-Object { $_ -isnot [array] }).Count) {
            throw "Incomplete chart evidence pages: $Endpoint."
        }
        return ,@($value | ForEach-Object { foreach ($item in $_) { $item } })
    }
    if ($value -isnot [hashtable]) { throw "Incomplete chart evidence object: $Endpoint." }
    $value
}

function Get-ChartDiscussion([string] $Repository, [int] $Epic, [int] $Number) {
    $owner, $name = $Repository.Split("/")
    $query = 'query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){nameWithOwner discussion(number:$number){id url body category{name}}}}'
    $context = (Invoke-ChartGraphQl $query @{ owner = $owner; name = $name; number = $Number }).repository
    $discussion = $context.discussion
    $markers = [regex]::Matches("$($discussion.body)", '<!--\s*fingvibe:epic=(\d+)\s*-->')
    if ($context.nameWithOwner -ine $Repository -or -not $discussion.id -or
        $discussion.category.name -cnotin @("Epic coordination", "🧭 Epic coordination") -or
        $markers.Count -ne 1 -or [int] $markers[0].Groups[1].Value -ne $Epic) {
        throw "Chart target does not match the repository, Epic marker and coordination category."
    }
    $discussion
}

function Get-ChartComments([string] $DiscussionId) {
    $comments = @(); $cursor = $null; $seen = @{}
    do {
        $query = 'query($id:ID!,$cursor:String){node(id:$id){... on Discussion{comments(first:100,after:$cursor){nodes{id body url createdAt updatedAt} pageInfo{hasNextPage endCursor}}}}}'
        $connection = (Invoke-ChartGraphQl $query @{ id = $DiscussionId; cursor = $cursor }).node.comments
        if ($null -eq $connection.pageInfo.hasNextPage -or $connection.nodes -isnot [array]) {
            throw "Incomplete chart throttle history."
        }
        $comments += $connection.nodes
        $cursor = $connection.pageInfo.endCursor
        if ($connection.pageInfo.hasNextPage) {
            if (-not $cursor -or $seen.ContainsKey($cursor)) { throw "Invalid chart comment pagination." }
            $seen[$cursor] = $true
        }
    } while ($connection.pageInfo.hasNextPage)
    return ,$comments
}

function Confirm-ChartComment([string] $Id, [string] $Body) {
    $query = 'query($id:ID!){node(id:$id){... on DiscussionComment{id body url createdAt updatedAt}}}'
    $comment = (Invoke-ChartGraphQl $query @{ id = $Id }).node
    if ($comment.id -cne $Id -or $comment.body -cne $Body -or -not $comment.url -or -not $comment.updatedAt) {
        throw "Chart comment readback failed; reconcile publication before retrying."
    }
    $comment
}

function Send-ChartImage([string] $Path, [long] $RepositoryId) {
    $filename = [Uri]::EscapeDataString([IO.Path]::GetFileName($Path))
    $uri = "https://uploads.github.com/user-attachments/assets?name=$filename&content_type=image%2Fpng&repository_id=$RepositoryId"
    $text = gh api --hostname github.com --method POST $uri -H "Content-Type: application/octet-stream" `
        -H "Accept: application/vnd.github+json" --input $Path
    if ($LASTEXITCODE -ne 0) { throw "GitHub chart upload failed; verify write access and supported attachment credentials." }
    $response = ($text -join "`n") | ConvertFrom-Json
    if ($response.url -notmatch '^https://github\.com/user-attachments/assets/[a-zA-Z0-9-]+$') {
        throw "GitHub upload did not return a persistent user-attachment URL."
    }
    $download = "$Path.download"
    try {
        # Native redirection preserves binary bytes in PowerShell 7.5 and uses gh's repository credentials.
        gh api --hostname github.com $response.url > $download
        if ($LASTEXITCODE -ne 0) { throw "Authenticated hosted chart verification failed." }
        if ((Get-FileHash -LiteralPath $Path).Hash -cne (Get-FileHash -LiteralPath $download).Hash) {
            throw "Hosted chart bytes do not match the generated PNG."
        }
    } finally {
        if (Test-Path -LiteralPath $download) { Remove-Item -LiteralPath $download }
    }
    $response.url
}

function Publish-EpicChart([string] $EvidencePath, [string] $TimeZoneId, [string] $Directory) {
    if (-not $IsWindows) { throw "Chart reporting requires local Windows." }
    $now = [DateTimeOffset]::UtcNow
    $evidence = Get-Content -LiteralPath $EvidencePath -Raw |
        ConvertFrom-Json -AsHashtable -DateKind String -Depth 100
    $repository = "$($evidence.repository)"; $epic = [int] $evidence.epic
    if ($evidence.schema -cne "fingvibe-loop4-evidence-v1" -or
        $repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or $epic -le 0 -or -not $evidence.utc) {
        throw "A valid loop4 packet evidence artifact is required."
    }
    $age = $now - [DateTimeOffset] $evidence.utc
    if ($age.TotalSeconds -lt 0) { throw "Chart packet timestamp is in the future; check clock." }
    $timezone = [TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)
    $matches = @($evidence.discussions | Where-Object {
        $_.category.name -cin @("Epic coordination", "🧭 Epic coordination") -and
        "$($_.body)" -match "<!--\s*fingvibe:epic=$epic\s*-->"
    })
    if ($matches.Count -ne 1) { throw "Exactly one marked Epic coordination Discussion is required." }
    $discussion = Get-ChartDiscussion $repository $epic $matches[0].number
    $comments = Get-ChartComments $discussion.id
    if (-not (Test-EpicChartDue $comments $epic $now)) {
        return @{ status = "throttled"; epic = $epic; discussion = $discussion.url }
    }
    $repo = $evidence.reads["repos/$repository|False|"]
    $epicIssue = $evidence.reads["repos/$repository/issues/$epic|False|"]
    $childKey = "repos/$repository/issues/$epic/sub_issues?per_page=100|True|"
    if (-not $evidence.reads.ContainsKey($childKey)) { throw "Packet native-child inventory is missing." }
    $children = @($evidence.reads[$childKey])
    if ($age.TotalMinutes -gt 10) {
        # Reporting runs last; a long coordination cycle must not reuse stale task states.
        $repo = Read-ChartRest "repos/$repository"
        $epicIssue = Read-ChartRest "repos/$repository/issues/$epic"
        $children = @(Read-ChartRest "repos/$repository/issues/$epic/sub_issues?per_page=100" -Paginated |
            ForEach-Object { $_ })
    }
    if (-not $repo.id -or $repo.full_name -ine $repository -or
        $epicIssue.number -ne $epic -or "type:epic" -notin $epicIssue.labels.name -or -not $epicIssue.created_at) {
        throw "Packet repository/Epic/native-child evidence is incomplete."
    }
    if (@($children.number | Sort-Object -Unique).Count -ne $children.Count -or
        @($children | Where-Object { -not $_.number -or $_.pull_request }).Count) {
        throw "Invalid native child cohort."
    }
    $histories = @{}
    foreach ($child in $children) {
        $histories[[int] $child.number] = @(Read-ChartRest "repos/$repository/issues/$($child.number)/timeline?per_page=100" -Paginated |
            ForEach-Object { $_ })
    }
    $report = Get-EpicChartSnapshots $children $histories ([DateTimeOffset] $epicIssue.created_at) $now $timezone
    $null = New-Item -ItemType Directory -Path $Directory -Force
    $image = Join-Path $Directory ("epic-$epic-" + [guid]::NewGuid() + ".png")
    Save-EpicChart $report $epic $image

    $pending = Get-EpicChartMarker $epic pending
    $body = "$pending`n`nPreparing an hourly Epic chart. If this remains pending, reconcile this publication before retrying."
    $reserve = 'mutation($id:ID!,$body:String!){addDiscussionComment(input:{discussionId:$id,body:$body}){comment{id url}}}'
    $reservation = (Invoke-ChartGraphQl $reserve @{ id = $discussion.id; body = $body }).addDiscussionComment.comment
    if (-not $reservation.id) { throw "Chart reservation outcome uncertain; inspect $($discussion.url) before retrying." }
    try {
        $null = Confirm-ChartComment $reservation.id $body
        $others = @(Get-ChartComments $discussion.id | ForEach-Object { $_ } | Where-Object { $_.id -cne $reservation.id })
        if (-not (Test-EpicChartDue $others $epic ([DateTimeOffset]::UtcNow))) {
            throw "Another chart was published during collection; reconcile this reservation."
        }
        $url = Send-ChartImage $image ([long] $repo.id)
        $last = $report.snapshots[-1]
        $at = [TimeZoneInfo]::ConvertTime($now, $timezone).ToString("yyyy-MM-dd HH:mm zzz")
        $published = Get-EpicChartMarker $epic published
        $body = @"
$published

### Hourly Epic progress - $at

![Epic $epic stacked task status and cumulative trend lines]($url)

**Completed:** $($last.completed) | **In progress:** $($last.inProgress) | **Not started:** $($last.notStarted) | **Total:** $($last.total).

Timezone: $($timezone.Id). Green = completed; orange = in progress (including review/CI waits); red = not started. Lines follow cumulative stack tops; gray dashed reference = total.

Current native child cohort: $(($children.number | Sort-Object | ForEach-Object { "#$_" }) -join ', '). Historical membership is not reconstructed. Latest 24 hourly snapshots plus the current partial hour; task lifecycle timestamps, not coding-time estimates.
"@
        if ($report.warnings.Count) { $body += "`n`nEvidence notes: " + ($report.warnings -join " ") }
        $update = 'mutation($id:ID!,$body:String!){updateDiscussionComment(input:{commentId:$id,body:$body}){comment{id}}}'
        $null = Invoke-ChartGraphQl $update @{ id = $reservation.id; body = $body }
        $verified = Confirm-ChartComment $reservation.id $body
        @{ status = "published"; epic = $epic; url = $verified.url; image = $url; path = $image }
    } catch {
        throw "Chart publication failed or is uncertain. Reconcile $($reservation.url) before retrying. $($_.Exception.Message)"
    }
}

if ($MyInvocation.InvocationName -ne ".") {
    Publish-EpicChart $EvidencePath $TimeZoneId $Directory | ConvertTo-Json -Depth 10
}
