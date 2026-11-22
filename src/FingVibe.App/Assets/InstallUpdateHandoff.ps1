[CmdletBinding()]
param([string] $RecordPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($RecordPath)) {
    $RecordPath = [Environment]::GetEnvironmentVariable("FINGVIBE_UPDATE_HANDOFF_RECORD")
}

function Write-UpdateInstallJson {
    param([Parameter(Mandatory)] $Record, [Parameter(Mandatory)] [string] $Path)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        $null = New-Item -ItemType Directory -Path $directory -Force
    }
    $temporary = Join-Path $directory ".$([IO.Path]::GetFileName($Path)).$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temporary, ($Record | ConvertTo-Json -Depth 10 -Compress),
        [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $backup = "$temporary.backup"
        [IO.File]::Replace($temporary, $Path, $backup)
        Remove-Item -LiteralPath $backup -Force
    }
    else {
        [IO.File]::Move($temporary, $Path)
    }
}

function Save-UpdateInstallRecord {
    param([Parameter(Mandatory)] $Record, [Parameter(Mandatory)] [string] $Path)
    Write-UpdateInstallJson $Record $Path
    if ($Record.PSObject.Properties.Name -contains "latestRecordPath") {
        $latestPath = [string] $Record.latestRecordPath
        if (-not [string]::IsNullOrWhiteSpace($latestPath) -and
            -not $latestPath.Equals($Path, [StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $latestPath -PathType Leaf)) {
            $latest = Get-Content -LiteralPath $latestPath -Raw | ConvertFrom-Json
            if ([string] $latest.attemptId -ceq [string] $Record.attemptId) {
                Write-UpdateInstallJson $Record $latestPath
            }
        }
    }
}

function Wait-SourceProcessExit {
    param(
        [Parameter(Mandatory)] [int] $ProcessId,
        [Parameter(Mandatory)] [DateTimeOffset] $StartedUtc,
        [ValidateRange(1, 600)] [int] $TimeoutSeconds = 90,
        [scriptblock] $GetProcessState
    )
    if (-not $GetProcessState) {
        $GetProcessState = {
            param([int] $Id)
            $process = Get-Process -Id $Id -ErrorAction SilentlyContinue
            if (-not $process) { return }
            [pscustomobject]@{ StartedUtc = ([DateTimeOffset] $process.StartTime.ToUniversalTime()) }
        }
    }
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $actual = & $GetProcessState $ProcessId
        if (-not $actual) { return }
        $difference = [Math]::Abs(($actual.StartedUtc - $StartedUtc).TotalSeconds)
        if ($difference -gt 2) { return }
        if ([DateTimeOffset]::UtcNow -ge $deadline) {
            throw "FingVibe did not exit within $TimeoutSeconds seconds. The installer was not started."
        }
        Start-Sleep -Milliseconds 250
    } while ($true)
}

function Assert-UpdateInstaller {
    param([Parameter(Mandatory)] $Record)
    $path = [string] $Record.installerPath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "The verified Setup file is unavailable."
    }
    $file = [IO.FileInfo]::new($path)
    if ($file.Length -ne [long] $Record.installerSize) {
        throw "The downloaded Setup size changed before installation."
    }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if ($hash -cne [string] $Record.installerSha256) {
        throw "The downloaded Setup hash changed before installation."
    }
    $zonePath = "${path}:Zone.Identifier"
    if (-not (Test-Path -LiteralPath $zonePath -PathType Leaf)) {
        throw "The downloaded Setup Internet security marking is unavailable."
    }
    $zone = Get-Content -LiteralPath $zonePath -Raw
    if ($zone -notmatch "(?m)^ZoneId=$([int] $Record.expectedZoneId)\s*$") {
        throw "The downloaded Setup Internet security marking changed."
    }
}

function Invoke-VerifiedUpdateInstaller {
    param([Parameter(Mandatory)] $Record, [scriptblock] $Started)
    $process = Start-Process -FilePath ([string] $Record.installerPath) -PassThru `
        -ArgumentList @(
            "/SP-", "/SILENT", "/SUPPRESSMSGBOXES", "/NORESTART",
            "/LOG=`"$([string] $Record.installerLogPath)`""
        )
    if (-not $process) { throw "Windows did not accept the verified installer launch." }
    if ($Started) { & $Started $process }
    $process.WaitForExit()
    return $process.ExitCode
}

function Assert-InstalledUpdate {
    param([Parameter(Mandatory)] $Record)
    $expected = [version] ([string] $Record.expectedVersion)
    $directory = [IO.Path]::GetFullPath([string] $Record.installationDirectory).TrimEnd("\")
    $registered = Get-ItemProperty -LiteralPath `
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{BA17F8F1-EF47-4D63-9D8F-E46B23F79225}_is1"
    $marker = Get-ItemProperty -LiteralPath "HKCU:\Software\FingVibe\Installer"
    $registeredDirectory = [IO.Path]::GetFullPath([string] $registered.InstallLocation).TrimEnd("\")
    if (-not $registeredDirectory.Equals($directory, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The verified installer did not update the expected FingVibe installation directory."
    }
    if ([string] $registered.DisplayVersion -cne $expected.ToString()) {
        throw "The installed FingVibe version is not the confirmed update."
    }
    $expectedMs = ($expected.Major -shl 16) -bor $expected.Minor
    $expectedLs = ($expected.Build -shl 16) -bor ([Math]::Max(0, $expected.Revision))
    if ([long] $marker.VersionMS -ne $expectedMs -or [long] $marker.VersionLS -ne $expectedLs) {
        throw "The FingVibe installation ownership marker does not match the confirmed update."
    }
    foreach ($required in @(
        (Join-Path $directory "FingVibe.App.exe"),
        (Join-Path $directory "unins000.exe"),
        (Join-Path $directory "_fingvibe-files.txt")
    )) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "The installed FingVibe update is incomplete: $required."
        }
    }
}

function Start-UpdatedFingVibe {
    param([Parameter(Mandatory)] $Record)
    $process = Start-Process -FilePath ([string] $Record.relaunchExecutablePath) `
        -WorkingDirectory ([string] $Record.installationDirectory) -PassThru
    if (-not $process) { throw "The verified FingVibe installation did not relaunch." }
    return $process.Id
}

function Invoke-UpdateInstallHandoff {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RecordPath,
        [scriptblock] $WaitForOriginExit,
        [scriptblock] $VerifyInstaller,
        [scriptblock] $RunInstaller,
        [scriptblock] $VerifyInstallation,
        [scriptblock] $StartRelaunch
    )
    if (-not $WaitForOriginExit) {
        $WaitForOriginExit = { param($Record) Wait-SourceProcessExit $Record.originProcessId ([DateTimeOffset]::Parse($Record.originProcessStartedUtc)) }
    }
    if (-not $VerifyInstaller) { $VerifyInstaller = { param($Record) Assert-UpdateInstaller $Record } }
    if (-not $RunInstaller) {
        $RunInstaller = {
            param($Record)
            Invoke-VerifiedUpdateInstaller $Record -Started {
                param($Process)
                $Record.installerProcessId = $Process.Id
                $Record.installerProcessStartedUtc = ([DateTimeOffset] $Process.StartTime.ToUniversalTime()).ToString("o")
                Save-UpdateInstallRecord $Record $RecordPath
            }
        }
    }
    if (-not $VerifyInstallation) { $VerifyInstallation = { param($Record) Assert-InstalledUpdate $Record } }
    if (-not $StartRelaunch) { $StartRelaunch = { param($Record) Start-UpdatedFingVibe $Record } }

    $record = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json
    if ($record.PSObject.Properties.Name -contains "latestRecordPath" -and
    (Test-Path -LiteralPath ([string] $record.latestRecordPath) -PathType Leaf)) {
    $latest = Get-Content -LiteralPath ([string] $record.latestRecordPath) -Raw | ConvertFrom-Json
    if ([string] $latest.attemptId -cne [string] $record.attemptId) {
        throw "A newer update handoff superseded this attempt."
    }
    }
    $installerExitCode = $null
    try {
        $currentHelper = Get-Process -Id $PID
        $record.helperProcessId = $currentHelper.Id
        $record.helperProcessStartedUtc = ([DateTimeOffset] $currentHelper.StartTime.ToUniversalTime()).ToString("o")
        $record.state = "waiting"
        Save-UpdateInstallRecord $record $RecordPath
        & $WaitForOriginExit $record
        & $VerifyInstaller $record
        $record.state = "installing"
        Save-UpdateInstallRecord $record $RecordPath
        $installerExitCode = [int] (& $RunInstaller $record)
        if ($installerExitCode -ne 0) {
            throw "The FingVibe installer exited with code $installerExitCode."
        }
        & $VerifyInstallation $record
        $relaunchStarted = $false
        $relaunchProcessId = $null
        if ([bool] $record.relaunchRequested) {
            $relaunchProcessId = [int] (& $StartRelaunch $record)
            $relaunchStarted = $true
        }
        $record.outcome = [pscustomobject]@{
            completedUtc = [DateTimeOffset]::UtcNow.ToString("o")
            installerExitCode = $installerExitCode
            relaunchStarted = $relaunchStarted
            relaunchProcessId = $relaunchProcessId
            error = $null
        }
        $record.state = "succeeded"
        Save-UpdateInstallRecord $record $RecordPath
        return $record
    }
    catch {
        $record.outcome = [pscustomobject]@{
            completedUtc = [DateTimeOffset]::UtcNow.ToString("o")
            installerExitCode = $installerExitCode
            relaunchStarted = $false
            relaunchProcessId = $null
            error = $_.Exception.GetBaseException().Message
        }
        $record.state = "failed"
        Save-UpdateInstallRecord $record $RecordPath
        throw
    }
}

if (-not [string]::IsNullOrWhiteSpace($RecordPath)) {
    $mutex = [Threading.Mutex]::new($false, "FingVibe-Update-Installer-Handoff")
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne([TimeSpan]::FromMinutes(10))
        if (-not $acquired) { throw "Another FingVibe update handoff remained active for ten minutes." }
        $null = Invoke-UpdateInstallHandoff -RecordPath $RecordPath
        exit 0
    }
    catch {
        if (Test-Path -LiteralPath $RecordPath -PathType Leaf) {
            $failed = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json
            if ([string] $failed.state -cne "failed") {
                $failed.state = "failed"
                $failed.outcome = [pscustomobject]@{
                    completedUtc = [DateTimeOffset]::UtcNow.ToString("o")
                    installerExitCode = $null
                    relaunchStarted = $false
                    relaunchProcessId = $null
                    error = $_.Exception.GetBaseException().Message
                }
                Save-UpdateInstallRecord $failed $RecordPath
            }
        }
        Write-Error $_
        exit 1
    }
    finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
