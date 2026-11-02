[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $AppDirectory,
    [Parameter(Mandatory)][string] $InstallerPath,
    [Parameter(Mandatory)][string] $Version,
    [Parameter(Mandatory)][string] $LogDirectory
)

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

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw $Message }
}
function Invoke-Setup([string] $Path, [string] $Name, [switch] $ExpectFailure, [string[]] $Extra = @()) {
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
function Uninstall-App([string] $Name) {
    $uninstaller = Join-Path $app "unins000.exe"
    Assert-True (Test-Path -LiteralPath $uninstaller) "Uninstaller is missing."
    Invoke-Setup $uninstaller $Name
    Assert-True (-not (Test-Path -LiteralPath $registration)) "Uninstall registration was not removed."
    Assert-True (-not (Test-Path -LiteralPath $versionKey)) "Installer version was not removed."
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $app "FingVibe.App.exe"))) "Installed executable was not removed."
}
try {
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
    foreach ($relative in $sourceHashes.Keys) {
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $app $relative)).Hash -eq $sourceHashes[$relative]) "Installed payload differs: $relative"
    }
    $env:FINGVIBE_UI_REVIEW = "1"
    $process = Start-Process -FilePath (Join-Path $app "FingVibe.App.exe") -WorkingDirectory $app -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    do {
        Start-Sleep -Milliseconds 500
        $process.Refresh()
        if ($process.HasExited) { throw "Installed app exited before opening a window: $($process.ExitCode)" }
    } until ($process.MainWindowHandle -ne 0 -or [DateTime]::UtcNow -gt $deadline)
    Assert-True ($process.MainWindowHandle -ne 0) "Installed app did not open a window."
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

    # Emulate the existing ZIP script, including a file the installer must not own.
    $null = New-Item -ItemType Directory -Path $app -Force
    Copy-Item -Path (Join-Path $source "*") -Destination $app -Recurse -Force
    $unknown = Join-Path $app "user-file.txt"
    "keep unknown file" | Set-Content -LiteralPath $unknown
    Invoke-Setup $installer "adopt-script-install" -Extra @("/TASKS=desktopicon")
    Assert-True (Test-Path -LiteralPath $desktopShortcut) "Selected desktop shortcut is missing."
    Assert-True ((Get-Content -LiteralPath $unknown) -eq "keep unknown file") "Adoption removed an unknown file."

    $v = [version] $Version
    if ($v.Build -ge 65533) { throw "Lifecycle fixture versions require two additional build numbers." }
    $next = "$($v.Major).$($v.Minor).$($v.Build + 1)"
    $latest = "$($v.Major).$($v.Minor).$($v.Build + 2)"
    $fixtureApp = Join-Path $fixture "app"
    $null = New-Item -ItemType Directory -Path $fixtureApp
    Copy-Item -Path (Join-Path $source "*") -Destination $fixtureApp -Recurse
    "obsolete managed file" | Set-Content -LiteralPath (Join-Path $fixtureApp "obsolete-test.txt")
    $builder = Join-Path $PSScriptRoot "..\tools\New-Installer.ps1"
    & $builder -AppDirectory $fixtureApp -Version $next -OutputDirectory $fixture | Out-Host
    Invoke-Setup (Join-Path $fixture "FingVibe-$next-win-x64-Setup.exe") "upgrade-with-owned-file"
    Remove-Item -LiteralPath (Join-Path $fixtureApp "obsolete-test.txt")
    & $builder -AppDirectory $fixtureApp -Version $latest -OutputDirectory $fixture | Out-Host
    Invoke-Setup (Join-Path $fixture "FingVibe-$latest-win-x64-Setup.exe") "upgrade-removes-obsolete-file"
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $app "obsolete-test.txt"))) "Upgrade retained obsolete managed file."
    Assert-True ((Get-Content -LiteralPath $unknown) -eq "keep unknown file") "Upgrade changed an unknown file."
    Invoke-Setup $installer "reject-downgrade" -ExpectFailure
    Assert-True ((Get-Content -LiteralPath (Join-Path $logs "reject-downgrade.log") -Raw) -match 'Downgrades are not supported') "Downgrade rejection was not reported."
    Assert-True ((Get-ItemProperty -LiteralPath $registration).DisplayVersion -eq $latest) "Rejected downgrade changed installed version."
    Assert-True ((Get-Content -LiteralPath $savedData) -eq "keep saved data") "Upgrade changed saved data."
    Uninstall-App "upgrade-uninstall"
    Assert-True ((Get-Content -LiteralPath $unknown) -eq "keep unknown file") "Uninstall removed an unknown file."
    Assert-True ((Get-Content -LiteralPath $savedData) -eq "keep saved data") "Uninstall removed saved data."
    Assert-True (-not (Test-Path -LiteralPath $desktopShortcut)) "Desktop shortcut survived uninstall."
    Write-Host "Installer fresh install, launch, adoption, upgrade, downgrade, and uninstall checks passed."
} finally {
    $env:FINGVIBE_UI_REVIEW = $savedReview
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
