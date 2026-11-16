[CmdletBinding()]
param(
    [int] $Issue,
    [string] $AssignmentId,
    [ValidateSet("implement", "resume", "repair")] [string] $Action,
    [string] $Branch,
    [string] $ExpectedHead,
    [string] $Repository = ".",
    [string] $Remote = "origin",
    [string] $BaseBranch = "main",
    [string] $Root
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Agent4TaskWorktree.ps1")

# Creates a fresh worktree for one start assignment. Never reuses an existing path.
# implement: new branch from <remote>/<base>. resume/repair: detached at the verified pushed PR head.
function New-Agent4TaskWorktree([int] $Issue, [string] $AssignmentId, [string] $Action, [string] $Branch,
    [string] $ExpectedHead, [string] $Repository, [string] $Remote, [string] $BaseBranch, [string] $Root) {
    $name = Get-Agent4WorktreeName $Issue $AssignmentId
    if ($Action -notin @("implement", "resume", "repair")) { throw "Action must be implement, resume or repair." }
    if (-not $Root) { $Root = Get-Agent4WorktreeRoot $Repository }
    $path = Join-Path $Root $name
    if (Test-Path -LiteralPath $path) { throw "Worktree path already exists: $path" }
    $null = New-Item -ItemType Directory -Force -Path $Root

    if ($Action -eq "implement") {
        if (-not $Branch) { $Branch = "agent4/$name" }
        $null = Invoke-Agent4Git $Repository @("fetch", "--quiet", $Remote, $BaseBranch)
        $null = Invoke-Agent4Git $Repository @("worktree", "add", "--quiet", "-b", $Branch, $path, "$Remote/$BaseBranch")
        $detached = $false
    }
    else {
        if (-not $Branch -or $ExpectedHead -notmatch '^[0-9a-f]{40}$') {
            throw "$Action requires the PR branch and full lowercase expected head."
        }
        $null = Invoke-Agent4Git $Repository @("fetch", "--quiet", $Remote, $Branch)
        $pushed = (Invoke-Agent4Git $Repository @("rev-parse", "$Remote/$Branch")).Trim()
        if ($pushed -ne $ExpectedHead) { throw "Pushed head $pushed of $Branch differs from expected $ExpectedHead; reassess." }
        # Detached because the branch may still be checked out in an earlier worktree.
        $null = Invoke-Agent4Git $Repository @("worktree", "add", "--quiet", "--detach", $path, $ExpectedHead)
        $detached = $true
    }
    $head = (Invoke-Agent4Git $path @("rev-parse", "HEAD")).Trim()
    [ordered] @{ issue = $Issue; assignmentId = $AssignmentId; action = $Action; path = $path
        branch = $Branch; head = $head; detached = $detached
        push = if ($detached) { "git -C `"$path`" push $Remote HEAD:$Branch" } else { "git -C `"$path`" push -u $Remote $Branch" } }
}

if ($MyInvocation.InvocationName -ne ".") {
    New-Agent4TaskWorktree $Issue $AssignmentId $Action $Branch $ExpectedHead $Repository $Remote $BaseBranch $Root |
        ConvertTo-Json -Compress
}
