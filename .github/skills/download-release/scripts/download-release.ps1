[CmdletBinding()]
param(
    [ValidateSet('iricigor/fingvibe')]
    [string] $Repo = 'iricigor/fingvibe',

    [ValidatePattern('(?i)^[A-Za-z0-9][A-Za-z0-9._ -]*\.exe$')]
    [string] $AssetName,

    [string] $Tag,

    [string] $DownloadRoot = (Join-Path $HOME 'Downloads'),

    [switch] $Run
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'This script must run locally on Windows.'
}
foreach ($indicator in @('CI', 'GITHUB_ACTIONS', 'CODESPACES', 'SSH_CONNECTION', 'SSH_CLIENT', 'SSH_TTY')) {
    $value = [Environment]::GetEnvironmentVariable($indicator)
    if ($value -and $value -notin @('false', '0')) {
        throw "Cloud/remote execution detected ($indicator). Provide the command for the user's local Windows machine instead."
    }
}
if ($null -ne (Get-Variable PSSenderInfo -ValueOnly -ErrorAction SilentlyContinue)) {
    throw "PowerShell remoting detected. Provide the command for the user's local Windows machine instead."
}
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI (gh) is required. Install it locally before using this skill.'
}

& gh auth status
if ($LASTEXITCODE -ne 0) {
    throw 'GitHub authentication failed. Existing GitHub CLI access is required; nothing was downloaded or launched.'
}

$viewArgs = @('release', 'view', '--repo', $Repo, '--json', 'tagName,url,assets,isDraft,isPrerelease')
if ($Tag) { $viewArgs += @('--', $Tag) }
$json = & gh @viewArgs
if ($LASTEXITCODE -ne 0) {
    throw 'Could not read the release. Check repository access, the tag, and gh authentication.'
}
$release = ($json -join "`n") | ConvertFrom-Json
if ($release.isDraft -or (-not $Tag -and $release.isPrerelease)) {
    throw 'Expected a published stable release (or an explicitly selected published tag).'
}
if ([string]::IsNullOrWhiteSpace($release.tagName) -or [string]::IsNullOrWhiteSpace($release.url)) {
    throw 'Release metadata is missing its tag or URL.'
}

$executables = @($release.assets | Where-Object { $_.name -match '(?i)\.exe$' })
$assets = @(if ($AssetName) {
    $executables | Where-Object { $_.name -ceq $AssetName }
} else {
    $executables
})
if ($assets.Count -eq 0) {
    throw "No matching Windows EXE asset was found in release '$($release.tagName)'."
}
if ($assets.Count -ne 1) {
    throw "Ambiguous EXE selection. Ask the user which exact asset to use, then pass -AssetName. Choices: $($assets.name -join ', ')"
}
$selectedName = $assets[0].name
if ($selectedName -notmatch '(?i)^[A-Za-z0-9][A-Za-z0-9._ -]*\.exe$') {
    throw "Unsafe EXE asset filename '$selectedName'; paths and wildcard patterns are not allowed."
}

$checkout = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\..')).TrimEnd('\')
$root = [IO.Path]::GetFullPath($DownloadRoot)
if ($root -notmatch '^[A-Za-z]:\\' -or $root.Substring(3) -match '[<>:"|?*]|[. ](\\|$)') {
    throw 'DownloadRoot must be an ordinary local drive path without redirected or ambiguous path syntax.'
}
if ($root.Length -gt 3) { $root = $root.TrimEnd('\') }
if ($root -ieq $checkout -or $root.StartsWith($checkout + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'DownloadRoot must be outside the checkout.'
}
$ancestor = $root
while ($ancestor) {
    if (Test-Path -LiteralPath $ancestor) {
        $item = Get-Item -LiteralPath $ancestor -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "DownloadRoot must use ordinary directories, not files, symlinks, or junctions: '$ancestor'."
        }
    }
    $ancestor = Split-Path -Path $ancestor -Parent
}
$destination = Join-Path $root ('github-release-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $destination | Out-Null

$downloadArgs = @('release', 'download', '--repo', $Repo, '--pattern', $selectedName, '--dir', $destination, '--', $release.tagName)
& gh @downloadArgs
if ($LASTEXITCODE -ne 0) {
    throw "Download failed. Any partial files remain in '$destination'; nothing was unblocked or launched."
}
$exe = Join-Path $destination $selectedName
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw "The expected executable was not downloaded to '$exe'; nothing was launched."
}
$file = Get-Item -LiteralPath $exe -Force
if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw 'The downloaded executable must not be a symlink or reparse point.'
}
if ($file.Length -eq 0) {
    throw 'The downloaded executable is empty; nothing was launched.'
}
$downloads = @(Get-ChildItem -LiteralPath $destination -Force)
if ($downloads.Count -ne 1 -or $downloads[0].Name -cne $selectedName) {
    throw 'Expected exactly one downloaded EXE and no other files; nothing was launched.'
}

$hash = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
Write-Output "Release: $($release.url)"
Write-Output "Tag: $($release.tagName)"
Write-Output "File: $exe"
Write-Output "SHA-256 (informational, not verification against a trusted hash): $hash"

if ($Run) {
    Unblock-File -LiteralPath $exe
    Start-Process -FilePath $exe -WorkingDirectory $destination
}
