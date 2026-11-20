# Publication and final gate: failure diagnostics, the required ui-ux-review gate and draft readiness.
if ($publishJob -notmatch 'INSTALLER_RESULT: \$\{\{ needs.installer.result \}\}' -or
    $publishJob -notmatch "needs.installer.result == 'failure'" -or
    $publishJob -notmatch 'Installer packaging, lifecycle validation, or tested download publication failed') {
    throw "Installer failures must be explained by the existing failure publisher."
}

foreach ($wrapper in @(
    @{ Step = "Exercise primary UI interactions"; Upload = "Upload UI smoke diagnostics"; Part = "Smoke"
        Directory = "artifacts\ui-smoke"; Log = "smoke-test.log"; Precreated = $false }
    @{ Step = "Exercise People and Rooms names and assignments"; Upload = "Upload UI assignment diagnostics"; Part = "Assignments"
        Directory = "artifacts\ui-assignments"; Log = "assignments.log"; Precreated = $false }
    @{ Step = "Capture required views"; Upload = "Upload UI review captures"; Part = "Capture"
        Directory = "artifacts\ui-review"; Log = "capture.log"; Precreated = $true }
    @{ Step = "Capture documentation Devices and Room map showcase"; Upload = "Upload UI review captures"; Part = "Showcase"
        Directory = "artifacts\ui-review"; Log = "documentation-devices.log"; Precreated = $true }
)) {
    $smokeMatch = [regex]::Match($workflow, '(?s)- name: ' + [regex]::Escape($wrapper.Step) + '.*?run: \|\r?\n(.*?)(?=\r?\n      - name: |\z)')
    if (-not $smokeMatch.Success) { throw "UI $($wrapper.Part) wrapper was not found." }
    if ($workflow -notmatch ('- name: ' + [regex]::Escape($wrapper.Upload))) { throw "UI $($wrapper.Part) diagnostic upload was not found." }
    $smoke = [scriptblock]::Create(($smokeMatch.Groups[1].Value -replace '(?m)^          ', '' -replace '\$\{\{ github.workspace \}\}', '$env:GITHUB_WORKSPACE'))
    $fixture = Join-Path ([System.IO.Path]::GetTempPath()) "fingvibe-smoke-failure-$([Guid]::NewGuid())"
    $savedWorkspace = $env:GITHUB_WORKSPACE
    try {
        $runner = if ($wrapper.Part -eq 'Showcase') { 'tests\DocumentationDevices.Ui.Tests.ps1' } else { '.github\scripts\Invoke-UiReview.ps1' }
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent (Join-Path $fixture $runner)) -Force
        # Capture's plan step creates its directory first; smoke must create its own.
        if ($wrapper.Precreated) { $null = New-Item -ItemType Directory -Path (Join-Path $fixture $wrapper.Directory) -Force }
        @'
param($Part, $AppPath, $ScreenshotDirectory, $CapturePlanPath)
if (-not $Part) { $Part = 'Showcase' }
"partial screenshot" | Set-Content (Join-Path $ScreenshotDirectory "partial.png")
"driver failure details" | Set-Content (Join-Path $ScreenshotDirectory "driver.log")
throw "Simulated native $Part failure"
'@ | Set-Content (Join-Path $fixture $runner)
        $env:GITHUB_WORKSPACE = $fixture
        Push-Location $fixture
        try {
            Assert-Throws { & $smoke } "*Simulated native $($wrapper.Part) failure*"
            foreach ($file in @("partial.png", "driver.log", $wrapper.Log)) {
                if (-not (Test-Path -LiteralPath (Join-Path $fixture "$($wrapper.Directory)\$file"))) {
                    throw "$($wrapper.Part) failure diagnostics must retain $file."
                }
            }
            $transcript = Get-Content (Join-Path $fixture "$($wrapper.Directory)\$($wrapper.Log)") -Raw
            if (-not $transcript.Contains("Simulated native $($wrapper.Part) failure")) { throw "The $($wrapper.Part) failure transcript must retain the original error." }
        } finally {
            Pop-Location
        }
    } finally {
        $env:GITHUB_WORKSPACE = $savedWorkspace
        Remove-Item -LiteralPath $fixture -Recurse -Force
    }
}

$gateMatch = [regex]::Match($workflow, '(?s)- name: Report validation result.*?run: \|\r?\n(.*?)(?=\r?\n  [a-z][a-z-]*:\r?\n|\z)')
if (-not $gateMatch.Success) { throw "Required UI gate script was not found." }
$gate = [scriptblock]::Create(($gateMatch.Groups[1].Value -replace '(?m)^          ', ''))
$names = @("CHANGES_RESULT", "COVERAGE_RESULT", "TEST_RESULT", "BUILD_RESULT", "INSTALLER_RESULT", "TEST_REQUIRED", "BUILD_REQUIRED", "UI_REQUIRED", "SMOKE_RESULT", "ASSIGNMENTS_RESULT", "CAPTURE_RESULT", "REGRESSION_RESULT", "PUBLISH_RESULT", "TRUSTED", "EVENT_NAME", "GITHUB_STEP_SUMMARY")
$saved = @{}
$summary = Join-Path ([System.IO.Path]::GetTempPath()) "fingvibe-gate-$([Guid]::NewGuid()).txt"
try {
    foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    $env:GITHUB_STEP_SUMMARY = $summary
    $env:CHANGES_RESULT = "success"
    $env:COVERAGE_RESULT = "success"
    $env:TEST_RESULT = "success"
    $env:BUILD_RESULT = "success"
    $env:INSTALLER_RESULT = "success"
    $env:TEST_REQUIRED = "true"
    $env:BUILD_REQUIRED = "true"
    $env:UI_REQUIRED = "true"
    $env:SMOKE_RESULT = "success"
    $env:ASSIGNMENTS_RESULT = "success"
    $env:CAPTURE_RESULT = "success"
    $env:REGRESSION_RESULT = "success"
    $env:PUBLISH_RESULT = "success"
    $env:TRUSTED = "true"
    $env:EVENT_NAME = "pull_request"
    & $gate
    foreach ($name in @("TEST_RESULT", "BUILD_RESULT", "INSTALLER_RESULT", "SMOKE_RESULT", "ASSIGNMENTS_RESULT", "CAPTURE_RESULT", "REGRESSION_RESULT", "PUBLISH_RESULT")) {
        foreach ($result in @("failure", "cancelled", "skipped", "")) {
            [Environment]::SetEnvironmentVariable($name, $result)
            Assert-Throws { & $gate } "*did not*"
        }
        [Environment]::SetEnvironmentVariable($name, "success")
    }
    foreach ($result in @("failure", "cancelled", "skipped", "")) {
        $env:COVERAGE_RESULT = $result
        Assert-Throws { & $gate } "*Deterministic PR regression coverage did not*"
    }
    $env:COVERAGE_RESULT = "success"
    foreach ($name in @("TEST_REQUIRED", "BUILD_REQUIRED", "UI_REQUIRED")) {
        foreach ($value in @("", "invalid")) {
            [Environment]::SetEnvironmentVariable($name, $value)
            Assert-Throws { & $gate } "*missing or invalid requirements*"
        }
        [Environment]::SetEnvironmentVariable($name, "true")
    }
    $env:CAPTURE_RESULT = "success"
    $env:PUBLISH_RESULT = "failure"
    Assert-Throws { & $gate } "*publication/commenting did not complete*"
    $env:PUBLISH_RESULT = "skipped"
    $env:COVERAGE_RESULT = "skipped"
    $env:EVENT_NAME = "workflow_dispatch"
    & $gate
    $env:EVENT_NAME = "pull_request"
    $env:COVERAGE_RESULT = "success"
    $env:TRUSTED = "false"
    $env:SMOKE_RESULT = "skipped"
    $env:ASSIGNMENTS_RESULT = "skipped"
    $env:CAPTURE_RESULT = "skipped"
    $env:REGRESSION_RESULT = "skipped"
    & $gate
    foreach ($result in @("failure", "cancelled", "skipped", "")) {
        $env:INSTALLER_RESULT = $result
        Assert-Throws { & $gate } "*installer validation/download publication did not complete*"
    }
    $env:INSTALLER_RESULT = "success"
    $env:TRUSTED = "true"
    $env:UI_REQUIRED = "false"
    $env:TEST_REQUIRED = "false"
    $env:BUILD_REQUIRED = "false"
    $env:TEST_RESULT = "skipped"
    $env:BUILD_RESULT = "skipped"
    $env:INSTALLER_RESULT = "skipped"
    $env:PUBLISH_RESULT = "skipped"
    & $gate
    $env:TEST_REQUIRED = "true"
    $env:TEST_RESULT = "success"
    & $gate
    $env:TEST_RESULT = "skipped"
    Assert-Throws { & $gate } "*Prerequisite tests/build did not pass*"
    $env:TEST_RESULT = "failure"
    Assert-Throws { & $gate } "*Prerequisite tests/build did not pass*"
    foreach ($result in @("failure", "cancelled", "skipped", "")) {
        $env:CHANGES_RESULT = $result
        Assert-Throws { & $gate } "*Validation planning failed*"
    }
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    if (Test-Path -LiteralPath $summary) { Remove-Item -LiteralPath $summary }
}

# Draft-to-ready promotion: only after the aggregate gate passes on a first-attempt opened/synchronize run.
$readyJob = Get-WorkflowJob ready-for-review
foreach ($pattern in @(
    'needs: ui-ux-review\r?\n',
    "!cancelled\(\)\s+&& needs\.ui-ux-review\.result == 'success'",
    "github\.event_name == 'pull_request'",
    "\(github\.event\.action == 'opened' \|\| github\.event\.action == 'synchronize'\)",
    "github\.run_attempt == '1'",
    'github\.event\.pull_request\.draft',
    'github\.event\.pull_request\.head\.repo\.full_name == github\.repository',
    "github\.actor != 'dependabot\[bot\]'",
    "contains\(fromJSON\('\[`"OWNER`",`"MEMBER`",`"COLLABORATOR`"\]'\), github\.event\.pull_request\.author_association\)",
    '(?s)permissions:\s+contents: write\s+pull-requests: write\s+steps:',
    'persist-credentials: false',
    'EXPECTED_HEAD: \$\{\{ github\.event\.pull_request\.head\.sha \}\}',
    'Set-PrReadyForReview\.ps1'
)) {
    if ($readyJob -notmatch $pattern) { throw "Missing draft-readiness invariant: $pattern" }
}
if ($readyJob -match '(?i)gh pr (merge|edit)|mergePullRequest|enablePullRequestAutoMerge|--title|issues: write|actions: write|git push') {
    throw "Draft readiness must not merge, push, edit titles/metadata or request extra write permissions."
}
if ($workflow -match '(?m)^\s*pull_request_target:') {
    throw "Promotion must not use pull_request_target."
}

. (Join-Path $PSScriptRoot "..\.github\scripts\Set-PrReadyForReview.ps1")
$savedExitCode = $global:LASTEXITCODE
$global:PrReadyState = @{ Calls = [System.Collections.Generic.List[string]]::new() }
function gh {
    $state = $global:PrReadyState
    $state.Calls.Add(($args -join " "))
    if ($args[1] -eq "graphql") {
        $global:LASTEXITCODE = if ($state.MutationFails) { 1 } else { 0 }
        if (-not $state.MutationFails -and -not $state.MutationIgnored) { $state.Pull.draft = $false }
        return '{"data":{}}'
    }
    $global:LASTEXITCODE = if ($state.ReadFails) { 1 } else { 0 }
    $state.Pull | ConvertTo-Json -Depth 5
}
function Reset-PrReadyState([hashtable] $Pull = @{}) {
    $pullState = @{
        node_id = "PR_node"; state = "open"; merged = $false; draft = $true; title = "Add readiness automation"
        author_association = "OWNER"; user = @{ login = "iricigor" }
        head = @{ sha = "a" * 40; repo = @{ full_name = "test/repo" } }
    }
    foreach ($key in $Pull.Keys) { $pullState[$key] = $Pull[$key] }
    $global:PrReadyState.Pull = $pullState
    $global:PrReadyState.Calls.Clear()
    $global:PrReadyState.ReadFails = $false
    $global:PrReadyState.MutationFails = $false
    $global:PrReadyState.MutationIgnored = $false
}
function Invoke-PrReady([hashtable] $Override = @{}) {
    $parameters = @{ Repository = "test/repo"; PullRequestNumber = 7; ExpectedHead = "a" * 40
        EventName = "pull_request"; EventAction = "synchronize"; RunAttempt = "1" }
    foreach ($key in $Override.Keys) { $parameters[$key] = $Override[$key] }
    Set-PrReadyForReview @parameters
}
function Assert-PrReadyUnchanged($Result, [string] $Message) {
    Assert-Equal $Result.Outcome "unchanged" $Message
    if (@($global:PrReadyState.Calls | Where-Object { $_ -like "api graphql*" }).Count) { throw "$Message must not request readiness." }
}
try {
    foreach ($action in @("opened", "synchronize")) {
        Reset-PrReadyState
        $result = Invoke-PrReady @{ EventAction = $action }
        Assert-Equal $result.Outcome "ready" "Validated $action draft is promoted"
        Assert-Equal $global:PrReadyState.Calls.Count 3 "Re-read, transition and verify"
        if ($global:PrReadyState.Calls[1] -notmatch 'markPullRequestReadyForReview.*id=PR_node') { throw "Promote only the re-read PR node." }
        if ($global:PrReadyState.Calls[0] -ne "api repos/test/repo/pulls/7") { throw "Re-read only the validated PR." }
    }
    $global:PrReadyState.Calls.Clear()
    Assert-PrReadyUnchanged (Invoke-PrReady) "Already-ready PR (repeated run) stays unchanged"
    foreach ($trigger in @(
        @{ EventName = "workflow_dispatch" }, @{ EventAction = "reopened" }, @{ EventAction = "edited" },
        @{ EventAction = "ready_for_review" }, @{ RunAttempt = "2" }, @{ RunAttempt = "3"; EventAction = "opened" }
    )) {
        Reset-PrReadyState
        Assert-PrReadyUnchanged (Invoke-PrReady $trigger) "Ineligible trigger $($trigger | ConvertTo-Json -Compress)"
        Assert-Equal $global:PrReadyState.Calls.Count 0 "Ineligible triggers do not read the PR"
    }
    foreach ($case in @(
        @{ state = "closed" }, @{ state = "closed"; merged = $true }, @{ draft = $false },
        @{ head = @{ sha = "b" * 40; repo = @{ full_name = "test/repo" } } },
        @{ head = @{ sha = "a" * 40; repo = @{ full_name = "fork/repo" } } },
        @{ author_association = "CONTRIBUTOR" }, @{ author_association = "NONE" }
    )) {
        Reset-PrReadyState $case
        Assert-PrReadyUnchanged (Invoke-PrReady) "Ineligible PR $($case | ConvertTo-Json -Compress)"
    }
    Reset-PrReadyState @{ author_association = "CONTRIBUTOR"; user = @{ login = "Copilot" } }
    Assert-Equal (Invoke-PrReady).Outcome "ready" "Copilot-authored drafts keep their existing trust"
    foreach ($title in @("WIP", "[WIP] Add", "WIP: Add", "wip add", "Add (Wip)", "Add - wIp", "[WIP] 🛠️ Automate")) {
        Reset-PrReadyState @{ title = $title }
        Assert-PrReadyUnchanged (Invoke-PrReady) "Re-read title '$title' blocks promotion"
    }
    foreach ($title in @("Wipe stale cache", "Add swipe gesture", "Wiping", "WIPE")) {
        Reset-PrReadyState @{ title = $title }
        Assert-Equal (Invoke-PrReady).Outcome "ready" "'$title' is not a WIP token"
    }
    Reset-PrReadyState
    $global:PrReadyState.ReadFails = $true
    Assert-Throws { Invoke-PrReady } "*Could not read pull request #7*"
    Reset-PrReadyState
    $global:PrReadyState.MutationFails = $true
    Assert-Throws { Invoke-PrReady } "*Could not mark pull request #7 ready*"
    Reset-PrReadyState
    $global:PrReadyState.MutationIgnored = $true
    Assert-Throws { Invoke-PrReady } "*still a draft*"
} finally {
    Remove-Item Function:\gh
    Remove-Variable PrReadyState -Scope Global
    $global:LASTEXITCODE = $savedExitCode
}
