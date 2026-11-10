[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Configuration,
    [Parameter(Mandatory)][switch] $AllowDesktopInput
)

$ErrorActionPreference = 'Stop'
if (-not $AllowDesktopInput) { throw 'Explicit desktop permission is required.' }
$jsonOptions = @{}
if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonOptions.DateKind = 'String' }
$config = Get-Content -LiteralPath $Configuration -Raw | ConvertFrom-Json @jsonOptions
if ($config.consentToken -notmatch '^[a-f0-9]{32}$') { throw 'Invalid local consent token.' }
$env:FINGVIBE_UI_COMPARISON_DESKTOP = $config.consentToken
. (Join-Path $PSScriptRoot 'Desktop.ps1')
Assert-ComparisonDesktop
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
if ($config.backend -eq 'flaui') {
    foreach ($name in @('Interop.UIAutomationClient.dll', 'FlaUI.Core.dll', 'FlaUI.UIA3.dll',
        'UiAutomationComparison.Backend.dll')) {
        $null = [Reflection.Assembly]::LoadFrom((Join-Path $config.backendDirectory $name))
    }
}
$originalContrast = [FullComparisonDesktop]::GetContrast()
$originalForeground = [FullComparisonDesktop]::GetForegroundWindow()
$originalClipboard = $null
$clipboardSaved = $false
$originalPointer = [FullComparisonDesktop+Point]::new()
if (-not [FullComparisonDesktop]::GetCursorPos([ref] $originalPointer)) { throw 'Cannot save pointer position.' }
$global:UiComparisonState = @{
    Apps = [Collections.Generic.List[object]]::new()
    AppPath = $config.appPath
    Output = $config.output
}

function Start-Process {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string] $FilePath,
        [string[]] $ArgumentList,
        [switch] $PassThru,
        [string] $WorkingDirectory,
        [string] $RedirectStandardOutput,
        [string] $RedirectStandardError
    )
    $parameters = @{}
    foreach ($key in $PSBoundParameters.Keys) { $parameters[$key] = $PSBoundParameters[$key] }
    $parameters.PassThru = $true
    $app = Microsoft.PowerShell.Management\Start-Process @parameters
    if ([IO.Path]::GetFullPath($FilePath) -eq $global:UiComparisonState.AppPath) {
        $global:UiComparisonState.Apps.Add([pscustomobject]@{ id = $app.Id; started = $app.StartTime.ToUniversalTime().ToString('o') })
        $global:UiComparisonState.Apps | ConvertTo-Json -Depth 3 |
            Set-Content -LiteralPath (Join-Path $global:UiComparisonState.Output 'owned-apps.json') -Encoding utf8
        $clock = [Diagnostics.Stopwatch]::StartNew()
        do {
            $app.Refresh()
            if ($app.HasExited) { throw "Comparison app exited with code $($app.ExitCode)." }
            if ($app.MainWindowHandle -ne [IntPtr]::Zero) { break }
            if ($clock.ElapsedMilliseconds -ge 30000) { throw 'Comparison app has no main window.' }
            Start-Sleep -Milliseconds 100
        } while ($true)
        Enter-ComparisonWindow -WindowHandle $app.MainWindowHandle
    }
    if ($PassThru) { return $app }
}

$result = [ordered]@{
    case = $config.case; backend = $config.backend; success = $false
    stage = 'execution'; error = $null; position = $null; stack = $null
    cleanupErrors = @(); seconds = 0.0; hostVersion = $PSVersionTable.PSVersion.ToString()
    contrastBefore = $originalContrast; contrastAfter = $null
    backendFindCalls = 0; backendPatternCalls = 0; backendFocusCalls = 0; captureRequests = 0
}
$clock = [Diagnostics.Stopwatch]::StartNew()
try {
    if ($config.case -eq 'additional-services') {
        $result.stage = 'clipboard-precondition'
        $originalClipboard = Save-ComparisonClipboard
        $clipboardSaved = $true
        $result.stage = 'execution'
    }
    foreach ($key in @([Environment]::GetEnvironmentVariables().Keys | Where-Object { $_ -like 'FINGVIBE_UI_REVIEW*' })) {
        [Environment]::SetEnvironmentVariable($key, $null)
    }
    $fixture = Join-Path $config.output 'base-fixture'
    $null = New-Item -ItemType Directory -Path $fixture -Force
    $env:FINGVIBE_UI_REVIEW = '1'
    $env:FINGVIBE_UI_REVIEW_INVENTORY = Join-Path $fixture 'inventory.sqlite'
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = Join-Path $fixture 'latest-scan.json'
    $env:FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT = '0'
    $parameters = @{}
    foreach ($property in $config.parameters.PSObject.Properties) { $parameters[$property.Name] = $property.Value }
    & (Join-Path $config.source $config.entryPoint) @parameters
    $result.success = $true
}
catch {
    $result.error = $_.Exception.ToString()
    $result.position = $_.InvocationInfo.PositionMessage
    $result.stack = $_.ScriptStackTrace
    Write-Host "CASE FAILED: $($config.case) / $($config.backend): $_"
    Write-Host $_.ScriptStackTrace
}
finally {
    if ($config.backend -eq 'flaui') {
        $result.backendFindCalls = [FingVibe.UiComparison.AutomationElement]::FindCalls
        $result.backendPatternCalls = [FingVibe.UiComparison.AutomationElement]::PatternCalls
        $result.backendFocusCalls = [FingVibe.UiComparison.AutomationElement]::FocusCalls
        if ($config.case -eq 'capture') {
            $result.captureRequests = [FingVibe.UiComparison.CaptureDriver]::Requests
            $capturePid = [FingVibe.UiComparison.CaptureDriver]::AppProcessId
            if ($capturePid -gt 0 -and $capturePid -notin @($global:UiComparisonState.Apps.id)) {
                $captureApp = Get-Process -Id $capturePid -ErrorAction SilentlyContinue
                if ($captureApp) {
                    $global:UiComparisonState.Apps.Add([pscustomobject]@{
                        id = $capturePid; started = $captureApp.StartTime.ToUniversalTime().ToString('o')
                    })
                }
            }
        }
    }
    foreach ($owned in $global:UiComparisonState.Apps) {
        try {
            $app = Get-Process -Id $owned.id -ErrorAction SilentlyContinue
            if (-not $app) { continue }
            if ($app.Path -ne $config.appPath -or $app.StartTime.ToUniversalTime().ToString('o') -ne $owned.started) {
                throw "Owned app identity changed for PID $($owned.id); it was not touched."
            }
            Write-Warning "Suite left app PID $($app.Id) open; closing the owned fixture app."
            $null = $app.CloseMainWindow()
            if (-not $app.WaitForExit(5000)) {
                Stop-Process -Id $app.Id -Force
                $null = $app.WaitForExit(5000)
                throw "Owned app PID $($app.Id) required forced cleanup."
            }
        }
        catch {
            $result.cleanupErrors += $_.Exception.ToString()
            Write-Warning "App cleanup failed: $_"
        }
    }
    try {
        if ([FullComparisonDesktop]::GetContrast() -ne $originalContrast) {
            [FullComparisonDesktop]::SetContrast($originalContrast)
        }
        $result.contrastAfter = [FullComparisonDesktop]::GetContrast()
        if ($result.contrastAfter -ne $originalContrast) { throw 'Original high-contrast flags were not restored.' }
    }
    catch {
        $result.cleanupErrors += $_.Exception.ToString()
        Write-Warning "Contrast cleanup failed: $_"
    }
    if ($config.backend -eq 'flaui') {
        try { [FingVibe.UiComparison.AutomationElement]::Shutdown() }
        catch { $result.cleanupErrors += $_.Exception.ToString(); Write-Warning "UIA3 cleanup failed: $_" }
    }
    try { if ($clipboardSaved) { Restore-ComparisonClipboard $originalClipboard } }
    catch {
        $result.cleanupErrors += $_.Exception.ToString()
        Write-Warning "Clipboard restoration failed: $_"
    }
    if (-not [FullComparisonDesktop]::SetCursorPos($originalPointer.X, $originalPointer.Y)) {
        $result.cleanupErrors += 'Could not restore the pointer position.'
    }
    if ($originalForeground -ne [IntPtr]::Zero) {
        $null = [FullComparisonDesktop]::SetForegroundWindow($originalForeground)
    }
    if ($result.cleanupErrors.Count) { $result.success = $false }
    $result.seconds = $clock.Elapsed.TotalSeconds
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $config.output 'result.json') -Encoding utf8
}
if (-not $result.success) { exit 1 }
