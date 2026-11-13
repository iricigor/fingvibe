function Assert-Agent3DiscussionDirectory([string] $Directory) {
    if (-not [IO.Path]::IsPathFullyQualified($Directory) -or -not [IO.Directory]::Exists($Directory)) {
        throw "Discussion storage requires an existing absolute shared directory."
    }
}

function Invoke-Agent3DiscussionApi {
    param([string] $Query, $Variables, [string] $Directory)
    Assert-Agent3DiscussionDirectory $Directory
    $path = Get-Agent3ProtocolPath $Directory "discussion-requests" ([guid]::NewGuid().ToString())
    Write-Agent3Atomic @{ query = $Query; variables = $Variables } $path -Immutable
    try {
        $response = ConvertFrom-Agent3Json (Invoke-Agent3GitHubWrite "graphql" $path "POST")
        if ($response.Contains("errors")) { throw "Discussion API returned errors: $($response.errors | ConvertTo-Json -Depth 20 -Compress)" }
        if (-not $response.Contains("data") -or $null -eq $response.data) { throw "Discussion API returned incomplete data." }
        return $response.data
    } finally { [IO.File]::Delete($path) }
}

function Get-Agent3DiscussionInventory {
    param([string] $Repository, [string] $Directory,
        [scriptblock] $Api = ${function:Invoke-Agent3DiscussionApi})
    if ($Repository -cnotmatch '^[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9_.-]*$') { throw "Invalid Discussion repository." }
    Assert-Agent3DiscussionDirectory $Directory
    $parts = $Repository.Split("/")
    $items = @()
    $cursor = $null
    $seen = @{}
    $cursors = @{}
    do {
        $data = & $Api 'query($owner:String!,$name:String!,$cursor:String){repository(owner:$owner,name:$name){id dispatcher:label(name:"3️⃣disp"){id name} developer1:label(name:"3️⃣dev1"){id name} developer2:label(name:"3️⃣dev2"){id name} discussionCategories(first:100){nodes{id name} pageInfo{hasNextPage}} discussions(first:100,after:$cursor,orderBy:{field:CREATED_AT,direction:ASC}){nodes{id number title body url author{login} repository{nameWithOwner} category{id name} labels(first:100){nodes{name} pageInfo{hasNextPage}}} pageInfo{hasNextPage endCursor}}}}' `
            @{ owner = $parts[0]; name = $parts[1]; cursor = $cursor } $Directory
        Assert-Agent3Fields $data @("repository")
        if ($null -eq $data.repository) { throw "Discussion repository unavailable." }
        $repo = $data.repository
        if ($repo.discussionCategories.pageInfo.hasNextPage) { throw "Incomplete Discussion categories." }
        $page = $repo.discussions
        if ($page.pageInfo.hasNextPage -isnot [bool]) { throw "Incomplete Discussion pagination." }
        foreach ($item in $page.nodes) {
            Assert-Agent3Fields $item @("id", "number", "title", "body", "url", "repository", "category")
            if ($item.repository.nameWithOwner -ine $Repository -or $seen.ContainsKey($item.id)) {
                throw "Wrong repository or duplicate Discussion."
            }
            $seen[$item.id] = $true
            $items += $item
        }
        $next = $page.pageInfo.endCursor
        if ($page.pageInfo.hasNextPage) {
            if (-not $next -or $cursors.ContainsKey($next)) { throw "Invalid Discussion cursor." }
            $cursors[$next] = $true
        }
        $cursor = $next
    } while ($page.pageInfo.hasNextPage)
    return @{ repositoryId = $repo.id; categories = @($repo.discussionCategories.nodes); discussions = $items
        labels = @($repo.dispatcher, $repo.developer1, $repo.developer2) }
}

function Get-Agent3DiscussionComments {
    param([string] $DiscussionId, [string] $Directory,
        [scriptblock] $Api = ${function:Invoke-Agent3DiscussionApi})
    Assert-Agent3DiscussionDirectory $Directory
    $comments = @()
    $cursor = $null
    $ids = @{}
    $cursors = @{}
    do {
        $data = & $Api 'query($id:ID!,$cursor:String){node(id:$id){... on Discussion{id comments(first:100,after:$cursor){nodes{id body url authorAssociation author{login} discussion{id} replies(first:100){nodes{id body url authorAssociation author{login} discussion{id}} pageInfo{hasNextPage endCursor}}} pageInfo{hasNextPage endCursor}}}}}' `
            @{ id = $DiscussionId; cursor = $cursor } $Directory
        if ($null -eq $data.node -or $data.node.id -cne $DiscussionId) { throw "Mapped Discussion missing." }
        $page = $data.node.comments
        if ($page.pageInfo.hasNextPage -isnot [bool]) { throw "Incomplete comment pagination." }
        foreach ($comment in $page.nodes) {
            $replies = @($comment.replies.nodes)
            $replyCursor = $comment.replies.pageInfo.endCursor
            $more = $comment.replies.pageInfo.hasNextPage
            $replyCursors = @{}
            if ($more -isnot [bool]) { throw "Incomplete reply pagination." }
            while ($more) {
                if (-not $replyCursor -or $replyCursors.ContainsKey($replyCursor)) { throw "Invalid reply cursor." }
                $replyCursors[$replyCursor] = $true
                $replyData = & $Api 'query($id:ID!,$cursor:String){node(id:$id){... on DiscussionComment{id replies(first:100,after:$cursor){nodes{id body url authorAssociation author{login} discussion{id}} pageInfo{hasNextPage endCursor}}}}}' `
                    @{ id = $comment.id; cursor = $replyCursor } $Directory
                if ($null -eq $replyData.node -or $replyData.node.id -cne $comment.id) { throw "Reply parent missing." }
                $replyPage = $replyData.node.replies
                if ($replyPage.pageInfo.hasNextPage -isnot [bool] -or
                    ($replyPage.pageInfo.hasNextPage -and (-not $replyPage.pageInfo.endCursor -or $replyPage.pageInfo.endCursor -ceq $replyCursor))) {
                    throw "Invalid reply pagination."
                }
                $replies += @($replyPage.nodes)
                $replyCursor = $replyPage.pageInfo.endCursor
                $more = $replyPage.pageInfo.hasNextPage
            }
            foreach ($entry in @($comment) + $replies) {
                Assert-Agent3Fields $entry @("id", "body", "url", "author", "discussion")
                if ($entry.discussion.id -cne $DiscussionId -or $ids.ContainsKey($entry.id) -or $entry.body -isnot [string]) {
                    throw "Invalid/duplicate Discussion comment."
                }
                $ids[$entry.id] = $true
                $comments += $entry
            }
        }
        $next = $page.pageInfo.endCursor
        if ($page.pageInfo.hasNextPage) {
            if (-not $next -or $cursors.ContainsKey($next)) { throw "Invalid comment cursor." }
            $cursors[$next] = $true
        }
        $cursor = $next
    } while ($page.pageInfo.hasNextPage)
    return ,$comments
}

function Invoke-Agent3DiscussionMutation {
    param([string] $Id, $Identity, [string] $Query, $Variables, [string] $Directory, [scriptblock] $Api)
    Assert-Agent3DiscussionDirectory $Directory
    $null = Get-Agent3ProtocolPath $Directory "discussion-operations" $Id
    $root = [IO.Path]::GetDirectoryName((Get-Agent3ProtocolPath $Directory "discussion-operations\$Id" "intent"))
    Write-Agent3ProtocolRecord $Identity (Join-Path $root "identity.json")
    $attempts = @(Get-ChildItem -LiteralPath $root -Filter "attempt-*.json" -File)
    foreach ($attempt in $attempts) {
        $reserved = Read-Agent3Json $attempt.FullName
        $number = $reserved.number
        $failurePath = Join-Path $root "pre-request-$number.json"
        if ($number -isnot [int] -and $number -isnot [long]) { throw "Invalid Discussion attempt number." }
        if ($number -lt 1 -or $attempt.Name -cne "attempt-$number.json" -or
            (Get-Agent3Hash $reserved.identity) -cne (Get-Agent3Hash $Identity)) { throw "Conflicting Discussion attempt identity." }
        if (-not [IO.File]::Exists($failurePath) -or
            (Get-Agent3Hash (Read-Agent3Json $failurePath)) -cne (Get-Agent3Hash $reserved)) {
            throw "Discussion mutation already attempted; reconcile remote outcome, never blindly retry."
        }
    }
    $number = $attempts.Count + 1
    $intent = @{ number = $number; identity = $Identity; utc = [DateTime]::UtcNow.ToString("o") }
    Write-Agent3Atomic $intent (Join-Path $root "attempt-$number.json") -Immutable
    try { return & $Api $Query $Variables $Directory }
    catch {
        if ($_.Exception.Data["agent3PublicationPhase"] -ceq "pre-request") {
            Write-Agent3Atomic $intent (Join-Path $root "pre-request-$number.json") -Immutable
        }
        throw
    }
}

function Get-Agent3DiscussionScope([string] $Kind, [string] $Key) {
    if ($Kind -cnotin @("task", "epic", "agent", "ideas", "corners", "problems") -or
        ($Kind -ceq "agent" -and $Key -cnotin @("dispatcher", "developer-1", "developer-2")) -or
        ($Kind -cne "agent" -and $Key -cnotmatch '^[1-9][0-9]*$')) { throw "Invalid Discussion scope key." }
    $category = switch ($Kind) { "task" { "🛠️ Task conversations" }; "agent" { "🤖 Agent logs" }; default { "🧭 Epic coordination" } }
    $labels = if ($Kind -ceq "agent") {
        switch ($Key) { "dispatcher" { "3️⃣disp" }; "developer-1" { "3️⃣dev1" }; "developer-2" { "3️⃣dev2" } }
    } else { @("3️⃣disp", "3️⃣dev1", "3️⃣dev2") }
    return @{ category = $category; labels = @($labels) }
}

function Get-Agent3MappedDiscussion {
    param([string] $Repository, [string] $Kind, [string] $Key, [string] $Directory,
        [scriptblock] $Api = ${function:Invoke-Agent3DiscussionApi})
    $scope = Get-Agent3DiscussionScope $Kind $Key
    $path = Get-Agent3ProtocolPath $Directory "discussions" "$Kind-$Key"
    $mapping = Read-Agent3Json $path
    Assert-Agent3Fields $mapping @("schema", "repository", "kind", "key", "id", "url", "categoryId", "openingBody", "labels")
    if ($mapping.schema -cne "fingvibe-agent3-discussion-v1" -or $mapping.repository -cne $Repository -or
        $mapping.kind -cne $Kind -or $mapping.key -cne $Key -or $mapping.openingBody -isnot [string] -or
        $mapping.labels -isnot [array] -or $mapping.labels.Count -ne $scope.labels.Count -or
        @($scope.labels | Where-Object { $_ -cnotin $mapping.labels }).Count -gt 0 -or
        -not [regex]::IsMatch($mapping.url, ('^https://github\.com/' + [regex]::Escape($Repository) + '/discussions/[1-9][0-9]*$'))) {
        throw "Discussion mapping mismatch."
    }
    $data = & $Api 'query($id:ID!){node(id:$id){... on Discussion{id url body repository{nameWithOwner} category{id name} labels(first:100){nodes{name} pageInfo{hasNextPage}}}}}' @{ id = $mapping.id } $Directory
    if ($null -eq $data.node -or $data.node.repository.nameWithOwner -ine $Repository -or
        $data.node.id -cne $mapping.id -or $data.node.url -cne $mapping.url -or
        $data.node.category.id -cne $mapping.categoryId -or $data.node.category.name -cne $scope.category -or
        $data.node.body -cne $mapping.openingBody) {
        throw "Mapped Discussion missing or changed; explicit reconciliation required."
    }
    if ($data.node.labels.pageInfo.hasNextPage) { throw "Incomplete mapped Discussion labels." }
    $actualLabels = @($data.node.labels.nodes | ForEach-Object { $_.name })
    foreach ($label in $mapping.labels) {
        if ($label -cnotin $actualLabels) { throw "Mapped Discussion agent label missing." }
    }
    return $mapping
}

function New-Agent3TaskDiscussionLink {
    param([string] $Body, $Mapping)
    $line = "[Agent conversation]($($Mapping.url))"
    $pattern = '(?s)<!-- agent3-discussion-link -->.*?<!-- /agent3-discussion-link -->'
    $replacement = "<!-- agent3-discussion-link -->`n$line`n<!-- /agent3-discussion-link -->"
    if ([regex]::Matches($Body, $pattern).Count -gt 1) { throw "Ambiguous issue Discussion links." }
    if ($Body -match $pattern) { return [regex]::Replace($Body, $pattern, [Text.RegularExpressions.MatchEvaluator]{ param($match) $replacement }) }
    return $Body.TrimEnd() + "`n`n$replacement"
}

function Assert-Agent3DiscussionGate([string] $Repository, [guid] $GateOwner, [string] $GateDirectory) {
    if ($GateOwner -eq [guid]::Empty) { throw "Dispatcher-owned gate required for Discussion setup." }
    if ($Repository -cnotmatch '^[a-z0-9][a-z0-9-]*/[a-z0-9][a-z0-9_.-]*$') { throw "Invalid Discussion repository." }
    $parts = $Repository.Split("/")
    $gate = Read-Agent3Json (Join-Path $GateDirectory "$($parts[0])\$($parts[1]).dispatch.json")
    if ($gate.schema -cne "fingvibe-dispatch-gate-v1" -or $gate.repository -cne $Repository -or
        $gate.owner -cne $GateOwner.ToString()) { throw "Discussion setup requires this Dispatcher's existing gate." }
}

function Publish-Agent3IssueDiscussionLink {
    param($Mapping, [string] $Directory, [guid] $GateOwner,
        [string] $GateDirectory = (Join-Path $env:LOCALAPPDATA "FingVibe\AgentCoordination"),
        [scriptblock] $Api = ${function:Invoke-Agent3DiscussionApi})
    Assert-Agent3DiscussionGate $Mapping.repository $GateOwner $GateDirectory
    if ($Mapping.kind -cnotin @("task", "epic")) { throw "Only task/Epic Discussions belong on issue bodies." }
    $null = Get-Agent3MappedDiscussion $Mapping.repository $Mapping.kind $Mapping.key $Directory $Api
    $parts = $Mapping.repository.Split("/")
    $query = 'query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){issue(number:$number){id body url}}}'
    $variables = @{ owner = $parts[0]; name = $parts[1]; number = [int]$Mapping.key }
    $data = & $Api $query $variables $Directory
    $issue = $data.repository.issue
    if ($null -eq $issue -or $issue.url -cne "https://github.com/$($Mapping.repository)/issues/$($Mapping.key)") {
        throw "Issue Discussion-link target unavailable or mismatched."
    }
    $body = New-Agent3TaskDiscussionLink $issue.body $Mapping
    if ($body -cne $issue.body) {
        $latest = & $Api $query $variables $Directory
        if ($null -eq $latest.repository.issue -or $latest.repository.issue.id -cne $issue.id -or
            $latest.repository.issue.body -cne $issue.body) {
            throw "Issue body changed before Discussion-link publication; stop without overwriting human edits."
        }
        $null = Invoke-Agent3DiscussionMutation "issue-link-$($Mapping.kind)-$($Mapping.key)" `
            @{ issue = $issue.id; expectedBody = $issue.body; body = $body } `
            'mutation($input:UpdateIssueInput!){updateIssue(input:$input){issue{id}}}' `
            @{ input = @{ id = $issue.id; body = $body } } $Directory $Api
    }
    $data = & $Api $query $variables $Directory
    if ($data.repository.issue.id -cne $issue.id -or $data.repository.issue.body -cne $body) {
        throw "Issue Discussion link changed during publication; reconcile without overwriting unrelated edits."
    }
    return $Mapping.url
}

function Initialize-Agent3Discussion {
    param([string] $Repository, [ValidateSet("task", "epic", "agent", "ideas", "corners", "problems")] [string] $Kind,
        [string] $Key, [string] $ActorLogin, [string] $Directory, [guid] $GateOwner,
        [string] $GateDirectory = (Join-Path $env:LOCALAPPDATA "FingVibe\AgentCoordination"),
        [string] $ExistingId, [scriptblock] $Api = ${function:Invoke-Agent3DiscussionApi})
    Assert-Agent3Text $ActorLogin "observed GitHub account"
    Assert-Agent3DiscussionDirectory $Directory
    if ($Kind -ceq "task" -and $ExistingId) { throw "Task mappings cannot adopt ExistingId; discover the exact task scope." }
    Assert-Agent3DiscussionGate $Repository $GateOwner $GateDirectory
    $scope = Get-Agent3DiscussionScope $Kind $Key
    $path = Get-Agent3ProtocolPath $Directory "discussions" "$Kind-$Key"
    if ([IO.File]::Exists($path)) { return Get-Agent3MappedDiscussion $Repository $Kind $Key $Directory $Api }
    $inventory = Get-Agent3DiscussionInventory $Repository $Directory $Api
    $categoryName = $scope.category
    $categories = @($inventory.categories | Where-Object name -CEQ $categoryName)
    if ($categories.Count -ne 1) { throw "Required Discussion category missing or ambiguous: $categoryName" }
    $identity = [ordered]@{ schema = "fingvibe-agent3-discussion-v1"; repository = $Repository; kind = $Kind; key = $Key }
    $marker = "<!-- fingvibe-agent3-discussion:$Kind-$Key -->"
    $names = @{ dispatcher = "3️⃣ Dispatcher"; "developer-1" = "3️⃣ Developer 1"; "developer-2" = "3️⃣ Developer 2" }
    $title = switch ($Kind) {
        "task" { "Task #$Key - agent conversation" }; "epic" { "Epic #$Key - coordination" }
        "agent" { "$($names[$Key]) - activity log" }; "ideas" { "Epic #$Key - Ideas and improvements" }
        "corners" { "Epic #$Key - Corner cases and unclear requirements" }; "problems" { "Epic #$Key - Agentic-loop problems" }
    }
    $body = "$marker`n$title`n`n<details><summary>Discussion mapping</summary>`n`n``````json`n$($identity | ConvertTo-Json -Compress)`n```````n`n</details>"
    $matches = @($inventory.discussions | Where-Object { $_.body.Contains($marker) })
    if ($ExistingId) {
        $matches = @($inventory.discussions | Where-Object id -CEQ $ExistingId)
        if ($matches.Count -ne 1) { throw "Explicitly selected Discussion unavailable." }
    }
    if ($matches.Count -gt 1) { throw "Duplicate Discussion scope; reconcile without creating another." }
    $operationId = "mapping-$Kind-$Key"
    if ($matches.Count -eq 0) {
        $data = Invoke-Agent3DiscussionMutation $operationId @{ scope = $identity; body = $body; actor = $ActorLogin } `
            'mutation($input:CreateDiscussionInput!){createDiscussion(input:$input){discussion{id}}}' `
            @{ input = @{ repositoryId = $inventory.repositoryId; categoryId = $categories[0].id; title = $title; body = $body } } $Directory $Api
        $id = $data.createDiscussion.discussion.id
        $inventory = Get-Agent3DiscussionInventory $Repository $Directory $Api
        $matches = @($inventory.discussions | Where-Object id -CEQ $id)
    }
    if ($matches.Count -ne 1 -or $matches[0].category.id -cne $categories[0].id -or
        (-not $ExistingId -and ($matches[0].body -cne $body -or $matches[0].author.login -ine $ActorLogin))) {
        throw "Discussion scope/readback mismatch."
    }
    $selected = $matches[0]
    $requiredLabels = $scope.labels
    $labelIds = @()
    foreach ($name in $requiredLabels) {
        $label = @($inventory.labels | Where-Object { $null -ne $_ -and $_.name -ceq $name })
        if ($label.Count -ne 1) { throw "Required agent label missing: $name" }
        $labelIds += $label[0].id
    }
    if ($selected.labels.pageInfo.hasNextPage) { throw "Incomplete Discussion labels." }
    $actualLabels = @($selected.labels.nodes | ForEach-Object { $_.name })
    if (@($requiredLabels | Where-Object { $_ -cnotin $actualLabels }).Count -gt 0) {
        $null = Invoke-Agent3DiscussionMutation "labels-$Kind-$Key" @{ discussion = $selected.id; labels = $requiredLabels } `
            'mutation($input:AddLabelsToLabelableInput!){addLabelsToLabelable(input:$input){clientMutationId}}' `
            @{ input = @{ labelableId = $selected.id; labelIds = $labelIds } } $Directory $Api
    }
    $mapping = @{} + $identity + @{ id = $selected.id; url = $selected.url; categoryId = $selected.category.id
        openingBody = $selected.body; labels = @($requiredLabels) }
    Write-Agent3ProtocolRecord $mapping $path
    return Get-Agent3MappedDiscussion $Repository $Kind $Key $Directory $Api
}

function Publish-Agent3DiscussionComment {
    param($Mapping, [string] $Id, [string] $Body, [string] $ActorLogin, [string] $Directory,
        [scriptblock] $Api = ${function:Invoke-Agent3DiscussionApi}, [string] $CommentId, [string] $ExpectedBody)
    $verifiedMapping = Get-Agent3MappedDiscussion $Mapping.repository $Mapping.kind $Mapping.key $Directory $Api
    if ($verifiedMapping.id -cne $Mapping.id) { throw "Publication Discussion mismatch." }
    Assert-Agent3Text $ActorLogin "independently observed publishing account"
    $marker = "<!-- agent3-publication:$Id -->"
    if (-not $Body.Contains($marker)) { throw "Stable publication marker required." }
    if ($Body -match '<!--\s*fingvibe-real-claim-v1\s*-->') {
        $null = Get-Agent3DiscussionClaimBody $Body $Mapping
    }
    if ($CommentId) {
        $oldClaim = Get-Agent3DiscussionClaimBody $ExpectedBody $Mapping
        $newClaim = Get-Agent3DiscussionClaimBody $Body $Mapping
        if ($oldClaim.claimId -cne $newClaim.claimId) { throw "Claim revision identity changed." }
    }
    $receipt = Get-Agent3ProtocolPath $Directory "discussion-publications" $Id
    $identity = @{ discussionId = $Mapping.id; body = $Body; actor = $ActorLogin; commentId = $CommentId; expectedBody = $ExpectedBody }
    Write-Agent3ProtocolRecord $identity (Get-Agent3ProtocolPath $Directory "discussion-operations\comment-$Id" "identity")
    $comments = Get-Agent3DiscussionComments $Mapping.id $Directory $Api
    $matches = @($comments | Where-Object { $_.body.Contains($marker) })
    if ($matches.Count -gt 1) { throw "Duplicate Discussion publication identity." }
    if ([IO.File]::Exists($receipt)) {
        $previous = Read-Agent3Json $receipt
        if ((Get-Agent3Hash $previous.identity) -cne (Get-Agent3Hash $identity) -or
            $matches.Count -ne 1 -or $matches[0].id -cne $previous.id) { throw "Verified publication missing or conflicting." }
    }
    if ($matches.Count -eq 0) {
        if ($CommentId) {
            $null = Test-Agent3DiscussionReceipts $Mapping $comments $Directory
            $current = @($comments | Where-Object id -CEQ $CommentId)
            if ($current.Count -ne 1 -or $current[0].body -cne $ExpectedBody -or $current[0].author.login -ine $ActorLogin) {
                throw "Claim revision expected body/account changed."
            }
            $query = 'mutation($input:UpdateDiscussionCommentInput!){updateDiscussionComment(input:$input){comment{id}}}'
            $input = @{ commentId = $CommentId; body = $Body }
        } else {
            $query = 'mutation($input:AddDiscussionCommentInput!){addDiscussionComment(input:$input){comment{id}}}'
            $input = @{ discussionId = $Mapping.id; body = $Body }
        }
        $null = Invoke-Agent3DiscussionMutation "comment-$Id" $identity $query @{ input = $input } $Directory $Api
        $comments = Get-Agent3DiscussionComments $Mapping.id $Directory $Api
        $matches = @($comments | Where-Object { $_.body.Contains($marker) })
    }
    if ($matches.Count -ne 1 -or $matches[0].body -cne $Body -or $matches[0].author.login -ine $ActorLogin -or
        -not [regex]::IsMatch($matches[0].url, ('^' + [regex]::Escape($Mapping.url) + '#discussioncomment-[1-9][0-9]*$')) -or
        ($CommentId -and $matches[0].id -cne $CommentId)) { throw "Discussion publication identity/content readback mismatch." }
    $result = @{ identity = $identity; id = $matches[0].id; url = $matches[0].url }
    Write-Agent3ProtocolRecord $result $receipt
    return $result
}

function Get-Agent3FirstMessageLine([string] $Text) {
    $Text = [regex]::Replace($Text, '(?is)<summary\b[^>]*>.*?</summary>', '')
    $prose = [regex]::Replace($Text, '(?s)<!--.*?-->|```.*?```', '')
    $prose = [regex]::Replace($prose, '<[^>]+>', '')
    $trimmed = $prose.Trim()
    if ($trimmed.StartsWith("{") -or $trimmed.StartsWith("[")) {
        try {
            $json = ConvertFrom-Json -InputObject $trimmed -Depth 100 -NoEnumerate -ErrorAction Stop
            if ($null -ne $json) { return "" }
        } catch [ArgumentException] {
            # Non-JSON prose can start with a Markdown link or brace.
        }
    }
    foreach ($line in $prose -split '\r?\n') { if (-not [string]::IsNullOrWhiteSpace($line)) { return $line.Trim() } }
    return ""
}

function New-Agent3DiscussionBody {
    param([string] $AgentId, [string] $Text, [string] $CreatedUtc, [string] $UpdatedUtc,
        [string] $SourceUrl, [string] $SourceLabel, $Claim)
    $names = @{ dispatcher = "3️⃣ Dispatcher"; "developer-1" = "3️⃣ Developer 1"; "developer-2" = "3️⃣ Developer 2" }
    if (-not $names.ContainsKey($AgentId)) { throw "Unknown agent identity." }
    Assert-Agent3Utc $CreatedUtc
    if (-not $UpdatedUtc) { $UpdatedUtc = $CreatedUtc }
    Assert-Agent3Utc $UpdatedUtc
    $created = [DateTimeOffset]::Parse($CreatedUtc).UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss")
    $updated = [DateTimeOffset]::Parse($UpdatedUtc).UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss")
    $time = if ([DateTimeOffset]$CreatedUtc -eq [DateTimeOffset]$UpdatedUtc) { "Created/updated UTC: $created" } else { "Created UTC: $created · Updated UTC: $updated" }
    $source = if ($SourceUrl) { " · [$SourceLabel]($SourceUrl)" } else { "" }
    $body = "_**$($names[$AgentId])**$source  ${time}_`n`n$Text"
    if ($null -ne $Claim) {
        if ([regex]::Matches($Text, '(?s)```json\s*(.*?)\s*```').Count -ne 0) { throw "Claim message already contains JSON; supply the claim separately." }
        $body += "`n`n<!-- fingvibe-real-claim-v1 -->`n<details><summary>Claim details</summary>`n`n``````json`n$($Claim | ConvertTo-Json -Depth 100)`n```````n`n</details>"
    }
    return $body
}

function Publish-Agent3DiscussionReport {
    [CmdletBinding()]
    param($Mapping, $AgentMapping, [string] $Id, [string] $Text, [string] $ActorLogin,
        [string] $AgentId, [string] $CreatedUtc, [string] $Directory,
        [scriptblock] $Api = ${function:Invoke-Agent3DiscussionApi}, $Claim,
        [string] $CommentId, [string] $ExpectedBody)
    if ($Mapping.kind -cnotin @("task", "epic") -or $AgentMapping.kind -cne "agent" -or $AgentMapping.key -cne $AgentId) {
        throw "Canonical reports require a task/Epic and the actual agent index."
    }
    if ($null -ne $Claim) { Assert-Agent3DiscussionClaim $Claim $Mapping }
    $body = New-Agent3DiscussionBody $AgentId $Text $CreatedUtc -Claim $Claim
    $body += "`n`n<!-- agent3-publication:$Id -->"
    $canonical = Publish-Agent3DiscussionComment $Mapping $Id $body $ActorLogin $Directory $Api $CommentId $ExpectedBody
    $indexText = Get-Agent3FirstMessageLine $Text
    $indexBody = New-Agent3DiscussionBody $AgentId $indexText $CreatedUtc -SourceUrl $canonical.url -SourceLabel "Task/Epic message"
    $indexBody += "`n`n<!-- agent3-publication:index-$Id -->"
    $pending = Get-Agent3ProtocolPath $Directory "discussion-indexes" "$Id-pending"
    Write-Agent3ProtocolRecord @{ sourceId = $canonical.id; sourceUrl = $canonical.url; agent = $AgentId; indexBody = $indexBody } $pending
    try {
        $index = Publish-Agent3DiscussionComment $AgentMapping "index-$Id" $indexBody $ActorLogin $Directory $Api
        return @{ canonical = $canonical; index = $index; indexStatus = "verified"; indexError = $null }
    } catch {
        $errorText = $_.Exception.Message
        $path = Get-Agent3ProtocolPath $Directory "discussion-index-errors" ([guid]::NewGuid().ToString())
        Write-Agent3Atomic @{ sourceId = $canonical.id; error = $errorText; utc = [DateTime]::UtcNow.ToString("o") } $path -Immutable
        Write-Warning "Canonical publication verified; agent index pending reconciliation: $errorText"
        return @{ canonical = $canonical; index = $null; indexStatus = "pending"; indexError = $errorText }
    }
}

function Assert-Agent3DiscussionClaim($Claim, $Mapping) {
    Assert-Agent3Fields $Claim @("schema", "repository", "issue", "claimId")
    $claimId = [guid]::Empty
    if ($Mapping.kind -cne "task" -or $Claim.schema -cne "fingvibe-real-claim-v1" -or
        ($Claim.issue -isnot [int] -and $Claim.issue -isnot [long]) -or
        $Claim.repository -cne $Mapping.repository -or $Claim.issue.ToString() -cne $Mapping.key -or
        -not [guid]::TryParse($Claim.claimId, [ref]$claimId) -or $claimId -eq [guid]::Empty) {
        throw "Uncorrelated Discussion claim."
    }
}

function Get-Agent3DiscussionClaimBody([string] $Body, $Mapping) {
    if ([regex]::Matches($Body, '<!--\s*fingvibe-real-claim-v1\s*-->').Count -ne 1) {
        throw "Malformed Discussion claim marker."
    }
    $blocks = [regex]::Matches($Body, '(?s)```json\s*(.*?)\s*```')
    if ($blocks.Count -ne 1) { throw "Malformed Discussion claim JSON." }
    $claim = ConvertFrom-Agent3Json $blocks[0].Groups[1].Value
    Assert-Agent3DiscussionClaim $claim $Mapping
    return $claim
}

function Test-Agent3DiscussionReceipts {
    param($Mapping, $Comments, [string] $Directory)
    $root = Join-Path $Directory "discussion-publications"
    $receipts = @(
        if ([IO.Directory]::Exists($root)) {
            foreach ($file in Get-ChildItem -LiteralPath $root -Filter "*.json" -File) {
                $record = Read-Agent3Json $file.FullName
                if ($record.identity.discussionId -cne $Mapping.id) { continue }
                $reserved = Read-Agent3Json (Get-Agent3ProtocolPath $Directory "discussion-operations\comment-$($file.BaseName)" "identity")
                if ((Get-Agent3Hash $reserved) -cne (Get-Agent3Hash $record.identity)) { throw "Canonical receipt conflicts with reserved identity." }
                $record
            }
        }
    )
    foreach ($group in ($receipts | Group-Object id -CaseSensitive)) {
        $remaining = @($group.Group)
        $first = @($remaining | Where-Object { -not $_.identity.commentId })
        if ($first.Count -ne 1) { throw "Canonical revision chain requires exactly one original publication." }
        $current = $first[0]
        $remaining = @($remaining | Where-Object { $_ -ne $current })
        while ($remaining.Count -gt 0) {
            $next = @($remaining | Where-Object {
                $_.identity.commentId -ceq $current.id -and $_.identity.expectedBody -ceq $current.identity.body
            })
            if ($next.Count -ne 1) { throw "Canonical revision chain missing, ambiguous or conflicting." }
            $revision = $next[0]
            $oldClaim = Get-Agent3DiscussionClaimBody $current.identity.body $Mapping
            $newClaim = Get-Agent3DiscussionClaimBody $revision.identity.body $Mapping
            if ($newClaim.claimId -cne $oldClaim.claimId -or $revision.identity.actor -cne $current.identity.actor -or
                $revision.url -cne $current.url) { throw "Canonical claim revision identity changed." }
            $current = $revision
            $remaining = @($remaining | Where-Object { $_ -ne $current })
        }
        $remote = @($Comments | Where-Object id -CEQ $current.id)
        if ($remote.Count -ne 1 -or $remote[0].body -cne $current.identity.body -or
            $remote[0].author.login -ine $current.identity.actor -or $remote[0].url -cne $current.url) {
            throw "Verified canonical comment missing or changed."
        }
    }
    return ,$receipts
}

function Repair-Agent3DiscussionIndex {
    [CmdletBinding()]
    param($Mapping, $AgentMapping, [string] $Id, [string] $Directory,
        [scriptblock] $Api = ${function:Invoke-Agent3DiscussionApi})
    $mappingReadback = Get-Agent3MappedDiscussion $Mapping.repository $Mapping.kind $Mapping.key $Directory $Api
    if ($Mapping.kind -cnotin @("task", "epic") -or $Mapping.id -cne $mappingReadback.id) { throw "Invalid canonical mapping for index recovery." }
    $comments = Get-Agent3DiscussionComments $Mapping.id $Directory $Api
    $receipts = Test-Agent3DiscussionReceipts $Mapping $comments $Directory
    $source = Read-Agent3Json (Get-Agent3ProtocolPath $Directory "discussion-publications" $Id)
    $pending = Read-Agent3Json (Get-Agent3ProtocolPath $Directory "discussion-indexes" "$Id-pending")
    if (@($receipts | Where-Object { (Get-Agent3Hash $_) -ceq (Get-Agent3Hash $source) }).Count -ne 1 -or
        $pending.sourceId -cne $source.id -or $pending.sourceUrl -cne $source.url -or
        $pending.agent -cne $AgentMapping.key -or $AgentMapping.kind -cne "agent" -or
        $AgentMapping.repository -cne $Mapping.repository) { throw "Index recovery source/projection mismatch." }
    return Publish-Agent3DiscussionComment $AgentMapping "index-$Id" $pending.indexBody $source.identity.actor $Directory $Api
}

function Get-Agent3DiscussionEvidence {
    param([string] $Repository, [string] $Directory,
        [scriptblock] $Api = ${function:Invoke-Agent3DiscussionApi})
    $inventory = Get-Agent3DiscussionInventory $Repository $Directory $Api
    $claims = @()
    $reports = @()
    $taskScopes = @{}
    foreach ($discussion in $inventory.discussions) {
        if ($discussion.category.name -cne "🛠️ Task conversations") { continue }
        $markers = [regex]::Matches($discussion.body, '<!-- fingvibe-agent3-discussion:task-([1-9][0-9]*) -->')
        if ($markers.Count -gt 1) { throw "Ambiguous task Discussion scope." }
        $hasScope = $markers.Count -eq 1
        $issue = if ($hasScope) { [int]$markers[0].Groups[1].Value } else { 0 }
        if ($hasScope) {
            if ($taskScopes.ContainsKey($issue)) { throw "Duplicate task Discussion scope." }
            $taskScopes[$issue] = $true
        }
        foreach ($comment in (Get-Agent3DiscussionComments $discussion.id $Directory $Api)) {
            if ($hasScope) {
                $reports += @{ issue = $issue; url = $comment.url; body = $comment.body; authorAssociation = $comment.authorAssociation }
            }
            if ($comment.body -notmatch '<!--\s*fingvibe-real-claim-v1\s*-->') { continue }
            if (-not $hasScope) { throw "Discussion claim lost its task scope marker." }
            $claim = Get-Agent3DiscussionClaimBody $comment.body @{kind="task";repository=$Repository;key=[string]$issue}
            $claims += @{ issue = $issue; url = $comment.url; body = $comment.body; claim = $claim }
        }
    }
    $mappingRoot = Join-Path $Directory "discussions"
    if ([IO.Directory]::Exists($mappingRoot)) {
        foreach ($file in Get-ChildItem -LiteralPath $mappingRoot -Filter "task-*.json" -File) {
            $mapping = Read-Agent3Json $file.FullName
            $null = Get-Agent3MappedDiscussion $Repository $mapping.kind $mapping.key $Directory $Api
            $comments = Get-Agent3DiscussionComments $mapping.id $Directory $Api
            $null = Test-Agent3DiscussionReceipts $mapping $comments $Directory
        }
    }
    return @{ claims = $claims; reports = $reports }
}

function Get-Agent3DiscussionClaims {
    param([string] $Repository, [string] $Directory,
        [scriptblock] $Api = ${function:Invoke-Agent3DiscussionApi})
    $evidence = Get-Agent3DiscussionEvidence $Repository $Directory $Api
    return ,$evidence.claims
}
