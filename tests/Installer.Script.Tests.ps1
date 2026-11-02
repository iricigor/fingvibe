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
"fixture" | Set-Content (Join-Path $options.OutputDirectory "FingVibe-$($options.AppVersion)-win-x64-Setup.exe")
$global:LASTEXITCODE = 0
'@ | Set-Content -LiteralPath $compiler
    $parameters = @{ AppDirectory = $app; OutputDirectory = $output; Version = "1.2.3.4"; CompilerPath = $compiler }
    $installer = & $builder @parameters
    if (-not (Test-Path -LiteralPath $installer)) { throw "Installer output was not returned." }
    if (Test-Path -LiteralPath (Join-Path $app "_fingvibe-files.txt")) {
        throw "Packaging must not modify the ZIP's publish output."
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
