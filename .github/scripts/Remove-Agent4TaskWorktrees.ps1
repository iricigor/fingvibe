[CmdletBinding()]
param(
    [int] $Issue,
    [string] $MergedHead,
    [string] $Repository = ".",
    [string] $Remote = "origin",
    [string] $Root
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Agent4TaskWorktree.ps1")

function Test-Agent4Ancestor([string] $Repository, [string] $Commit, [string] $Of) {
    git -C $Repository merge-base --is-ancestor $Commit $Of 2>$null
    $LASTEXITCODE -eq 0
}

# Removes an issue's task worktrees after its PR merged. MergedHead is the verified merged
# PR head; squash merges keep task commits out of main's history, so containment is checked
# against that head. Never forces: anything unsafe is skipped with a reason.
function Remove-Agent4TaskWorktrees([int] $Issue, [string] $MergedHead, [string] $Repository, [string] $Remote, [string] $Root) {
    if ($Issue -le 0) { throw "Positive issue number required." }
    if ($MergedHead -notmatch '^[0-9a-f]{40}$') { throw "Full lowercase merged PR head required." }
    if (-not $Root) { $Root = Get-Agent4WorktreeRoot $Repository }
    $Root = [IO.Path]::GetFullPath($Root)
    $current = [IO.Path]::GetFullPath((Invoke-Agent4Git $Repository @("rev-parse", "--show-toplevel")).Trim())
    git -C $Repository cat-file -e "$MergedHead^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) { $null = Invoke-Agent4Git $Repository @("fetch", "--quiet", $Remote, $MergedHead) }

    $removed = @(); $skipped = @()
    $candidates = @(Get-Agent4Worktrees $Repository | Where-Object {
        (Split-Path $_.path) -eq $Root -and (Split-Path $_.path -Leaf) -like "task-$Issue-*" })
    foreach ($tree in $candidates) {
        $reason = if ($tree.path -eq $current) { "current worktree" }
            elseif ($tree.locked) { "locked" }
            elseif (-not (Test-Path -LiteralPath $tree.path)) { "missing directory" }
            elseif ((git -C $tree.path status --porcelain 2>&1) -or $LASTEXITCODE -ne 0) { "uncommitted or untracked changes" }
            elseif (-not (Test-Agent4Ancestor $Repository $tree.head $MergedHead)) { "HEAD $($tree.head) not contained in merged head" }
        if ($reason) { $skipped += [ordered] @{ path = $tree.path; reason = $reason }; continue }
        $out = git -C $Repository worktree remove $tree.path 2>&1
        if ($LASTEXITCODE -ne 0) { $skipped += [ordered] @{ path = $tree.path; reason = "worktree remove failed: $($out -join ' ')" }; continue }
        $entry = [ordered] @{ path = $tree.path; branch = $tree.branch; branchDeleted = $false }
        if ($tree.branch) {
            # The tip was verified as contained in the merged head; -d alone rejects squash-merged branches.
            $out = git -C $Repository branch -D $tree.branch 2>&1
            if ($LASTEXITCODE -eq 0) { $entry.branchDeleted = $true } else { $entry.branchError = $out -join ' ' }
        }
        $removed += $entry
    }
    $null = Invoke-Agent4Git $Repository @("worktree", "prune")
    [ordered] @{ issue = $Issue; mergedHead = $MergedHead; root = $Root; removed = $removed; skipped = $skipped }
}

if ($MyInvocation.InvocationName -ne ".") {
    Remove-Agent4TaskWorktrees $Issue $MergedHead $Repository $Remote $Root | ConvertTo-Json -Depth 4 -Compress
}
