# Shared helpers for 4️⃣ per-assignment task worktrees.

function Invoke-Agent4Git([string] $Repository, [string[]] $Arguments) {
    $output = git -C $Repository @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed: $($output -join ' ')" }
    $output -join "`n"
}

# One root shared by every worktree of the same repository, next to its main checkout.
function Get-Agent4WorktreeRoot([string] $Repository) {
    $commonDir = Invoke-Agent4Git $Repository @("rev-parse", "--path-format=absolute", "--git-common-dir")
    $mainCheckout = Split-Path ([IO.Path]::GetFullPath($commonDir.Trim()))
    Join-Path (Split-Path $mainCheckout) ((Split-Path $mainCheckout -Leaf) + "-agent4-worktrees")
}

function Get-Agent4WorktreeName([int] $Issue, [string] $AssignmentId) {
    if ($Issue -le 0) { throw "Positive issue number required." }
    if ($AssignmentId -notmatch '^[A-Za-z0-9._:-]+$') { throw "Assignment ID must use letters, digits and ._:-" }
    # ':' is not valid in Windows paths.
    "task-$Issue-$($AssignmentId.Replace(':', '_'))"
}

function Get-Agent4Worktrees([string] $Repository) {
    $entries = @()
    $current = $null
    foreach ($line in (Invoke-Agent4Git $Repository @("worktree", "list", "--porcelain")) -split "`n") {
        if ($line -like "worktree *") {
            if ($current) { $entries += [pscustomobject] $current }
            $current = @{ path = [IO.Path]::GetFullPath($line.Substring(9)); head = $null; branch = $null; locked = $false }
        }
        elseif ($line -like "HEAD *") { $current.head = $line.Substring(5) }
        elseif ($line -like "branch refs/heads/*") { $current.branch = $line.Substring(18) }
        elseif ($line -like "locked*") { $current.locked = $true }
    }
    if ($current) { $entries += [pscustomobject] $current }
    $entries
}
