[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $AppDirectory,
    [Parameter(Mandatory)]
    [string] $Version,
    [Parameter(Mandatory)]
    [string] $OutputDirectory,
    [string] $CompilerPath = "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe"
)

$ErrorActionPreference = "Stop"
if ($Version -notmatch '^\d+\.\d+\.\d+(\.\d+)?$') {
    throw "Version must contain three or four numeric components."
}
$numericVersion = [version] $Version
$components = @($numericVersion.Major, $numericVersion.Minor, $numericVersion.Build, [Math]::Max(0, $numericVersion.Revision))
if (@($components | Where-Object { $_ -gt 65535 }).Count) {
    throw "Installer version components must not exceed 65535."
}
if (-not (Test-Path -LiteralPath $CompilerPath -PathType Leaf)) {
    throw "Inno Setup 6 compiler not found: $CompilerPath"
}
$source = (Resolve-Path -LiteralPath $AppDirectory).Path
if ((Get-Item -LiteralPath $source).Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw "Published application must not contain reparse points."
}
foreach ($required in @("FingVibe.App.exe", "FingVibe.App.dll", "Assets\Scanner.ico")) {
    if (-not (Test-Path -LiteralPath (Join-Path $source $required) -PathType Leaf)) {
        throw "Published application is missing $required."
    }
}
$output = [IO.Path]::GetFullPath($OutputDirectory)
if ($output.Equals($source, [StringComparison]::OrdinalIgnoreCase) -or
    $output.StartsWith($source + "\", [StringComparison]::OrdinalIgnoreCase)) {
    throw "Installer output must be outside the published application directory."
}
$files = @(Get-ChildItem -LiteralPath $source -Recurse -Force)
if ($files | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }) {
    throw "Published application must not contain reparse points."
}
$relativePaths = @($files | Where-Object { -not $_.PSIsContainer } |
    ForEach-Object { [IO.Path]::GetRelativePath($source, $_.FullName) } | Sort-Object)
if ($relativePaths -contains "_fingvibe-files.txt" -or $relativePaths -match '^unins\d+\.(exe|dat|msg)$') {
    throw "Published application contains reserved installer filenames."
}
$null = New-Item -ItemType Directory -Path $output -Force
$installer = Join-Path $output "FingVibe-$Version-win-x64-Setup.exe"
if (Test-Path -LiteralPath $installer) { Remove-Item -LiteralPath $installer }
$manifestDirectory = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-manifest-$([guid]::NewGuid())"
try {
    $null = New-Item -ItemType Directory -Path $manifestDirectory
    $manifest = Join-Path $manifestDirectory "_fingvibe-files.txt"
    [IO.File]::WriteAllLines($manifest, [string[]] $relativePaths, [Text.UTF8Encoding]::new($true))
    & $CompilerPath /Qp "/DAppVersion=$Version" "/DVersionMS=$(([long] $components[0] -shl 16) + $components[1])" `
        "/DVersionLS=$(([long] $components[2] -shl 16) + $components[3])" `
        "/DSourceDirectory=$source" "/DOutputDirectory=$output" "/DOwnershipManifest=$manifest" `
        (Join-Path $PSScriptRoot "installer\FingVibe.iss")
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed with exit code $LASTEXITCODE." }
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
        throw "Inno Setup did not produce $installer."
    }
    Write-Output $installer
} finally {
    if (Test-Path -LiteralPath $manifestDirectory) {
        Remove-Item -LiteralPath $manifestDirectory -Recurse -Force
    }
}
