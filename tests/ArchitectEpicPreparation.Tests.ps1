$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot "..\.github\skills\architect-epic-preparation\scripts\ArchitectEpicPreparation.psm1") -Force

function Assert-GenericEpicPreparation([string] $Path) {
    $text = [IO.File]::ReadAllText($Path)
    if ([regex]::IsMatch($text, '(?im)Epic #\d+|issue #\d+|#[1-9]\d{2,}')) {
        throw "Architect Epic preparation source must not reference a specific repository issue: $Path"
    }
}

function Assert-ArchitectEqual($Actual, $Expected, [string] $Message) {
    if (($Actual -join "|") -cne ($Expected -join "|")) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}
function Assert-ArchitectThrows([scriptblock] $Action, [string] $Pattern) {
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected failure matching '$Pattern'."
}
function New-ArchitectIssue([int] $Number, [string] $State, [string[]] $Labels = @()) {
    [pscustomobject]@{
        number = $Number
        state = $State
        state_reason = $null
        html_url = "https://github.com/test/repo/issues/$Number"
        labels = @($Labels | ForEach-Object { [pscustomobject]@{ name = $_ } })
    }
}
function New-ArchitectDiscussion([int] $Number, [string] $Kind, [int] $Issue, [string] $Category, [bool] $Closed = $false) {
    [pscustomobject]@{
        id = "D$Number"
        number = $Number
        title = "$Kind #$Issue"
        body = "<!-- fingvibe:$Kind=$Issue -->"
        url = "https://github.com/test/repo/discussions/$Number"
        closed = $Closed
        category = [pscustomobject]@{ id = "C$Number"; name = $Category }
    }
}

$skillRoot = Join-Path $PSScriptRoot "..\.github\skills\architect-epic-preparation"
foreach ($path in @(
    (Join-Path $skillRoot "SKILL.md"),
    (Join-Path $skillRoot "scripts\ArchitectEpicPreparation.psm1"),
    (Join-Path $skillRoot "scripts\Prepare-ArchitectEpic.ps1")
)) {
    Assert-GenericEpicPreparation $path
}

$epic = [pscustomobject]@{
    number = 10
    title = "🔥 Epic: Aggregate preparation"
    html_url = "https://github.com/test/repo/issues/10"
    body = "## Goal`n`nPrepare the next bounded Epic without task evaluation.`n`n## Scope`nIgnored."
}
$children = @(
    (New-ArchitectIssue 11 "open" @("type:task", "decision-needed")),
    (New-ArchitectIssue 12 "closed" @("type:task", "size:small", "priority:normal")),
    (New-ArchitectIssue 13 "open" @("type:task", "active", "human-task")),
    (New-ArchitectIssue 14 "open" @("type:task", "status:blocked"))
)
$option = Get-ArchitectEpicOption $epic $children
Assert-ArchitectEqual $option.summary "Prepare the next bounded Epic without task evaluation." "Epic Goal summary"
Assert-ArchitectEqual @($option.total, $option.open, $option.closed) @(4, 3, 1) "Aggregate child counts"
if (@($option.warnings | Where-Object { $_ -like "*human decision*" }).Count -ne 1) {
    throw "Human-decision warning missing."
}
if (@($option.warnings | Where-Object { $_ -like "*human-led*" }).Count -ne 1) {
    throw "Human-task warning missing."
}
if (@($option.warnings | Where-Object { $_ -like "*missing size" }).Count -ne 1) {
    throw "Missing-size warning missing."
}
Assert-ArchitectEqual (
    Get-ArchitectEpicSummary "## Goal  Keep space-formatted legacy Epics readable.  ## Scope  Details."
) "Keep space-formatted legacy Epics readable." "Legacy space-formatted Goal summary"

$taskClosed = New-ArchitectDiscussion 101 "task" 1 "🛠️ Task conversations"
$taskOpen = New-ArchitectDiscussion 102 "task" 2 "🛠️ Task conversations"
$epicClosed = New-ArchitectDiscussion 103 "epic" 10 "🧭 Epic coordination"
$issues = @(
    (New-ArchitectIssue 1 "closed"),
    (New-ArchitectIssue 2 "open"),
    (New-ArchitectIssue 10 "closed" @("type:epic"))
)
$childrenByEpic = @(
    [pscustomobject]@{ epic = 10; children = @((New-ArchitectIssue 11 "closed"), (New-ArchitectIssue 12 "closed")) }
)
$plan = Get-ArchitectDiscussionPlan @($taskClosed, $taskOpen, $epicClosed) $issues $childrenByEpic 20
Assert-ArchitectEqual @($plan.close | ForEach-Object { $_.discussion }) @(101, 103) "Only closed associated work closes"
Assert-ArchitectEqual @($plan.open | ForEach-Object { $_.number }) @(2) "Open task remains open"
Assert-ArchitectEqual $plan.selected.action "create" "Missing selected mapping creates"

$openEpic = New-ArchitectIssue 20 "open" @("type:epic")
$openEpicDiscussion = New-ArchitectDiscussion 104 "epic" 20 "🧭 Epic coordination"
$unsafePlan = Get-ArchitectDiscussionPlan @($openEpicDiscussion) @($openEpic) @(
    [pscustomobject]@{ epic = 20; children = @((New-ArchitectIssue 21 "open")) }
) 20
Assert-ArchitectEqual $unsafePlan.close.Count 0 "Open-Epic Discussion is never closed"
Assert-ArchitectEqual $unsafePlan.open[0].openTasks 1 "Open child count is aggregate-only"
Assert-ArchitectEqual $unsafePlan.selected.action "reuse" "Existing selected mapping is reused"

$duplicate = New-ArchitectDiscussion 105 "epic" 20 "🧭 Epic coordination"
$duplicatePlan = Get-ArchitectDiscussionPlan @($openEpicDiscussion, $duplicate) @($openEpic) @(
    [pscustomobject]@{ epic = 20; children = @() }
) 20
if (@($duplicatePlan.blockers | Where-Object { $_.reason -like "Duplicate*" }).Count -ne 2) {
    throw "Both duplicate mappings must be blocked."
}
Assert-ArchitectEqual $duplicatePlan.selected.action "blocked" "Duplicate selected mapping blocks creation"

$wrongCategory = New-ArchitectDiscussion 106 "task" 1 "🧭 Epic coordination"
$wrongPlan = Get-ArchitectDiscussionPlan @($wrongCategory) @((New-ArchitectIssue 1 "closed")) @() 20
Assert-ArchitectEqual $wrongPlan.blockers[0].discussion 106 "Wrong category blocks mutation"
$unmapped = New-ArchitectDiscussion 107 "task" 1 "🛠️ Task conversations"
$unmapped.body = ""
$unmappedPlan = Get-ArchitectDiscussionPlan @($unmapped) @((New-ArchitectIssue 1 "closed")) @() 20
Assert-ArchitectEqual $unmappedPlan.blockers[0].discussion 107 "Open unmarked task Discussion is reported"

$developerLog = [pscustomobject]@{
    id = "DA1"
    number = 120
    body = "<!-- fingvibe:epic=10 developer=developer-1 -->"
    url = "https://github.com/test/repo/discussions/120"
    closed = $false
    category = [pscustomobject]@{ name = "🤖 Agent logs" }
}
$developerPlan = Get-ArchitectDeveloperPlan @($developerLog) 10 2
Assert-ArchitectEqual @($developerPlan.entries | ForEach-Object { $_.action }) @("reuse", "create") "One log per confirmed Developer"
Assert-ArchitectEqual $developerPlan.entries[0].developer 1 "Developer identity"
Assert-ArchitectEqual $developerPlan.blockers.Count 0 "Complete Developer plan has no blockers"
$developerQuestion = Get-ArchitectDeveloperPlan @() 10 0
Assert-ArchitectEqual $developerQuestion.question "How many Developers will work on Epic #10?" "Ask for Developer count"
$closedDeveloperLog = $developerLog.PSObject.Copy()
$closedDeveloperLog.closed = $true
$closedDeveloperPlan = Get-ArchitectDeveloperPlan @($closedDeveloperLog) 10 1
Assert-ArchitectEqual $closedDeveloperPlan.blockers.Count 1 "Closed Developer mapping blocks recreation"
$counts = @(Get-ArchitectOpenDiscussionCounts @(
    $openEpicDiscussion,
    $taskClosed,
    $developerLog,
    [pscustomobject]@{ closed = $true; category = [pscustomobject]@{ name = "🤖 Agent logs" } }
))
Assert-ArchitectEqual $counts.Count 3 "Open categories are counted and closed-only logs are omitted"
if (@($counts | Where-Object { $_.category -eq "🛠️ Task conversations" -and $_.count -eq 1 }).Count -ne 1) {
    throw "Open task-conversation count is missing."
}
if (@($counts | Where-Object { $_.category -eq "🤖 Agent logs" -and $_.count -eq 1 }).Count -ne 1) {
    throw "Open Agent-log count is missing."
}
if (@($counts | Where-Object { $_.category -eq "🧭 Epic coordination" -and $_.count -eq 1 }).Count -ne 1) {
    throw "Open Epic coordination count is missing."
}

$script:inventoryCalls = 0
$inventoryApi = {
    param($Query, $Variables)
    $script:inventoryCalls++
    if ($script:inventoryCalls -eq 1) {
        return @{
            repository = @{
                id = "R1"
                nameWithOwner = "test/repo"
                discussionCategories = @{
                    nodes = @(@{ id = "C1"; name = "🧭 Epic coordination" })
                    pageInfo = @{ hasNextPage = $false }
                }
                discussions = @{
                    nodes = @((New-ArchitectDiscussion 1 "epic" 10 "🧭 Epic coordination"))
                    pageInfo = @{ hasNextPage = $true; endCursor = "next" }
                }
            }
        }
    }
    @{
        repository = @{
            id = "R1"
            nameWithOwner = "test/repo"
            discussionCategories = @{
                nodes = @(@{ id = "C1"; name = "🧭 Epic coordination" })
                pageInfo = @{ hasNextPage = $false }
            }
            discussions = @{
                nodes = @((New-ArchitectDiscussion 2 "epic" 20 "🧭 Epic coordination"))
                pageInfo = @{ hasNextPage = $true; endCursor = "next" }
            }
        }
    }
}
Assert-ArchitectThrows {
    $null = Get-ArchitectDiscussionInventory "test/repo" $inventoryApi
} "*Invalid Discussion inventory cursor*"

$script:inventoryCalls = 0
$missingPaginationApi = {
    param($Query, $Variables)
    @{
        repository = @{
            id = "R1"
            nameWithOwner = "test/repo"
            discussionCategories = @{
                nodes = @()
                pageInfo = @{ hasNextPage = $false }
            }
            discussions = @{
                nodes = @()
                pageInfo = @{}
            }
        }
    }
}
Assert-ArchitectThrows {
    $null = Get-ArchitectDiscussionInventory "test/repo" $missingPaginationApi
} "*pagination is incomplete*"

Write-Host "Architect Epic preparation regression tests passed."
