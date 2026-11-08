$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\.github\scripts\Get-PrValidationChanges.ps1")

function Assert-Equal($Actual, $Expected, [string] $Message) {
    if (($Actual -join "|") -cne ($Expected -join "|")) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected failure matching '$Pattern'."
}

foreach ($case in @(
    @{ Paths = @("README.md", "docs/speed-test.md", "CONTRIBUTING.md"); Expected = @($false, $false, $false) },
    @{ Paths = @("tests/FingVibe.Core.Tests/ScannerTests.cs"); Expected = @($true, $false, $false) },
    @{ Paths = @("tests/UiReviewScenarios.Tests.ps1"); Expected = @($true, $false, $false) },
    @{ Paths = @("tests/UiReviewScreenshot.Tests.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/NetworkTroubleshooting.Ui.Tests.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/FingImport.Ui.Tests.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/SqlEditor.Ui.Tests.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/DeviceScanHistory.Ui.Tests.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/DeviceActivity.Ui.Tests.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/DeviceActivity.Fixture.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/Installer.Lifecycle.Tests.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/Installer.Script.Tests.ps1"); Expected = @($true, $false, $false) },
    @{ Paths = @("tools/installer/FingVibe.iss"); Expected = @($true, $true, $true) },
    @{ Paths = @("src/FingVibe.Core/Models/Device.cs"); Expected = @($true, $true, $true) },
    @{ Paths = @("src/FingVibe.App/Tools/ToolsPage.xaml"); Expected = @($true, $true, $true) },
    @{ Paths = @(".github/workflows/ci.yml"); Expected = @($true, $true, $true) },
    @{ Paths = @(".github/scripts/UiReviewNavigation.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("Directory.Build.props", "global.json"); Expected = @($true, $true, $true) },
    @{ Paths = @("NuGet.Config"); Expected = @($true, $true, $true) },
    @{ Paths = @("tools/New-SpeedTestPayload.ps1"); Expected = @($true, $true, $true) }
)) {
    $plan = Get-PrValidationChanges -Paths $case.Paths
    Assert-Equal @($plan.Tests, $plan.Build, $plan.Ui) $case.Expected "Classification: $($case.Paths)"
}
$plan = Get-PrValidationChanges -Manual
Assert-Equal @($plan.Tests, $plan.Build, $plan.Ui) @($true, $true, $true) "Manual validation"

$publisher = Join-Path $PSScriptRoot "..\.github\scripts\Publish-PrComment.ps1"
$savedExitCode = $global:LASTEXITCODE
$global:PrValidationGhState = @{
    Calls = [System.Collections.Generic.List[string]]::new()
    CommandFails = $false
    Existing = $false
}
function gh {
    $global:PrValidationGhState.Calls.Add(($args -join " "))
    $global:LASTEXITCODE = if ($global:PrValidationGhState.CommandFails) { 1 } else { 0 }
    if ($args -contains "--paginate") {
        if ($global:PrValidationGhState.Existing) {
            '[[{"id":99,"user":{"login":"other"},"body":"<!-- marker -->"}],[{"id":123,"user":{"login":"github-actions[bot]"},"body":"<!-- marker --> old"}]]'
        } else { '[[]]' }
    }
}
try {
    $parameters = @{ PullRequestNumber = 62; Repository = "test/repo"; Marker = "<!-- marker -->"; Body = "<!-- marker --> new" }
    & $publisher @parameters -Mode Append
    & $publisher @parameters -Mode Append
    Assert-Equal $global:PrValidationGhState.Calls.Count 2 "One new comment per successful build run"
    foreach ($call in $global:PrValidationGhState.Calls) {
        if ($call -notlike "pr comment 62 *" -or $call -match "PATCH|DELETE|--paginate") {
            throw "Append mode must not search for, edit, or remove earlier comments."
        }
    }
    $global:PrValidationGhState.Calls.Clear()
    $global:PrValidationGhState.Existing = $true
    & $publisher @parameters
    Assert-Equal $global:PrValidationGhState.Calls.Count 2 "Upsert queries then updates"
    if ($global:PrValidationGhState.Calls[1] -notlike "*PATCH repos/test/repo/issues/comments/123*") { throw "Update only the bot's matching comment across all pages." }
    $global:PrValidationGhState.Calls.Clear()
    & $publisher @parameters -Mode Remove
    if ($global:PrValidationGhState.Calls[1] -notlike "*DELETE repos/test/repo/issues/comments/123*") { throw "Remove only the matching bot comment." }
    $global:PrValidationGhState.Existing = $false
    $global:PrValidationGhState.Calls.Clear()
    & $publisher @parameters
    if ($global:PrValidationGhState.Calls[1] -notlike "pr comment 62 *") { throw "Missing marker must create a comment." }
    $global:PrValidationGhState.CommandFails = $true
    Assert-Throws { & $publisher @parameters -Mode Append } "*Could not append*"
    Assert-Throws { & $publisher @parameters } "*Could not list*"
    $global:PrValidationGhState.CommandFails = $false
    Assert-Throws { & $publisher -PullRequestNumber 62 -Repository "test/repo" -Marker "missing" -Body "invalid" } "*must include its marker*"
} finally {
    Remove-Item Function:\gh
    Remove-Variable PrValidationGhState -Scope Global
    $global:LASTEXITCODE = $savedExitCode
}

$workflow = Get-Content (Join-Path $PSScriptRoot "..\.github\workflows\ci.yml") -Raw
[xml]$appProject = Get-Content (Join-Path $PSScriptRoot "..\src\FingVibe.App\FingVibe.App.csproj") -Raw
Assert-Equal $appProject.Project.PropertyGroup.SatelliteResourceLanguages "en" "Local and PR builds retain English managed satellite resources"
$releaseWorkflow = Get-Content (Join-Path $PSScriptRoot "..\.github\workflows\release.yml") -Raw
if ($releaseWorkflow -notmatch '(?m)^\s+/property:SatelliteResourceLanguages=[ \t]+`\r?$') {
    throw "Release publishing must override the language filter with an empty global MSBuild property."
}
if ($workflow -match 'SatelliteResourceLanguages') {
    throw "PR publishing must use the application's default English language filter."
}
Assert-Equal ([regex]::Matches($workflow, 'run: dotnet test ').Count) 1 "Run core tests once"
Assert-Equal ([regex]::Matches($workflow, 'msbuild src\\FingVibe.App\\FingVibe.App.csproj').Count) 1 "Publish the app once"
foreach ($pattern in @(
    '(?s)  tests:\s+name: core-tests\s+needs: changes',
    '(?s)  build:\s+needs: changes',
    '(?s)  installer:\s+needs: \[changes, tests, build\]',
    '(?s)  ui-capture:\s+needs: \[changes, tests, build\]',
    '(?s)  build-comment:\s+needs: installer',
    '(?s)  ui-publish:\s+needs: \[changes, tests, build, installer, ui-capture, ui-regression\]',
    '(?s)  ui-ux-review:\s+name: ui-ux-review\s+needs: \[changes, tests, build, installer, ui-capture, ui-regression, ui-publish\]',
    '(?s)name: Upload UI review captures and diagnostics\s+id: screenshot\s+if: always\(\)',
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

function Get-WorkflowJob([string] $Name) {
    $match = [regex]::Match($workflow, "(?ms)^  ${Name}:\r?`n.*?(?=^  [a-z][a-z-]*:\r?`n|\z)")
    if (-not $match.Success) { throw "Workflow job '$Name' was not found." }
    return $match.Value
}

$buildJob = Get-WorkflowJob build
$installerJob = Get-WorkflowJob installer
$captureJob = Get-WorkflowJob ui-capture
$regressionJob = Get-WorkflowJob ui-regression
$publishJob = Get-WorkflowJob ui-publish
Assert-Equal ([regex]::Matches($workflow, 'artifact-ids: \$\{\{ needs.build.outputs.artifact-id \}\}').Count) 3 "Installer, capture and regression matrix consume the same payload ID"
Assert-Equal ([regex]::Matches($buildJob, 'uses: actions/upload-artifact@v4').Count) 1 "Publish uploads only the transfer payload"
if ($buildJob -notmatch '(?s)name: Upload unvalidated payload.*?id: upload.*?name: fingvibe-validation-payload-pr-.*-attempt-\$\{\{ github.run_attempt \}\}.*?retention-days: 1' -or
    $buildJob -match 'New-Installer|Installer.Lifecycle|name: Upload runnable app|name: Upload tested installer') {
    throw "Publishing must not advertise tested downloads or wait for installer validation."
}
foreach ($job in @($installerJob, $captureJob, $regressionJob)) {
    if ($job -notmatch 'uses: actions/download-artifact@v4' -or $job -match 'msbuild|/target:Publish') {
        throw "Downstream validation must download the single published payload, not rebuild."
    }
}
if ($installerJob -notmatch '(?s)Download the published payload.*?path: artifacts\\fingvibe-win-x64.*?New-Installer.ps1.*?Installer.Lifecycle.Tests.ps1.*?name: Upload tested installer.*?name: Upload runnable app\s+id: upload' -or
    $installerJob -notmatch '(?s)name: Upload installer diagnostics\s+if: always\(\)') {
    throw "Tested downloads must follow installer validation, retaining failure diagnostics."
}
foreach ($step in @("Download completed captures", "Publish screenshots for inline review", "Add screenshots to pull request")) {
    if ($publishJob -notmatch ("(?s)name: " + [regex]::Escape($step) + "\s+(?:id: [^\r\n]+\s+)?if: needs.ui-capture.result == 'success' && needs.installer.result == 'success' && needs.ui-regression.result == 'success'")) {
        throw "Screenshot publication must wait for successful UI and installer checks: $step"
    }
}
    foreach ($pattern in @(
        'needs: \[changes, tests, build\]',
        'runs-on: windows-2025',
        'timeout-minutes: 20',
        'fail-fast: false',
        'suite: \[sidebar, devices, history, history-semantics, history-rendering, history-persistence, history-paging, tools\]',
        '(?s)name: Run native regression suite\s+timeout-minutes: 15',
        "(?s)name: Run native regression suite\s+timeout-minutes: 15\s+if: matrix.suite != 'sidebar'\s+shell: pwsh",
        "(?s)name: Run sidebar regression in Windows PowerShell\s+timeout-minutes: 15\s+if: matrix.suite == 'sidebar'\s+shell: powershell",
        '(?s)name: Upload native regression diagnostics\s+if: always\(\)',
        'name: fingvibe-ui-regression-\$\{\{ matrix.suite \}\}-pr-',
        'REGRESSION_RESULT: \$\{\{ needs.ui-regression.result \}\}'
    )) {
        $target = if ($pattern.StartsWith('REGRESSION_RESULT')) { $publishJob } else { $regressionJob }
        if ($target -notmatch $pattern) { throw "Missing parallel regression invariant: $pattern" }
    }
    foreach ($job in @($captureJob, $regressionJob)) {
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
        "UsageCategory.Ui", "DeviceActivity.Ui",
        "BuildIdentity.Ui", "NetworkTroubleshooting.Ui", "FingImport.Ui", "AdditionalServices.Ui", "SqlEditor.Ui")) {
        if ($captureJob.Contains($suite) -or $smokeScript.Contains($suite)) { throw "Capture still runs extracted suite: $suite" }
        Assert-Equal ([regex]::Matches($regressionScript, ('Invoke-RegressionCheck "' + [regex]::Escape($suite) + '"')).Count) 1 "Preserve suite exactly once: $suite"
    }
    if ($regressionScript -notmatch '\$plan.Scenario -contains "DeviceDetails"' -or
        $regressionScript -notmatch 'Stop-Transcript' -or
        $captureJob -notmatch 'timeout-minutes: 10' -or
        $captureJob -notmatch '(?s)id: smoke\s+timeout-minutes: 7') {
        throw "Preserve history selection, transcripts and bounded native execution."
    }

    $runnerFixture = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-regression-runner-$([Guid]::NewGuid())"
    $runnerSaved = @{}
    try {
        foreach ($name in @("UI_REGRESSION_CALLS", "UI_REGRESSION_FAIL", "GITHUB_STEP_SUMMARY")) {
            $runnerSaved[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $scripts = Join-Path $runnerFixture ".github\scripts"
        $null = New-Item -ItemType Directory -Path $scripts -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $runnerFixture "tests") -Force
        foreach ($name in @("Invoke-UiRegression.ps1", "UiReviewScenarios.ps1")) {
            Copy-Item (Join-Path $PSScriptRoot "..\.github\scripts\$name") $scripts
        }
        foreach ($name in @("SidebarNavigation", "DevicesList.Ui", "DeviceScanHistory.Ui", "DeviceDiscovery.Ui",
            "UsageCategory.Ui", "DeviceActivity.Ui",
            "BuildIdentity.Ui", "NetworkTroubleshooting.Ui", "FingImport.Ui", "AdditionalServices.Ui", "SqlEditor.Ui")) {
            @(
                'param($AppPath, $ScreenshotDirectory, $Version, $BuildKind, $BuildTimestamp, $BuildCommit, $PullRequestNumber, $Group)',
                '$name = [IO.Path]::GetFileName($PSCommandPath).Replace(".Tests.ps1", "")',
                '@{ Name = $name; Parameters = $PSBoundParameters } | ConvertTo-Json -Compress | Add-Content $env:UI_REGRESSION_CALLS',
                'if ($env:UI_REGRESSION_FAIL -eq $name) { throw "Simulated regression failure: $name" }'
            ) | Set-Content (Join-Path $runnerFixture "tests\$name.Tests.ps1")
        }
        $env:UI_REGRESSION_CALLS = Join-Path $runnerFixture "calls.jsonl"
        $env:GITHUB_STEP_SUMMARY = Join-Path $runnerFixture "summary.txt"
        $env:UI_REGRESSION_FAIL = $null
        $planPath = Join-Path $runnerFixture "capture-plan.json"
        $definitions = @(Get-UiReviewCapturePlan -RepositoryPath $runnerFixture -AdditionalScenarios DeviceDetails)
        ConvertTo-Json -InputObject $definitions -Depth 5 | Set-Content $planPath
        $runner = Join-Path $scripts "Invoke-UiRegression.ps1"
        $parameters = @{
            AppPath = "synthetic.exe"; ScreenshotDirectory = (Join-Path $runnerFixture "diagnostics")
            CapturePlanPath = $planPath; Version = "0.0.123"; BuildKind = "PullRequest"
            BuildTimestamp = "2026-11-06T09:00:00Z"; BuildCommit = "test-commit"; PullRequestNumber = 198
        }
        foreach ($suite in @("sidebar", "devices", "history", "history-semantics", "history-rendering",
            "history-persistence", "history-paging", "tools")) {
            & $runner -Suite $suite @parameters
        }
        $calls = @(Get-Content $env:UI_REGRESSION_CALLS | ConvertFrom-Json)
        Assert-Equal $calls.Name @("SidebarNavigation", "DevicesList.Ui", "DeviceDiscovery.Ui",
            "UsageCategory.Ui", "DeviceActivity.Ui", "DeviceScanHistory.Ui", "DeviceScanHistory.Ui",
            "DeviceScanHistory.Ui", "DeviceScanHistory.Ui",
            "BuildIdentity.Ui", "NetworkTroubleshooting.Ui", "FingImport.Ui", "AdditionalServices.Ui", "SqlEditor.Ui") "Dispatch every preserved suite once"
        Assert-Equal $calls[5..8].Parameters.Group @("Semantics", "Rendering", "Persistence", "Paging") "Each group has its own exact-once matrix dispatch"
        Assert-Equal ([DateTimeOffset]$calls[9].Parameters.BuildTimestamp).UtcDateTime ([DateTimeOffset]$parameters.BuildTimestamp).UtcDateTime "Forward stamped identity"
        Assert-Equal $calls[9].Parameters.PullRequestNumber 198 "Forward PR identity"
        Assert-Equal ($calls.Parameters.AppPath | Select-Object -Unique) "synthetic.exe" "Reuse supplied app"
        & powershell.exe -NoProfile -File $runner -Suite sidebar -AppPath $parameters.AppPath `
            -ScreenshotDirectory $parameters.ScreenshotDirectory -CapturePlanPath $planPath
        if ($LASTEXITCODE -ne 0) { throw "Sidebar runner must support multi-scenario plans under Windows PowerShell." }
        Assert-Equal @(Get-Content $env:UI_REGRESSION_CALLS).Count 15 "Windows PowerShell dispatches the sidebar without parsing history selection"
        ConvertTo-Json -InputObject @($definitions | Where-Object Scenario -eq Devices) -Depth 5 | Set-Content $planPath
        & $runner -Suite history @parameters
        foreach ($suite in @("history-semantics", "history-rendering", "history-persistence", "history-paging")) {
            & $runner -Suite $suite @parameters
        }
        Assert-Equal @(Get-Content $env:UI_REGRESSION_CALLS).Count 15 "Unselected history and groups must not launch native checks"
        ConvertTo-Json -InputObject $definitions -Depth 5 | Set-Content $planPath
        $env:UI_REGRESSION_FAIL = "DeviceScanHistory.Ui"
        foreach ($suite in @("history-semantics", "history-rendering", "history-persistence", "history-paging")) {
            Assert-Throws { & $runner -Suite $suite @parameters } "*Simulated regression failure*"
            if ((Get-Content $env:GITHUB_STEP_SUMMARY -Raw) -notlike "*$suite / DeviceScanHistory.Ui elapsed:*") {
                throw "Independent group failure must expose named job timing: $suite."
            }
        }
        $env:UI_REGRESSION_FAIL = "DevicesList.Ui"
        Assert-Throws { & $runner -Suite devices @parameters } "*Simulated regression failure*"
        if ((Get-Content (Join-Path $parameters.ScreenshotDirectory "regression.log") -Raw) -notmatch 'Simulated regression failure') {
            throw "Regression transcript must retain the original failure."
        }
        if ((Get-Content $env:GITHUB_STEP_SUMMARY -Raw) -notmatch 'devices / DevicesList.Ui elapsed:') {
            throw "Regression timing must be reported even on failure."
        }
    } finally {
        foreach ($name in $runnerSaved.Keys) { [Environment]::SetEnvironmentVariable($name, $runnerSaved[$name]) }
        Remove-Item -LiteralPath $runnerFixture -Recurse -Force
    }
if ($publishJob -notmatch 'INSTALLER_RESULT: \$\{\{ needs.installer.result \}\}' -or
    $publishJob -notmatch "needs.installer.result == 'failure'" -or
    $publishJob -notmatch 'Installer packaging, lifecycle validation, or tested download publication failed') {
    throw "Installer failures must be explained by the existing failure publisher."
}

$smokeMatch = [regex]::Match($workflow, '(?s)- name: Exercise primary UI and capture required views.*?run: \|\r?\n(.*?)\r?\n      - name: Upload UI review')
if (-not $smokeMatch.Success) { throw "UI smoke-test wrapper was not found." }
$smoke = [scriptblock]::Create(($smokeMatch.Groups[1].Value -replace '(?m)^          ', '' -replace '\$\{\{ github.workspace \}\}', '$env:GITHUB_WORKSPACE'))
$fixture = Join-Path ([System.IO.Path]::GetTempPath()) "fingvibe-smoke-failure-$([Guid]::NewGuid())"
$savedWorkspace = $env:GITHUB_WORKSPACE
try {
    $null = New-Item -ItemType Directory -Path (Join-Path $fixture ".github\scripts") -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $fixture "artifacts\ui-review") -Force
    @'
param($AppPath, $ScreenshotDirectory, $CapturePlanPath)
"partial screenshot" | Set-Content (Join-Path $ScreenshotDirectory "partial.png")
"driver failure details" | Set-Content (Join-Path $ScreenshotDirectory "driver.log")
throw "Simulated native smoke failure"
'@ | Set-Content (Join-Path $fixture ".github\scripts\Invoke-UiReview.ps1")
    $env:GITHUB_WORKSPACE = $fixture
    Push-Location $fixture
    try {
        Assert-Throws { & $smoke } "*Simulated native smoke failure*"
        foreach ($file in @("partial.png", "driver.log", "smoke-test.log")) {
            if (-not (Test-Path -LiteralPath (Join-Path $fixture "artifacts\ui-review\$file"))) {
                throw "Failure diagnostics must retain $file."
            }
        }
        $transcript = Get-Content (Join-Path $fixture "artifacts\ui-review\smoke-test.log") -Raw
        if (-not $transcript.Contains("Simulated native smoke failure")) { throw "The failure transcript must retain the original error." }
    } finally {
        Pop-Location
    }
} finally {
    $env:GITHUB_WORKSPACE = $savedWorkspace
    Remove-Item -LiteralPath $fixture -Recurse -Force
}

$gateMatch = [regex]::Match($workflow, '(?s)- name: Report validation result.*?run: \|\r?\n(.*)$')
if (-not $gateMatch.Success) { throw "Required UI gate script was not found." }
$gate = [scriptblock]::Create(($gateMatch.Groups[1].Value -replace '(?m)^          ', ''))
$names = @("CHANGES_RESULT", "TEST_RESULT", "BUILD_RESULT", "INSTALLER_RESULT", "TEST_REQUIRED", "BUILD_REQUIRED", "UI_REQUIRED", "CAPTURE_RESULT", "REGRESSION_RESULT", "PUBLISH_RESULT", "TRUSTED", "EVENT_NAME", "GITHUB_STEP_SUMMARY")
$saved = @{}
$summary = Join-Path ([System.IO.Path]::GetTempPath()) "fingvibe-gate-$([Guid]::NewGuid()).txt"
try {
    foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    $env:GITHUB_STEP_SUMMARY = $summary
    $env:CHANGES_RESULT = "success"
    $env:TEST_RESULT = "success"
    $env:BUILD_RESULT = "success"
    $env:INSTALLER_RESULT = "success"
    $env:TEST_REQUIRED = "true"
    $env:BUILD_REQUIRED = "true"
    $env:UI_REQUIRED = "true"
    $env:CAPTURE_RESULT = "success"
    $env:REGRESSION_RESULT = "success"
    $env:PUBLISH_RESULT = "success"
    $env:TRUSTED = "true"
    $env:EVENT_NAME = "pull_request"
    & $gate
    foreach ($name in @("TEST_RESULT", "BUILD_RESULT", "INSTALLER_RESULT", "CAPTURE_RESULT", "REGRESSION_RESULT", "PUBLISH_RESULT")) {
        foreach ($result in @("failure", "cancelled", "skipped", "")) {
            [Environment]::SetEnvironmentVariable($name, $result)
            Assert-Throws { & $gate } "*did not*"
        }
        [Environment]::SetEnvironmentVariable($name, "success")
    }
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
    $env:EVENT_NAME = "workflow_dispatch"
    & $gate
    $env:EVENT_NAME = "pull_request"
    $env:TRUSTED = "false"
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
Write-Host "PR validation planning, comment history, and required-check regression tests passed."
