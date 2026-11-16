[CmdletBinding()]
param(
    [string] $Repository = "iricigor/fingvibe",
    [int] $Discussion,
    [int] $Issue,
    [ValidateSet("developer-1", "developer-2")] [string] $Developer
)

$ErrorActionPreference = "Stop"

function Invoke-Agent4DiscussionGraphQl([string] $Query, [hashtable] $Variables) {
    $arguments = @("api", "graphql", "-f", "query=$Query")
    foreach ($key in $Variables.Keys) {
        $arguments += @("-F", "$key=$($Variables[$key])")
    }
    $output = gh @arguments
    if ($LASTEXITCODE -ne 0) { throw "Discussion GraphQL request failed." }
    $response = ($output -join "`n") | ConvertFrom-Json
    if ($response.errors -or -not $response.data) { throw "Discussion GraphQL response failed: $($response.errors | ConvertTo-Json -Compress)" }
    $response.data
}

function Set-Agent4DiscussionParticipant([string] $Repository, [int] $Discussion, [int] $Issue, [string] $Developer) {
    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
        $Discussion -le 0 -or $Issue -le 0 -or $Developer -notin @("developer-1", "developer-2")) {
        throw "Repository, positive Discussion/task numbers and developer-1/developer-2 identity required."
    }
    $owner, $name = $Repository.Split("/")
    $labelName = if ($Developer -eq "developer-1") { "4️⃣dev1" } else { "4️⃣dev2" }
    $variables = @{ owner = $owner; name = $name; number = $Discussion; label = $labelName }
    $query = 'query($owner:String!,$name:String!,$number:Int!,$label:String!){repository(owner:$owner,name:$name){nameWithOwner label(name:$label){id name} discussion(number:$number){id url body category{name} labels(first:100){nodes{id name} pageInfo{hasNextPage}}}}}'
    $originalLabels = @()
    $discussionId = $null
    for ($read = 0; $read -lt 2; $read++) {
        $context = (Invoke-Agent4DiscussionGraphQl $query $variables).repository
        $task = $context.discussion
        $markers = [regex]::Matches([string] $task.body, '<!-- fingvibe:task=(\d+) -->')
        if ($context.nameWithOwner -ine $Repository -or -not $task.id -or
            $task.category.name -cnotin @("Task conversations", "🛠️ Task conversations") -or $markers.Count -ne 1 -or
            $markers[0].Groups[1].Value -ne [string] $Issue) {
            throw "Discussion does not match the assigned repository, category and task marker."
        }
        if (-not $context.label.id -or $context.label.name -cne $labelName) {
            throw "Required Discussion participation label '$labelName' is unavailable."
        }
        if ($null -eq $task.labels.pageInfo.hasNextPage -or $task.labels.pageInfo.hasNextPage -or
            $task.labels.nodes -isnot [array]) {
            throw "Incomplete Discussion labels; no participation update can be verified."
        }
        $actualLabels = @($task.labels.nodes.name)
        if ($read -eq 0) {
            $originalLabels = $actualLabels
            $discussionId = $task.id
            if ($labelName -cnotin $actualLabels) {
                $mutation = 'mutation($discussion:ID!,$label:ID!){addLabelsToLabelable(input:{labelableId:$discussion,labelIds:[$label]}){clientMutationId}}'
                $null = Invoke-Agent4DiscussionGraphQl $mutation @{ discussion = $discussionId; label = $context.label.id }
            }
        } elseif ($task.id -cne $discussionId -or $labelName -cnotin $actualLabels -or
            @($originalLabels | Where-Object { $_ -cnotin $actualLabels }).Count) {
            throw "Discussion participation verification failed; required or existing labels are missing."
        }
    }
    @{ discussion = $Discussion; issue = $Issue; developer = $Developer; label = $labelName; url = $task.url }
}

if ($MyInvocation.InvocationName -ne ".") {
    Set-Agent4DiscussionParticipant $Repository $Discussion $Issue $Developer | ConvertTo-Json -Compress
}
