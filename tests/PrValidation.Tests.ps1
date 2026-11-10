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
    @{ Paths = @("tests/NetworkActivity.Ui.Tests.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/NetworkActivity.Fixture.ps1"); Expected = @($true, $true, $true) },
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
$securityWorkflow = Get-Content (Join-Path $PSScriptRoot "..\.github\workflows\security-review.yml") -Raw
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
    '(?s)  tests:\s+name: core-tests\s+needs: changes',
    '(?s)  build:\s+needs: changes',
    '(?s)  installer:\s+needs: \[changes, tests, build\]',
    '(?s)  ui-capture:\s+needs: \[changes, build\]',
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

$testJob = Get-WorkflowJob tests
$buildJob = Get-WorkflowJob build
$installerJob = Get-WorkflowJob installer
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
foreach ($job in @($captureJob, $regressionJob)) {
    if ($job -notmatch 'needs: \[changes, build\]' -or $job -match 'needs.tests') {
        throw "Native UI validation must overlap core tests after the single published build."
    }
}
if ($installerJob -notmatch 'needs: \[changes, tests, build\]' -or
    $publishJob -notmatch 'needs: \[changes, tests, build, installer, ui-capture, ui-regression\]') {
    throw "Tested downloads and screenshot publication must still wait for passing core tests."
}
Assert-Equal ([regex]::Matches($workflow, 'artifact-ids: \$\{\{ needs.build.outputs.artifact-id \}\}').Count) 3 "Installer, capture and regression matrix consume the same payload ID"
Assert-Equal ([regex]::Matches($buildJob, 'uses: actions/upload-artifact@v7\.0\.2').Count) 1 "Publish uploads only the transfer payload"
if ($buildJob -notmatch '(?s)name: Upload unvalidated payload.*?id: upload.*?name: fingvibe-validation-payload-pr-.*-attempt-\$\{\{ github.run_attempt \}\}.*?retention-days: 1' -or
    $buildJob -match 'New-Installer|Installer.Lifecycle|name: Upload runnable app|name: Upload tested installer') {
    throw "Publishing must not advertise tested downloads or wait for installer validation."
}
foreach ($job in @($installerJob, $captureJob, $regressionJob)) {
    if ($job -notmatch 'uses: actions/download-artifact@v8\.0\.2' -or $job -match 'msbuild|/target:Publish') {
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
        'needs: \[changes, build\]',
        'runs-on: windows-2025',
        'timeout-minutes: 20',
        'fail-fast: false',
        'suite: \[sidebar-presentation, sidebar-scan-flows, sidebar-preferences-scheduling, devices-presentation, devices-filters-previews, devices-columns-sorting, details-summary, details-identity, details-observations, details-activity, tools-utilities, tools-device-data\]',
        '(?s)name: Run native regression suite\s+timeout-minutes: 15',
        "(?s)name: Run native regression suite\s+timeout-minutes: 15\s+if: \$\{\{ !startsWith\(matrix.suite, 'sidebar-'\) \}\}\s+shell: pwsh",
        "(?s)name: Run sidebar regression in Windows PowerShell\s+timeout-minutes: 15\s+if: startsWith\(matrix.suite, 'sidebar-'\)\s+shell: powershell",
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
        "UsageCategory.Ui", "DeviceActivity.Ui", "NetworkActivity.Ui",
        "Tools.Ui")) {
        if ($captureJob.Contains($suite) -or $smokeScript.Contains($suite)) { throw "Capture still runs extracted suite: $suite" }
        $expectedCount = if ($suite -eq "DeviceScanHistory.Ui") { 2 } else { 1 }
        Assert-Equal ([regex]::Matches($regressionScript, ('Invoke-RegressionCheck "' + [regex]::Escape($suite) + '"')).Count) $expectedCount "Preserve suite dispatch: $suite"
    }
    if ($regressionScript -notmatch 'SummaryOnly = \$true') {
        throw "Retained summary checks remain required independently of observation checks."
    }
    if ($regressionScript -notmatch [regex]::Escape('$_ -in @("DeviceDetails", "DeviceHistory")') -or
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
        $groupModules = Join-Path $runnerFixture "tests\UiRegression"
        $null = New-Item -ItemType Directory -Path $groupModules -Force
        Copy-Item (Join-Path $PSScriptRoot "Tools.Ui.Tests.ps1") (Join-Path $runnerFixture "tests")
        Copy-Item (Join-Path $PSScriptRoot "UiRegression\Tools.*") $groupModules
        Copy-Item (Join-Path $PSScriptRoot "UiRegression\Helpers.ps1") $groupModules
        foreach ($name in @("Invoke-UiRegression.ps1", "UiReviewScenarios.ps1")) {
            Copy-Item (Join-Path $PSScriptRoot "..\.github\scripts\$name") $scripts
        }
        foreach ($name in @("SidebarNavigation", "DevicesList.Ui", "DeviceScanHistory.Ui", "DeviceDiscovery.Ui",
            "UsageCategory.Ui", "DeviceActivity.Ui", "NetworkActivity.Ui",
            "BuildIdentity.Ui", "NetworkTroubleshooting.Ui", "FingImport.Ui", "AdditionalServices.Ui", "SqlEditor.Ui")) {
            @(
                'param($AppPath, $ScreenshotDirectory, $Version, $BuildKind, $BuildTimestamp, $BuildCommit, $PullRequestNumber, $SummaryOnly, $ObservationsOnly, $Group)',
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
        $matrixSuites = @([regex]::Match($regressionJob, 'suite: \[([^\]]+)\]').Groups[1].Value.Split(",") | ForEach-Object { $_.Trim() })
        $expectedSuiteChecks = [ordered]@{
            "sidebar-presentation" = @("SidebarNavigation")
            "sidebar-scan-flows" = @("SidebarNavigation")
            "sidebar-preferences-scheduling" = @("SidebarNavigation")
            "devices-presentation" = @("DevicesList.Ui")
            "devices-filters-previews" = @("DevicesList.Ui")
            "devices-columns-sorting" = @("DevicesList.Ui")
            "details-summary" = @("DeviceScanHistory.Ui")
            "details-identity" = @("DeviceDiscovery.Ui", "UsageCategory.Ui")
            "details-observations" = @("DeviceScanHistory.Ui")
            "details-activity" = @("DeviceActivity.Ui")
            "tools-utilities" = @("BuildIdentity.Ui", "NetworkTroubleshooting.Ui", "FingImport.Ui")
            "tools-device-data" = @("AdditionalServices.Ui", "SqlEditor.Ui")
        }
        Assert-Equal $matrixSuites @($expectedSuiteChecks.Keys) "CI matrix dispatches every split suite"
        foreach ($suite in $matrixSuites) {
            $before = if (Test-Path $env:UI_REGRESSION_CALLS) { @(Get-Content $env:UI_REGRESSION_CALLS).Count } else { 0 }
            & $runner -Suite $suite @parameters
            $suiteCalls = @(Get-Content $env:UI_REGRESSION_CALLS | Select-Object -Skip $before | ConvertFrom-Json)
            # A dispatched matrix job must never pass without running a native check.
            if ($suiteCalls.Count -eq 0) { throw "Matrix suite '$suite' dispatched no native checks." }
            Assert-Equal $suiteCalls.Name $expectedSuiteChecks[$suite] "Suite '$suite' runs exactly its assigned checks"
        }
        $calls = @(Get-Content $env:UI_REGRESSION_CALLS | ConvertFrom-Json)
        Assert-Equal $calls.Name @("SidebarNavigation", "SidebarNavigation", "SidebarNavigation", "DevicesList.Ui", "DevicesList.Ui", "DevicesList.Ui", "DeviceScanHistory.Ui", "DeviceDiscovery.Ui",
            "UsageCategory.Ui", "DeviceScanHistory.Ui", "DeviceActivity.Ui",
            "BuildIdentity.Ui", "NetworkTroubleshooting.Ui", "FingImport.Ui", "AdditionalServices.Ui", "SqlEditor.Ui") "Dispatch every preserved suite once"
        $deviceGroups = @((Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot "UiRegression\Devices.Groups.psd1")).Groups.Name)
        Assert-Equal @($matrixSuites | Where-Object { $_ -like "devices*" }) @($deviceGroups | ForEach-Object { "devices-$_" }) "CI matrix runs every Devices group once on its own worker"
        Assert-Equal @($calls | Where-Object Name -eq "DevicesList.Ui" | ForEach-Object { $_.Parameters.Group }) $deviceGroups "Devices group jobs dispatch exactly their group"
        foreach ($groupSuite in @("Sidebar", "Tools")) {
            $groups = @((Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot "UiRegression\$groupSuite.Groups.psd1")).Groups.Name)
            Assert-Equal @($matrixSuites | Where-Object { $_ -like "$groupSuite-*" }) @($groups | ForEach-Object { "$($groupSuite.ToLowerInvariant())-$_" }) "CI dispatches every $groupSuite group exactly once, never the full suite"
        }
        Assert-Equal @($calls | Where-Object Name -eq "SidebarNavigation" | ForEach-Object { $_.Parameters.Group }) @("presentation", "scan-flows", "preferences-scheduling") "Sidebar forwards each independent group"
        Assert-Equal $calls[6].Parameters.SummaryOnly $true "Details summary dispatch tests only retained summaries"
        Assert-Equal $calls[9].Parameters.ObservationsOnly $true "Details history dispatch includes full observation rendering and paging"
        Assert-Equal ([DateTimeOffset]$calls[11].Parameters.BuildTimestamp).UtcDateTime ([DateTimeOffset]$parameters.BuildTimestamp).UtcDateTime "Forward stamped identity"
        Assert-Equal $calls[11].Parameters.PullRequestNumber 198 "Forward PR identity"
        Assert-Equal ($calls.Parameters.AppPath | Select-Object -Unique) "synthetic.exe" "Reuse supplied app"
        & powershell.exe -NoProfile -File $runner -Suite sidebar -AppPath $parameters.AppPath `
            -ScreenshotDirectory $parameters.ScreenshotDirectory -CapturePlanPath $planPath
        if ($LASTEXITCODE -ne 0) { throw "Sidebar runner must support multi-scenario plans under Windows PowerShell." }
        Assert-Equal @(Get-Content $env:UI_REGRESSION_CALLS).Count 17 "Windows PowerShell dispatches the sidebar without parsing details selection"
        ConvertTo-Json -InputObject @($definitions | Where-Object Scenario -eq Devices) -Depth 5 | Set-Content $planPath
        foreach ($suite in @("details-summary", "details-identity", "details-observations", "details-activity")) {
            & $runner -Suite $suite @parameters
            Assert-Equal @(Get-Content $env:UI_REGRESSION_CALLS).Count 17 "Unselected $suite must not launch native checks"
        }
        ConvertTo-Json -InputObject @(Get-UiReviewCapturePlan -RepositoryPath $runnerFixture -AdditionalScenarios Network) -Depth 5 | Set-Content $planPath
        foreach ($suite in @("details-summary", "details-observations", "details-activity")) {
            & $runner -Suite $suite @parameters
            Assert-Equal @(Get-Content $env:UI_REGRESSION_CALLS).Count 17 "Network-only plan adds no checks to $suite"
        }
        & $runner -Suite details-identity @parameters
        $networkCalls = @(Get-Content $env:UI_REGRESSION_CALLS | Select-Object -Skip 17 | ConvertFrom-Json)
        Assert-Equal $networkCalls.Name @("NetworkActivity.Ui") "Network-only plan still runs its activity regression"
        ConvertTo-Json -InputObject @(Get-UiReviewCapturePlan -RepositoryPath $runnerFixture -AdditionalScenarios DeviceDetails, Network) -Depth 5 |
            Set-Content $planPath
        foreach ($suite in @("details-summary", "details-identity", "details-observations", "details-activity")) {
            $before = @(Get-Content $env:UI_REGRESSION_CALLS).Count
            & $runner -Suite $suite @parameters
            $suiteCalls = @(Get-Content $env:UI_REGRESSION_CALLS | Select-Object -Skip $before | ConvertFrom-Json)
            $expected = if ($suite -eq "details-identity") { @($expectedSuiteChecks[$suite]) + "NetworkActivity.Ui" } else { $expectedSuiteChecks[$suite] }
            Assert-Equal $suiteCalls.Name $expected "Combined plan runs Network Activity once, in details-identity"
        }
        ConvertTo-Json -InputObject @(Get-UiReviewCapturePlan -RepositoryPath $runnerFixture -AdditionalScenarios DeviceHistory, Network) -Depth 5 |
            Set-Content $planPath
        foreach ($suite in @("details-summary", "details-identity", "details-observations", "details-activity")) {
            $before = @(Get-Content $env:UI_REGRESSION_CALLS).Count
            & $runner -Suite $suite @parameters
            $suiteCalls = @(Get-Content $env:UI_REGRESSION_CALLS | Select-Object -Skip $before | ConvertFrom-Json)
            $expected = if ($suite -eq "details-identity") { @($expectedSuiteChecks[$suite]) + "NetworkActivity.Ui" } else { $expectedSuiteChecks[$suite] }
            Assert-Equal $suiteCalls.Name $expected "History-tab plan preserves split suites and Network Activity coverage"
        }
        Assert-Throws { & $runner -Suite history @parameters } "*history*"
        $env:UI_REGRESSION_FAIL = "DevicesList.Ui"
        Assert-Throws { & $runner -Suite devices @parameters } "*Simulated regression failure*"
        if ($null -ne @(Get-Content $env:UI_REGRESSION_CALLS | ConvertFrom-Json)[-1].Parameters.Group) {
            throw "The full devices suite must run every group sequentially."
        }
        if ((Get-Content (Join-Path $parameters.ScreenshotDirectory "regression.log") -Raw) -notmatch 'Simulated regression failure') {
            throw "Regression transcript must retain the original failure."
        }
        if ((Get-Content $env:GITHUB_STEP_SUMMARY -Raw) -notmatch 'devices / DevicesList.Ui elapsed:') {
            throw "Regression timing must be reported even on failure."
        }
        $env:UI_REGRESSION_FAIL = $null
        $before = @(Get-Content $env:UI_REGRESSION_CALLS).Count
        & $runner -Suite tools @parameters
        $toolChecks = @("BuildIdentity.Ui", "NetworkTroubleshooting.Ui", "FingImport.Ui", "AdditionalServices.Ui", "SqlEditor.Ui")
        Assert-Equal @(Get-Content $env:UI_REGRESSION_CALLS | Select-Object -Skip $before | ConvertFrom-Json).Name $toolChecks "Default Tools entry point preserves full sequential coverage"
        $env:UI_REGRESSION_FAIL = "BuildIdentity.Ui"
        $before = @(Get-Content $env:UI_REGRESSION_CALLS).Count
        Assert-Throws { & $runner -Suite tools @parameters } "*Tools groups failed: utilities*Simulated regression failure*"
        Assert-Equal @(Get-Content $env:UI_REGRESSION_CALLS | Select-Object -Skip $before | ConvertFrom-Json).Name @("BuildIdentity.Ui", "AdditionalServices.Ui", "SqlEditor.Ui") "An independent Tools group must still run after another group fails"
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
& (Join-Path $PSScriptRoot "NativeValidation.Tests.ps1")
Write-Host "PR validation planning, comment history, and required-check regression tests passed."
