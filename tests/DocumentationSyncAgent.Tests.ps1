$ErrorActionPreference = "Stop"
$repoRoot = Split-Path $PSScriptRoot -Parent
$stateScript = Join-Path $repoRoot ".github\scripts\Get-DocumentationSyncState.ps1"
$publishScript = Join-Path $repoRoot ".github\scripts\Publish-DocumentationSyncRun.ps1"

function Assert-SyncTrue($Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-SyncThrows([scriptblock] $Action, [string] $Expected) {
    try {
        & $Action
    } catch {
        if ($_ -notlike "*$Expected*") { throw }
        return
    }
    throw "Expected failure containing '$Expected'."
}

. $stateScript
. $publishScript

$agent = Get-Content -LiteralPath (Join-Path $repoRoot ".github\agents\documentation-sync.agent.md") -Raw
$guide = Get-Content -LiteralPath (Join-Path $repoRoot "docs\documentation-sync.md") -Raw
$prompt = Get-Content -LiteralPath (Join-Path $repoRoot "docs\automation-prompts\documentation-sync.md") -Raw

Assert-SyncTrue ($agent -match '(?m)^name: Documentation sync\r?$') "The user-selectable agent must have the agreed name."
Assert-SyncTrue ($agent.Contains("24 hours") -and
    $agent.Contains("Get-DocumentationSyncState.ps1")) "The agent must use the preflight contract for its exact minimum lookback."
Assert-SyncTrue ($agent.Contains("Publish-DocumentationSyncRun.ps1") -and
    $agent.Contains("keep the previous successful checkpoint")) "The agent must retain checkpoints on blocked runs."
Assert-SyncTrue ($agent.Contains("existing agent-owned PR") -and
    $agent.Contains("Do not merge the PR")) "The agent must reuse its open PR and leave merge to a human."
Assert-SyncTrue ($agent.Contains('Never add `Closes #650`') -and
    $agent.Contains("Do not capture screenshots")) "The run must not close task #650 or fabricate screenshots."
Assert-SyncTrue (([regex]::Matches($prompt, '(?m)^[^#\s].+$')).Count -eq 1) "The Automation UI prompt must remain one substantive line."
Assert-SyncTrue ($guide.Contains("daily at the machine's local 03:00") -and
    $guide.Contains("disabled until an approved manual trial")) "The setup guide must preserve local schedule and activation gates."

$shaA = "a" * 40
$shaB = "b" * 40
$shaC = "c" * 40
$now = [DateTimeOffset]::Parse("2026-11-20T21:00:00Z")
$emptyCheckpoint = Get-DocumentationSyncCheckpoint -Comments @()
Assert-SyncTrue ($null -eq $emptyCheckpoint) "A task with no run history must have no checkpoint."
$run = @{
    schema = "fingvibe-documentation-sync-run-v1"
    status = "clean"
    startedAt = "2026-11-19T01:00:00Z"
    completedAt = "2026-11-19T02:00:00Z"
    startSha = $shaA
    auditedMainSha = $shaB
    pullRequestUrl = $null
    evidence = @("No supported edit.")
    uncertainties = @()
    blocker = $null
}
$cleanComment = @{
    id = 10
    body = "<!-- documentation-sync-run:v1`n$($run | ConvertTo-Json -Compress)`n-->"
}
$blockedRun = $run.Clone()
$blockedRun.status = "blocked"
$blockedRun.completedAt = "2026-11-20T20:00:00Z"
$blockedRun.auditedMainSha = $shaC
$blockedRun.blocker = "Human PR conflict."
$blockedComment = @{
    id = 11
    body = "<!-- documentation-sync-run:v1`n$($blockedRun | ConvertTo-Json -Compress)`n-->"
}
$checkpoint = Get-DocumentationSyncCheckpoint -Comments @($cleanComment, $blockedComment)
Assert-SyncTrue ($checkpoint.auditedMainSha -eq $shaB) "Blocked runs must not advance the checkpoint."
$malformedComment = @{
    id = 12
    body = "<!-- documentation-sync-run:v1`n{`"schema`":`"wrong`"}`n-->"
}
Assert-SyncThrows { Get-DocumentationSyncCheckpoint -Comments @($malformedComment) } "schema is invalid"

$validPr = @{
    number = 77
    state = "open"
    base = @{ ref = "main" }
    head = @{
        ref = "copilot/documentation-sync/20261120-$($shaC.Substring(0, 7))"
        repo = @{ full_name = "iricigor/fingvibe" }
    }
    title = "Documentation sync: abc1234..7654321"
    body = "<!-- documentation-sync-agent:650 -->`nRelated to #650."
    html_url = "https://github.com/iricigor/fingvibe/pull/77"
}
$selected = Select-DocumentationSyncPullRequest -PullRequests @($validPr)
Assert-SyncTrue ($selected.number -eq 77) "A uniquely marked open agent PR must be reused."
Assert-SyncTrue ($null -eq (Select-DocumentationSyncPullRequest -PullRequests @())) "No open PR must be a valid first-run state."
$humanPr = $validPr.Clone()
$humanPr.number = 78
$humanPr.head = @{
    ref = "docs-human-refresh"
    repo = @{ full_name = "iricigor/fingvibe" }
}
$humanPr.body = "Refresh docs."
Assert-SyncTrue ($null -eq (Select-DocumentationSyncPullRequest -PullRequests @($humanPr))) "Human-owned PRs must not be selected for reuse."
$second = $validPr | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
$second.number = 79
Assert-SyncThrows { Select-DocumentationSyncPullRequest -PullRequests @($validPr, $second) } "Multiple agent-owned"

$merged = $validPr | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
$merged.state = "closed"
Assert-SyncTrue ($null -eq (Select-DocumentationSyncPullRequest -PullRequests @($merged))) "A merged/closed PR must not be reused."

$body = New-DocumentationSyncRunBody `
    -Status "clean" `
    -StartedAt $now.AddMinutes(-2) `
    -CompletedAt $now `
    -StartSha $shaA `
    -AuditedMainSha $shaC `
    -Evidence @("No supported Markdown edit.")
Assert-SyncTrue ($body.Contains("documentation-sync-run:v1") -and
    $body.Contains("No supported Markdown edit.")) "A clean run must publish a durable, evidence-bearing record."
Assert-SyncThrows {
    New-DocumentationSyncRunBody `
        -Status "updated" `
        -StartedAt $now.AddMinutes(-2) `
        -CompletedAt $now `
        -StartSha $shaA `
        -AuditedMainSha $shaC
} "requires a verifiable GitHub pull request URL"
Assert-SyncThrows {
    New-DocumentationSyncRunBody `
        -Status "blocked" `
        -StartedAt $now.AddMinutes(-2) `
        -CompletedAt $now `
        -StartSha $shaA `
        -AuditedMainSha $shaC
} "requires an explicit blocker"

$fixture = Join-Path ([IO.Path]::GetTempPath()) ("fingvibe-doc-sync-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    & git -C $fixture init --quiet
    & git -C $fixture config user.name Fixture
    & git -C $fixture config user.email fixture@example.invalid
    "initial" | Set-Content -LiteralPath (Join-Path $fixture "README.md")
    & git -C $fixture add README.md
    $env:GIT_AUTHOR_DATE = "2026-11-17T00:00:00Z"
    $env:GIT_COMMITTER_DATE = $env:GIT_AUTHOR_DATE
    & git -C $fixture commit --quiet -m "Initial"
    Remove-Item Env:GIT_AUTHOR_DATE
    Remove-Item Env:GIT_COMMITTER_DATE

    "older" | Add-Content -LiteralPath (Join-Path $fixture "README.md")
    & git -C $fixture add README.md
    $env:GIT_AUTHOR_DATE = "2026-11-18T00:00:00Z"
    $env:GIT_COMMITTER_DATE = $env:GIT_AUTHOR_DATE
    & git -C $fixture commit --quiet -m "Older"
    Remove-Item Env:GIT_AUTHOR_DATE
    Remove-Item Env:GIT_COMMITTER_DATE
    $olderSha = (& git -C $fixture rev-parse HEAD).Trim()

    "recent" | Add-Content -LiteralPath (Join-Path $fixture "README.md")
    & git -C $fixture add README.md
    $env:GIT_AUTHOR_DATE = "2026-11-20T18:00:00Z"
    $env:GIT_COMMITTER_DATE = $env:GIT_AUTHOR_DATE
    & git -C $fixture commit --quiet -m "Recent"
    Remove-Item Env:GIT_AUTHOR_DATE
    Remove-Item Env:GIT_COMMITTER_DATE
    $head = (& git -C $fixture rev-parse HEAD).Trim()

    $oldCheckpoint = @{
        auditedMainSha = $olderSha
    }
    $window = Resolve-DocumentationSyncStart `
        -RepositoryPath $fixture `
        -HeadSha $head `
        -Checkpoint $oldCheckpoint `
        -NowUtc $now
    Assert-SyncTrue ($window.startSha -eq $olderSha) "A checkpoint older than 24 hours must retain older work."

    $recentCheckpoint = @{
        auditedMainSha = $head
    }
    $window = Resolve-DocumentationSyncStart `
        -RepositoryPath $fixture `
        -HeadSha $head `
        -Checkpoint $recentCheckpoint `
        -NowUtc $now
    Assert-SyncTrue ($window.startSha -ne $head -and $window.cutoffSha -ne $head) "A recent checkpoint must still expand to the 24-hour boundary."

    $window = Resolve-DocumentationSyncStart `
        -RepositoryPath $fixture `
        -HeadSha $head `
        -Checkpoint $null `
        -NowUtc $now
    Assert-SyncTrue ($window.startSha -eq $window.cutoffSha) "A first run must start at the 24-hour boundary."
} finally {
    Remove-Item Env:GIT_AUTHOR_DATE -ErrorAction SilentlyContinue
    Remove-Item Env:GIT_COMMITTER_DATE -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fixture -Recurse -Force
}

Write-Host "Documentation sync agent, state and run-record fixtures passed."
