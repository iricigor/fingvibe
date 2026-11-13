$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "..\.github\scripts\Agent3Coordination.psm1") -Force
$root = Join-Path ([IO.Path]::GetTempPath()) ("fingvibe-discussion-test-" + [guid]::NewGuid())
$gateRoot = Join-Path $root "gates"
$owner = [guid]::NewGuid()
$gateScript = Join-Path $PSScriptRoot "..\.github\scripts\Invoke-Agent3DispatcherGate.ps1"

function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    try { & $Action | Out-Null }
    catch { if ($_.Exception.Message -notlike $Pattern) { throw }; return }
    throw "Expected failure matching '$Pattern'."
}

$store = @{ discussions = @(); writes = 0; next = 100; mode = "success"; paginated = $false; categoryMissing = $false
    issue = @{id="I-100";body="## Goal`nPreserve scope and acceptance.";url="https://github.com/testowner/testrepo/issues/100"} }
$categoryNames = @("🛠️ Task conversations", "🧭 Epic coordination", "🤖 Agent logs")
$labels = @(@{id="label-0";name="3️⃣disp"}, @{id="label-1";name="3️⃣dev1"}, @{id="label-2";name="3️⃣dev2"})
$api = {
    param($query, $variables, $directory)
    if ($query.StartsWith("mutation")) {
        $store.writes++
        if ($store.mode -ceq "pre-request") {
            $error = [InvalidOperationException]::new("Fixture process did not start.")
            $error.Data["agent3PublicationPhase"] = "pre-request"
            throw $error
        }
        if ($store.mode -ceq "uncertain-absent") { throw "Remote outcome uncertain." }
        if ($query.Contains("createDiscussion(")) {
            $input = $variables.input
            $number = $store.next++
            $discussion = @{id="D-$number"; number=$number;title=$input.title;body=$input.body
                url="https://github.com/testowner/testrepo/discussions/$number"
                repository=@{nameWithOwner="testowner/testrepo"};author=@{login="testowner"}
                category=@{id=$input.categoryId;name=$categoryNames[[int]($input.categoryId -replace 'category-','')]}
                labels=@{nodes=@();pageInfo=@{hasNextPage=$false}};entries=@()}
            $store.discussions += $discussion
            if ($store.mode -ceq "lost-create") { throw "Creation response lost." }
            return @{createDiscussion=@{discussion=@{id=$discussion.id}}}
        }
        if ($query.Contains("addLabelsToLabelable(")) {
            $discussion = @($store.discussions | Where-Object id -CEQ $variables.input.labelableId)[0]
            $discussion.labels.nodes = @($labels | Where-Object id -In $variables.input.labelIds)
            return @{addLabelsToLabelable=@{clientMutationId=$null}}
        }
        if ($query.Contains("updateIssue(")) {
            $store.issue.body = $variables.input.body
            return @{updateIssue=@{issue=@{id=$store.issue.id}}}
        }
        if ($query.Contains("addDiscussionComment(") -or $query.Contains("updateDiscussionComment(")) {
            if ($query.Contains("updateDiscussionComment(")) {
                $discussion = @($store.discussions | Where-Object { $_.entries.id -contains $variables.input.commentId })[0]
                $comment = @($discussion.entries | Where-Object id -CEQ $variables.input.commentId)[0]
                $comment.body = $variables.input.body
            } else {
                $discussion = @($store.discussions | Where-Object id -CEQ $variables.input.discussionId)[0]
                if ($store.mode -ceq "index-failure" -and $discussion.category.name -ceq "🤖 Agent logs") { throw "Index API throttled." }
                $number = $store.next++
                $comment = @{id="C-$number";body=$variables.input.body;author=@{login="testowner"};authorAssociation="OWNER"
                    discussion=@{id=$discussion.id};url="$($discussion.url)#discussioncomment-$number"
                    replies=@{nodes=@();pageInfo=@{hasNextPage=$false;endCursor=$null}}}
                $discussion.entries += $comment
            }
            if ($store.mode -ceq "lost-comment") { throw "Comment response lost." }
            return @{addDiscussionComment=@{comment=@{id=$comment.id}};updateDiscussionComment=@{comment=@{id=$comment.id}}}
        }
        throw "Unexpected fixture mutation: $query"
    }
    if ($query.Contains("repository(owner:")) {
        if ($query.Contains("issue(number:")) { return @{repository=@{issue=$store.issue}} }
        $items = $store.discussions
        $more = $false
        if ($store.paginated -and $items.Count -gt 1) {
            if ($null -eq $variables.cursor) { $items = @($items[0]); $more = $true }
            else { $items = @($items | Select-Object -Skip 1) }
        }
        $categories = @()
        for ($i=0; $i -lt $categoryNames.Count; $i++) {
            if (-not $store.categoryMissing -or $i -ne 0) { $categories += @{id="category-$i";name=$categoryNames[$i]} }
        }
        return @{repository=@{id="repo-id";dispatcher=$labels[0];developer1=$labels[1];developer2=$labels[2]
            discussionCategories=@{nodes=$categories;pageInfo=@{hasNextPage=$false}}
            discussions=@{nodes=@($items);pageInfo=@{hasNextPage=$more;endCursor=$(if($more){"next"}else{$null})}}}}
    }
    if ($query.Contains("... on DiscussionComment")) {
        return @{node=@{id=$variables.id;replies=@{nodes=@($store.extraReply);pageInfo=@{hasNextPage=$false;endCursor=$null}}}}
    }
    $matches = @($store.discussions | Where-Object id -CEQ $variables.id)
    if ($matches.Count -eq 0) { return @{node=$null} }
    $discussion = $matches[0]
    if ($query.Contains("comments(first:")) {
        $items = @($discussion.entries)
        $more = $false
        if ($store.paginated -and $items.Count -gt 1) {
            if ($null -eq $variables.cursor) { $items = @($items[0]); $more = $true }
            else { $items = @($items | Select-Object -Skip 1) }
        }
        return @{node=@{id=$discussion.id;comments=@{nodes=$items;pageInfo=@{hasNextPage=$more;endCursor=$(if($more){"next"}else{$null})}}}}
    }
    return @{node=$discussion}
}

try {
    $null = & $gateScript -Action Acquire -Repository testowner/testrepo -Owner $owner -StateDirectory $gateRoot
    $setup = @{Repository="testowner/testrepo";ActorLogin="testowner";Directory=$root;GateOwner=$owner;GateDirectory=$gateRoot;Api=$api}
    $wrongGate = @{} + $setup
    $wrongGate.GateOwner = [guid]::NewGuid()
    Assert-Throws { Initialize-Agent3Discussion -Kind task -Key 100 @wrongGate } "*existing gate*"
    $store.categoryMissing=$true
    Assert-Throws { Initialize-Agent3Discussion -Kind task -Key 100 @setup } "*category missing*"
    $store.categoryMissing=$false
    $store.mode="lost-create"
    Assert-Throws { Initialize-Agent3Discussion -Kind task -Key 100 @setup } "*response lost*"
    $writes=$store.writes
    $store.mode="success"
    $task = Initialize-Agent3Discussion -Kind task -Key 100 @setup
    if ($store.writes -ne $writes+1) { throw "Lost creation must be found, not repeated; only labels may be written." }
    $same = Initialize-Agent3Discussion -Kind task -Key 100 @setup
    if ($same.id -cne $task.id -or $store.discussions.Count -ne 1) { throw "Task mapping must be reused." }
    $initialIssue = $store.issue.body
    $null = Publish-Agent3IssueDiscussionLink $task $root $owner $gateRoot $api
    $writes = $store.writes
    $null = Publish-Agent3IssueDiscussionLink $task $root $owner $gateRoot $api
    if ($store.writes -ne $writes -or -not $store.issue.body.StartsWith($initialIssue) -or
        -not $store.issue.body.Contains($task.url)) { throw "Issue link must preserve existing body and never republish unchanged content." }
    $agent = Initialize-Agent3Discussion -Kind agent -Key developer-1 @setup
    $epic = Initialize-Agent3Discussion -Kind epic -Key 92 @setup
    foreach ($kind in @("ideas","corners","problems")) { $null = Initialize-Agent3Discussion -Kind $kind -Key 92 @setup }
    $existing = $store.discussions[1] | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
    $existing.id="D-existing"; $existing.number=999; $existing.url="https://github.com/testowner/testrepo/discussions/999"
    $existing.body=""; $existing.entries=@(); $existing.labels.nodes=@($labels[2])
    $store.discussions += $existing
    $writes=$store.writes
    $registered = Initialize-Agent3Discussion -Kind agent -Key developer-2 -ExistingId $existing.id @setup
    if ($store.writes -ne $writes -or $registered.openingBody -cne "") { throw "Explicit clean-log registration must preserve its empty opening without recreation." }
    $store.paginated=$true
    $cycleApi = {
        param($query, $variables, $directory)
        $data = & $api $query $variables $directory
        $next = if ($variables.cursor -ceq "cursor-a") { "cursor-b" } else { "cursor-a" }
        $page = if ($query.Contains("repository(owner:")) { $data.repository.discussions } else { $data.node.comments }
        $page.nodes=@(); $page.pageInfo=@{hasNextPage=$true;endCursor=$next}
        return $data
    }
    Assert-Throws { Get-Agent3DiscussionClaims testowner/testrepo $root $cycleApi } "*Invalid Discussion cursor*"
    Assert-Throws { Get-Agent3DiscussionComments $task.id $root $cycleApi } "*Invalid comment cursor*"

    $claim = @{schema="fingvibe-real-claim-v1";repository="testowner/testrepo";issue=100;claimId=[guid]::NewGuid().ToString()
        path='D:\Igor\"quoted"';head="a"*40}
    $text = "<!-- control -->`nImplementation checkpoint ready.`n`n" + ('D:\Igor\"quoted" {"nested":"C:\\Users\\worker"}' * 1000)
    $report = Publish-Agent3DiscussionReport $task $agent checkpoint $text testowner developer-1 "2026-11-13T19:00:00Z" $root $api -Claim $claim
    $canonical = @($store.discussions | Where-Object id -CEQ $task.id)[0].entries[0]
    if (-not $canonical.body.Contains("<details><summary>Claim details</summary>") -or
        -not $canonical.body.Contains($claim.path) -or $canonical.body.Split("`n")[0] -notlike "_**3️⃣ Developer 1** *") {
        throw "Compact header and collapsed claim must retain exact payload."
    }
    $index = @($store.discussions | Where-Object id -CEQ $agent.id)[0].entries[0]
    if (-not $index.body.Contains("Implementation checkpoint ready.") -or $index.body.Contains($claim.path)) {
        throw "Index must include first prose line, not full logs or JSON."
    }
    $before=$store.writes
    $null = Publish-Agent3DiscussionReport $task $agent checkpoint $text testowner developer-1 "2026-11-13T19:00:00Z" $root $api -Claim $claim
    if ($store.writes -ne $before) { throw "Duplicate report must not publish again." }
    $claims = Get-Agent3DiscussionClaims testowner/testrepo $root $api
    if ($claims.Count -ne 1 -or $claims[0].claim.claimId -cne $claim.claimId -or
        $claims[0].claim.path -cne $claim.path) { throw "Collapsed claim discovery must preserve escaped JSON values." }
    $canonical.body = $canonical.body.Replace('"schema": "fingvibe-real-claim-v1"', '"schema": "invalid"')
    Assert-Throws { Get-Agent3DiscussionClaims testowner/testrepo $root $api } "*Uncorrelated Discussion claim*"
    $canonical.body = $report.canonical.identity.body
    $canonical.body += "`nchanged"
    Assert-Throws { Publish-Agent3DiscussionReport $task $agent checkpoint $text testowner developer-1 "2026-11-13T19:00:00Z" $root $api -Claim $claim } "*readback mismatch*"
    $canonical.body = $report.canonical.identity.body

    $store.mode="index-failure"
    $pending = Publish-Agent3DiscussionReport $task $agent pending "A new checkpoint." testowner developer-1 "2026-11-13T19:01:00Z" $root $api -WarningVariable warning
    if ($pending.indexStatus -cne "pending" -or -not $pending.canonical.url -or -not $warning) {
        throw "Index failure must be explicit and nonblocking after canonical success."
    }
    $store.mode="success"
    $pendingAgain = Publish-Agent3DiscussionReport $task $agent pending "A new checkpoint." testowner developer-1 "2026-11-13T19:01:00Z" $root $api -WarningVariable warning
    if ($pendingAgain.indexStatus -cne "pending") { throw "An uncertain missing index must not be blindly retried." }

    $store.mode="lost-comment"
    $body = "Exact escaped JSON D:\Igor`n<!-- agent3-publication:lost -->"
    Assert-Throws { Publish-Agent3DiscussionComment $task lost $body testowner $root $api } "*response lost*"
    $afterLost=$store.writes
    $store.mode="success"
    $null = Publish-Agent3DiscussionComment $task lost $body testowner $root $api
    if ($store.writes -ne $afterLost) { throw "Lost response must reconcile existing comment without another mutation." }
    $store.mode="uncertain-absent"
    Assert-Throws { Publish-Agent3DiscussionComment $task unknown "<!-- agent3-publication:unknown -->" testowner $root $api } "*uncertain*"
    $afterUnknown=$store.writes
    $store.mode="success"
    Assert-Throws { Publish-Agent3DiscussionComment $task unknown "<!-- agent3-publication:unknown -->" testowner $root $api } "*already attempted*"
    if ($store.writes -ne $afterUnknown) { throw "Missing readback cannot authorize uncertain retry." }

    $store.mode="pre-request"
    Assert-Throws { Publish-Agent3DiscussionComment $task pre "<!-- agent3-publication:pre -->" testowner $root $api } "*did not start*"
    $store.mode="success"
    $null = Publish-Agent3DiscussionComment $task pre "<!-- agent3-publication:pre -->" testowner $root $api
    $revision = "New claim revision.`n<!-- agent3-publication:revision -->"
    Assert-Throws { Publish-Agent3DiscussionComment $task revision $revision testowner $root $api -CommentId $canonical.id -ExpectedBody stale } "*expected body*"
    $null = Publish-Agent3DiscussionComment $task revision $revision testowner $root $api -CommentId $canonical.id -ExpectedBody $canonical.body
    if ($canonical.body -cne $revision) { throw "Claim revision must preserve comment identity." }

    if ((Get-Agent3FirstMessageLine "<!-- marker -->`n``````json`n{}`n``````") -cne "") { throw "JSON-only message must not invent a preview." }
    $times = New-Agent3DiscussionBody developer-1 "Hello" "2026-11-13T19:00:00Z" "2026-11-13T19:01:00Z"
    if ($times.Split("`n")[0] -notlike "*Created UTC:*Updated UTC:*") { throw "Different timestamps must both remain in one header." }
    $originalIssue = "## Goal`nPreserve scope.`n- [ ] acceptance"
    $linked = New-Agent3TaskDiscussionLink $originalIssue $task
    if (-not $linked.StartsWith($originalIssue) -or (New-Agent3TaskDiscussionLink $linked $task) -cne $linked) {
        throw "Issue link updates must preserve scope and be idempotent."
    }
    $store.extraReply = @{id="C-reply";body="Historical reply";url="$($task.url)#discussioncomment-999";author=@{login="testowner"};authorAssociation="OWNER";discussion=@{id=$task.id}}
    $first = @($store.discussions | Where-Object id -CEQ $task.id)[0].entries[0]
    $first.replies = @{nodes=@();pageInfo=@{hasNextPage=$true;endCursor="reply-next"}}
    $all = Get-Agent3DiscussionComments $task.id $root $api
    if ($store.extraReply.id -cnotin $all.id) { throw "Historical paginated replies must not be skipped." }

    $taskRemote = @($store.discussions | Where-Object id -CEQ $task.id)[0]
    $oldOpening=$taskRemote.body
    $taskRemote.body += "`n<!-- fingvibe-agent3-discussion:task-101 -->"
    Assert-Throws { Get-Agent3DiscussionClaims testowner/testrepo $root $api } "*Ambiguous task Discussion scope*"
    $taskRemote.body=$oldOpening
    $mappingPath=Join-Path $root "discussions\task-100.json"
    $originalMapping=[IO.File]::ReadAllText($mappingPath)
    $badMapping=ConvertFrom-Json $originalMapping -AsHashtable
    $badMapping.labels=@()
    [IO.File]::WriteAllText($mappingPath, ($badMapping | ConvertTo-Json -Depth 100))
    Assert-Throws { Get-Agent3MappedDiscussion testowner/testrepo task 100 $root $api } "*mapping mismatch*"
    [IO.File]::WriteAllText($mappingPath, $originalMapping)
    $taskRemote.category.name="🤖 Agent logs"
    Assert-Throws { Get-Agent3MappedDiscussion testowner/testrepo task 100 $root $api } "*missing or changed*"
    $taskRemote.category.name="🛠️ Task conversations"
    $taskRemote.body="edited"
    Assert-Throws { Get-Agent3MappedDiscussion testowner/testrepo task 100 $root $api } "*missing or changed*"
    $taskRemote.body=$oldOpening
    $store.discussions = @($store.discussions | Where-Object id -CNE $task.id)
    Assert-Throws { Initialize-Agent3Discussion -Kind task -Key 100 @setup } "*missing or changed*"

    $module = Get-Module Agent3Coordination
    & $module {
        param($Directory)
        function script:Invoke-Agent3GitHubWrite {
            param($Endpoint, $InputPath, $Method)
            if ($Endpoint -cne "graphql" -or $Method -cne "POST") { throw "Discussion request must use file-backed GraphQL." }
            $script:requestProbe = Read-Agent3Json $InputPath
            $script:requestProbePath = $InputPath
            '{"data":{"ok":true}}'
        }
        $large = 'D:\Igor\"quoted" {"nested":"C:\\Users\\worker"}' * 2000
        $null = Invoke-Agent3DiscussionApi 'query($body:String!){node(id:$body){id}}' @{body=$large} $Directory
        if ($script:requestProbe.variables.body -cne $large -or
            [Text.Encoding]::UTF8.GetByteCount($large) -le 32767 -or
            [IO.File]::Exists($script:requestProbePath)) {
            throw "Large escaped Discussion body must survive actual request-file serialization and temporary cleanup."
        }
    } $root
    "Agent-3 Discussion tests passed."
} finally {
    $null = & $gateScript -Action Release -Repository testowner/testrepo -Owner $owner -StateDirectory $gateRoot
    if ([IO.Directory]::Exists($root)) { Remove-Item -LiteralPath $root -Recurse -Force }
}
