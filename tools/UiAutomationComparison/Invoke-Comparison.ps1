[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $FlaUiPath,
    [Parameter(Mandatory)][string] $OutputDirectory,
    [Parameter(Mandatory)][switch] $AllowDesktopInput,
    [ValidateRange(1, 100)][int] $Pairs = 30,
    [string] $SourceRevision = '6fd07fd04ffc7a3e919eaa7916f2487f2b59a870'
)

$ErrorActionPreference = 'Stop'
if (-not $AllowDesktopInput) { throw 'Explicit authorization to take desktop input is required.' }
$repository = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$source = Join-Path $repository 'tests\DeviceScanHistory.Ui.Tests.ps1'
foreach ($relative in @('tests\DeviceScanHistory.Ui.Tests.ps1', 'tests\UiRegression\Helpers.ps1',
    'tests\UiRegression\Devices.Controls.Helpers.ps1', '.github\scripts\UiReviewScreenshot.ps1')) {
    $gitPath = $relative.Replace('\', '/')
    $expected = & git -C $repository rev-parse "${SourceRevision}:$gitPath"
    if ($LASTEXITCODE -ne 0) { throw "Cannot resolve frozen source '$relative'." }
    $actual = & git -C $repository hash-object (Join-Path $repository $relative)
    if ($LASTEXITCODE -ne 0 -or $actual -ne $expected) { throw "Frozen source changed: $relative." }
}
& git -C $repository diff --quiet $SourceRevision -- src
if ($LASTEXITCODE -ne 0) { throw 'Application source differs from the frozen revision.' }
foreach ($path in @($AppPath, $FlaUiPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing benchmark payload '$path'." }
}
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Use a new output directory to preserve previous evidence.' }
$null = New-Item -ItemType Directory -Path $OutputDirectory
. (Join-Path $repository '.github\scripts\UiReviewScreenshot.ps1')
. (Join-Path $repository 'tests\UiRegression\Helpers.ps1')
. (Join-Path $repository 'tests\UiRegression\Devices.Controls.Helpers.ps1')
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class ComparisonPointer {
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(Point point);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out Point point);
}
'@
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref] $tokens, [ref] $parseErrors)
if ($parseErrors.Count) { throw "Baseline parsing failed: $parseErrors" }
$functions = @('Find-HistoryControl', 'Wait-HistoryState', 'Select-HistoryDevices', 'Find-HistoryDeviceRow',
    'Open-HistoryDetails', 'Get-HistoryLocalTime', 'Show-HistorySection', 'Assert-HistoryRows')
foreach ($name in $functions) {
    $definition = @($ast.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true))
    if ($definition.Count -ne 1) { throw "Expected one baseline definition for '$name'." }
    . ([scriptblock]::Create($definition[0].Extent.Text))
}
$SummaryOnly = $false
$keys = @('FINGVIBE_UI_REVIEW', 'FINGVIBE_UI_REVIEW_INVENTORY', 'FINGVIBE_UI_REVIEW_SNAPSHOT',
    'FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT', 'FINGVIBE_UI_REVIEW_NETWORK', 'FINGVIBE_UI_REVIEW_SCAN_HOLD')
$saved = Save-UiRegressionEnvironment $keys
$results = [Collections.Generic.List[object]]::new()
$AppPath = (Resolve-Path -LiteralPath $AppPath).Path
$FlaUiPath = (Resolve-Path -LiteralPath $FlaUiPath).Path
$previousDpi = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
if ($previousDpi -eq [IntPtr]::Zero) { throw 'Could not establish physical-pixel DPI context.' }
$previousForeground = [UiReviewNativeWindow]::GetForegroundWindow()
$previousPointer = [ComparisonPointer+Point]::new()
if (-not [ComparisonPointer]::GetCursorPos([ref] $previousPointer)) { throw 'Could not save pointer position.' }
@{
    sourceRevision = $SourceRevision
    appSha256 = (Get-FileHash -LiteralPath $AppPath -Algorithm SHA256).Hash
    appAssemblySha256 = (Get-FileHash -LiteralPath (Join-Path (Split-Path $AppPath) 'FingVibe.App.dll') -Algorithm SHA256).Hash
    coreAssemblySha256 = (Get-FileHash -LiteralPath (Join-Path (Split-Path $AppPath) 'FingVibe.Core.dll') -Algorithm SHA256).Hash
    flauiSha256 = (Get-FileHash -LiteralPath $FlaUiPath -Algorithm SHA256).Hash
    pairs = $Pairs; startedAt = [DateTimeOffset]::Now.ToString('o')
    os = [Environment]::OSVersion.VersionString
    powershell = $PSVersionTable.PSVersion.ToString()
    window = '1280x900 physical pixels'
    baselineFunctions = $functions
} | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $OutputDirectory 'manifest.json')

try {
    foreach ($pair in 1..$Pairs) {
        $order = if ($pair % 2 -eq 1) { @('baseline', 'flaui') } else { @('flaui', 'baseline') }
        foreach ($backend in $order) {
            $trial = Join-Path $OutputDirectory ('{0:D2}-{1}' -f $pair, $backend)
            $null = New-Item -ItemType Directory -Path $trial
            $inventory = Join-Path $trial 'inventory.json'
            $snapshot = Join-Path $trial 'snapshot.json'
            $history = @(0..1 | ForEach-Object {
                @{ completedAt = "2026-11-01T12:0${_}:00+00:00"; networkId = 'ui-review-network'
                    subnet = '127.0.0.1/32'; present = $true }
            })
            $observation = @{
                networkId = 'ui-review-network'; subnet = '127.0.0.1/32'; address = '127.0.0.1'
                hostname = $null; vendor = 'Example'; ports = @(); latency = 1; probeDuration = '00:00:00.001'
                classification = @{ type = 0; operatingSystem = 0; typeEvidence = 'Synthetic fixture'
                    operatingSystemEvidence = 'Synthetic fixture' }
                firstSeen = '2026-11-01T12:00:00+00:00'; lastSeen = '2026-11-01T12:01:00+00:00'
                lastChecked = '2026-11-01T12:01:00+00:00'; present = $true
            }
            @{ version = 3; data = @{
                revision = '4cb4859b-155d-44ec-842a-78bea139a657'
                devices = @{ '020000000001' = @{ mac = '020000000001'; imported = @{ name = 'History normal' }
                    observations = @($observation); scanHistory = $history } }
                names = @{}; classifications = @{}
                peopleRooms = @{ people = @(); rooms = @(); assignments = @{} }; virtualDevices = @()
            } } | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $inventory -Encoding utf8
            @{ version = 3; subnet = '127.0.0.1/32'; completedAt = '2026-11-01T12:04:00+00:00'; results = @() } |
                ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $snapshot -Encoding utf8
            $env:FINGVIBE_UI_REVIEW = '1'
            $env:FINGVIBE_UI_REVIEW_INVENTORY = $inventory
            $env:FINGVIBE_UI_REVIEW_SNAPSHOT = $snapshot
            $env:FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT = '0'
            $env:FINGVIBE_UI_REVIEW_NETWORK = 'ui-review-network'
            $env:FINGVIBE_UI_REVIEW_SCAN_HOLD = Join-Path $trial 'scan.hold'
            $ScreenshotDirectory = $trial
            $script:process = $null
            $script:root = $null
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $result = [ordered]@{
                pair = $pair; backend = $backend; success = $false; phase = 'launch'
                error = $null; cleanupError = $null; launchMilliseconds = 0.0
                attachMilliseconds = 0.0; navigationMilliseconds = 0.0
                assertionMilliseconds = 0.0; driverMilliseconds = 0.0; totalMilliseconds = 0.0
            }
            Write-Host "Trial $pair/$Pairs $backend"
            try {
                $script:process = Start-Process -FilePath $AppPath -PassThru
                $null = Wait-UiRegressionState -Description 'benchmark app window' -TimeoutMilliseconds 30000 -Condition {
                    $script:process.Refresh()
                    if ($script:process.HasExited) { throw "Benchmark app exited: $($script:process.ExitCode)." }
                    if ($script:process.MainWindowHandle -ne [IntPtr]::Zero) { return $true }
                }
                $handle = $script:process.MainWindowHandle
                $area = [System.Windows.Forms.Screen]::FromHandle($handle).WorkingArea
                if ($area.Width -lt 1280 -or $area.Height -lt 900) {
                    throw "Desktop work area must fit 1280x900: $area."
                }
                if (-not [UiReviewNativeWindow]::SetWindowPos($handle, [IntPtr]::new(-1),
                    $area.Left, $area.Top, 1280, 900, 0x0050)) { throw 'Could not present the benchmark window.' }
                try {
                    $point = [ComparisonPointer+Point]::new()
                    $point.X = $area.Left + 640
                    $point.Y = $area.Top + 16
                    [DevicesReviewInput]::MoveTo($point.X, $point.Y)
                    if ([ComparisonPointer]::GetAncestor([ComparisonPointer]::WindowFromPoint($point), 2) -ne $handle) {
                        throw 'The activation point does not belong to the benchmark app; no click was sent.'
                    }
                    [DevicesReviewInput]::Click()
                    $null = Wait-UiRegressionState -Description 'benchmark title-bar click to activate its window' `
                        -TimeoutMilliseconds 2000 -Condition { [UiReviewNativeWindow]::GetForegroundWindow() -eq $handle }
                }
                finally {
                    if (-not [UiReviewNativeWindow]::SetWindowPos($handle, [IntPtr]::new(-2), 0, 0, 0, 0, 0x0013)) {
                        throw 'Could not remove temporary topmost state from the benchmark window.'
                    }
                }
                Initialize-UiReviewWindow $handle
                $result.launchMilliseconds = $clock.Elapsed.TotalMilliseconds
                $driver = [Diagnostics.Stopwatch]::StartNew()
                if ($backend -eq 'baseline') {
                    $result.phase = 'attach'
                    $script:root = [System.Windows.Automation.AutomationElement]::FromHandle($handle)
                    $result.attachMilliseconds = $driver.Elapsed.TotalMilliseconds
                    $result.phase = 'navigation'
                    $navigation = [Diagnostics.Stopwatch]::StartNew()
                    Wait-HistoryState { Find-HistoryControl DevicesNavItem -Optional } 'device navigation'
                    Start-Sleep -Milliseconds 500
                    try { Open-HistoryDetails 'History normal' }
                    finally { $result.navigationMilliseconds = $navigation.Elapsed.TotalMilliseconds }
                    $result.phase = 'reachability'
                    $assertion = [Diagnostics.Stopwatch]::StartNew()
                    try { Assert-HistoryRows 'history-two-scans' 1 }
                    finally { $result.assertionMilliseconds = $assertion.Elapsed.TotalMilliseconds }
                    $result.success = $true
                }
                else {
                    $result.phase = 'flaui-worker'
                    $worker = Start-Process -FilePath $FlaUiPath -ArgumentList @(
                        $handle.ToInt64().ToString(), ('"{0}"' -f $trial)) -PassThru `
                        -RedirectStandardOutput (Join-Path $trial 'flaui.stdout.log') `
                        -RedirectStandardError (Join-Path $trial 'flaui.stderr.log')
                    if (-not $worker.WaitForExit(90000)) {
                        Stop-Process -Id $worker.Id -Force
                        throw 'FlaUI worker exceeded the 90-second scenario deadline.'
                    }
                    $workerResult = Get-Content (Join-Path $trial 'flaui-result.json') -Raw | ConvertFrom-Json
                    foreach ($key in @('success', 'phase', 'error', 'attachMilliseconds',
                        'navigationMilliseconds', 'assertionMilliseconds')) { $result[$key] = $workerResult.$key }
                    if ($worker.ExitCode -ne 0 -or -not $result.success) {
                        throw "FlaUI scenario failed: $($workerResult.error)"
                    }
                    $capture = [Diagnostics.Stopwatch]::StartNew()
                    Save-UiReviewWindowScreenshot $handle (Join-Path $trial 'history-two-scans.png')
                    $result.assertionMilliseconds += $capture.Elapsed.TotalMilliseconds
                }
                $result.driverMilliseconds = $driver.Elapsed.TotalMilliseconds
            }
            catch {
                $result.success = $false
                $result.error = $_.Exception.ToString()
                Write-Host "$backend failed in $($result.phase): $($_.Exception.Message)"
                if ($script:process -and -not $script:process.HasExited -and $script:process.MainWindowHandle -ne [IntPtr]::Zero) {
                    try {
                        Save-UiReviewWindowScreenshot $script:process.MainWindowHandle (Join-Path $trial 'failure.png')
                        if ($backend -eq 'baseline' -and $script:root) {
                            $script:root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                                [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object {
                                    [ordered]@{ id = $_.Current.AutomationId; name = $_.Current.Name
                                        offscreen = $_.Current.IsOffscreen; bounds = $_.Current.BoundingRectangle.ToString() }
                                } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $trial 'baseline-tree.json')
                        }
                    }
                    catch { Write-Warning "Failure diagnostics also failed: $_" }
                }
            }
            finally {
                if ($driver) { $result.driverMilliseconds = $driver.Elapsed.TotalMilliseconds }
                try { Stop-UiRegressionApp -Process $script:process }
                catch {
                    $result.success = $false
                    $result.cleanupError = $_.Exception.ToString()
                    Write-Warning "Trial cleanup failed: $_"
                }
                $result.totalMilliseconds = $clock.Elapsed.TotalMilliseconds
                $results.Add([pscustomobject] $result)
                $result | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $trial 'result.json')
                $results | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputDirectory 'results.json')
                $driver = $null
            }
        }
        if (@($results | Where-Object { $_.pair -eq $pair -and
            ((-not $_.success -and $_.phase -eq 'launch') -or $_.cleanupError) }).Count) {
            Write-Warning 'Stopping: a shared desktop setup/cleanup prerequisite failed, so further pairs would not compare the backends.'
            break
        }
    }
}
finally {
    Restore-UiRegressionEnvironment -Saved $saved
    $null = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext($previousDpi)
    if ($previousForeground -ne [IntPtr]::Zero) {
        $null = [UiReviewNativeWindow]::SetForegroundWindow($previousForeground)
    }
    if (-not [DevicesReviewInput]::SetCursorPos($previousPointer.X, $previousPointer.Y)) {
        Write-Warning 'Could not restore the pointer position.'
    }
}
$summary = foreach ($backend in @('baseline', 'flaui')) {
    $trials = @($results | Where-Object backend -eq $backend)
    $passed = @($trials | Where-Object success)
    $entry = [ordered]@{ backend = $backend; trials = $trials.Count; passed = $passed.Count
        failed = $trials.Count - $passed.Count }
    foreach ($metric in @('totalMilliseconds', 'driverMilliseconds', 'navigationMilliseconds', 'assertionMilliseconds')) {
        $values = @($trials.$metric | Sort-Object)
        $entry["${metric}Median"] = if ($values.Count % 2) { $values[[int][Math]::Floor($values.Count / 2)] }
            else { ($values[$values.Count / 2 - 1] + $values[$values.Count / 2]) / 2 }
        $entry["${metric}P95"] = $values[[Math]::Ceiling($values.Count * 0.95) - 1]
    }
    [pscustomobject] $entry
}
$summary | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $OutputDirectory 'summary.json')
$summary | Format-List | Out-Host
if (@($results | Where-Object { -not $_.success }).Count) {
    throw 'Comparison completed with first-attempt scenario failures; see retained results and diagnostics.'
}
