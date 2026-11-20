# Validation planning: path classification, allow-list verification and the native test closure.
foreach ($case in @(
    @{ Paths = @("README.md", "docs/speed-test.md", "CONTRIBUTING.md"); Expected = @($false, $false, $false) },
    @{ Paths = @("tests/FingVibe.Core.Tests/ScannerTests.cs"); Expected = @($true, $false, $false) },
    @{ Paths = @("tests/UiReviewScenarios.Tests.ps1"); Expected = @($true, $false, $false) },
    @{ Paths = @("tests/UiReviewScreenshot.Tests.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/NetworkHealth.Ui.Tests.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/FingImport.Ui.Tests.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/SqlEditor.Ui.Tests.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/ReleaseUpdates.Ui.Tests.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/UiRegression/Tools.Updates.Scenario.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/DeviceScanHistory.Ui.Tests.ps1"); Expected = @($true, $true, $true) },
    # Modules dot-sourced by a native UI entry remain native; modules of core test entries remain tests-only.
    @{ Paths = @("tests/DeviceScanHistory.Ui.Tests.Summary.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/DeviceScanHistory.Ui.Tests.PagingPhase.ps1"); Expected = @($true, $true, $true) },
    @{ Paths = @("tests/PrValidation.Tests.Planning.ps1", "tests/UiReviewScenarios.Tests.Navigation.ps1",
        "tests/UiRegression.Helpers.Tests.DevicesFilters.ps1"); Expected = @($true, $false, $false) },
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
foreach ($required in @("NetworkHealth.Ui.Tests.ps1", "Inventory.Sqlite.Helpers.ps1", "UiReviewScreenshot.Tests.ps1")) {
    if (-not $nativeFiles.Contains($required)) { throw "Native closure must include '$required'." }
}
