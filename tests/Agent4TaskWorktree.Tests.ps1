$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\.github\scripts\New-Agent4TaskWorktree.ps1")
. (Join-Path $PSScriptRoot "..\.github\scripts\Remove-Agent4TaskWorktrees.ps1")
function Assert-True($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Assert-Fails([scriptblock] $Action, [string] $Pattern) {
    try { & $Action | Out-Null }
    catch { if ($_.Exception.Message -notlike $Pattern) { throw }; return }
    throw "Expected failure matching $Pattern."
}
function Invoke-TestGit([string] $Path) { $out = git -C $Path @args 2>&1; if ($LASTEXITCODE -ne 0) { throw "git $args failed: $out" }; $out }
function Commit-File([string] $Path, [string] $Name) {
    Set-Content -LiteralPath (Join-Path $Path $Name) -Value $Name
    Invoke-TestGit $Path add $Name | Out-Null
    Invoke-TestGit $Path -c user.name=t -c user.email=t@t commit -q -m $Name | Out-Null
    (Invoke-TestGit $Path rev-parse HEAD).Trim()
}

$temp = Join-Path ([IO.Path]::GetTempPath()) ("fingvibe-loop4-worktree-test-" + [guid]::NewGuid())
try {
    $remote = Join-Path $temp "remote.git"
    $main = Join-Path $temp "fingvibe"
    git init -q --bare -b main $remote
    git clone -q $remote $main 2>$null
    Commit-File $main "base.txt" | Out-Null
    Invoke-TestGit $main push -q origin HEAD:main | Out-Null
    $expectedRoot = Join-Path $temp "fingvibe-agent4-worktrees"
    Assert-True ((Get-Agent4WorktreeRoot $main) -eq $expectedRoot) "Root sits next to the main checkout."
    $session = Join-Path $temp "session"
    Invoke-TestGit $main worktree add -q -b session $session | Out-Null
    Assert-True ((Get-Agent4WorktreeRoot $session) -eq $expectedRoot) "Every worktree shares the root."
    Assert-Fails { Get-Agent4WorktreeName 0 "a1" } "*Positive issue*"
    Assert-Fails { Get-Agent4WorktreeName 5 "a/b" } "*Assignment ID*"

    # implement: new branch from origin/main, run from a Developer's session worktree.
    $impl = New-Agent4TaskWorktree 5 "a:1" implement "" "" $session origin main ""
    Assert-True ($impl.path -eq (Join-Path $expectedRoot "task-5-a_1") -and $impl.branch -eq "agent4/task-5-a_1" -and
        -not $impl.detached) "Implement creates a named branch worktree."
    Assert-Fails { New-Agent4TaskWorktree 5 "a:1" implement "" "" $session origin main "" } "*already exists*"
    $first = Commit-File $impl.path "task.txt"
    Invoke-TestGit $impl.path push -q -u origin agent4/task-5-a_1 | Out-Null

    # repair: detached at the verified pushed head, even though the branch is checked out elsewhere.
    Assert-Fails { New-Agent4TaskWorktree 5 "a2" repair "agent4/task-5-a_1" ("0" * 40) $session origin main "" } "*differs from expected*"
    Assert-Fails { New-Agent4TaskWorktree 5 "a2" repair "agent4/task-5-a_1" "" $session origin main "" } "*expected head*"
    $repair = New-Agent4TaskWorktree 5 "a2" repair "agent4/task-5-a_1" $first $session origin main ""
    Assert-True ($repair.detached -and $repair.head -eq $first) "Repair is detached at the expected head."
    $final = Commit-File $repair.path "fix.txt"
    Invoke-TestGit $repair.path push -q origin HEAD:agent4/task-5-a_1 | Out-Null

    # Unrelated issue and a dirty worktree for the same issue.
    $other = New-Agent4TaskWorktree 50 "b1" implement "" "" $session origin main ""
    $dirty = New-Agent4TaskWorktree 5 "a3" repair "agent4/task-5-a_1" $final $session origin main ""
    Set-Content -LiteralPath (Join-Path $dirty.path "scratch.txt") -Value "x"
    $unmerged = New-Agent4TaskWorktree 5 "a4" repair "agent4/task-5-a_1" $final $session origin main ""
    Commit-File $unmerged.path "late.txt" | Out-Null

    # Squash merge: main gets a new commit; task commits are not ancestors of main.
    Invoke-TestGit $main merge -q --squash origin/agent4/task-5-a_1 | Out-Null
    Invoke-TestGit $main -c user.name=t -c user.email=t@t commit -q -m "squash" | Out-Null
    Invoke-TestGit $main push -q origin HEAD:main | Out-Null

    Assert-Fails { Remove-Agent4TaskWorktrees 5 "abc" $session origin "" } "*merged PR head*"
    $result = Remove-Agent4TaskWorktrees 5 $final $session origin ""
    $removedPaths = @($result.removed | ForEach-Object path)
    Assert-True ($removedPaths.Count -eq 2 -and $impl.path -in $removedPaths -and $repair.path -in $removedPaths) "Clean contained worktrees are removed."
    Assert-True (-not (Test-Path $impl.path) -and -not (Test-Path $repair.path)) "Removed directories are gone."
    Assert-True (@($result.removed | Where-Object branch -EQ "agent4/task-5-a_1")[0].branchDeleted) "Squash-merged task branch is deleted."
    $reasons = @{}; foreach ($s in $result.skipped) { $reasons[$s.path] = $s.reason }
    Assert-True ($reasons[$dirty.path] -like "*untracked*" -and (Test-Path $dirty.path)) "Dirty worktree is kept."
    Assert-True ($reasons[$unmerged.path] -like "*not contained*" -and (Test-Path $unmerged.path)) "Unmerged commits are kept."
    Assert-True ($reasons.Count -eq 2 -and (Test-Path $other.path) -and (Test-Path $session)) "Other issues and sessions are untouched."
    "Agent4 task worktree tests passed."
}
finally {
    if (Test-Path $temp) { Remove-Item -Recurse -Force $temp -ErrorAction SilentlyContinue }
}
