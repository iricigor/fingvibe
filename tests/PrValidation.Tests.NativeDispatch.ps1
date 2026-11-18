# Native regression dispatch fixtures: suite selection, retries and runner orchestration.
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
        $definitions = @(Get-UiReviewCapturePlan -RepositoryPath $runnerFixture -AdditionalScenarios DeviceDetails, Network)
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
            "network-activity" = @("NetworkActivity.Ui")
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
            "UsageCategory.Ui", "DeviceScanHistory.Ui", "DeviceActivity.Ui", "NetworkActivity.Ui",
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
        Assert-Equal ([DateTimeOffset]$calls[13].Parameters.BuildTimestamp).UtcDateTime ([DateTimeOffset]$parameters.BuildTimestamp).UtcDateTime "Forward stamped identity"
        Assert-Equal $calls[13].Parameters.PullRequestNumber 198 "Forward PR identity"
        Assert-Equal ($calls.Parameters.AppPath | Select-Object -Unique) $parameters.AppPath "Reuse supplied app, including spaces"
        $troubleshootingCall = @($calls | Where-Object Name -eq "NetworkTroubleshooting.Ui")[0]
        Assert-Equal $troubleshootingCall.HostEdition "Desktop" "Troubleshooting resolves WinRT in Windows PowerShell"
        Assert-Equal $troubleshootingCall.Apartment "STA" "Troubleshooting retains the desktop automation apartment"
        Assert-Equal $troubleshootingCall.Parameters.ScreenshotDirectory (Join-Path $parameters.ScreenshotDirectory "troubleshooting") "Forward the troubleshooting capture path, including spaces"
        & powershell.exe -NoProfile -File $runner -Suite sidebar -AppPath $parameters.AppPath `
            -ScreenshotDirectory $parameters.ScreenshotDirectory -CapturePlanPath $planPath
        if ($LASTEXITCODE -ne 0) { throw "Sidebar runner must support multi-scenario plans under Windows PowerShell." }
        Assert-Equal @(Get-Content $env:UI_REGRESSION_CALLS).Count 21 "Windows PowerShell dispatches the sidebar without parsing details selection"
        ConvertTo-Json -InputObject @($definitions | Where-Object Scenario -eq Devices) -Depth 5 | Set-Content $planPath
        foreach ($suite in @("details-summary", "details-identity", "details-observations", "details-activity", "network-activity")) {
            & $runner -Suite $suite @parameters
            Assert-Equal @(Get-Content $env:UI_REGRESSION_CALLS).Count 21 "Unselected $suite must not launch native checks"
        }
        ConvertTo-Json -InputObject @(Get-UiReviewCapturePlan -RepositoryPath $runnerFixture -AdditionalScenarios Network) -Depth 5 | Set-Content $planPath
        foreach ($suite in @("details-summary", "details-identity", "details-observations", "details-activity")) {
            & $runner -Suite $suite @parameters
            Assert-Equal @(Get-Content $env:UI_REGRESSION_CALLS).Count 21 "Network-only plan adds no checks to $suite"
        }
        & $runner -Suite network-activity @parameters
        $networkCalls = @(Get-Content $env:UI_REGRESSION_CALLS | Select-Object -Skip 21 | ConvertFrom-Json)
        Assert-Equal $networkCalls.Name @("NetworkActivity.Ui") "Network-only plan still runs its activity regression"
        ConvertTo-Json -InputObject @(Get-UiReviewCapturePlan -RepositoryPath $runnerFixture -AdditionalScenarios DeviceDetails) -Depth 5 |
            Set-Content $planPath
        $before = @(Get-Content $env:UI_REGRESSION_CALLS).Count
        & $runner -Suite network-activity @parameters
        Assert-Equal @(Get-Content $env:UI_REGRESSION_CALLS).Count $before "Device-Details-only plans do not launch Network Activity"
        ConvertTo-Json -InputObject @(Get-UiReviewCapturePlan -RepositoryPath $runnerFixture -AdditionalScenarios DeviceDetails, Network) -Depth 5 |
            Set-Content $planPath
        foreach ($suite in @("details-summary", "details-identity", "details-observations", "details-activity", "network-activity")) {
            $before = @(Get-Content $env:UI_REGRESSION_CALLS).Count
            & $runner -Suite $suite @parameters
            $suiteCalls = @(Get-Content $env:UI_REGRESSION_CALLS | Select-Object -Skip $before | ConvertFrom-Json)
            Assert-Equal $suiteCalls.Name $expectedSuiteChecks[$suite] "Combined plan runs Network Activity once, in its independent suite"
        }
        ConvertTo-Json -InputObject @(Get-UiReviewCapturePlan -RepositoryPath $runnerFixture -AdditionalScenarios DeviceHistory, Network) -Depth 5 |
            Set-Content $planPath
        foreach ($suite in @("details-summary", "details-identity", "details-observations", "details-activity", "network-activity")) {
            $before = @(Get-Content $env:UI_REGRESSION_CALLS).Count
            & $runner -Suite $suite @parameters
            $suiteCalls = @(Get-Content $env:UI_REGRESSION_CALLS | Select-Object -Skip $before | ConvertFrom-Json)
            Assert-Equal $suiteCalls.Name $expectedSuiteChecks[$suite] "History-tab plan preserves split suites and Network Activity coverage"
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
            "details-identity" = @("DeviceDiscovery.Ui", "UsageCategory.Ui")
            "details-observations" = @("DeviceScanHistory.Ui")
            "details-activity" = @("DeviceActivity.Ui")
            "network-activity" = @("NetworkActivity.Ui")
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
        $env:UI_REGRESSION_FAIL = "NetworkActivity.Ui"
        Assert-Throws { & $runner -Suite network-activity @parameters } "*Simulated regression failure: NetworkActivity.Ui*"
        if ((Get-Content $env:GITHUB_STEP_SUMMARY -Raw) -notmatch 'network-activity / NetworkActivity.Ui elapsed:') {
            throw "Independent Network Activity must preserve failure propagation and timing diagnostics."
        }
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
