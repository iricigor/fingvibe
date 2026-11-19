#Requires -Version 7.5
[CmdletBinding()]
param(
    [string] $Repository = "iricigor/fingvibe",
    [int] $Epic = 0,
    [ValidateRange(0, 20)] [int] $DeveloperCount = 0,
    [switch] $Apply
)

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "ArchitectEpicPreparation.psm1") -Force

function Invoke-ArchitectGraphQl {
    param([string] $Query, [hashtable] $Variables)
    $payload = @{ query = $Query; variables = $Variables } |
        ConvertTo-Json -Depth 30 -Compress
    $text = $payload | gh api --hostname github.com graphql --input -
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub Discussion GraphQL operation failed; do not blindly retry a write."
    }
    $response = ($text -join "`n") | ConvertFrom-Json -AsHashtable -DateKind String -Depth 100
    if ($response.errors -or -not $response.data) {
        throw "GitHub Discussion GraphQL returned errors: $($response.errors.message -join '; ')"
    }
    $response.data
}

function Read-ArchitectRest {
    param([string] $Endpoint, [switch] $Paginated)
    $text = if ($Paginated) {
        gh api --hostname github.com --paginate --slurp $Endpoint
    } else {
        gh api --hostname github.com $Endpoint
    }
    if ($LASTEXITCODE -ne 0) { throw "GitHub read failed: $Endpoint." }
    $value = ($text -join "`n") |
        ConvertFrom-Json -AsHashtable -DateKind String -Depth 100 -NoEnumerate
    if ($Paginated) {
        if ($value -isnot [array] -or @($value | Where-Object { $_ -isnot [array] }).Count) {
            throw "Incomplete paginated GitHub read: $Endpoint."
        }
        $items = [Collections.Generic.List[object]]::new()
        foreach ($page in $value) {
            foreach ($item in @($page)) { $items.Add($item) }
        }
        return $items.ToArray()
    }
    $value
}

function Get-ArchitectDiscussionByNumber {
    param([int] $Number)
    $owner, $name = $Repository.Split("/")
    $query = 'query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){nameWithOwner discussion(number:$number){id number title body url closed closedAt stateReason category{id name}}}}'
    $data = Invoke-ArchitectGraphQl $query @{ owner = $owner; name = $name; number = $Number }
    if ("$($data.repository.nameWithOwner)" -ine $Repository -or -not $data.repository.discussion) {
        throw "Discussion #$Number is unavailable or belongs to another repository."
    }
    $data.repository.discussion
}

function Assert-ArchitectDiscussionIdentity {
    param($PlanItem)
    $current = Get-ArchitectDiscussionByNumber ([int] $PlanItem.discussion)
    if ("$($current.id)" -cne "$($PlanItem.id)" -or [bool] $current.closed -or
        "$($current.url)" -cne "$($PlanItem.url)") {
        throw "Discussion #$($PlanItem.discussion) changed before close; stop without retrying."
    }
    $scope = Get-ArchitectDiscussionScope "$($current.body)"
    if (-not $scope.found -or $scope.ambiguous -or
        $scope.kind -cne $PlanItem.kind -or $scope.number -ne $PlanItem.number) {
        throw "Discussion #$($PlanItem.discussion) scope changed before close."
    }
    $current
}

function Close-ArchitectDiscussion {
    param($PlanItem)
    $current = Assert-ArchitectDiscussionIdentity $PlanItem
    $query = 'mutation($input:CloseDiscussionInput!){closeDiscussion(input:$input){discussion{id closed stateReason url}}}'
    $data = Invoke-ArchitectGraphQl $query @{
        input = @{ discussionId = $current.id; reason = "RESOLVED" }
    }
    $mutation = $data.closeDiscussion.discussion
    $verified = Get-ArchitectDiscussionByNumber ([int] $PlanItem.discussion)
    if ("$($mutation.id)" -cne "$($current.id)" -or
        -not [bool] $verified.closed -or "$($verified.id)" -cne "$($current.id)" -or
        "$($verified.url)" -cne "$($current.url)") {
        throw "Closing Discussion #$($PlanItem.discussion) could not be verified; reconcile before retrying."
    }
    $verified
}

function Get-ArchitectPreparationData {
    param([int] $SelectedEpic)
    $inventory = Get-ArchitectDiscussionInventory $Repository ${function:Invoke-ArchitectGraphQl}
    $scopes = @(
        $inventory.discussions | ForEach-Object {
            $scope = Get-ArchitectDiscussionScope "$($_.body)"
            if ($scope.found -or $scope.ambiguous) {
                [pscustomobject]@{ discussion = $_; scope = $scope }
            }
        }
    )
    $numbers = @($scopes |
        Where-Object { -not $_.scope.ambiguous } |
        ForEach-Object { [int] $_.scope.number } |
        Sort-Object -Unique)
    if ($numbers -notcontains $SelectedEpic) { $numbers += $SelectedEpic }
    $issues = [Collections.Generic.List[object]]::new()
    $epicChildren = [Collections.Generic.List[object]]::new()
    foreach ($number in @($numbers | Sort-Object -Unique)) {
        $issue = Read-ArchitectRest "repos/$Repository/issues/$number"
        $issues.Add($issue)
    }
    foreach ($record in @($scopes | Where-Object {
        -not $_.scope.ambiguous -and $_.scope.kind -eq "epic"
    })) {
        $number = [int] $record.scope.number
        if (@($epicChildren | Where-Object { [int] $_.epic -eq $number }).Count -gt 0) {
            continue
        }
        $children = @(Read-ArchitectRest "repos/$Repository/issues/$number/sub_issues?per_page=100" -Paginated)
        $epicChildren.Add([pscustomobject]@{ epic = $number; children = $children })
    }
    if (@($epicChildren | Where-Object { [int] $_.epic -eq $SelectedEpic }).Count -eq 0) {
        $children = @(Read-ArchitectRest "repos/$Repository/issues/$SelectedEpic/sub_issues?per_page=100" -Paginated)
        $epicChildren.Add([pscustomobject]@{ epic = $SelectedEpic; children = $children })
    }
    [pscustomobject]@{
        inventory = $inventory
        issues = @($issues)
        epicChildren = @($epicChildren)
    }
}

function Find-ArchitectSelectedDiscussion {
    param([object[]] $Discussions)
    @($Discussions | Where-Object {
        $scope = Get-ArchitectDiscussionScope "$($_.body)"
        $scope.found -and -not $scope.ambiguous -and
            $scope.kind -eq "epic" -and $scope.number -eq $Epic
    })
}

function New-ArchitectEpicDiscussion {
    param($Inventory)
    $category = @($Inventory.categories | Where-Object {
        "$($_.name)" -ceq "🧭 Epic coordination"
    })
    if ($category.Count -ne 1) {
        throw "Required Epic coordination Discussion category is missing or ambiguous."
    }
    $refresh = Get-ArchitectDiscussionInventory $Repository ${function:Invoke-ArchitectGraphQl}
    $matches = @(Find-ArchitectSelectedDiscussion @($refresh.discussions))
    if ($matches.Count -eq 1 -and -not [bool] $matches[0].closed) { return $matches[0] }
    if ($matches.Count -ne 0) {
        throw "Epic #$Epic Discussion mapping appeared or is closed; reconcile without retrying creation."
    }
    $body = "<!-- fingvibe:epic=$Epic -->`nArchitect preparation for Epic #$Epic."
    $title = "Epic #$Epic - coordination"
    $mutation = 'mutation($input:CreateDiscussionInput!){createDiscussion(input:$input){discussion{id number title body url closed category{id name}}}}'
    $data = Invoke-ArchitectGraphQl $mutation @{
        input = @{
            repositoryId = $refresh.repositoryId
            categoryId = $category[0].id
            title = $title
            body = $body
        }
    }
    $created = $data.createDiscussion.discussion
    if (-not "$($created.id)") { throw "Epic Discussion creation returned incomplete data; do not retry." }
    $verified = Get-ArchitectDiscussionByNumber ([int] $created.number)
    $verifyInventory = Get-ArchitectDiscussionInventory $Repository ${function:Invoke-ArchitectGraphQl}
    $verifyMatches = @(Find-ArchitectSelectedDiscussion @($verifyInventory.discussions))
    if ($verifyMatches.Count -ne 1 -or "$($verified.id)" -cne "$($created.id)" -or
        "$($verified.title)" -cne $title -or "$($verified.body)" -cne $body -or
        "$($verified.category.name)" -cne "🧭 Epic coordination" -or [bool] $verified.closed) {
        throw "Epic #$Epic Discussion creation/readback failed; reconcile without retrying."
    }
    $verified
}

function Find-ArchitectDeveloperDiscussion {
    param([object[]] $Discussions, [int] $Developer)
    @($Discussions | Where-Object {
        $scope = Get-ArchitectDeveloperScope "$($_.body)"
        $scope.found -and -not $scope.ambiguous -and
            $scope.epic -eq $Epic -and $scope.developer -eq $Developer
    })
}

function New-ArchitectDeveloperDiscussion {
    param([int] $Developer)
    $refresh = Get-ArchitectDiscussionInventory $Repository ${function:Invoke-ArchitectGraphQl}
    $matches = @(Find-ArchitectDeveloperDiscussion @($refresh.discussions) $Developer)
    if ($matches.Count -eq 1 -and -not [bool] $matches[0].closed -and
        "$($matches[0].category.name)" -ceq "🤖 Agent logs") {
        return $matches[0]
    }
    if ($matches.Count -ne 0) {
        throw "Epic #$Epic Developer $Developer log appeared, changed or is closed; reconcile without retrying creation."
    }
    $category = @($refresh.categories | Where-Object {
        "$($_.name)" -ceq "🤖 Agent logs"
    })
    if ($category.Count -ne 1) {
        throw "Required Agent logs Discussion category is missing or ambiguous."
    }
    $body = "<!-- fingvibe:epic=$Epic developer=developer-$Developer -->`nAgent log for Epic #$Epic Developer $Developer."
    $title = "Epic #$Epic - Developer $Developer log"
    $mutation = 'mutation($input:CreateDiscussionInput!){createDiscussion(input:$input){discussion{id number title body url closed category{id name}}}}'
    $data = Invoke-ArchitectGraphQl $mutation @{
        input = @{
            repositoryId = $refresh.repositoryId
            categoryId = $category[0].id
            title = $title
            body = $body
        }
    }
    $created = $data.createDiscussion.discussion
    if (-not "$($created.id)") {
        throw "Epic #$Epic Developer $Developer log creation returned incomplete data; do not retry."
    }
    $verified = Get-ArchitectDiscussionByNumber ([int] $created.number)
    $verifyInventory = Get-ArchitectDiscussionInventory $Repository ${function:Invoke-ArchitectGraphQl}
    $verifyMatches = @(Find-ArchitectDeveloperDiscussion @($verifyInventory.discussions) $Developer)
    if ($verifyMatches.Count -ne 1 -or "$($verified.id)" -cne "$($created.id)" -or
        "$($verified.title)" -cne $title -or "$($verified.body)" -cne $body -or
        "$($verified.category.name)" -cne "🤖 Agent logs" -or [bool] $verified.closed) {
        throw "Epic #$Epic Developer $Developer log creation/readback failed; reconcile without retrying."
    }
    $verified
}

if ($Repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw "Invalid repository '$Repository'."
}
$null = gh auth status
if ($LASTEXITCODE -ne 0) { throw "GitHub authentication is required for Epic preparation." }

if ($Epic -le 0) {
    $epics = @(Read-ArchitectRest "repos/$Repository/issues?state=open&labels=type:epic&per_page=100" -Paginated)
    $options = [Collections.Generic.List[object]]::new()
    foreach ($issue in @($epics | Sort-Object number)) {
        $children = @(Read-ArchitectRest "repos/$Repository/issues/$($issue.number)/sub_issues?per_page=100" -Paginated)
        $options.Add((Get-ArchitectEpicOption $issue $children))
    }
    [pscustomobject]@{ schema = "fingvibe-architect-epic-options-v1"; options = @($options) } |
        ConvertTo-Json -Depth 20
    return
}

$data = Get-ArchitectPreparationData $Epic
$selectedIssue = @($data.issues | Where-Object { [int] $_.number -eq $Epic })
if ($selectedIssue.Count -ne 1 -or
    @($selectedIssue[0].labels | ForEach-Object { $_.name }) -notcontains "type:epic") {
    throw "#$Epic is not a verified type:epic issue."
}
$plan = Get-ArchitectDiscussionPlan $data.inventory.discussions $data.issues $data.epicChildren $Epic
$developerPlan = Get-ArchitectDeveloperPlan $data.inventory.discussions $Epic $DeveloperCount
if (-not $Apply) {
    [pscustomobject]@{
        schema = "fingvibe-architect-epic-preparation-plan-v1"
        epic = $Epic
        openDiscussionCounts = @(Get-ArchitectOpenDiscussionCounts $data.inventory.discussions)
        developerQuestion = $developerPlan.question
        developerDiscussions = @($developerPlan.entries)
        developerBlockers = @($developerPlan.blockers)
        close = @($plan.close)
        open = @($plan.open)
        blockers = @($plan.blockers)
        selected = $plan.selected
    } | ConvertTo-Json -Depth 20
    return
}
if ($plan.selected.action -eq "blocked") {
    $plan | ConvertTo-Json -Depth 20
    throw "Selected Epic has a Discussion blocker; no mutations were performed."
}
if ($DeveloperCount -lt 1) {
    throw "How many Developers will work on Epic #${Epic}? No mutations were performed."
}
if (@($developerPlan.blockers).Count -gt 0) {
    $developerPlan | ConvertTo-Json -Depth 20
    throw "Selected Epic has a Developer-log blocker; no mutations were performed."
}
$closed = [Collections.Generic.List[object]]::new()
foreach ($item in @($plan.close | Sort-Object discussion)) {
    $closed.Add((Close-ArchitectDiscussion $item))
}
$selectedDiscussion = if ($plan.selected.action -eq "reuse") {
    $current = Get-ArchitectDiscussionByNumber ([int] $plan.selected.discussion)
    if ("$($current.id)" -cne "$($plan.selected.id)" -or [bool] $current.closed) {
        throw "Selected Epic Discussion changed before verification."
    }
    $current
} elseif ($plan.selected.action -eq "create") {
    New-ArchitectEpicDiscussion $data.inventory
} else {
    throw "Selected Epic Discussion action is blocked."
}
$developerDiscussions = [Collections.Generic.List[object]]::new()
foreach ($entry in @($developerPlan.entries | Sort-Object developer)) {
    $current = if ($entry.action -eq "create") {
        New-ArchitectDeveloperDiscussion ([int] $entry.developer)
    } elseif ($entry.action -eq "reuse") {
        $verified = Get-ArchitectDiscussionByNumber ([int] $entry.discussion)
        if ("$($verified.id)" -cne "$($entry.id)" -or [bool] $verified.closed -or
            "$($verified.category.name)" -cne "🤖 Agent logs") {
            throw "Epic #$Epic Developer $($entry.developer) log changed before verification."
        }
        $verified
    } else {
        throw "Epic #$Epic Developer $($entry.developer) action is blocked."
    }
    $developerDiscussions.Add($current)
}
$finalInventory = Get-ArchitectDiscussionInventory $Repository ${function:Invoke-ArchitectGraphQl}
[pscustomobject]@{
    schema = "fingvibe-architect-epic-preparation-result-v1"
    epic = $Epic
    openDiscussionCounts = @(Get-ArchitectOpenDiscussionCounts $finalInventory.discussions)
    closed = @($closed | ForEach-Object {
        [pscustomobject]@{ discussion = $_.number; url = $_.url }
    })
    unresolved = @($plan.open)
    blockers = @($plan.blockers)
    selectedDiscussion = [pscustomobject]@{
        discussion = $selectedDiscussion.number
        url = $selectedDiscussion.url
        closed = [bool] $selectedDiscussion.closed
    }
    developerDiscussions = @($developerDiscussions | ForEach-Object {
        [pscustomobject]@{ discussion = $_.number; url = $_.url; closed = [bool] $_.closed }
    })
} | ConvertTo-Json -Depth 20
