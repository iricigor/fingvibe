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
foreach ($brand in @(@{ Name = "ConnectedHome-48.png"; Size = 96 }, @{ Name = "ConnectedHome.png"; Size = 256 })) {
    $source = Join-Path $PSScriptRoot "..\src\FingVibe.App\Assets\$($brand.Name)"
    $deployed = Join-Path $AppDirectory "Assets\$($brand.Name)"
    if (-not (Test-Path -LiteralPath $deployed -PathType Leaf) -or
        (Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $deployed).Hash) {
        throw "In-app brand image $($brand.Name) is missing or differs from the source."
    }
    $image = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $deployed).Path)
    try {
        if ($image.Width -ne $brand.Size -or $image.Height -ne $brand.Size -or
            -not [System.Drawing.Image]::IsAlphaPixelFormat($image.PixelFormat)) {
            throw "In-app brand image $($brand.Name) must be a $($brand.Size) px image with alpha."
        }
    }
    finally { $image.Dispose() }
}

# Page-family icons load by ms-appx URI at runtime, so the published payload must carry every referenced file.
$appSource = Join-Path $PSScriptRoot "..\src\FingVibe.App"
$pageIconSource = Join-Path $appSource "Assets\PageIcons"
$pageIcons = @(Get-ChildItem -LiteralPath $pageIconSource -Filter *.png -File)
if ($pageIcons.Count -eq 0) { throw "No page-family icons were found in $pageIconSource." }
$pageIconConcepts = Join-Path $PSScriptRoot "..\docs\branding\icon-concepts"
foreach ($icon in $pageIcons | Where-Object Name -like "*-color.png") {
    $source = Join-Path $pageIconConcepts $icon.Name
    $svg = [IO.Path]::ChangeExtension($source, ".svg")
    if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or -not (Test-Path -LiteralPath $svg -PathType Leaf)) {
        throw "Full-color PageIcon $($icon.Name) must retain matching concept PNG and SVG masters."
    }
    if ((Get-FileHash -LiteralPath $icon.FullName).Hash -ne (Get-FileHash -LiteralPath $source).Hash) {
        throw "Runtime PageIcon $($icon.Name) differs from its documented 256 px master."
    }
    $vector = Get-Content -LiteralPath $svg -Raw
    if ($vector -notmatch 'stroke="none"' -or $vector -match 'stroke="#38577B"') {
        throw "Full-color PageIcon $($icon.Name) must not retain the halo-producing #38577B tile stroke."
    }
    $bitmap = [Drawing.Bitmap]::new((Resolve-Path -LiteralPath $icon.FullName).Path)
    try {
        if ($bitmap.Width -ne 256 -or $bitmap.Height -ne 256) {
            throw "Full-color PageIcon $($icon.Name) must remain 256 x 256."
        }
        foreach ($coordinate in 60..195) {
            $points = @(
                [Drawing.Point]::new($coordinate, 15),
                [Drawing.Point]::new($coordinate, 16),
                [Drawing.Point]::new($coordinate, 239),
                [Drawing.Point]::new($coordinate, 240),
                [Drawing.Point]::new(15, $coordinate),
                [Drawing.Point]::new(16, $coordinate),
                [Drawing.Point]::new(239, $coordinate),
                [Drawing.Point]::new(240, $coordinate)
            )
            foreach ($point in $points) {
                $color = $bitmap.GetPixel($point.X, $point.Y)
                if ($color.A -gt 32 -and $color.G -gt 70 -and $color.B -gt 105) {
                    throw "Full-color PageIcon $($icon.Name) contains a pale tile-edge halo pixel at $point."
                }
            }
        }
    }
    finally { $bitmap.Dispose() }
}
$referenced = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($xaml in Get-ChildItem -LiteralPath $appSource -Filter *.xaml -File -Recurse |
    Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' }) {
    $text = Get-Content -LiteralPath $xaml.FullName -Raw
    foreach ($match in [regex]::Matches($text, 'ms-appx:///Assets/PageIcons/([A-Za-z0-9-]+\.png)')) {
        $null = $referenced.Add($match.Groups[1].Value)
    }
    # PageHeaderIcon resolves Icon="name" to name-color.png and name-mono.png.
    foreach ($match in [regex]::Matches($text, '<local:PageHeaderIcon\b[^>]*\bIcon="([A-Za-z0-9-]+)"')) {
        $null = $referenced.Add("$($match.Groups[1].Value)-color.png")
        $null = $referenced.Add("$($match.Groups[1].Value)-mono.png")
    }
}
if ($referenced.Count -eq 0) { throw "No page-family icon references were found; the reference scan is out of date." }
foreach ($name in $referenced) {
    if (-not (Test-Path -LiteralPath (Join-Path $pageIconSource $name) -PathType Leaf)) {
        throw "Page-family icon $name is referenced but missing from the source assets."
    }
}
# BitmapIcon point-samples monochrome masks, so 16-DIP sidebar icons need 2x (32 px) art to stay legible.
$mainWindow = Get-Content -LiteralPath (Join-Path $appSource "MainWindow.xaml") -Raw
$sidebarIcons = @([regex]::Matches($mainWindow,
        '<BitmapIcon\b[^>]*\bUriSource="ms-appx:///Assets/PageIcons/([A-Za-z0-9-]+\.png)"') |
    ForEach-Object { $_.Groups[1].Value })
if ($sidebarIcons.Count -ne 5) { throw "Expected five sidebar family BitmapIcons; found $($sidebarIcons.Count)." }
foreach ($name in $sidebarIcons) {
    $image = [System.Drawing.Image]::FromFile((Join-Path $pageIconSource $name))
    try {
        if ($name -notlike "*-mono-32.png" -or $image.Width -ne 32 -or $image.Height -ne 32 -or
            -not [System.Drawing.Image]::IsAlphaPixelFormat($image.PixelFormat)) {
            throw "Sidebar icon $name must be a 32 px single-color mask with alpha."
        }
    }
    finally { $image.Dispose() }
}
foreach ($icon in $pageIcons) {
    $deployed = Join-Path $AppDirectory "Assets\PageIcons\$($icon.Name)"
    if (-not (Test-Path -LiteralPath $deployed -PathType Leaf) -or
        (Get-FileHash -LiteralPath $icon.FullName).Hash -ne (Get-FileHash -LiteralPath $deployed).Hash) {
        throw "Page-family icon Assets\PageIcons\$($icon.Name) is missing from or differs in the published payload."
    }
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

Write-Host "Icon frames ($($requiredSizes -join ', ') px), transparency, deployment, in-app brand images, $($pageIcons.Count) page-family icons and embedded executable icon checks passed."
