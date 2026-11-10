[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $OutputDirectory,
    [Parameter(Mandatory)][string] $BackendBuildDirectory,
    [Parameter(Mandatory)][switch] $AllowDesktopInput,
    [ValidateSet('baseline', 'flaui')][string[]] $Backends = @('baseline', 'flaui'),
    [string[]] $Cases = @(),
    [string] $WinAppDriverPath = "${env:ProgramFiles(x86)}\Windows Application Driver\WinAppDriver.exe",
    [string] $SourceRevision = '6fd07fd04ffc7a3e919eaa7916f2487f2b59a870'
)

$ErrorActionPreference = 'Stop'
if (-not $AllowDesktopInput) { throw 'Explicit permission for desktop input and temporary system high contrast is required.' }
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Use a new full-comparison output directory.' }
$repository = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$AppPath = (Resolve-Path -LiteralPath $AppPath).Path
$BackendBuildDirectory = (Resolve-Path -LiteralPath $BackendBuildDirectory).Path
$consent = [Guid]::NewGuid().ToString('N')
$null = New-Item -ItemType Directory -Path $OutputDirectory
. (Join-Path $PSScriptRoot 'Desktop.ps1')
Assert-ComparisonDesktop
$originalContrast = [FullComparisonDesktop]::GetContrast()
$originalForeground = [FullComparisonDesktop]::GetForegroundWindow()
$originalClipboard = $null
$clipboardSaved = $false
$originalPointer = [FullComparisonDesktop+Point]::new()
if (-not [FullComparisonDesktop]::GetCursorPos([ref] $originalPointer)) { throw 'Cannot save the original pointer.' }
$sources = @{}
foreach ($backend in $Backends) {
    $sources[$backend] = Join-Path $OutputDirectory "source-$backend"
    & (Join-Path $PSScriptRoot 'Prepare-Suite.ps1') -Repository $repository -Destination $sources[$backend] `
        -Backend $backend -ConsentToken $consent -SourceRevision $SourceRevision
}
$assembly = [Reflection.Assembly]::LoadFrom((Join-Path (Split-Path $AppPath) 'FingVibe.App.dll'))
$identity = @{}
foreach ($attribute in $assembly.GetCustomAttributesData()) {
    if ($attribute.AttributeType.FullName -eq 'System.Reflection.AssemblyMetadataAttribute') {
        $identity[$attribute.ConstructorArguments[0].Value] = $attribute.ConstructorArguments[1].Value
    }
}
$catalog = @(
    @{ id = 'sidebar'; entry = 'tests\SidebarNavigation.Tests.ps1'; legacy = $true },
    @{ id = 'devices'; entry = 'tests\DevicesList.Ui.Tests.ps1' },
    @{ id = 'details-summary'; entry = 'tests\DeviceScanHistory.Ui.Tests.ps1'; flags = @{ SummaryOnly = $true } },
    @{ id = 'discovery'; entry = 'tests\DeviceDiscovery.Ui.Tests.ps1' },
    @{ id = 'usage-category'; entry = 'tests\UsageCategory.Ui.Tests.ps1' },
    @{ id = 'details-history'; entry = 'tests\DeviceScanHistory.Ui.Tests.ps1'; flags = @{ ObservationsOnly = $true } },
    @{ id = 'activity'; entry = 'tests\DeviceActivity.Ui.Tests.ps1' },
    @{ id = 'build-identity'; entry = 'tests\BuildIdentity.Ui.Tests.ps1'; flags = @{
        Version = $assembly.GetName().Version.ToString(3); BuildKind = $identity.BuildKind
        BuildTimestamp = $identity.BuildTimestamp
    } },
    @{ id = 'troubleshooting'; entry = 'tests\NetworkTroubleshooting.Ui.Tests.ps1' },
    @{ id = 'fing-import'; entry = 'tests\FingImport.Ui.Tests.ps1' },
    @{ id = 'additional-services'; entry = 'tests\AdditionalServices.Ui.Tests.ps1' },
    @{ id = 'sql-editor'; entry = 'tests\SqlEditor.Ui.Tests.ps1' },
    @{ id = 'screenshot-contract'; entry = 'tests\UiReviewScreenshot.Tests.ps1'; noAppParameters = $true },
    @{ id = 'capture'; entry = '.github\scripts\Invoke-UiReview.ps1'; flags = @{ Mode = 'Full' } }
)
foreach ($case in $Cases) {
    if ($case -notin $catalog.id) { throw "Unknown case '$case'." }
}
if ($Cases.Count) { $catalog = @($catalog | Where-Object { $_.id -in $Cases }) }
@{
    sourceRevision = $SourceRevision; backends = $Backends
    cases = @($catalog | ForEach-Object { @{ id = $_.id; entry = $_.entry; legacy = [bool]$_.legacy } })
    appAssemblySha256 = (Get-FileHash (Join-Path (Split-Path $AppPath) 'FingVibe.App.dll') -Algorithm SHA256).Hash
    fullCatalog = ($Cases.Count -eq 0)
    startedUtc = [DateTime]::UtcNow.ToString('o'); contrastBefore = $originalContrast
    workArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.ToString()
} | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $OutputDirectory 'manifest.json') -Encoding utf8
$results = [Collections.Generic.List[object]]::new()
$worker = $null
$index = 0
try {
    foreach ($case in $catalog) {
        $index++
        $order = if ($index % 2 -eq 0) { @($Backends | Sort-Object -Descending) } else { $Backends }
        foreach ($backend in $order) {
            Assert-ComparisonDesktop
            $caseDirectory = Join-Path $OutputDirectory "$($case.id)-$backend"
            $null = New-Item -ItemType Directory -Path $caseDirectory
            $parameters = @{}
            if (-not $case.noAppParameters) {
                $parameters.AppPath = $AppPath
                $parameters.ScreenshotDirectory = $caseDirectory
            }
            if ($case.flags) { foreach ($key in $case.flags.Keys) { $parameters[$key] = $case.flags[$key] } }
            $framework = if ($case.legacy) { 'net48' } else { 'net8.0-windows' }
            $backendDirectory = Join-Path $BackendBuildDirectory $framework
            if ($backend -eq 'flaui' -and -not (Test-Path (Join-Path $backendDirectory 'UiAutomationComparison.Backend.dll'))) {
                throw "Missing $framework FlaUI backend build."
            }
            if ($case.id -eq 'capture') {
                $parameters.SourceDirectory = $sources[$backend]
                $parameters.WinAppDriverPath = if ($backend -eq 'baseline') { $WinAppDriverPath }
                    else { Join-Path $backendDirectory 'UiAutomationComparison.Backend.dll' }
            }
            $configuration = Join-Path $caseDirectory 'configuration.json'
            @{
                case = $case.id; backend = $backend; entryPoint = $case.entry
                source = $sources[$backend]; output = $caseDirectory; parameters = $parameters
                consentToken = $consent; appPath = $AppPath; backendDirectory = $backendDirectory
            } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $configuration -Encoding utf8
            $shell = if ($case.legacy) { (Get-Command powershell.exe).Source } else { (Get-Command pwsh.exe).Source }
            $arguments = @('-NoProfile', '-NonInteractive', '-STA', '-File', ('"{0}"' -f (Join-Path $PSScriptRoot 'Invoke-SuiteCase.ps1')),
                '-Configuration', ('"{0}"' -f $configuration), '-AllowDesktopInput')
            Write-Host "Starting full comparison case: $($case.id) / $backend ($framework)"
            $caseClock = [Diagnostics.Stopwatch]::StartNew()
            if ($case.id -eq 'additional-services') {
                try {
                    $originalClipboard = Save-ComparisonClipboard
                    $clipboardSaved = $true
                }
                catch {
                    $result = [pscustomobject]@{
                        case = $case.id; backend = $backend; success = $false; stage = 'clipboard-precondition'
                        error = "Cannot preserve the desktop clipboard; copy-button tests were not run: $($_.Exception)"
                        seconds = $caseClock.Elapsed.TotalSeconds; timedOut = $false; workerExitCode = $null
                        parentCleanupApps = @()
                    }
                    $result | ConvertTo-Json -Depth 7 | Set-Content (Join-Path $caseDirectory 'result.json') -Encoding utf8
                    $results.Add($result)
                    $results | ConvertTo-Json -Depth 7 | Set-Content (Join-Path $OutputDirectory 'results.json') -Encoding utf8
                    Write-Warning $result.error
                    continue
                }
            }
            $caseStarted = [DateTime]::UtcNow
            $worker = Start-Process -FilePath $shell -ArgumentList $arguments -PassThru -WindowStyle Hidden `
                -RedirectStandardOutput (Join-Path $caseDirectory 'stdout.log') `
                -RedirectStandardError (Join-Path $caseDirectory 'stderr.log')
            $timedOut = -not $worker.WaitForExit(900000)
            if ($timedOut) {
                Stop-Process -Id $worker.Id -Force
                $null = $worker.WaitForExit(5000)
            }
            $resultPath = Join-Path $caseDirectory 'result.json'
            $result = if (Test-Path -LiteralPath $resultPath) {
                Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            } else {
                [pscustomobject]@{ case = $case.id; backend = $backend; success = $false
                    stage = 'worker'; error = 'Worker did not publish a result; inspect stdout/stderr.'
                    seconds = $caseClock.Elapsed.TotalSeconds }
            }
            if ($timedOut -or $worker.ExitCode -ne 0) { $result.success = $false }
            $leftovers = @(Get-Process -Name FingVibe.App -ErrorAction SilentlyContinue | Where-Object {
                $_.Path -eq $AppPath -and $_.StartTime.ToUniversalTime() -ge $caseStarted.AddSeconds(-1)
            })
            foreach ($app in $leftovers) {
                $result.success = $false
                Write-Warning "Case left owned app PID $($app.Id); performing parent-level cleanup."
                $null = $app.CloseMainWindow()
                if (-not $app.WaitForExit(5000)) { Stop-Process -Id $app.Id -Force; $null = $app.WaitForExit(5000) }
                if (-not $app.HasExited) { throw "Owned app PID $($app.Id) could not be stopped." }
            }
            $driverChildren = @(Get-CimInstance Win32_Process -Filter "ParentProcessId = $($worker.Id)" |
                Where-Object { $_.Name -eq 'WinAppDriver.exe' -and $_.ExecutablePath -eq $WinAppDriverPath })
            foreach ($driver in $driverChildren) {
                $result.success = $false
                Stop-Process -Id $driver.ProcessId -Force
                Write-Warning "Case left owned driver PID $($driver.ProcessId); it was stopped."
            }
            $result | Add-Member NoteProperty timedOut $timedOut
            $result | Add-Member NoteProperty workerExitCode $worker.ExitCode
            $result | Add-Member NoteProperty parentCleanupApps @($leftovers | ForEach-Object { $_.Id })
            $results.Add($result)
            $results | ConvertTo-Json -Depth 7 | Set-Content (Join-Path $OutputDirectory 'results.json') -Encoding utf8
            Write-Host "Finished $($case.id) / ${backend}: success=$($result.success), $([Math]::Round($result.seconds, 1)) s"
            $worker = $null
            if ($clipboardSaved) { Restore-ComparisonClipboard $originalClipboard; $clipboardSaved = $false }
            if ([FullComparisonDesktop]::GetContrast() -ne $originalContrast) {
                [FullComparisonDesktop]::SetContrast($originalContrast)
                throw 'A case did not restore system contrast; remaining execution was stopped.'
            }
        }
    }
}
finally {
    if ($worker -and -not $worker.HasExited) { Stop-Process -Id $worker.Id -Force }
    if ([FullComparisonDesktop]::GetContrast() -ne $originalContrast) { [FullComparisonDesktop]::SetContrast($originalContrast) }
    if ([FullComparisonDesktop]::GetContrast() -ne $originalContrast) { throw 'Original contrast could not be restored.' }
    if ($clipboardSaved) { Restore-ComparisonClipboard $originalClipboard }
    if (-not [FullComparisonDesktop]::SetCursorPos($originalPointer.X, $originalPointer.Y)) {
        Write-Warning 'Original pointer position could not be restored.'
    }
    if ($originalForeground -ne [IntPtr]::Zero) { $null = [FullComparisonDesktop]::SetForegroundWindow($originalForeground) }
}
$results | Select-Object case, backend, success, stage, seconds | Format-Table -AutoSize | Out-Host
if (@($results | Where-Object { -not $_.success }).Count) {
    throw 'Full comparison retained failed or blocked cases. Results are not a successful full-suite validation.'
}
