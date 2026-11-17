[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $AppDirectory,
    [Parameter(Mandatory)][string] $InstallerPath,
    [Parameter(Mandatory)][string] $Version,
    [Parameter(Mandatory)][string] $LogDirectory
)

# The current feature family; keep it equal to the release version in .github/workflows/release.yml.
# Bumping the feature version changes only this value: the previous family and every fixture
# version are derived from it, so no lifecycle case is added per release.
$FeatureFamily = "1.3"

$ErrorActionPreference = "Stop"
if ($env:GITHUB_ACTIONS -ne "true" -or $env:RUNNER_ENVIRONMENT -ne "github-hosted") {
    throw "Installer lifecycle tests may run only on disposable GitHub-hosted Windows runners."
}
$app = Join-Path $env:LOCALAPPDATA "Programs\FingVibe"
$data = Join-Path $env:LOCALAPPDATA "FingVibe"
$registration = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{BA17F8F1-EF47-4D63-9D8F-E46B23F79225}_is1"
$versionKey = "HKCU:\Software\FingVibe\Installer"
foreach ($path in @($app, $data, $registration, $versionKey)) {
    if (Test-Path -LiteralPath $path) { throw "Refusing to overwrite an existing FingVibe installation/data: $path" }
}
$logs = [IO.Path]::GetFullPath($LogDirectory)
$null = New-Item -ItemType Directory -Path $logs -Force
$fixture = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-installer-lifecycle-$([guid]::NewGuid())"
$process = $null
$savedReview = $env:FINGVIBE_UI_REVIEW
$timings = [Collections.Generic.List[object]]::new()
$lifecycle = [Diagnostics.Stopwatch]::StartNew()
$lifecycleOutcome = "failed"

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Measure-Phase([string] $Kind, [string] $Name, [scriptblock] $Action) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $outcome = "failed"
    try {
        & $Action
        $outcome = "succeeded"
    } finally {
        $seconds = [Math]::Round($timer.Elapsed.TotalSeconds, 1)
        $timings.Add([pscustomobject]@{ Kind = $Kind; Name = $Name; Seconds = $seconds; Outcome = $outcome })
        Write-Host "Installer $Kind $Name $outcome in $seconds s."
    }
}
function Invoke-Setup([string] $Path, [string] $Name, [switch] $ExpectFailure, [string[]] $Extra = @()) {
    $kind = if ($Path -like "*unins000.exe") { "uninstall" } else { "setup" }
    Measure-Phase $kind $Name {
        $arguments = @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/SP-", "/LOG=`"$(Join-Path $logs "$Name.log")`"") + $Extra
        $setup = Start-Process -FilePath $Path -ArgumentList $arguments -PassThru
        if (-not $setup.WaitForExit(180000)) {
            Stop-Process -Id $setup.Id -Force
            throw "Installer timed out: $Name"
        }
        if ($ExpectFailure) {
            Assert-True ($setup.ExitCode -ne 0) "$Name unexpectedly succeeded."
        } else {
            Assert-True ($setup.ExitCode -eq 0) "$Name failed with exit code $($setup.ExitCode). See $logs."
        }
    }
}
function New-FixtureInstaller([string] $Source, [string] $FixtureVersion) {
    Measure-Phase "compile" $FixtureVersion {
        & $builder -AppDirectory $Source -Version $FixtureVersion -OutputDirectory $fixture -FixtureCompression | Out-Host
    }
    Join-Path $fixture "FingVibe-$FixtureVersion-win-x64-Setup.exe"
}
function Uninstall-App([string] $Name) {
    $uninstaller = Join-Path $app "unins000.exe"
    Assert-True (Test-Path -LiteralPath $uninstaller) "Uninstaller is missing."
    Invoke-Setup $uninstaller $Name
    Assert-True (-not (Test-Path -LiteralPath $registration)) "Uninstall registration was not removed."
    Assert-True (-not (Test-Path -LiteralPath $versionKey)) "Installer version was not removed."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $app "FingVibe.App.exe"))) "Installed executable was not removed."
}
function Get-SavedDataHashes {
    $hashes = @{}
    Get-ChildItem -LiteralPath $data -Recurse -File | ForEach-Object {
        $hashes[[IO.Path]::GetRelativePath($data, $_.FullName)] = (Get-FileHash -LiteralPath $_.FullName).Hash
    }
    $hashes
}
function Assert-SavedDataUnchanged([hashtable] $Expected, [string] $Message) {
    $actual = Get-SavedDataHashes
    Assert-True ($actual.Count -eq $Expected.Count) "$Message (file count changed)"
    foreach ($relative in $Expected.Keys) {
        Assert-True ($actual[$relative] -eq $Expected[$relative]) "$Message ($relative)"
    }
}
function Assert-InstalledPayload([string] $Message) {
    foreach ($relative in $sourceHashes.Keys) {
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $app $relative)).Hash -eq $sourceHashes[$relative]) "${Message}: $relative"
    }
}
try {
    $v = [version] $Version
    if ($v.Build -lt 1 -or $v.Build -ge 65534) { throw "Lifecycle fixture versions require adjacent lower and higher build numbers." }
    $family = [version] $FeatureFamily
    if ($family.Minor -lt 1) { throw "Define the previous feature family explicitly for a major-version bump." }
    $previousFamily = "$($family.Major).$($family.Minor - 1)"
    $builder = Join-Path $PSScriptRoot "..\tools\New-Installer.ps1"
    $source = (Resolve-Path -LiteralPath $AppDirectory).Path
    $installer = (Resolve-Path -LiteralPath $InstallerPath).Path
    $null = New-Item -ItemType Directory -Path $fixture
    $sourceHashes = @{}
    Get-ChildItem -LiteralPath $source -Recurse -File | ForEach-Object {
        $sourceHashes[[IO.Path]::GetRelativePath($source, $_.FullName)] = (Get-FileHash -LiteralPath $_.FullName).Hash
    }
    Invoke-Setup $installer "fresh-install"
    Assert-True ((Get-ItemProperty -LiteralPath $registration).DisplayVersion -eq $Version) "Installed version differs from release version."
    Assert-True ((Get-ItemProperty -LiteralPath $registration).InstallLocation.TrimEnd('\') -eq $app) "Installation must be per-user."
    $startShortcut = Join-Path ([Environment]::GetFolderPath("Programs")) "FingVibe.lnk"
    $desktopShortcut = Join-Path ([Environment]::GetFolderPath("Desktop")) "FingVibe.lnk"
    Assert-True (Test-Path -LiteralPath $startShortcut) "Start menu shortcut is missing."
    Assert-True (-not (Test-Path -LiteralPath $desktopShortcut)) "Desktop shortcut should be opt-in."
    Assert-InstalledPayload "Installed payload differs"
    $env:FINGVIBE_UI_REVIEW = "1"
    Measure-Phase "launch" "installed-app-window" {
        $script:process = Start-Process -FilePath (Join-Path $app "FingVibe.App.exe") -WorkingDirectory $app -PassThru
        $deadline = [DateTime]::UtcNow.AddSeconds(45)
        do {
            Start-Sleep -Milliseconds 500
            $script:process.Refresh()
            if ($script:process.HasExited) { throw "Installed app exited before opening a window: $($script:process.ExitCode)" }
        } until ($script:process.MainWindowHandle -ne 0 -or [DateTime]::UtcNow -gt $deadline)
        Assert-True ($script:process.MainWindowHandle -ne 0) "Installed app did not open a window."
    }
    Invoke-Setup $installer "running-app-blocks-install" -ExpectFailure
    Assert-True ((Get-Content -LiteralPath (Join-Path $logs "running-app-blocks-install.log") -Raw) -match 'Close FingVibe') "App-running rejection was not reported."
    Invoke-Setup (Join-Path $app "unins000.exe") "running-app-blocks-uninstall" -ExpectFailure
    Assert-True ($process.CloseMainWindow()) "Could not close the installed app normally."
    Assert-True ($process.WaitForExit(15000)) "Installed app did not close."
    $process = $null
    $null = New-Item -ItemType Directory -Path $data -Force
    $savedData = Join-Path $data "installer-test-saved-data.txt"
    "keep saved data" | Set-Content -LiteralPath $savedData
    Uninstall-App "fresh-uninstall"
    Assert-True (-not (Test-Path -LiteralPath $startShortcut)) "Start menu shortcut survived uninstall."
    Assert-True ((Get-Content -LiteralPath $savedData) -eq "keep saved data") "Saved data was changed by uninstall."

    # One representative previous-feature upgrade with a higher build number, plus downgrade rejection.
    # Release runs upgrade to the actual release installer; other runs use a current-family fixture.
    if ($v -ge $family) {
        $featureVersion = $Version
        $featureInstaller = $installer
    } else {
        $featureVersion = "$FeatureFamily.$($v.Build)"
        $featureInstaller = New-FixtureInstaller $source $featureVersion
    }
    $legacyVersion = "$previousFamily.$($v.Build + 1)"
    Assert-True ([version] $legacyVersion -lt [version] $featureVersion) "Feature version must order above the higher-build previous-family fixture."
    $legacyInstaller = New-FixtureInstaller $source $legacyVersion
    Invoke-Setup $legacyInstaller "legacy-$previousFamily-install"
    Assert-True ((Get-ItemProperty -LiteralPath $registration).DisplayVersion -eq $legacyVersion) "$previousFamily fixture was not installed."
    foreach ($name in @("device-inventory.sqlite", "latest-scan.json", "people-rooms.json", "appearance.json", "device-table.json", "periodic-scan.json")) {
        "synthetic $previousFamily $name" | Set-Content -LiteralPath (Join-Path $data $name)
    }
    $legacyData = Get-SavedDataHashes
    Invoke-Setup $featureInstaller "feature-upgrade-from-$previousFamily"
    Assert-True ((Get-ItemProperty -LiteralPath $registration).DisplayVersion -eq $featureVersion) "$previousFamily installation was not upgraded to $featureVersion."
    Assert-SavedDataUnchanged $legacyData "$previousFamily feature-version upgrade changed saved inventory, history, or settings."
    Invoke-Setup $legacyInstaller "reject-$previousFamily-feature-downgrade" -ExpectFailure
    Assert-True ((Get-Content -LiteralPath (Join-Path $logs "reject-$previousFamily-feature-downgrade.log") -Raw) -match 'Downgrades are not supported') "$previousFamily downgrade rejection was not reported."
    Assert-True ((Get-ItemProperty -LiteralPath $registration).DisplayVersion -eq $featureVersion) "Rejected $previousFamily downgrade changed installed version."
    Assert-SavedDataUnchanged $legacyData "Rejected $previousFamily downgrade changed saved inventory, history, or settings."
    Uninstall-App "feature-upgrade-from-$previousFamily-uninstall"
    Assert-SavedDataUnchanged $legacyData "Uninstall after $previousFamily feature-version upgrade changed saved inventory, history, or settings."

    # The real production-compressed installer upgrades a lower same-family fixture, removing the
    # fixture's obsolete managed file while keeping unknown files and saved data.
    $lowerVersion = "$($v.Major).$($v.Minor).$($v.Build - 1)"
    $fixtureApp = Join-Path $fixture "app"
    $null = New-Item -ItemType Directory -Path $fixtureApp
    Copy-Item -Path (Join-Path $source "*") -Destination $fixtureApp -Recurse
    "obsolete managed file" | Set-Content -LiteralPath (Join-Path $fixtureApp "obsolete-test.txt")
    $lowerInstaller = New-FixtureInstaller $fixtureApp $lowerVersion
    Invoke-Setup $lowerInstaller "lower-$lowerVersion-install"
    Assert-True ((Get-ItemProperty -LiteralPath $registration).DisplayVersion -eq $lowerVersion) "Lower-version fixture was not installed."
    Assert-True (Test-Path -LiteralPath (Join-Path $app "obsolete-test.txt")) "Lower-version fixture did not install its managed file."
    $unknown = Join-Path $app "user-file.txt"
    "keep unknown file" | Set-Content -LiteralPath $unknown
    $upgradeData = Get-SavedDataHashes
    Invoke-Setup $installer "real-installer-upgrade-from-$lowerVersion"
    Assert-True ((Get-ItemProperty -LiteralPath $registration).DisplayVersion -eq $Version) "Real installer did not upgrade the lower-version installation."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $app "obsolete-test.txt"))) "Upgrade retained obsolete managed file."
    Assert-True ((Get-Content -LiteralPath $unknown) -eq "keep unknown file") "Upgrade changed an unknown file."
    Assert-SavedDataUnchanged $upgradeData "Real installer upgrade changed saved data."
    Assert-InstalledPayload "Upgraded payload differs"
    Invoke-Setup $lowerInstaller "reject-downgrade" -ExpectFailure
    Assert-True ((Get-Content -LiteralPath (Join-Path $logs "reject-downgrade.log") -Raw) -match 'Downgrades are not supported') "Downgrade rejection was not reported."
    Assert-True ((Get-ItemProperty -LiteralPath $registration).DisplayVersion -eq $Version) "Rejected downgrade changed installed version."
    Assert-SavedDataUnchanged $upgradeData "Rejected downgrade changed saved data."
    Uninstall-App "upgrade-uninstall"
    Assert-True ((Get-Content -LiteralPath $unknown) -eq "keep unknown file") "Uninstall removed an unknown file."
    Assert-SavedDataUnchanged $upgradeData "Uninstall removed saved data."

    # Emulate the existing ZIP script over the retained unknown file; the real installer adopts it.
    Copy-Item -Path (Join-Path $source "*") -Destination $app -Recurse -Force
    Invoke-Setup $installer "adopt-script-install" -Extra @("/TASKS=desktopicon")
    Assert-True ((Get-ItemProperty -LiteralPath $registration).DisplayVersion -eq $Version) "Real installer did not adopt the script installation."
    Assert-True (Test-Path -LiteralPath $desktopShortcut) "Selected desktop shortcut is missing."
    Assert-True ((Get-Content -LiteralPath $unknown) -eq "keep unknown file") "Adoption removed an unknown file."
    Uninstall-App "adopt-uninstall"
    Assert-True ((Get-Content -LiteralPath $unknown) -eq "keep unknown file") "Uninstall after adoption removed an unknown file."
    Assert-SavedDataUnchanged $upgradeData "Uninstall after adoption removed saved data."
    Assert-True (-not (Test-Path -LiteralPath $desktopShortcut)) "Desktop shortcut survived uninstall."
    $lifecycleOutcome = "succeeded"
    Write-Host "Installer fresh install, launch, $previousFamily to $FeatureFamily feature-version upgrade, adoption, real-installer upgrade, downgrade, and uninstall checks passed."
} finally {
    $env:FINGVIBE_UI_REVIEW = $savedReview
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
    $total = [Math]::Round($lifecycle.Elapsed.TotalSeconds, 1)
    $timings.Add([pscustomobject]@{ Kind = "lifecycle"; Name = "total"; Seconds = $total; Outcome = $lifecycleOutcome })
    $timings | Export-Csv -LiteralPath (Join-Path $logs "lifecycle-timings.csv") -NoTypeInformation
    if ($env:GITHUB_STEP_SUMMARY) {
        $table = @("", "### Installer lifecycle timings ($lifecycleOutcome, $total s)", "", "| Phase | Action | Seconds | Outcome |", "| --- | --- | ---: | --- |")
        $table += $timings | ForEach-Object { "| $($_.Kind) | $($_.Name) | $($_.Seconds) | $($_.Outcome) |" }
        $table -join "`n" >> $env:GITHUB_STEP_SUMMARY
    }
}
