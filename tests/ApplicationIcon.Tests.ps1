param(
    [Parameter(Mandatory)]
    [string]$AppDirectory
)

$ErrorActionPreference = "Stop"
$sourceIcon = Join-Path $PSScriptRoot "..\src\FingVibe.App\Assets\Scanner.ico"
$deployedIcon = Join-Path $AppDirectory "Assets\Scanner.ico"
$executable = Join-Path $AppDirectory "FingVibe.App.exe"
$requiredSizes = @(16, 20, 24, 32, 40, 48, 64, 256)

Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class ApplicationIconResources
{
    private delegate bool EnumResNameProc(IntPtr module, IntPtr type, IntPtr name, IntPtr parameter);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadLibraryEx(string file, IntPtr reserved, uint flags);
    [DllImport("kernel32.dll")]
    private static extern bool FreeLibrary(IntPtr module);
    [DllImport("kernel32.dll")]
    private static extern bool EnumResourceNames(IntPtr module, IntPtr type, EnumResNameProc callback, IntPtr parameter);
    [DllImport("kernel32.dll")]
    private static extern IntPtr FindResource(IntPtr module, IntPtr name, IntPtr type);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LockResource(IntPtr data);
    [DllImport("kernel32.dll")]
    private static extern uint SizeofResource(IntPtr module, IntPtr resource);

    private static byte[] Read(IntPtr module, IntPtr name, int type)
    {
        IntPtr resource = FindResource(module, name, new IntPtr(type));
        if (resource == IntPtr.Zero) throw new InvalidOperationException("Icon resource is missing.");
        var bytes = new byte[SizeofResource(module, resource)];
        Marshal.Copy(LockResource(LoadResource(module, resource)), bytes, 0, bytes.Length);
        return bytes;
    }

    // Returns each frame of the executable's first icon group, keyed by pixel size.
    public static Dictionary<int, byte[]> ReadFirstIconGroup(string executable)
    {
        IntPtr module = LoadLibraryEx(executable, IntPtr.Zero, 0x2 | 0x20);
        if (module == IntPtr.Zero) throw new InvalidOperationException("Cannot load executable resources.");
        var frames = new Dictionary<int, byte[]>();
        try
        {
            EnumResourceNames(module, new IntPtr(14), (m, t, name, p) =>
            {
                byte[] group = Read(m, name, 14);
                int count = BitConverter.ToUInt16(group, 4);
                for (int i = 0; i < count; i++)
                {
                    int entry = 6 + i * 14;
                    int size = group[entry] == 0 ? 256 : group[entry];
                    frames[size] = Read(m, new IntPtr(BitConverter.ToUInt16(group, entry + 12)), 3);
                }
                return false;
            }, IntPtr.Zero);
        }
        finally { FreeLibrary(module); }
        return frames;
    }
}
'@

function Read-IconFrames([string] $Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ([BitConverter]::ToUInt16($bytes, 0) -ne 0 -or [BitConverter]::ToUInt16($bytes, 2) -ne 1) {
        throw "$Path is not an icon file."
    }
    $frames = @{}
    for ($i = 0; $i -lt [BitConverter]::ToUInt16($bytes, 4); $i++) {
        $entry = 6 + 16 * $i
        $size = if ($bytes[$entry] -eq 0) { 256 } else { [int]$bytes[$entry] }
        if ($frames.ContainsKey($size)) { throw "Icon frame ${size}px is duplicated." }
        if ([BitConverter]::ToUInt16($bytes, $entry + 4) -ne 1 -or [BitConverter]::ToUInt16($bytes, $entry + 6) -ne 32) {
            throw "Icon frame ${size}px must be a 32-bit image."
        }
        $length = [BitConverter]::ToInt32($bytes, $entry + 8)
        $frames[$size] = [byte[]]$bytes[[BitConverter]::ToInt32($bytes, $entry + 12)..([BitConverter]::ToInt32($bytes, $entry + 12) + $length - 1)]
    }
    $frames
}

function Get-IconFrameAlpha([int] $Size, [byte[]] $Frame) {
    $alpha = [byte[]]::new($Size * $Size)
    if ($Frame[0] -eq 0x89 -and $Frame[1] -eq 0x50) {
        $bitmap = [System.Drawing.Bitmap]::new([IO.MemoryStream]::new($Frame))
        try {
            if ($bitmap.Width -ne $Size -or $bitmap.Height -ne $Size) { throw "PNG frame ${Size}px has the wrong dimensions." }
            for ($y = 0; $y -lt $Size; $y++) { for ($x = 0; $x -lt $Size; $x++) { $alpha[$y * $Size + $x] = $bitmap.GetPixel($x, $y).A } }
        }
        finally { $bitmap.Dispose() }
        return , $alpha
    }
    if ([BitConverter]::ToInt32($Frame, 4) -ne $Size -or [BitConverter]::ToInt32($Frame, 8) -ne $Size * 2 -or
        [BitConverter]::ToUInt16($Frame, 14) -ne 32) {
        throw "Bitmap frame ${Size}px must be a ${Size}x${Size} 32-bit image."
    }
    $pixels = [BitConverter]::ToInt32($Frame, 0)
    for ($row = 0; $row -lt $Size; $row++) {
        for ($x = 0; $x -lt $Size; $x++) { $alpha[($Size - 1 - $row) * $Size + $x] = $Frame[$pixels + ($row * $Size + $x) * 4 + 3] }
    }
    , $alpha
}

# Frame inventory, transparency and composition checks on the committed source icon.
$frames = Read-IconFrames $sourceIcon
$actualSizes = @($frames.Keys | Sort-Object)
if (($actualSizes -join ",") -ne ($requiredSizes -join ",")) {
    throw "Icon frames are $($actualSizes -join ', ') px; expected $($requiredSizes -join ', ') px."
}
$hashes = @{}
foreach ($size in $requiredSizes) {
    $alpha = Get-IconFrameAlpha $size $frames[$size]
    $last = $size - 1
    foreach ($corner in @(0, $last, ($last * $size), ($size * $size - 1))) {
        if ($alpha[$corner] -ne 0) { throw "Icon frame ${size}px has an opaque corner." }
    }
    if (@($alpha | Where-Object { $_ -gt 0 -and $_ -lt 255 }).Count -eq 0) { throw "Icon frame ${size}px has no partial alpha." }
    $left = $size; $right = -1; $top = $size; $bottom = -1
    for ($y = 0; $y -lt $size; $y++) {
        for ($x = 0; $x -lt $size; $x++) {
            if ($alpha[$y * $size + $x] -ge 128) {
                $left = [Math]::Min($left, $x); $right = [Math]::Max($right, $x)
                $top = [Math]::Min($top, $y); $bottom = [Math]::Max($bottom, $y)
            }
        }
    }
    if ($right -lt 0 -or ($right - $left + 1) -lt $size * 0.9 -or ($bottom - $top + 1) -lt $size * 0.9) {
        throw "Icon frame ${size}px leaves excessive transparent padding."
    }
    $hash = [Convert]::ToBase64String([Security.Cryptography.SHA256]::Create().ComputeHash($frames[$size]))
    if ($hashes.ContainsKey($hash)) { throw "Icon frame ${size}px duplicates the $($hashes[$hash])px frame." }
    $hashes[$hash] = $size
}

if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    throw "Application executable is missing: $executable"
}
if (-not (Test-Path -LiteralPath $deployedIcon -PathType Leaf)) {
    throw "Runtime window icon is missing: $deployedIcon"
}
if ((Get-FileHash -LiteralPath $sourceIcon).Hash -ne (Get-FileHash -LiteralPath $deployedIcon).Hash) {
    throw "The deployed window icon differs from the source icon."
}

$embedded = [ApplicationIconResources]::ReadFirstIconGroup((Resolve-Path -LiteralPath $executable).Path)
if ($embedded.Count -eq 0) { throw "The executable has no embedded icon." }
$embeddedSizes = @($embedded.Keys | Sort-Object)
if (($embeddedSizes -join ",") -ne ($requiredSizes -join ",")) {
    throw "Embedded icon frames are $($embeddedSizes -join ', ') px; expected $($requiredSizes -join ', ') px."
}
foreach ($size in $requiredSizes) {
    if ([Convert]::ToBase64String($embedded[$size]) -ne [Convert]::ToBase64String($frames[$size])) {
        throw "Embedded ${size}px icon frame differs from the deployed icon."
    }
}

Write-Host "Icon frames ($($requiredSizes -join ', ') px), transparency, deployment and embedded executable icon checks passed."
