param(
    [Parameter(Mandatory)]
    [string]$AppDirectory
)

$ErrorActionPreference = "Stop"
$sourceIcon = Join-Path $PSScriptRoot "..\src\FingVibe.App\Assets\Scanner.ico"
$deployedIcon = Join-Path $AppDirectory "Assets\Scanner.ico"
$executable = Join-Path $AppDirectory "FingVibe.App.exe"

if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    throw "Application executable is missing: $executable"
}
if (-not (Test-Path -LiteralPath $deployedIcon -PathType Leaf)) {
    throw "Runtime window icon is missing: $deployedIcon"
}
if ((Get-FileHash -LiteralPath $sourceIcon).Hash -ne (Get-FileHash -LiteralPath $deployedIcon).Hash) {
    throw "The deployed window icon differs from the source icon."
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class ApplicationIconResources
{
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern uint ExtractIconEx(
        string file, int index, IntPtr largeIcons, IntPtr smallIcons, uint count);
}
'@

if ([ApplicationIconResources]::ExtractIconEx($executable, -1, [IntPtr]::Zero, [IntPtr]::Zero, 0) -eq 0) {
    throw "The executable has no embedded icon."
}

Write-Host "Runtime icon deployment and executable icon resource checks passed."
