[CmdletBinding()]
param(
    [string] $BaseRevision,
    [string] $HeadRevision = "HEAD",
    [switch] $Manual
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "UiReviewScenarios.ps1")

# Reviewed agent-loop/Dispatcher automation: only their own core-test steps use these, never build,
# installer, native UI, publication, Full-validation or release jobs. New scripts are not allow-listed.
$PrValidationNonNativeScripts = @(
    "Agent3Coordination.psm1", "Agent3Discussions.ps1", "Agent3Protocol.ps1", "Agent3Publication.ps1",
    "Agent4Coordination.psm1", "Agent4TaskWorktree.ps1", "Get-Agent3DispatcherPreflight.ps1",
    "Get-Agent4AssignmentPlan.ps1", "Get-Agent4DispatcherPacket.ps1", "Get-DispatcherPreflight.ps1",
    "Invoke-Agent3DispatcherGate.ps1", "Invoke-Agent3Message.ps1", "Invoke-Agent4Coordination.ps1",
    "Invoke-Agent4RepairAction.ps1", "Invoke-DispatcherGate.ps1", "New-Agent4TaskWorktree.ps1",
    "Remove-Agent4TaskWorktrees.ps1", "Set-Agent4DiscussionParticipant.ps1", "Set-Agent4TaskClaim.ps1"
)
# Standalone inspectors outside FingVibe.sln, the app build and the installer; core tests still compile some sources.
$PrValidationNonNativeTools = '^tools/(DecoX50Inspector|Ex220Inspector)/'
# Native UI test code: regression modules, UI entry scripts and the helpers/fixtures they load.
$PrValidationNativeTests = '^tests/(UiRegression/|[^/]+\.Ui\.(Tests|Helpers)\.ps1$|[^/]+\.Fixture\.ps1$|(SidebarNavigation|UiReviewScreenshot(\.Content)?|Installer\.Lifecycle)\.Tests\.ps1$|Inventory\.Sqlite\.Helpers\.ps1$)'

function Test-PrValidationNonNativePath([string] $Path) {
    $Path -cmatch $PrValidationNonNativeTools -or
        ($Path -cmatch '^\.github/scripts/([^/]+)$' -and $Matches[1] -cin $PrValidationNonNativeScripts)
}

function Get-PrValidationChanges {
    param([string[]] $Paths, [switch] $Manual)

    $tests = [bool] $Manual
    $build = [bool] $Manual
    $ui = [bool] $Manual
    foreach ($path in $Paths) {
        if ($path -match '^(src/|tests/|tools/|\.github/(scripts/|workflows/|agents/ui-ux-reviewer\.agent\.md))' -or
            $path -match '(^|/)([^/]+\.(sln|slnx|props|targets)|global\.json|[Nn]u[Gg]et\.[Cc]onfig)$') {
            $tests = $true
        }
        if (Test-PrValidationNonNativePath $path) { continue }
        if ($path -match '^(src/|tools/|\.github/(scripts/|workflows/|agents/ui-ux-reviewer\.agent\.md))' -or
            $path -match $PrValidationNativeTests -or
            $path -match '(^|/)([^/]+\.(sln|slnx|props|targets)|global\.json|[Nn]u[Gg]et\.[Cc]onfig)$') {
            $build = $true
            $ui = $true
        }
    }
    [pscustomobject]@{ Tests = $tests; Build = $build; Ui = $ui }
}

if ($MyInvocation.InvocationName -ne ".") {
    if (-not $Manual -and [string]::IsNullOrWhiteSpace($BaseRevision)) {
        throw "BaseRevision is required for automatic PR validation."
    }
    $paths = if ($Manual) { @() } else {
        $mergeBase = Invoke-UiReviewGit (Get-Location).Path @("merge-base", $BaseRevision, $HeadRevision)
        @(Invoke-UiReviewGit (Get-Location).Path @("diff", "--name-only", "--no-renames", $mergeBase, $HeadRevision, "--"))
    }
    $changes = Get-PrValidationChanges -Paths $paths -Manual:$Manual
    foreach ($name in @("Tests", "Build", "Ui")) {
        $line = "$($name.ToLowerInvariant())=$($changes.$name.ToString().ToLowerInvariant())"
        Write-Host $line
        if ($env:GITHUB_OUTPUT) { $line >> $env:GITHUB_OUTPUT }
    }
    if ($env:GITHUB_STEP_SUMMARY) {
        "Validation plan: tests=$($changes.Tests), build=$($changes.Build), UI=$($changes.Ui). Documentation-only changes skip native build/capture; reviewed agent-loop scripts, standalone inspectors and non-native test changes run tests only; native UI test changes run the native path." >> $env:GITHUB_STEP_SUMMARY
    }
}
