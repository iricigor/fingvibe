$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\.github\scripts\NativeValidation.ps1")

function Assert-NativeEqual($Actual, $Expected, [string] $Message) {
    if (($Actual -join "|") -cne ($Expected -join "|")) { throw "$Message : expected '$Expected', got '$Actual'." }
}
function Assert-NativeThrows([scriptblock] $Action, [string] $Pattern) {
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected failure matching '$Pattern'."
}

$baseline = @(Get-NativeValidationPlan -Mode Baseline -Suite capture)
Assert-NativeEqual $baseline.Scenario @("Devices", "DeviceDetails", "DevicesEmpty") "Baseline captures only its demonstrated states"
foreach ($suite in @("capture", "sidebar", "devices", "history", "tools")) {
    $full = @(Get-NativeValidationPlan -Mode Full -Suite $suite)
    Assert-NativeEqual $full.Scenario @($UiReviewScenarios.Keys) "Full always forces every catalog scenario, without PR metadata"
}
$focused = @(Get-NativeValidationPlan -Mode Focused -Suite capture -Scenarios @("Settings", "DeviceDetails"))
Assert-NativeEqual $focused.Scenario @("Devices", "DeviceDetails", "Settings") "Focused captures reuse catalog ordering"
Assert-NativeEqual @(Get-NativeValidationPlan -Mode Focused -Suite history).Scenario @("Devices", "DeviceDetails") "Focused history cannot inherit a plan that skips history/discovery"
Assert-NativeThrows { Get-NativeValidationPlan -Mode Baseline -Suite history } "*only the capture*"
Assert-NativeThrows { Get-NativeValidationPlan -Mode Full -Suite capture -Scenarios Settings } "*only in Focused*"
Assert-NativeThrows { Get-NativeValidationPlan -Mode Focused -Suite capture } "*requires at least one*"
Assert-NativeThrows { Get-NativeValidationPlan -Mode Focused -Suite devices -Scenarios Settings } "*cannot select native*"
Assert-NativeThrows { Get-NativeValidationPlan -Mode Focused -Suite capture -Scenarios Missing } "*Unknown UI capture*"

foreach ($mode in @("Baseline", "Full")) {
    $results = @{ build = "success"; native = "success"; checks = "success"; installer = "success" }
    if ($mode -eq "Baseline") { $results.checks = $results.installer = "skipped" }
    Assert-NativeValidationResults -Mode $mode -Results $results
    foreach ($stage in @("build", "native", "checks", "installer")) {
        $expected = $results[$stage]
        foreach ($result in @("failure", "cancelled", "", "skipped", "success")) {
            if ($result -eq $expected) { continue }
            $results[$stage] = $result
            Assert-NativeThrows { Assert-NativeValidationResults -Mode $mode -Results $results } "*"
        }
        $results[$stage] = $expected
        $results.Remove($stage)
        Assert-NativeThrows { Assert-NativeValidationResults -Mode $mode -Results $results } "*"
        $results[$stage] = $expected
    }
}

$fixture = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-native-modes-$([Guid]::NewGuid())"
$saved = @{}
$dispatchSource = Get-Content (Join-Path $PSScriptRoot "..\.github\scripts\Invoke-UiRegression.ps1") -Raw
$expectedChecks = @([regex]::Matches($dispatchSource, 'Invoke-RegressionCheck "([^"]+)"') |
    ForEach-Object { $_.Groups[1].Value })
foreach ($name in @("SidebarNavigation", "DevicesList.Ui", "DeviceScanHistory.Ui", "DeviceDiscovery.Ui",
    "UsageCategory.Ui", "BuildIdentity.Ui", "NetworkTroubleshooting.Ui", "FingImport.Ui", "AdditionalServices.Ui", "SqlEditor.Ui")) {
    Assert-NativeEqual @($expectedChecks | Where-Object { $_ -eq $name }).Count 1 "Existing native checks remain present exactly once"
}
try {
    foreach ($name in @("NATIVE_TEST_CALLS", "NATIVE_TEST_FAIL", "GITHUB_STEP_SUMMARY",
        "FINGVIBE_UI_REVIEW", "FINGVIBE_UI_REVIEW_INVENTORY", "FINGVIBE_UI_REVIEW_SNAPSHOT",
        "FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT")) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    $scripts = Join-Path $fixture ".github\scripts"
    $null = New-Item -ItemType Directory -Path $scripts -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $fixture "tests") -Force
    $helpers = Join-Path $fixture "tests\UiRegression"
    $null = New-Item -ItemType Directory -Path $helpers -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "UiRegression\Helpers.ps1") -Destination $helpers
    foreach ($name in @("NativeValidation.ps1", "Invoke-NativeValidation.ps1", "Invoke-UiRegression.ps1", "UiReviewScenarios.ps1")) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "..\.github\scripts\$name") -Destination $scripts
    }
    @'
param($Mode, $AppPath, $ScreenshotDirectory, $CapturePlanPath)
@{ name = "capture"; mode = $Mode; plan = (Get-Content $CapturePlanPath -Raw | ConvertFrom-Json) } |
    ConvertTo-Json -Depth 8 -Compress | Add-Content $env:NATIVE_TEST_CALLS
if ($env:NATIVE_TEST_FAIL -eq "capture") { throw "Simulated capture failure" }
'@ | Set-Content -LiteralPath (Join-Path $scripts "Invoke-UiReview.ps1")
    foreach ($name in (@("UiReviewScreenshot") + $expectedChecks)) {
        @'
param($AppPath, $ScreenshotDirectory, $Version, $BuildKind, $BuildTimestamp, $BuildCommit, $PullRequestNumber, $SummaryOnly)
$name = [IO.Path]::GetFileName($PSCommandPath).Replace(".Tests.ps1", "")
@{ name = $name; parameters = $PSBoundParameters } | ConvertTo-Json -Depth 5 -Compress | Add-Content $env:NATIVE_TEST_CALLS
if ($env:NATIVE_TEST_FAIL -eq $name) { throw "Simulated native failure: $name" }
'@ | Set-Content -LiteralPath (Join-Path $fixture "tests\$name.Tests.ps1")
    }
    $env:NATIVE_TEST_CALLS = Join-Path $fixture "calls.jsonl"
    $env:NATIVE_TEST_FAIL = $null
    $env:GITHUB_STEP_SUMMARY = Join-Path $fixture "summary.txt"
    $runner = Join-Path $scripts "Invoke-NativeValidation.ps1"
    $parameters = @{
        AppPath = "synthetic.exe"; ScreenshotDirectory = (Join-Path $fixture "diagnostics")
        Version = "0.0.123"; BuildCommit = "fixture-head"; BuildTimestamp = "2026-11-08T22:00:00Z"
    }
    foreach ($suite in @("sidebar", "devices", "history", "tools", "capture")) {
        & $runner -Mode Full -Suite $suite @parameters
        foreach ($name in @("FINGVIBE_UI_REVIEW", "FINGVIBE_UI_REVIEW_INVENTORY",
            "FINGVIBE_UI_REVIEW_SNAPSHOT", "FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT")) {
            Assert-NativeEqual ([Environment]::GetEnvironmentVariable($name)) $saved[$name] "Native wrapper restores $name"
        }
    }
    $calls = @(Get-Content $env:NATIVE_TEST_CALLS | ConvertFrom-Json)
    Assert-NativeEqual $calls.name ($expectedChecks + @("UiReviewScreenshot", "capture")) "Full dispatch inherits all current suites exactly once, including independently restored coverage"
    Assert-NativeEqual $calls[2].parameters.SummaryOnly $true "Full preserves deliberately dormant observation UI"
    Assert-NativeEqual @($calls | Where-Object name -eq "BuildIdentity.Ui")[0].parameters.BuildCommit "fixture-head" "Native identity uses exact built revision"
    Assert-NativeEqual $calls[-1].plan.Scenario @($UiReviewScenarios.Keys) "Full capture cannot omit history/details or discovery selection"
    & $runner -Mode Baseline -Suite capture @parameters
    $calls = @(Get-Content $env:NATIVE_TEST_CALLS | ConvertFrom-Json)
    Assert-NativeEqual $calls.Count ($expectedChecks.Count + 3) "Baseline must not run screenshot matrices or native feature suites"
    Assert-NativeEqual $calls[-1].mode Baseline "Baseline mode reaches the shared smoke implementation"
    Assert-NativeEqual $calls[-1].plan.Scenario $baseline.Scenario "Baseline forwards its bounded capture plan"
    & powershell.exe -NoProfile -File $runner -Mode Full -Suite sidebar `
        -AppPath synthetic.exe -ScreenshotDirectory $parameters.ScreenshotDirectory -BuildCommit fixture-head
    if ($LASTEXITCODE -ne 0) { throw "Full sidebar must retain Windows PowerShell compatibility." }
    $env:NATIVE_TEST_FAIL = "capture"
    Assert-NativeThrows { & $runner -Mode Baseline -Suite capture @parameters } "*Simulated capture failure*"
    $evidence = Get-Content (Join-Path $parameters.ScreenshotDirectory "execution.json") -Raw | ConvertFrom-Json
    Assert-NativeEqual $evidence.result failure "Failed native execution must retain failed evidence"
    Assert-NativeEqual $evidence.revision fixture-head "Failure provenance must not disappear"
    if ($evidence.executionSeconds -lt 0 -or
        (Get-Content $env:GITHUB_STEP_SUMMARY -Raw) -notmatch "Baseline / capture execution:.*failure") {
        throw "Failure timing and summary must survive."
    }

    Copy-Item -LiteralPath (Join-Path $PSScriptRoot "..\.github\scripts\Invoke-FullValidationChecks.ps1") -Destination $scripts
    @'
param($Version, $ArchiveName, $ArchivePath, $ChecksumsName, $ChecksumsPath)
throw "Simulated secret asset failure"
'@ | Set-Content -LiteralPath (Join-Path $scripts "Download-Gitleaks.ps1")
    foreach ($name in @("UiReviewScenarios", "UiRegression.Helpers", "AdditionalServices.Script",
        "SqlEditor.Script", "UsageCategory.Script", "DeviceActivity.Script", "PrValidation",
        "DispatcherGate", "LogoDevConfiguration", "BuildIdentity.Metadata", "Installer.Script", "GitleaksDownload")) {
        @'
$name = [IO.Path]::GetFileName($PSCommandPath).Replace(".Tests.ps1", "")
if ($name -eq "PrValidation") { throw "Simulated independent script failure" }
'@ | Set-Content -LiteralPath (Join-Path $fixture "tests\$name.Tests.ps1")
    }
    $savedExitCode = $global:LASTEXITCODE
    function dotnet {
        $global:LASTEXITCODE = 0
        if ($args[0] -eq "test") { $global:LASTEXITCODE = 1 }
        if ($args[0] -eq "list") { '{"projects":[]}' }
    }
    function node { $global:LASTEXITCODE = 0 }
    try {
        $logDirectory = Join-Path $fixture "checks"
        Assert-NativeThrows {
            & (Join-Path $scripts "Invoke-FullValidationChecks.ps1") -SourceDirectory $fixture -LogDirectory $logDirectory
        } "*Full non-UI validation failed*"
        $checkResults = @(Get-Content (Join-Path $logDirectory "checks.json") -Raw | ConvertFrom-Json)
        Assert-NativeEqual @($checkResults | Where-Object result -eq failure).name @("core", "PrValidation", "secrets") "Independent full failures are explicit"
        Assert-NativeEqual $checkResults[-1].name dependencies "Earlier failures must not hide independent checks"
        Assert-NativeEqual $checkResults[-1].result success "Dependency check must run after secret failure"
        if ((Get-Content (Join-Path $logDirectory "PrValidation.log") -Raw) -notmatch "Simulated independent script failure") {
            throw "Full non-UI diagnostics must retain the original failure."
        }
    }
    finally {
        Remove-Item Function:\dotnet, Function:\node
        $global:LASTEXITCODE = $savedExitCode
    }
}
finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    Remove-Item -LiteralPath $fixture -Recurse -Force
}

$workflowDirectory = Join-Path $PSScriptRoot "..\.github\workflows"
$comparison = Get-Content (Join-Path $workflowDirectory "native-comparison.yml") -Raw
$standalone = Get-Content (Join-Path $workflowDirectory "native-full.yml") -Raw
$reusable = Get-Content (Join-Path $workflowDirectory "native-validation.yml") -Raw
foreach ($workflow in @($comparison, $standalone, $reusable)) {
    if ($workflow -notmatch "contents: read" -or $workflow -match "contents: write|pull-requests: write|secrets: inherit|pull_request_target") {
        throw "Independent validation must retain read-only execution without privileged/fork triggers."
    }
    if ($workflow -match "ui-ux-review|ui-publish|Publish-PrComment|Publish-UiReviewScreenshot|gh pr|gh issue|gh release create") {
        throw "Independent validation must not feed authoritative aggregation or PR/release writes."
    }
}
foreach ($restriction in @("github.event.pull_request.head.repo.full_name == github.repository",
    "github.event.pull_request.author_association", "github.event.pull_request.user.login == 'Copilot'",
    "github.event.pull_request.head.sha || inputs.revision || github.sha", "group: native-comparison-")) {
    if (-not $comparison.Contains($restriction)) { throw "Missing comparison trust/provenance/concurrency restriction: $restriction" }
}
if ($standalone -notmatch "revision: main" -or $standalone -notmatch "pull-request: 0" -or
    $standalone -notmatch "group: native-full-main-" -or $standalone -notmatch "cancel-in-progress: false" -or
    $standalone -match "schedule:|cron:") {
    throw "Standalone full execution must target main without PR metadata; scheduling remains unactivated."
}
foreach ($invariant in @("fail-fast: false", "persist-credentials: false", "fromJSON(needs.plan.outputs.suites)",
    '@("sidebar", "devices", "history", "tools", "capture")', "ref: `${{ needs.plan.outputs.revision }}",
    "Assert-NativeValidationResults", "if: always()", "shell: powershell", "execution request")) {
    if (-not $reusable.Contains($invariant)) { throw "Missing full execution invariant: $invariant" }
}
$ci = Get-Content (Join-Path $workflowDirectory "ci.yml") -Raw
$matrix = [regex]::Match($ci, 'suite: \[([^\]]+)\]')
if (-not $matrix.Success) { throw "Existing authoritative native suite matrix was not found." }
$existingSuites = @($matrix.Groups[1].Value.Split(",") | ForEach-Object { $_.Trim() })
Assert-NativeEqual $existingSuites @("sidebar", "devices", "history", "tools") "New authoritative suites must be wired into full mode explicitly"
$ciTests = [regex]::Match($ci, '(?s)\r?\n  tests:\r?\n(.*?)\r?\n  build:').Groups[1].Value
if (-not $ciTests) { throw "Existing CI core/script job was not found." }
$checks = Get-Content (Join-Path $PSScriptRoot "..\.github\scripts\Invoke-FullValidationChecks.ps1") -Raw
foreach ($match in [regex]::Matches($ciTests, 'run: \.\\tests\\([A-Za-z.]+)\.Tests\.ps1')) {
    if (-not $checks.Contains('"' + $match.Groups[1].Value + '"')) {
        throw "Full non-UI execution omits existing CI script check: $($match.Groups[1].Value)"
    }
}
foreach ($path in @("FingVibe.Core.Tests.csproj", "SpeedTestHost.Tests.cjs", "Download-Gitleaks.ps1", "--vulnerable", "--redact")) {
    if (-not $checks.Contains($path)) { throw "Full execution omits existing non-UI check: $path" }
}
$smoke = Get-Content (Join-Path $PSScriptRoot "..\.github\scripts\Invoke-UiReview.ps1") -Raw
if ($smoke -notmatch '\$Mode = "Current"' -or
    [regex]::Matches($smoke, 'if \(\$Mode -in @\("Current", "Full"\)\)').Count -ne 3 -or
    $smoke -notmatch 'Get-NativeValidationPlan -Mode \$Mode -Suite capture' -or
    $smoke -notmatch "smoke-failure.png") {
    throw "Baseline must exclude exhaustive behavior groups while preserving default/full smoke assertions and failure captures."
}
Write-Host "Native validation modes, independent workflows, provenance and failure-contract tests passed."
