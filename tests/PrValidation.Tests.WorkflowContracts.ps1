# Workflow and release contracts: release identity, action versions, job graph and payload reuse.
$workflow = Get-Content (Join-Path $PSScriptRoot "..\.github\workflows\ci.yml") -Raw
[xml]$appProject = Get-Content (Join-Path $PSScriptRoot "..\src\FingVibe.App\FingVibe.App.csproj") -Raw
Assert-Equal $appProject.Project.PropertyGroup.SatelliteResourceLanguages "en" "Local and PR builds retain English managed satellite resources"
$releaseWorkflow = Get-Content (Join-Path $PSScriptRoot "..\.github\workflows\release.yml") -Raw
$securityWorkflow = Get-Content (Join-Path $PSScriptRoot "..\.github\workflows\security-review.yml") -Raw
$versionStep = [regex]::Match($releaseWorkflow, '(?ms)^      - name: Set release version\r?\n.*?        run: \|\r?\n(?<script>.*?)(?=^      - name:)')
$releaseStep = [regex]::Match($releaseWorkflow, '(?ms)^      - name: Publish GitHub Release\r?\n.*?        run: \|\r?\n(?<script>.*)\z')
if (-not $versionStep.Success -or -not $releaseStep.Success) {
    throw "Release version and publication scripts must remain testable."
}
$releaseOutput = [IO.Path]::GetTempFileName()
$savedOutput = $env:GITHUB_OUTPUT
$savedExitCode = $global:LASTEXITCODE
$global:PrValidationReleaseState = @{
    Calls = [System.Collections.Generic.List[object]]::new()
    Existing = $false
    PublishFails = $false
}
function gh {
    $global:PrValidationReleaseState.Calls.Add(@($args))
    if ($args[1] -eq "view") {
        $global:LASTEXITCODE = if ($global:PrValidationReleaseState.Existing) { 0 } else { 1 }
        if ($global:PrValidationReleaseState.Existing) { "existing release" }
    } else {
        $global:LASTEXITCODE = if ($global:PrValidationReleaseState.PublishFails) { 1 } else { 0 }
    }
}
try {
    $env:GITHUB_OUTPUT = $releaseOutput
    foreach ($runNumber in @(7, 123)) {
        Clear-Content -LiteralPath $releaseOutput
        $versionScript = $versionStep.Groups["script"].Value.Replace('${{ github.run_number }}', "$runNumber")
        & ([scriptblock]::Create($versionScript))
        $identity = Get-Content -LiteralPath $releaseOutput -Raw | ConvertFrom-StringData
        Assert-Equal @($identity.number, $identity.tag) @("1.4.$runNumber", "v1.4.$runNumber") "Generated feature version and tag retain the run number"
        $releaseScript = $releaseStep.Groups["script"].Value.
            Replace('${{ steps.version.outputs.number }}', $identity.number).
            Replace('${{ steps.version.outputs.tag }}', $identity.tag).
            Replace('${{ github.sha }}', "fixture-commit")
        $global:PrValidationReleaseState.Existing = $false
        $global:PrValidationReleaseState.Calls.Clear()
        & ([scriptblock]::Create($releaseScript))
        $create = $global:PrValidationReleaseState.Calls[1]
        Assert-Equal $create @(
            "release", "create", $identity.tag,
            "artifacts\FingVibe-$($identity.number)-win-x64.zip",
            "artifacts\installer\FingVibe-$($identity.number)-win-x64-Setup.exe",
            "--target", "fixture-commit", "--title", "FingVibe $($identity.number)",
            "--notes-file", "docs\release-notes-1.4.md", "--generate-notes"
        ) "Release artifacts, title and tag share the generated identity and prepend curated notes"
        $global:PrValidationReleaseState.Existing = $true
        $global:PrValidationReleaseState.Calls.Clear()
        & ([scriptblock]::Create($releaseScript))
        Assert-Equal $global:PrValidationReleaseState.Calls[1] @(
            "release", "upload", $identity.tag,
            "artifacts\FingVibe-$($identity.number)-win-x64.zip",
            "artifacts\installer\FingVibe-$($identity.number)-win-x64-Setup.exe", "--clobber"
        ) "Existing releases retain idempotent asset upload"
    }
    $global:PrValidationReleaseState.Existing = $false
    $global:PrValidationReleaseState.PublishFails = $true
    Assert-Throws { & ([scriptblock]::Create($releaseScript)) } "*Release publication failed*"
} finally {
    Remove-Item Function:\gh
    Remove-Variable PrValidationReleaseState -Scope Global
    $env:GITHUB_OUTPUT = $savedOutput
    $global:LASTEXITCODE = $savedExitCode
    Remove-Item -LiteralPath $releaseOutput
}
$actionVersions = @{
    "actions/checkout" = "v7.0.1"
    "actions/setup-dotnet" = "v6.1.0"
    "actions/cache" = "v6.1.0"
    "actions/upload-artifact" = "v7.0.2"
    "actions/download-artifact" = "v8.0.2"
    "microsoft/setup-msbuild" = "v3"
}
foreach ($pipeline in @($workflow, $releaseWorkflow, $securityWorkflow)) {
    $references = [regex]::Matches($pipeline, '(?m)^\s+uses: (?<action>[\w-]+/[\w-]+)@(?<version>[^\s]+)\s*$')
    if ($references.Count -eq 0) { throw "Pipeline action references were not found." }
    foreach ($reference in $references) {
        $action = $reference.Groups["action"].Value
        if (-not $actionVersions.ContainsKey($action)) {
            throw "Review the runtime and migration contract for unrecognized action '$action'."
        }
        Assert-Equal $reference.Groups["version"].Value $actionVersions[$action] "Maintained Node.js 24 release for $action"
    }
    if ($pipeline -match '(?m)^\s+archive:\s*false\s*$' -or
        $pipeline -match '(?m)^\s+(include-hidden-files|skip-decompress|allow-unsafe-pr-checkout):\s*true\s*$' -or
        $pipeline -match '(?m)^\s+digest-mismatch:\s*(warn|ignore)\s*$') {
        throw "Action migration must preserve zipped/hidden-file defaults, extraction and secure checkout/digest behavior."
    }
}
if ($releaseWorkflow -notmatch '(?m)^\s+/property:SatelliteResourceLanguages=[ \t]+`\r?$') {
    throw "Release publishing must override the language filter with an empty global MSBuild property."
}
if ($workflow -match 'SatelliteResourceLanguages') {
    throw "PR publishing must use the application's default English language filter."
}
Assert-Equal ([regex]::Matches($workflow, 'run: dotnet test ').Count) 1 "Run core tests once"
Assert-Equal ([regex]::Matches($workflow, 'msbuild src\\FingVibe.App\\FingVibe.App.csproj').Count) 1 "Publish the app once"
foreach ($pattern in @(
    '(?ms)^  pull_request:\s+types: \[opened, synchronize, reopened, edited\]',
    '(?s)  tests:\s+name: core-tests\s+needs: changes',
    '(?s)  regression-coverage:\s+name: pr-regression-coverage\s+needs: changes\s+if: github.event_name == ''pull_request''',
    '(?s)  build:\s+needs: changes',
    '(?s)  installer:\s+needs: \[changes, build\]',
    '(?s)  ui-smoke:\s+needs: \[changes, build\]',
    '(?s)  ui-assignments:\s+needs: \[changes, build\]',
    '(?s)  ui-capture:\s+needs: \[changes, build\]',
    '(?s)  build-comment:\s+needs: \[tests, installer\]',
    '(?s)  ui-publish:\s+needs: \[changes, regression-coverage, tests, build, installer, ui-smoke, ui-assignments, ui-capture, ui-regression\]',
    '(?s)  ui-ux-review:\s+name: ui-ux-review\s+needs: \[changes, regression-coverage, tests, build, installer, ui-smoke, ui-assignments, ui-capture, ui-regression, ui-publish\]',
    '(?s)name: Upload UI review captures and diagnostics\s+id: screenshot\s+if: always\(\)',
    '(?s)name: Upload UI smoke diagnostics\s+if: always\(\)',
    '(?s)name: Upload UI assignment diagnostics\s+if: always\(\)',
    'cancel-in-progress: true',
    'group: pr-validation-\$\{\{ github.event.pull_request.number \|\| github.ref \}\}',
    'FINGVIBE_UI_REVIEW: "1"',
    'artifact-ids: \$\{\{ needs.build.outputs.artifact-id \}\}',
    'ARTIFACT_URL: \$\{\{ needs.installer.outputs.artifact-url \}\}',
    'merge-multiple: true',
    'name: fingvibe-win-x64-pr-.*-attempt-\$\{\{ github.run_attempt \}\}',
    'name: fingvibe-ui-review-pr-.*-attempt-\$\{\{ github.run_attempt \}\}',
    'Publish-PrComment.ps1 -Mode Append',
    '(?s)workflow_dispatch:\s+inputs:\s+additional_scenarios:',
    '(?s)permissions:\s+contents: read\s+concurrency:',
    '(?s)  ui-ux-review:\s+name: ui-ux-review.*?if: always\(\)'
)) {
    if ($workflow -notmatch $pattern) { throw "Missing workflow invariant: $pattern" }
}
if (Test-Path (Join-Path $PSScriptRoot "..\.github\workflows\ui-ux-review.yml")) {
    throw "UI validation must not also run in a second PR workflow."
}
if ($workflow -notmatch 'Get-PrRegressionPlan\.ps1' -or
    $workflow -notmatch 'Invoke-PrRegressionTests\.ps1' -or
    $workflow -notmatch 'PR_BODY: \$\{\{ github\.event\.pull_request\.body \}\}') {
    throw "PR regression manifests must be planned from PR data and executed through the trusted runner."
}

function Get-WorkflowJob([string] $Name) {
    $match = [regex]::Match($workflow, "(?ms)^  ${Name}:\r?`n.*?(?=^  [a-z][a-z-]*:\r?`n|\z)")
    if (-not $match.Success) { throw "Workflow job '$Name' was not found." }
    return $match.Value
}

$testJob = Get-WorkflowJob tests
$buildJob = Get-WorkflowJob build
$installerJob = Get-WorkflowJob installer
$smokeJob = Get-WorkflowJob ui-smoke
$assignmentsJob = Get-WorkflowJob ui-assignments
$captureJob = Get-WorkflowJob ui-capture
$regressionJob = Get-WorkflowJob ui-regression
$publishJob = Get-WorkflowJob ui-publish
$caches = @()
foreach ($job in @($testJob, $buildJob)) {
    if ($job -notmatch 'NUGET_PACKAGES: \$\{\{ github.workspace \}\}\\\.nuget\\packages') {
        throw "Core tests/build must use a job-env-supported context for the NuGet package cache location."
    }
    $cache = [regex]::Match($job, '(?ms)^      - name: Cache NuGet packages\r?\n.*?(?=^      - name:|\z)')
    if (-not $cache.Success -or $cache.Value -notmatch 'uses: actions/cache@v6\.1\.0' -or
        $cache.Value -notmatch 'path: \$\{\{ env.NUGET_PACKAGES \}\}' -or
        $cache.Value -notmatch 'key: \$\{\{ runner.os \}\}-nuget-v1-\$\{\{ hashFiles\(' -or
        $cache.Value -notmatch '(?s)restore-keys:.*?\$\{\{ runner.os \}\}-nuget-v1-') {
        throw "Core tests/build must cache packages with OS/dependency keys and an OS-scoped fallback."
    }
    foreach ($dependency in @("**/*.csproj", "**/Directory.*.props", "**/Directory.*.targets",
        "**/NuGet.Config", "**/nuget.config", "global.json")) {
        if (-not $cache.Value.Contains("'$dependency'")) { throw "NuGet cache key omits $dependency." }
    }
    $caches += $cache.Value.Trim()
    if ($job -match '--no-restore|/property:Restore=false' -or
        $job.IndexOf("name: Cache NuGet packages") -gt $job.IndexOf(
            $(if ($job -eq $testJob) { "name: Test networking core" } else { "name: Publish Windows x64 app" }))) {
        throw "Cache restoration must precede normal restore/test/publish, never replace NuGet restore."
    }
}
Assert-Equal $caches[0] $caches[1] "Build and core tests share the same NuGet cache key/policy"
if ($buildJob -notmatch '/restore') { throw "MSBuild publishing must still restore dependencies." }
foreach ($job in @($smokeJob, $assignmentsJob, $captureJob, $regressionJob)) {
    if ($job -notmatch 'needs: \[changes, build\]' -or $job -match 'needs.tests') {
        throw "Native UI validation must overlap core tests after the single published build."
    }
}
# Option A: installer validation overlaps core tests, but nothing it produces is linked or published without them.
$commentJob = Get-WorkflowJob build-comment
if ($installerJob -notmatch 'needs: \[changes, build\]' -or $installerJob -match 'needs\.tests|needs: \[[^\]]*\btests\b' -or
    $commentJob -notmatch 'needs: \[tests, installer\]' -or $commentJob -match '(?m)^\s+if:.*(always|failure|cancelled)\(' -or
    $publishJob -notmatch 'needs: \[changes, regression-coverage, tests, build, installer, ui-smoke, ui-assignments, ui-capture, ui-regression\]') {
    throw "Installer validation must not wait for core tests; the download link and screenshots must still require them."
}
if ($installerJob -notmatch '(?s)name: Record prerequisite wait.*?PAYLOAD_READY_AT: \$\{\{ needs.build.outputs.payload-ready-at \}\}.*?GITHUB_STEP_SUMMARY' -or
    $installerJob -notmatch '(?s)name: Summarize installer job duration\s+if: always\(\)' -or
    $buildJob -notmatch '(?s)name: Upload unvalidated payload.*?name: Record payload readiness\s+id: ready' -or
    $buildJob -notmatch 'payload-ready-at: \$\{\{ steps.ready.outputs.at \}\}') {
    throw "Installer prerequisite wait and job duration must be reported separately, including on failure."
}
Assert-Equal ([regex]::Matches($captureJob, '(?m)^    outputs:').Count) 1 "Capture exposes one outputs mapping after branch integration"
Assert-Equal ([regex]::Matches($workflow, 'artifact-ids: \$\{\{ needs.build.outputs.artifact-id \}\}').Count) 5 "Installer, smoke, assignments, capture and regression matrix consume the same payload ID"
if ($captureJob -notmatch 'artifact-id: \$\{\{ steps.screenshot.outputs.artifact-id \}\}') {
    throw "Capture must expose the exact successful upload ID for downstream failed-only reruns."
}
$captureDownload = [regex]::Match($publishJob, '(?ms)^      - name: Download completed captures\r?\n.*?(?=^      - name:|\z)').Value
if ($captureDownload -notmatch 'artifact-ids: \$\{\{ needs.ui-capture.outputs.artifact-id \}\}' -or
    $captureDownload -notmatch 'merge-multiple: true' -or
    $captureDownload -match 'github.run_attempt|(?m)^\s+name: fingvibe-ui-review') {
    throw "Publication must download the successful producer's artifact ID, not reconstruct a name from the publisher's rerun attempt."
}
Assert-Equal ([regex]::Matches($buildJob, 'uses: actions/upload-artifact@v7\.0\.2').Count) 1 "Publish uploads only the transfer payload"
if ($buildJob -notmatch '(?s)name: Upload unvalidated payload.*?id: upload.*?name: fingvibe-validation-payload-pr-.*-attempt-\$\{\{ github.run_attempt \}\}.*?retention-days: 1' -or
    $buildJob -match 'New-Installer|Installer.Lifecycle|name: Upload runnable app|name: Upload tested installer') {
    throw "Publishing must not advertise tested downloads or wait for installer validation."
}
foreach ($job in @($installerJob, $smokeJob, $assignmentsJob, $captureJob, $regressionJob)) {
    if ($job -notmatch 'uses: actions/download-artifact@v8\.0\.2' -or $job -match 'msbuild|/target:Publish') {
        throw "Downstream validation must download the single published payload, not rebuild."
    }
}
if ($installerJob -notmatch '(?s)Download the published payload.*?path: artifacts\\fingvibe-win-x64.*?New-Installer.ps1.*?Installer.Lifecycle.Tests.ps1.*?name: Upload tested installer.*?name: Upload runnable app\s+id: upload' -or
    $installerJob -notmatch '(?s)name: Upload installer diagnostics\s+if: always\(\)') {
    throw "Tested downloads must follow installer validation, retaining failure diagnostics."
}
foreach ($step in @("Download completed captures", "Publish screenshots for inline review", "Add screenshots to pull request")) {
    if ($publishJob -notmatch ("(?s)name: " + [regex]::Escape($step) + "\s+(?:id: [^\r\n]+\s+)?if: needs.regression-coverage.result == 'success' && needs.tests.result == 'success' && needs.ui-smoke.result == 'success' && needs.ui-assignments.result == 'success' && needs.ui-capture.result == 'success' && needs.installer.result == 'success' && needs.ui-regression.result == 'success'")) {
        throw "Screenshot publication must wait for successful core tests, UI and installer checks: $step"
    }
}
    foreach ($pattern in @(
        'needs: \[changes, build\]',
        'runs-on: windows-2025',
        'timeout-minutes: 35',
        'fail-fast: false',
        'suite: \[sidebar-presentation, sidebar-scan-flows, sidebar-scan-presentation, sidebar-preferences-scheduling, devices-presentation, devices-row-expansion, devices-filters-previews, devices-columns-sorting, details-summary, details-identity, details-usage, details-observations, details-activity, details-linking, details-link-matches, network-activity, tools-utilities, tools-maintenance, tools-device-data, tools-sql-speed\]',
        '(?s)name: Run native regression suite\s+timeout-minutes: 15',
        "(?s)name: Run native regression suite\s+timeout-minutes: 15\s+id: native\s+continue-on-error: true\s+if: \$\{\{ !startsWith\(matrix.suite, 'sidebar-'\) \}\}\s+shell: pwsh",
        "(?s)name: Run sidebar regression in Windows PowerShell\s+timeout-minutes: 15\s+id: sidebar\s+continue-on-error: true\s+if: startsWith\(matrix.suite, 'sidebar-'\)\s+shell: powershell",
        '(?s)name: Upload native regression diagnostics\s+if: always\(\)',
        'name: fingvibe-ui-regression-\$\{\{ matrix.suite \}\}-pr-',
        'REGRESSION_RESULT: \$\{\{ needs.ui-regression.result \}\}'
    )) {
        $target = if ($pattern.StartsWith('REGRESSION_RESULT')) { $publishJob } else { $regressionJob }
        if ($target -notmatch $pattern) { throw "Missing parallel regression invariant: $pattern" }
    }
    foreach ($hostId in @("native", "sidebar")) {
        $shell = if ($hostId -eq "sidebar") { "powershell" } else { "pwsh" }
        $retryPattern = '(?s)id: ' + $hostId + '-retry\s+timeout-minutes: 15\s+if: ' +
            [regex]::Escape('${{ !cancelled() && steps.' + $hostId + '.outcome == ''failure'' }}') +
            '\s+shell: ' + $shell
        if ($regressionJob -notmatch $retryPattern) { throw "Only a failed $hostId attempt may retry, using its original host." }
    }
    Assert-Equal ([regex]::Matches($regressionJob, 'continue-on-error: true').Count) 2 "Only first attempts may tolerate failure"
    Assert-Equal ([regex]::Matches($regressionJob, 'Invoke-UiRegression.ps1').Count) 4 "At most one retry per host"
    foreach ($condition in @(
        '${{ !cancelled() && (steps.native.outcome == ''failure'' || steps.sidebar.outcome == ''failure'') }}',
        '${{ steps.native-retry.outcome == ''success'' || steps.sidebar-retry.outcome == ''success'' }}'
    )) {
        if (-not $regressionJob.Contains($condition)) { throw "Retry reporting must fail closed and run after retry failure: $condition" }
    }
    $readRegressionStep = {
        param([string] $Name)
        $step = [regex]::Match($regressionJob, ('(?ms)^      - name: ' + [regex]::Escape($Name) + '\r?\n.*?(?=^      - name:|\z)')).Value
        $script = [regex]::Match($step, '(?ms)^        run: \|\r?\n(?<script>.*)\z').Groups["script"].Value
        if (-not $script) { throw "Missing executable regression step: $Name" }
        $script
    }
    foreach ($job in @($smokeJob, $assignmentsJob, $captureJob, $regressionJob)) {
        foreach ($restriction in @(
            "needs.changes.outputs.ui == 'true'",
            "github.event_name == 'workflow_dispatch'",
            'github.event.pull_request.head.repo.full_name == github.repository',
            'github.event.pull_request.author_association',
            "github.event.pull_request.user.login == 'Copilot'"
        )) {
            if (-not $job.Contains($restriction)) { throw "Missing UI trust/selection restriction: $restriction" }
        }
    }
    $smokeScript = Get-Content (Join-Path $PSScriptRoot "..\.github\scripts\Invoke-UiReview.ps1") -Raw
    $regressionScript = Get-Content (Join-Path $PSScriptRoot "..\.github\scripts\Invoke-UiRegression.ps1") -Raw
    foreach ($suite in @("SidebarNavigation", "DevicesList.Ui", "DeviceScanHistory.Ui", "DeviceDiscovery.Ui",
        "UsageCategory.Ui", "DeviceActivity.Ui", "NetworkActivity.Ui",
        "Tools.Ui")) {
        if ($captureJob.Contains($suite) -or $smokeJob.Contains($suite) -or $assignmentsJob.Contains($suite) -or $smokeScript.Contains($suite)) { throw "Capture still runs extracted suite: $suite" }
        $expectedCount = if ($suite -eq "DeviceScanHistory.Ui") { 2 } else { 1 }
        Assert-Equal ([regex]::Matches($regressionScript, ('Invoke-RegressionCheck "' + [regex]::Escape($suite) + '"')).Count) $expectedCount "Preserve suite dispatch: $suite"
    }
    if ($regressionScript -notmatch 'SummaryOnly = \$true') {
        throw "Retained summary checks remain required independently of observation checks."
    }
    if ($regressionScript -notmatch [regex]::Escape('$_ -in @("DeviceDetails", "DeviceHistory")') -or
        $regressionScript -notmatch 'Stop-Transcript' -or
        $captureJob -notmatch 'timeout-minutes: 10' -or
        $captureJob -notmatch '(?s)id: capture\s+timeout-minutes: 7' -or
        $smokeJob -notmatch 'timeout-minutes: 10' -or
        $smokeJob -notmatch '(?s)id: smoke\s+timeout-minutes: 7' -or
        $assignmentsJob -notmatch 'timeout-minutes: 10' -or
        $assignmentsJob -notmatch '(?s)id: assignments\s+timeout-minutes: 7') {
        throw "Preserve history selection, transcripts and bounded native execution."
    }
    # Each runner owns one half of the former combined review; neither may drop or duplicate the other.
    if ($smokeJob -notmatch 'Invoke-UiReview\.ps1 -Part Smoke' -or $smokeJob -match 'CapturePlanPath|-Part (Capture|Assignments)|UiReviewScreenshot' -or
        $assignmentsJob -notmatch 'Invoke-UiReview\.ps1 -Part Assignments' -or $assignmentsJob -match 'CapturePlanPath|-Part (Capture|Smoke)|UiReviewScreenshot' -or
        $captureJob -notmatch 'Invoke-UiReview\.ps1 -Part Capture' -or $captureJob -match '-Part (Smoke|Assignments)' -or
        $captureJob -notmatch 'UiReviewScreenshot\.Tests\.ps1') {
        throw "Smoke, assignment and capture jobs must each run exactly their own review part."
    }
