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
    @{ Paths = @("tests/ReleaseUpdates.Ui.Tests.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/UiRegression/Tools.Updates.Scenario.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/DeviceScanHistory.Ui.Tests.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/DeviceActivity.Ui.Tests.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/DeviceActivity.Fixture.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/ActivityGrid.Ui.Helpers.ps1"); Expected = @($true, $true, $true) },
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
    @{ Paths = @("tools/New-SpeedTestPayload.ps1"); Expected = @($true, $true, $true) },
    # Reviewed agent-loop scripts and standalone inspectors run core/script tests only, alone or with docs/non-native tests.
    @{ Paths = @(".github/scripts/Get-Agent4DispatcherPacket.ps1"); Expected = @($true, $false, $false) },
    @{ Paths = @(".github/scripts/Agent3Coordination.psm1", "tests/Agent4DispatcherPacket.Tests.ps1", "docs/agentic-loop-4/README.md",
        ".github/agents/developer.agent.md"); Expected = @($true, $false, $false) },
    @{ Paths = @("tools/DecoX50Inspector/DecoCapture.cs", "tools/Ex220Inspector/RouterLogin.js"); Expected = @($true, $false, $false) },
    @{ Paths = @(".github/scripts/Set-Agent4TaskClaim.ps1", "tools/Ex220Inspector/ClientCapture.cs", "tests/UiRegression.Helpers.Tests.ps1",
        "tests/DeviceActivity.Script.Tests.ps1"); Expected = @($true, $false, $false) },
    # Anything else, alone or mixed with allow-listed paths, keeps the full native path.
    @{ Paths = @(".github/scripts/Set-Agent4TaskClaim.ps1", "src/FingVibe.App/MainWindow.xaml.cs"); Expected = @($true, $true, $true) },
    @{ Paths = @(".github/scripts/Get-Agent4DispatcherPacket.ps1", ".github/workflows/ci.yml"); Expected = @($true, $true, $true) },
    @{ Paths = @("tools/Ex220Inspector/ClientCapture.cs", "tools/installer/FingVibe.iss"); Expected = @($true, $true, $true) },
    @{ Paths = @("tools/DecoX50Inspector/DecoCapture.cs", "Directory.Build.props"); Expected = @($true, $true, $true) },
    @{ Paths = @(".github/scripts/New-UnreviewedHelper.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @(".github/scripts/Get-Agent4UnreviewedHelper.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @(".github/scripts/set-agent4taskclaim.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tools/New-LogoDevConfiguration.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tools/New-Installer.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tools/README.md"); Expected = @($true, $true, $true) },
    # Native UI test modules, entry scripts and fixtures select the build and native UI path.
    @{ Paths = @("tests/DevicesList.Ui.Tests.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/SidebarNavigation.Tests.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/Tools.Ui.Tests.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/UsageCategory.Ui.Tests.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/AdditionalServices.Ui.Tests.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/Inventory.Sqlite.Helpers.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/UiRegression/Devices.Filters.Scenario.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/UiRegression/Sidebar.Groups.psd1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/UiRegression/Helpers.ps1", ".github/scripts/Agent4Coordination.psm1"); Expected = @($true, $true, $true) }
)) {
    $plan = Get-PrValidationChanges -Paths $case.Paths
    Assert-Equal @($plan.Tests, $plan.Build, $plan.Ui) $case.Expected "Classification: $($case.Paths)"
}
$plan = Get-PrValidationChanges -Manual
Assert-Equal @($plan.Tests, $plan.Build, $plan.Ui) @($true, $true, $true) "Manual validation"
$plan = Get-PrValidationChanges -Paths @(".github/scripts/Get-Agent4DispatcherPacket.ps1") -Manual
Assert-Equal @($plan.Tests, $plan.Build, $plan.Ui) @($true, $true, $true) "Manual dispatch still forces everything for allow-listed paths"

$scriptsDirectory = Join-Path $PSScriptRoot "..\.github\scripts"
$nativeConsumers = @(@(Get-ChildItem (Join-Path $PSScriptRoot "..\.github\workflows") -Filter *.yml) +
    @(Get-ChildItem $scriptsDirectory -File | Where-Object { $_.Name -cnotin $PrValidationNonNativeScripts -and $_.Name -cne "Get-PrValidationChanges.ps1" }) +
    @(Get-ChildItem (Join-Path $PSScriptRoot "..\src"), (Join-Path $PSScriptRoot "..\tools\installer") -Recurse -File) +
    @(Get-ChildItem (Join-Path $PSScriptRoot "..\tools") -File) |
    Where-Object { $_.Extension -ne ".md" -and $_.FullName -notmatch '[\\/](bin|obj)[\\/]' } | ForEach-Object FullName)
foreach ($name in $PrValidationNonNativeScripts) {
    if (-not (Test-Path -LiteralPath (Join-Path $scriptsDirectory $name))) { throw "Allow-listed script '$name' no longer exists." }
    $stem = [regex]::Escape([IO.Path]::GetFileNameWithoutExtension($name))
    $uses = @($nativeConsumers | Where-Object { (Get-Content -LiteralPath $_ -Raw) -match "(?<![\w-])$stem(?!\.Tests)(?![\w-])" })
    if ($uses) { throw "Allow-listed '$name' is used outside its core tests: $($uses -join ', ')" }
}
foreach ($inspector in @("DecoX50Inspector", "Ex220Inspector")) {
    $uses = @($nativeConsumers | Where-Object { (Get-Content -LiteralPath $_ -Raw) -match [regex]::Escape($inspector) })
    if ($uses) { throw "Allow-listed tools/$inspector is used by build, installer or pipeline sources: $($uses -join ', ')" }
}

# Every native entry script CI dispatches, and every test file it loads, must select native validation.
$testsRoot = (Resolve-Path $PSScriptRoot).Path
$regressionRunner = Get-Content (Join-Path $scriptsDirectory "Invoke-UiRegression.ps1") -Raw
$nativeEntries = @([regex]::Matches($regressionRunner, 'Invoke-RegressionCheck "([^"]+)"') | ForEach-Object { "$($_.Groups[1].Value).Tests.ps1" }) +
    @(foreach ($source in @("Invoke-UiReview.ps1", "Invoke-NativeValidation.ps1")) {
        [regex]::Matches((Get-Content (Join-Path $scriptsDirectory $source) -Raw), 'tests\\([A-Za-z0-9_.\\]+\.ps1)') | ForEach-Object { $_.Groups[1].Value }
    }) + @("Installer.Lifecycle.Tests.ps1") +
    @(Get-ChildItem (Join-Path $testsRoot "UiRegression") -File | ForEach-Object { "UiRegression\$($_.Name)" })
if (@($nativeEntries | Where-Object { $_ -like "*.Ui.Tests.ps1" }).Count -lt 5 -or $nativeEntries -notcontains "SidebarNavigation.Tests.ps1") {
    throw "Native entry discovery must find the dispatched suites."
}
$pending = [Collections.Generic.Queue[string]]::new()
$nativeFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $nativeEntries) { $pending.Enqueue($entry) }
while ($pending.Count) {
    $relative = $pending.Dequeue()
    $full = Join-Path $testsRoot $relative
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Dispatched native test '$relative' is missing." }
    if (-not $nativeFiles.Add($relative)) { continue }
    foreach ($reference in [regex]::Matches((Get-Content -LiteralPath $full -Raw), '[''"\\](?<name>(UiRegression\\)?[A-Za-z0-9_.]+\.(ps1|psd1))[''"]')) {
        $name = $reference.Groups["name"].Value
        if (Test-Path -LiteralPath (Join-Path $testsRoot $name) -PathType Leaf) { $pending.Enqueue($name) }
    }
}
foreach ($relative in $nativeFiles) {
    $path = "tests/" + $relative.Replace("\", "/")
    $plan = Get-PrValidationChanges -Paths @($path)
    if (-not ($plan.Build -and $plan.Ui)) { throw "Native UI test '$path' must select the app build and native UI." }
}
foreach ($required in @("NetworkTroubleshooting.Ui.Tests.ps1", "Inventory.Sqlite.Helpers.ps1", "UiReviewScreenshot.Tests.ps1")) {
    if (-not $nativeFiles.Contains($required)) { throw "Native closure must include '$required'." }
}

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
        Assert-Equal @($identity.number, $identity.tag) @("1.3.$runNumber", "v1.3.$runNumber") "Generated feature version and tag retain the run number"
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
            "--notes-file", "docs\release-notes-1.3.md", "--generate-notes"
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
    '(?s)  tests:\s+name: core-tests\s+needs: changes',
    '(?s)  build:\s+needs: changes',
    '(?s)  installer:\s+needs: \[changes, tests, build\]',
    '(?s)  ui-smoke:\s+needs: \[changes, build\]',
    '(?s)  ui-assignments:\s+needs: \[changes, build\]',
    '(?s)  ui-capture:\s+needs: \[changes, build\]',
    '(?s)  build-comment:\s+needs: installer',
    '(?s)  ui-publish:\s+needs: \[changes, tests, build, installer, ui-smoke, ui-assignments, ui-capture, ui-regression\]',
    '(?s)  ui-ux-review:\s+name: ui-ux-review\s+needs: \[changes, tests, build, installer, ui-smoke, ui-assignments, ui-capture, ui-regression, ui-publish\]',
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
if ($installerJob -notmatch 'needs: \[changes, tests, build\]' -or
    $publishJob -notmatch 'needs: \[changes, tests, build, installer, ui-smoke, ui-assignments, ui-capture, ui-regression\]') {
    throw "Tested downloads and screenshot publication must still wait for passing core tests."
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
    if ($publishJob -notmatch ("(?s)name: " + [regex]::Escape($step) + "\s+(?:id: [^\r\n]+\s+)?if: needs.ui-smoke.result == 'success' && needs.ui-assignments.result == 'success' && needs.ui-capture.result == 'success' && needs.installer.result == 'success' && needs.ui-regression.result == 'success'")) {
        throw "Screenshot publication must wait for successful UI and installer checks: $step"
    }
}
    foreach ($pattern in @(
        'needs: \[changes, build\]',
        'runs-on: windows-2025',
        'timeout-minutes: 35',
        'fail-fast: false',
        'suite: \[sidebar-presentation, sidebar-scan-flows, sidebar-scan-presentation, sidebar-preferences-scheduling, devices-presentation, devices-filters-previews, devices-columns-sorting, details-summary, details-identity, details-observations, details-activity, tools-utilities, tools-device-data\]',
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

    $runnerFixture = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-regression-runner-$([Guid]::NewGuid())"
    $runnerSaved = @{}
    try {
        foreach ($name in @("UI_REGRESSION_CALLS", "UI_REGRESSION_FAIL", "GITHUB_STEP_SUMMARY", "REGRESSION_SUITE", "RETRY_PASSED")) {
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
            "UsageCategory.Ui", "DeviceActivity.Ui", "NetworkActivity.Ui", "EquipmentActivity.Ui",
            "BuildIdentity.Ui", "NetworkTroubleshooting.Ui", "FingImport.Ui", "ReleaseUpdates.Ui", "DatabaseBackups.Ui", "AdditionalServices.Ui", "SqlEditor.Ui")) {
            @(
                'param($AppPath, $ScreenshotDirectory, $Version, $BuildKind, $BuildTimestamp, $BuildCommit, $PullRequestNumber, $SummaryOnly, $ObservationsOnly, $Group)',
                '$name = [IO.Path]::GetFileName($PSCommandPath).Replace(".Tests.ps1", "")',
                'if ($name -eq "NetworkTroubleshooting.Ui") {',
                '    $settings = [Windows.UI.ViewManagement.UISettings, Windows.UI.ViewManagement, ContentType = WindowsRuntime]::new()',
                '    if ($settings.TextScaleFactor -le 0) { throw "Expected a readable effective Windows text scale." }',
                '    if ($env:UI_REGRESSION_FAIL -eq $name) { Write-Output "Troubleshooting child stdout before failure." }',
                '}',
                '@{ Name = $name; Parameters = $PSBoundParameters; ProcessId = $PID; HostEdition = $PSVersionTable.PSEdition; Apartment = [Threading.Thread]::CurrentThread.ApartmentState.ToString() } | ConvertTo-Json -Compress | Add-Content $env:UI_REGRESSION_CALLS',
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
            AppPath = "synthetic app.exe"; ScreenshotDirectory = (Join-Path $runnerFixture "diagnostics with spaces")
            CapturePlanPath = $planPath; Version = "0.0.123"; BuildKind = "PullRequest"
            BuildTimestamp = "2026-11-06T09:00:00Z"; BuildCommit = "test-commit"; PullRequestNumber = 198
        }
        $matrixSuites = @([regex]::Match($regressionJob, 'suite: \[([^\]]+)\]').Groups[1].Value.Split(",") | ForEach-Object { $_.Trim() })
        $expectedSuiteChecks = [ordered]@{
            "sidebar-presentation" = @("SidebarNavigation")
            "sidebar-scan-flows" = @("SidebarNavigation")
            "sidebar-scan-presentation" = @("SidebarNavigation")
            "sidebar-preferences-scheduling" = @("SidebarNavigation")
            "devices-presentation" = @("DevicesList.Ui")
            "devices-filters-previews" = @("DevicesList.Ui")
            "devices-columns-sorting" = @("DevicesList.Ui")
            "details-summary" = @("DeviceScanHistory.Ui")
            "details-identity" = @("DeviceDiscovery.Ui", "UsageCategory.Ui")
            "details-observations" = @("DeviceScanHistory.Ui")
            "details-activity" = @("DeviceActivity.Ui")
            "tools-utilities" = @("BuildIdentity.Ui", "NetworkTroubleshooting.Ui", "FingImport.Ui", "ReleaseUpdates.Ui", "DatabaseBackups.Ui")
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
        Assert-Equal $calls.Name @("SidebarNavigation", "SidebarNavigation", "SidebarNavigation", "SidebarNavigation", "DevicesList.Ui", "DevicesList.Ui", "DevicesList.Ui", "DeviceScanHistory.Ui", "DeviceDiscovery.Ui",
            "UsageCategory.Ui", "DeviceScanHistory.Ui", "DeviceActivity.Ui",
            "BuildIdentity.Ui", "NetworkTroubleshooting.Ui", "FingImport.Ui", "ReleaseUpdates.Ui", "DatabaseBackups.Ui", "AdditionalServices.Ui", "SqlEditor.Ui") "Dispatch every preserved suite and focused updates once"
        $deviceGroups = @((Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot "UiRegression\Devices.Groups.psd1")).Groups.Name)
        Assert-Equal @($matrixSuites | Where-Object { $_ -like "devices*" }) @($deviceGroups | ForEach-Object { "devices-$_" }) "CI matrix runs every Devices group once on its own worker"
        Assert-Equal @($calls | Where-Object Name -eq "DevicesList.Ui" | ForEach-Object { $_.Parameters.Group }) $deviceGroups "Devices group jobs dispatch exactly their group"
        foreach ($groupSuite in @("Sidebar", "Tools")) {
            $groups = @((Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot "UiRegression\$groupSuite.Groups.psd1")).Groups.Name)
            Assert-Equal @($matrixSuites | Where-Object { $_ -like "$groupSuite-*" }) @($groups | ForEach-Object { "$($groupSuite.ToLowerInvariant())-$_" }) "CI dispatches every $groupSuite group exactly once, never the full suite"
        }
        Assert-Equal @($calls | Where-Object Name -eq "SidebarNavigation" | ForEach-Object { $_.Parameters.Group }) @("presentation", "scan-flows", "scan-presentation", "preferences-scheduling") "Sidebar forwards each independent group"
        Assert-Equal $calls[7].Parameters.SummaryOnly $true "Details summary dispatch tests only retained summaries"
        Assert-Equal $calls[10].Parameters.ObservationsOnly $true "Details history dispatch includes full observation rendering and paging"
        Assert-Equal ([DateTimeOffset]$calls[12].Parameters.BuildTimestamp).UtcDateTime ([DateTimeOffset]$parameters.BuildTimestamp).UtcDateTime "Forward stamped identity"
        Assert-Equal $calls[12].Parameters.PullRequestNumber 198 "Forward PR identity"
        Assert-Equal ($calls.Parameters.AppPath | Select-Object -Unique) $parameters.AppPath "Reuse supplied app, including spaces"
        $troubleshootingCall = @($calls | Where-Object Name -eq "NetworkTroubleshooting.Ui")[0]
        Assert-Equal $troubleshootingCall.HostEdition "Desktop" "Troubleshooting resolves WinRT in Windows PowerShell"
        Assert-Equal $troubleshootingCall.Apartment "STA" "Troubleshooting retains the desktop automation apartment"
        Assert-Equal $troubleshootingCall.Parameters.ScreenshotDirectory (Join-Path $parameters.ScreenshotDirectory "troubleshooting") "Forward the troubleshooting capture path, including spaces"
        & powershell.exe -NoProfile -File $runner -Suite sidebar -AppPath $parameters.AppPath `
            -ScreenshotDirectory $parameters.ScreenshotDirectory -CapturePlanPath $planPath
        if ($LASTEXITCODE -ne 0) { throw "Sidebar runner must support multi-scenario plans under Windows PowerShell." }
        Assert-Equal @(Get-Content $env:UI_REGRESSION_CALLS).Count 20 "Windows PowerShell dispatches the sidebar without parsing details selection"
        ConvertTo-Json -InputObject @($definitions | Where-Object Scenario -eq Devices) -Depth 5 | Set-Content $planPath
        foreach ($suite in @("details-summary", "details-identity", "details-observations", "details-activity")) {
            & $runner -Suite $suite @parameters
            Assert-Equal @(Get-Content $env:UI_REGRESSION_CALLS).Count 20 "Unselected $suite must not launch native checks"
        }
        ConvertTo-Json -InputObject @(Get-UiReviewCapturePlan -RepositoryPath $runnerFixture -AdditionalScenarios Network) -Depth 5 | Set-Content $planPath
        foreach ($suite in @("details-summary", "details-observations", "details-activity")) {
            & $runner -Suite $suite @parameters
            Assert-Equal @(Get-Content $env:UI_REGRESSION_CALLS).Count 20 "Network-only plan adds no checks to $suite"
        }
        & $runner -Suite details-identity @parameters
        $networkCalls = @(Get-Content $env:UI_REGRESSION_CALLS | Select-Object -Skip 20 | ConvertFrom-Json)
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
        # Shared contracts must select plans that run their consumers' native checks, not Devices-only no-op details jobs.
        $selectionRepository = Join-Path $runnerFixture "shared-contract-selection"
        $null = New-Item -ItemType Directory -Path $selectionRepository -Force
        $sharedPaths = @("src/FingVibe.App/AsyncSurfaceSession.cs", "src/FingVibe.App/ScanResultRow.cs",
            "src/FingVibe.Core/Storage/DeviceInventoryStore.Analytics.cs")
        foreach ($sharedPath in $sharedPaths) {
            $null = New-Item -ItemType Directory -Path (Split-Path (Join-Path $selectionRepository $sharedPath)) -Force
            Set-Content -LiteralPath (Join-Path $selectionRepository $sharedPath) -Value "baseline"
        }
        $null = Invoke-UiReviewGit $selectionRepository @("init", "--quiet")
        $null = Invoke-UiReviewGit $selectionRepository @("-c", "user.name=test", "-c", "user.email=test@example.invalid", "add", ".")
        $null = Invoke-UiReviewGit $selectionRepository @("-c", "user.name=test", "-c", "user.email=test@example.invalid", "commit", "--quiet", "-m", "Baseline")
        $selectionBase = Invoke-UiReviewGit $selectionRepository @("rev-parse", "HEAD")
        $sharedPlanPath = Join-Path $runnerFixture "shared-contract-plan.json"
        $sharedDetailChecks = [ordered]@{
            "details-summary" = @("DeviceScanHistory.Ui", "EquipmentActivity.Ui")
            "details-identity" = @("DeviceDiscovery.Ui", "UsageCategory.Ui", "NetworkActivity.Ui")
            "details-observations" = @("DeviceScanHistory.Ui")
            "details-activity" = @("DeviceActivity.Ui")
        }
        foreach ($sharedCase in @(@($sharedPaths[0]), @($sharedPaths[1]), @($sharedPaths[2]), $sharedPaths)) {
            $null = Invoke-UiReviewGit $selectionRepository @("checkout", "--quiet", "--detach", $selectionBase)
            foreach ($sharedPath in $sharedCase) { Set-Content -LiteralPath (Join-Path $selectionRepository $sharedPath) -Value "changed" }
            $null = Invoke-UiReviewGit $selectionRepository @("-c", "user.name=test", "-c", "user.email=test@example.invalid", "commit", "--quiet", "-am", "Change")
            $sharedPlan = @(Get-UiReviewCapturePlan -RepositoryPath $selectionRepository -BaseRevision $selectionBase)
            ConvertTo-Json -InputObject $sharedPlan -Depth 5 | Set-Content $sharedPlanPath
            $sharedParameters = $parameters.Clone()
            $sharedParameters.CapturePlanPath = $sharedPlanPath
            foreach ($suite in $sharedDetailChecks.Keys) {
                $before = @(Get-Content $env:UI_REGRESSION_CALLS).Count
                & $runner -Suite $suite @sharedParameters
                $suiteCalls = @(Get-Content $env:UI_REGRESSION_CALLS | Select-Object -Skip $before | ConvertFrom-Json)
                Assert-Equal $suiteCalls.Name $sharedDetailChecks[$suite] "$($sharedCase -join ' + ') dispatches affected checks in $suite"
            }
            if ($sharedCase -contains "src/FingVibe.App/AsyncSurfaceSession.cs") {
                if (@($sharedPlan.Scenario | Where-Object { $_ -in @("Troubleshooting", "DatabaseBackups") }).Count -ne 2) {
                    throw "Asynchronous surface changes must select troubleshooting and backup captures."
                }
                $before = @(Get-Content $env:UI_REGRESSION_CALLS).Count
                & $runner -Suite tools-utilities @sharedParameters
                $toolCalls = @(Get-Content $env:UI_REGRESSION_CALLS | Select-Object -Skip $before | ConvertFrom-Json).Name
                foreach ($check in @("NetworkTroubleshooting.Ui", "DatabaseBackups.Ui")) {
                    if ($check -notin $toolCalls) { throw "Asynchronous surface plan must dispatch $check." }
                }
            }
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
        $toolChecks = @("BuildIdentity.Ui", "NetworkTroubleshooting.Ui", "FingImport.Ui", "ReleaseUpdates.Ui", "DatabaseBackups.Ui", "AdditionalServices.Ui", "SqlEditor.Ui")
        Assert-Equal @(Get-Content $env:UI_REGRESSION_CALLS | Select-Object -Skip $before | ConvertFrom-Json).Name $toolChecks "Default Tools entry point preserves full sequential coverage"
        $env:UI_REGRESSION_FAIL = "NetworkTroubleshooting.Ui"
        $before = @(Get-Content $env:UI_REGRESSION_CALLS).Count
        Assert-Throws { & $runner -Suite tools @parameters } "*Tools groups failed: utilities*troubleshooting*exit code 1*"
        Assert-Equal @(Get-Content $env:UI_REGRESSION_CALLS | Select-Object -Skip $before | ConvertFrom-Json).Name @("BuildIdentity.Ui", "NetworkTroubleshooting.Ui", "AdditionalServices.Ui", "SqlEditor.Ui") "A troubleshooting child failure fails its group without suppressing the independent group"
        $troubleshootingLog = Get-Content (Join-Path $parameters.ScreenshotDirectory "regression.log") -Raw
        if ($troubleshootingLog -notmatch 'Simulated regression failure' -or $troubleshootingLog -notmatch 'NetworkTroubleshooting.Ui') {
            throw "The parent transcript must retain the troubleshooting child failure diagnostics."
        }
        if ($troubleshootingLog -notmatch 'Troubleshooting child stdout before failure\.') {
            throw "The parent transcript must also retain troubleshooting child standard output before failure."
        }
        $troubleshootingFailureNames = @(Get-Content $env:UI_REGRESSION_CALLS | Select-Object -Skip $before | ConvertFrom-Json).Name
        $before = @(Get-Content $env:UI_REGRESSION_CALLS).Count
        & powershell.exe -NoProfile -File $runner -Suite tools -AppPath $parameters.AppPath `
            -ScreenshotDirectory $parameters.ScreenshotDirectory -CapturePlanPath $planPath
        if ($LASTEXITCODE -ne 1) { throw "A Windows PowerShell parent must propagate the troubleshooting child failure." }
        Assert-Equal @(Get-Content $env:UI_REGRESSION_CALLS | Select-Object -Skip $before | ConvertFrom-Json).Name $troubleshootingFailureNames "Windows PowerShell preserves troubleshooting failure and independent group dispatch"
        $troubleshootingLog = Get-Content (Join-Path $parameters.ScreenshotDirectory "regression.log") -Raw
        if ($troubleshootingLog -notmatch 'Simulated regression failure' -or
            $troubleshootingLog -notmatch 'Troubleshooting child stdout before failure\.' -or
            $troubleshootingLog -notmatch 'Windows PowerShell \(exit code 1\)') {
            throw "A Windows PowerShell parent must drain both child streams before enforcing the exit code."
        }
        $env:UI_REGRESSION_FAIL = "DatabaseBackups.Ui"
        $before = @(Get-Content $env:UI_REGRESSION_CALLS).Count
        Assert-Throws { & $runner -Suite tools @parameters } "*Tools groups failed: utilities*Simulated regression failure: DatabaseBackups.Ui*"
        Assert-Equal @(Get-Content $env:UI_REGRESSION_CALLS | Select-Object -Skip $before | ConvertFrom-Json).Name $toolChecks "A backup failure is retained while the independent device-data group still runs"
        $env:UI_REGRESSION_FAIL = "ReleaseUpdates.Ui"
        $before = @(Get-Content $env:UI_REGRESSION_CALLS).Count
        Assert-Throws { & $runner -Suite tools @parameters } "*Tools groups failed: utilities*Simulated regression failure: ReleaseUpdates.Ui*"
        Assert-Equal @(Get-Content $env:UI_REGRESSION_CALLS | Select-Object -Skip $before | ConvertFrom-Json).Name `
            @("BuildIdentity.Ui", "NetworkTroubleshooting.Ui", "FingImport.Ui", "ReleaseUpdates.Ui", "AdditionalServices.Ui", "SqlEditor.Ui") `
            "Update failure is retained, stops later utility checks and still runs independent device data"
        $env:UI_REGRESSION_FAIL = "BuildIdentity.Ui"
        $before = @(Get-Content $env:UI_REGRESSION_CALLS).Count
        Assert-Throws { & $runner -Suite tools @parameters } "*Tools groups failed: utilities*Simulated regression failure*"
        Assert-Equal @(Get-Content $env:UI_REGRESSION_CALLS | Select-Object -Skip $before | ConvertFrom-Json).Name @("BuildIdentity.Ui", "AdditionalServices.Ui", "SqlEditor.Ui") "An independent Tools group must still run after another group fails"
        $reportScript = & $readRegressionStep "Report regression retry outcome"
        $reportPath = Join-Path $runnerFixture "report.ps1"
        Set-Content -LiteralPath $reportPath -Value ('$ErrorActionPreference = "Stop"' + "`n" + $reportScript)
        foreach ($hostCase in @(
            @{ Suite = "devices-filters-previews"; HostExe = "pwsh.exe"; Edition = "Core"; Check = "DevicesList.Ui"
                First = "Run native regression suite"; Retry = "Retry failed native regression suite once" },
            @{ Suite = "sidebar-presentation"; HostExe = "powershell.exe"; Edition = "Desktop"; Check = "SidebarNavigation"
                First = "Run sidebar regression in Windows PowerShell"; Retry = "Retry failed sidebar regression once in Windows PowerShell" }
        )) {
            foreach ($outcome in @("pass", "flaky", "fail")) {
                $caseRoot = Join-Path $runnerFixture "$($hostCase.Suite)-$outcome"
                $null = New-Item -ItemType Directory -Path $caseRoot -Force
                $env:UI_REGRESSION_CALLS = Join-Path $caseRoot "calls.jsonl"
                $env:GITHUB_STEP_SUMMARY = Join-Path $caseRoot "summary.txt"
                Copy-Item $planPath (Join-Path $caseRoot "capture-plan.json")
                $env:REGRESSION_SUITE = $hostCase.Suite
                $exitCodes = @()
                Push-Location $runnerFixture
                try {
                    foreach ($attempt in @(1, 2)) {
                        if ($attempt -eq 2 -and $exitCodes[0] -eq 0) { break }
                        $env:UI_REGRESSION_FAIL = if ($outcome -eq "fail" -or ($outcome -eq "flaky" -and $attempt -eq 1)) { $hostCase.Check } else { $null }
                        $stepName = if ($attempt -eq 1) { $hostCase.First } else { $hostCase.Retry }
                        $script = (& $readRegressionStep $stepName).
                            Replace('${{ matrix.suite }}', $hostCase.Suite).
                            Replace('${{ github.workspace }}\artifacts\ui-regression', $caseRoot).
                            Replace('${{ github.workspace }}', $runnerFixture).
                            Replace('${{ github.run_number }}', "123").
                            Replace('${{ github.event_name == ''pull_request'' && ''PullRequest'' || ''Test'' }}', "PullRequest").
                            Replace('${{ needs.build.outputs.build-timestamp }}', $parameters.BuildTimestamp).
                            Replace('${{ github.sha }}', "test-commit").
                            Replace('${{ github.event.pull_request.number || 0 }}', "198")
                        $stepPath = Join-Path $caseRoot "step-$attempt.ps1"
                        Set-Content -LiteralPath $stepPath -Value ('$ErrorActionPreference = "Stop"' + "`n" + $script)
                        & $hostCase.HostExe -NoProfile -File $stepPath *> (Join-Path $caseRoot "step-$attempt.log")
                        $exitCodes += $LASTEXITCODE
                    }
                } finally { Pop-Location }
                $expectedCodes = switch ($outcome) { "pass" { @(0) }; "flaky" { @(1, 0) }; "fail" { @(1, 1) } }
                Assert-Equal $exitCodes $expectedCodes "Pipeline $($hostCase.Suite) $outcome outcomes"
                $attemptCalls = @(Get-Content $env:UI_REGRESSION_CALLS | ConvertFrom-Json)
                Assert-Equal $attemptCalls.Count $expectedCodes.Count "Only failed suites rerun once"
                Assert-Equal @($attemptCalls.ProcessId | Select-Object -Unique).Count $expectedCodes.Count "Each attempt uses a fresh process"
                Assert-Equal @($attemptCalls.HostEdition | Select-Object -Unique) $hostCase.Edition "Retry preserves the required PowerShell host"
                $group = $hostCase.Suite.Substring($hostCase.Suite.IndexOf("-") + 1)
                Assert-Equal @($attemptCalls.Parameters.Group | Select-Object -Unique) $group "Only the selected matrix group runs"
                foreach ($attempt in 1..$expectedCodes.Count) {
                    $directory = Join-Path $caseRoot "attempt-$attempt"
                    $transcript = Get-Content (Join-Path $directory "regression.log") -Raw
                    Assert-Equal $attemptCalls[$attempt - 1].Parameters.ScreenshotDirectory (Join-Path $directory $(if ($hostCase.Edition -eq "Desktop") { "sidebar" } else { "devices" })) "Separate diagnostics per attempt"
                    if ($expectedCodes[$attempt - 1] -ne 0 -and $transcript -notmatch 'Simulated regression failure') {
                        throw "Failed attempt diagnostics must survive the retry."
                    }
                }
                if ($outcome -eq "pass") {
                    if (Test-Path (Join-Path $caseRoot "attempt-2")) { throw "Successful suites must not retry." }
                    continue
                }
                $env:RETRY_PASSED = ($outcome -eq "flaky").ToString().ToLowerInvariant()
                $reportLog = Join-Path $caseRoot "report.log"
                & pwsh.exe -NoProfile -File $reportPath *> $reportLog
                Assert-Equal $LASTEXITCODE $(if ($outcome -eq "flaky") { 0 } else { 1 }) "Reporting cannot turn a second failure green"
                if ($outcome -eq "flaky" -and
                    ((Get-Content $reportLog -Raw) -notmatch '::warning::Flaky UI regression' -or
                    (Get-Content $env:GITHUB_STEP_SUMMARY -Raw) -notmatch 'passed only on retry')) {
                    throw "Retry-passes must visibly report flakiness."
                }
            }
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

foreach ($wrapper in @(
    @{ Step = "Exercise primary UI interactions"; Upload = "Upload UI smoke diagnostics"; Part = "Smoke"
        Directory = "artifacts\ui-smoke"; Log = "smoke-test.log"; Precreated = $false }
    @{ Step = "Exercise People and Rooms names and assignments"; Upload = "Upload UI assignment diagnostics"; Part = "Assignments"
        Directory = "artifacts\ui-assignments"; Log = "assignments.log"; Precreated = $false }
    @{ Step = "Capture required views"; Upload = "Upload UI review captures"; Part = "Capture"
        Directory = "artifacts\ui-review"; Log = "capture.log"; Precreated = $true }
)) {
    $smokeMatch = [regex]::Match($workflow, '(?s)- name: ' + [regex]::Escape($wrapper.Step) + '.*?run: \|\r?\n(.*?)\r?\n      - name: ' + [regex]::Escape($wrapper.Upload))
    if (-not $smokeMatch.Success) { throw "UI $($wrapper.Part) wrapper was not found." }
    $smoke = [scriptblock]::Create(($smokeMatch.Groups[1].Value -replace '(?m)^          ', '' -replace '\$\{\{ github.workspace \}\}', '$env:GITHUB_WORKSPACE'))
    $fixture = Join-Path ([System.IO.Path]::GetTempPath()) "fingvibe-smoke-failure-$([Guid]::NewGuid())"
    $savedWorkspace = $env:GITHUB_WORKSPACE
    try {
        $null = New-Item -ItemType Directory -Path (Join-Path $fixture ".github\scripts") -Force
        # Capture's plan step creates its directory first; smoke must create its own.
        if ($wrapper.Precreated) { $null = New-Item -ItemType Directory -Path (Join-Path $fixture $wrapper.Directory) -Force }
        @'
param($Part, $AppPath, $ScreenshotDirectory, $CapturePlanPath)
"partial screenshot" | Set-Content (Join-Path $ScreenshotDirectory "partial.png")
"driver failure details" | Set-Content (Join-Path $ScreenshotDirectory "driver.log")
throw "Simulated native $Part failure"
'@ | Set-Content (Join-Path $fixture ".github\scripts\Invoke-UiReview.ps1")
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
$names = @("CHANGES_RESULT", "TEST_RESULT", "BUILD_RESULT", "INSTALLER_RESULT", "TEST_REQUIRED", "BUILD_REQUIRED", "UI_REQUIRED", "SMOKE_RESULT", "ASSIGNMENTS_RESULT", "CAPTURE_RESULT", "REGRESSION_RESULT", "PUBLISH_RESULT", "TRUSTED", "EVENT_NAME", "GITHUB_STEP_SUMMARY")
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
if ($workflow -match '(?ms)^  pull_request:\s*\r?\n\s+types:' -or $workflow -match '(?m)^\s*pull_request_target:') {
    throw "Promotion must keep the default pull_request triggers; no title-edit or ready_for_review trigger."
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
& (Join-Path $PSScriptRoot "NativeValidation.Tests.ps1")
Write-Host "PR validation planning, comment history, and required-check regression tests passed."
