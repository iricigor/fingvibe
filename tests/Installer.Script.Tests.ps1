$ErrorActionPreference = "Stop"
$builder = Join-Path $PSScriptRoot "..\tools\New-Installer.ps1"
$fixture = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-installer-script-$([guid]::NewGuid())"
function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected failure matching '$Pattern'."
}
try {
    $app = Join-Path $fixture "app"
    $output = Join-Path $fixture "output"
    $null = New-Item -ItemType Directory -Path (Join-Path $app "Assets") -Force
    foreach ($path in @("FingVibe.App.exe", "FingVibe.App.dll", "Assets\Scanner.ico")) {
        "fixture" | Set-Content -LiteralPath (Join-Path $app $path)
    }
    $compiler = Join-Path $fixture "compiler.ps1"
    @'
$options = @{}
foreach ($arg in $args) {
    if ($arg -match '^/D([^=]+)=(.*)$') { $options[$Matches[1]] = $Matches[2] }
}
$manifest = @(Get-Content -LiteralPath $options.OwnershipManifest)
if (($manifest -join '|') -ne 'Assets\Scanner.ico|FingVibe.App.dll|FingVibe.App.exe') {
    throw "Unexpected ownership manifest: $manifest"
}
if ($options.VersionMS -ne 65538 -or $options.VersionLS -ne 196612) {
    throw "Incorrect packed version components."
}
$options | ConvertTo-Json | Set-Content (Join-Path $options.OutputDirectory "compiler-options.json")
"fixture" | Set-Content (Join-Path $options.OutputDirectory "FingVibe-$($options.AppVersion)-win-x64-Setup.exe")
$global:LASTEXITCODE = 0
'@ | Set-Content -LiteralPath $compiler
    $parameters = @{ AppDirectory = $app; OutputDirectory = $output; Version = "1.2.3.4"; CompilerPath = $compiler }
    $installer = & $builder @parameters
    if (-not (Test-Path -LiteralPath $installer)) { throw "Installer output was not returned." }
    if (Test-Path -LiteralPath (Join-Path $app "_fingvibe-files.txt")) {
        throw "Packaging must not modify the ZIP's publish output."
    }
    $defaults = Get-Content -LiteralPath (Join-Path $output "compiler-options.json") -Raw | ConvertFrom-Json
    if ($defaults.PSObject.Properties.Name -contains "Compression" -or $defaults.PSObject.Properties.Name -contains "SolidCompression") {
        throw "Release/PR packaging must keep the script's production compression defaults."
    }
    $null = & $builder @parameters -FixtureCompression
    $fast = Get-Content -LiteralPath (Join-Path $output "compiler-options.json") -Raw | ConvertFrom-Json
    if ($fast.Compression -ne "none" -or $fast.SolidCompression -ne "no") {
        throw "Test fixtures must request uncompressed, non-solid packaging explicitly."
    }
    Remove-Item -LiteralPath (Join-Path $output "compiler-options.json")
    $script = Get-Content -LiteralPath (Join-Path $PSScriptRoot "..\tools\installer\FingVibe.iss") -Raw
    foreach ($pattern in @('(?m)^\s*#define Compression "lzma2"\s*$', '(?m)^\s*#define SolidCompression "yes"\s*$',
        '(?m)^Compression=\{#Compression\}\s*$', '(?m)^SolidCompression=\{#SolidCompression\}\s*$')) {
        if ($script -notmatch $pattern) { throw "Installer script must default to LZMA2/solid compression: $pattern" }
    }
    $runSection = [regex]::Match($script, '(?ms)^\[Run\]\s*\r?\n(.*?)(?=^\[|\z)')
    $runEntries = @($runSection.Groups[1].Value -split '\r?\n' | Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith(';') })
    if (-not $runSection.Success -or $runEntries.Count -ne 1) {
        throw "Installer must have exactly one optional post-install launch entry."
    }
    $run = $runEntries[0]
    foreach ($parameter in @('Filename: "{app}\FingVibe.App.exe"', 'WorkingDir: "{app}"', 'Description: "Start FingVibe"')) {
        if (-not $run.Contains($parameter)) { throw "Installer launch is missing $parameter." }
    }
    $flags = [regex]::Match($run, '(?:^|;)\s*Flags:\s*([^;]+)').Groups[1].Value.Trim() -split '\s+'
    if (@($flags | Sort-Object) -join ' ' -cne 'nowait postinstall skipifsilent') {
        throw "Launch must be checked by default, wait for Finish, never wait for app exit, and skip both silent modes."
    }
    # Published installers never use fixture compression; fixtures are built only into the lifecycle's temporary directory.
    foreach ($workflow in @("ci.yml", "release.yml", "native-validation.yml")) {
        $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot "..\.github\workflows\$workflow") -Raw
        $calls = [regex]::Matches($text, '(?m)^.*New-Installer\.ps1.*$')
        if ($calls.Count -ne 1 -or $calls[0].Value -match 'FixtureCompression' -or $calls[0].Value -notmatch '-OutputDirectory artifacts\\installer') {
            throw "$workflow must build exactly one production-compressed installer into artifacts\installer."
        }
    }
    $lifecycle = Get-Content -LiteralPath (Join-Path $PSScriptRoot "Installer.Lifecycle.Tests.ps1") -Raw
    $parseErrors = $null
    $lifecycleAst = [Management.Automation.Language.Parser]::ParseInput($lifecycle, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) { throw "Installer lifecycle must parse: $parseErrors" }
    $lookup = $lifecycleAst.FindAll({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -in @(
                'Get-InstallerCaption', 'Get-InstallerButton',
                'Get-UninstallerExecutable', 'Resolve-RegisteredUninstaller',
                'New-LifecycleFixtureApp'
            )
    }, $true)
    foreach ($definition in $lookup) { Invoke-Expression $definition.Extent.Text }
    # Inno Setup 6.7 renders "&Next"; keep older "&Next >" captions working.
    foreach ($caption in @('&Next', '&Next >', '&Install', '&Finish')) {
        $button = [pscustomobject]@{ Handle = 1; Text = $caption; ClassName = 'TNewButton'; Visible = $true; Enabled = $true }
        $hidden = [pscustomobject]@{ Handle = 2; Text = $caption; ClassName = 'TNewButton'; Visible = $false; Enabled = $true }
        $disabled = [pscustomobject]@{ Handle = 3; Text = $caption; ClassName = 'TNewButton'; Visible = $true; Enabled = $false }
        $label = [pscustomobject]@{ Handle = 4; Text = $caption; ClassName = 'TNewStaticText'; Visible = $true; Enabled = $true }
        $names = @('Next', 'Install', 'Finish')
        $actual = Get-InstallerButton @($hidden, $disabled, $label, $button) $names
        if ($actual.Handle -ne 1) { throw "Native wizard lookup must select the visible, enabled action by caption and class." }
        if ($null -ne (Get-InstallerButton @($hidden, $disabled, $label) $names)) {
            throw "Hidden, disabled or non-button controls cannot advance the installer."
        }
        Assert-Throws { Get-InstallerButton @($button, $button) $names } '*More than one installer navigation button*'
    }
    $cancel = [pscustomobject]@{ Text = 'Cancel'; ClassName = 'TNewButton'; Visible = $true; Enabled = $true }
    if ($null -ne (Get-InstallerButton @($cancel) @('Next', 'Install', 'Finish'))) {
        throw "The lifecycle must not activate unrelated installer actions."
    }
    $registeredApp = Join-Path $fixture "registered app"
    $outsideApp = Join-Path $fixture "outside app"
    $null = New-Item -ItemType Directory -Path $registeredApp, $outsideApp -Force
    $numberedUninstaller = Join-Path $registeredApp "unins001.exe"
    $outsideUninstaller = Join-Path $outsideApp "unins002.exe"
    "fixture" | Set-Content -LiteralPath $numberedUninstaller
    "fixture" | Set-Content -LiteralPath $outsideUninstaller
    $registrationInfo = [pscustomobject]@{ UninstallString = "`"$numberedUninstaller`" /quiet" }
    if ((Resolve-RegisteredUninstaller $registrationInfo $registeredApp) -ne $numberedUninstaller) {
        throw "Lifecycle uninstall lookup must accept the registered numbered uninstaller and arguments."
    }
    if ((Get-UninstallerExecutable $registrationInfo.UninstallString) -ne $numberedUninstaller) {
        throw "Lifecycle uninstall command parsing must preserve a quoted path."
    }
    Assert-Throws { Resolve-RegisteredUninstaller ([pscustomobject]@{}) $registeredApp } '*UninstallString*'
    Assert-Throws { Resolve-RegisteredUninstaller ([pscustomobject]@{ UninstallString = "not a command" }) $registeredApp } '*Could not parse*'
    Assert-Throws { Resolve-RegisteredUninstaller ([pscustomobject]@{ UninstallString = "`"$outsideUninstaller`"" }) $registeredApp } '*outside*'
    Assert-Throws { Resolve-RegisteredUninstaller ([pscustomobject]@{ UninstallString = "`"$registeredApp\setup.exe`"" }) $registeredApp } '*Inno Setup uninstaller*'
    if ($lifecycle -match 'unins000\.exe') {
        throw "Lifecycle orchestration must not hardcode Inno's first uninstaller filename."
    }
    $invokeCalls = [regex]::Matches($lifecycle, '(?m)^\s*Invoke-Installer\b.*$')
    if ($invokeCalls.Count -eq 0) { throw "Lifecycle must use the explicit installer operation helper." }
    foreach ($call in $invokeCalls) {
        if ($call.Value -notmatch '-Operation\s+(Install|Uninstall)') {
            throw "Every lifecycle installer invocation must identify its operation: $call"
        }
    }
    foreach ($pattern in @('/SECONDPHASE=', 'Log closed', 'Get-InnoSecondPhaseProcesses')) {
        if (-not $lifecycle.Contains($pattern)) {
            throw "Uninstall synchronization is missing $pattern."
        }
    }
    $launchFixture = New-LifecycleFixtureApp $app (Join-Path $fixture "launch fixture")
    foreach ($required in @("FingVibe.App.exe", "FingVibe.App.dll", "Assets\Scanner.ico")) {
        if (-not (Test-Path -LiteralPath (Join-Path $launchFixture $required) -PathType Leaf)) {
            throw "Lifecycle launch fixture is missing $required."
        }
    }
    $fixtureCalls = [regex]::Matches($lifecycle, '(?m)^.*& \$builder .*$')
    if ($fixtureCalls.Count -ne 1 -or $fixtureCalls[0].Value -notmatch '-OutputDirectory \$fixture -FixtureCompression') {
        throw "Lifecycle fixtures must use fixture compression and the disposable fixture directory only."
    }
    $family = [regex]::Match($lifecycle, '(?m)^\$FeatureFamily = "(\d+\.\d+)"\s*$')
    $release = Get-Content -LiteralPath (Join-Path $PSScriptRoot "..\.github\workflows\release.yml") -Raw
    if (-not $family.Success -or $release -notmatch ('"number=' + [regex]::Escape($family.Groups[1].Value) + '\.\$\{\{ github\.run_number \}\}"')) {
        throw "The lifecycle feature family must match the release version family."
    }
    if ([regex]::Matches($lifecycle, '"\d+\.\d+"').Count -ne 1) {
        throw "Fixture versions must derive from the single feature-family definition."
    }
    Assert-Throws { & $builder @parameters -Version "1.2" } "*three or four*"
    Assert-Throws { & $builder @parameters -Version "1.2.65536" } "*must not exceed*"
    Assert-Throws { & $builder @parameters -CompilerPath (Join-Path $fixture "missing.exe") } "*compiler not found*"
    Assert-Throws { & $builder @parameters -OutputDirectory (Join-Path $app "setup") } "*outside*"
    "reserved" | Set-Content -LiteralPath (Join-Path $app "_fingvibe-files.txt")
    Assert-Throws { & $builder @parameters } "*reserved*"
    Remove-Item -LiteralPath (Join-Path $app "_fingvibe-files.txt")
    Remove-Item -LiteralPath (Join-Path $app "Assets\Scanner.ico")
    Assert-Throws { & $builder @parameters } "*missing Assets*"
    "throw 'simulated compiler failure'" | Set-Content -LiteralPath $compiler
    "icon" | Set-Content -LiteralPath (Join-Path $app "Assets\Scanner.ico")
    Assert-Throws { & $builder @parameters } "*simulated compiler failure*"
    '$global:LASTEXITCODE = 12' | Set-Content -LiteralPath $compiler
    Assert-Throws { & $builder @parameters } "*exit code 12*"
    "stale output" | Set-Content -LiteralPath $installer
    '$global:LASTEXITCODE = 0' | Set-Content -LiteralPath $compiler
    Assert-Throws { & $builder @parameters } "*did not produce*"
} finally {
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
Write-Host "Installer packaging script tests passed."
