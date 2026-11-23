$ErrorActionPreference = "Stop"
if (-not (Get-Command Assert-UiReviewBitmapContent -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScreenshot.ps1")
}

function Assert-BlankCaptureRejected([System.Drawing.Bitmap] $Bitmap) {
    try { Assert-UiReviewBitmapContent -Bitmap $Bitmap }
    catch {
        if ($_.Exception.Message -notlike "*appears blank*") { throw }
        return
    }
    throw "A blank or insufficiently detailed capture was accepted."
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class UiReviewCaptureBoundsFixture
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    public static bool Maximized;
    public static int FrameError;
    public static bool IsZoomed(IntPtr window) { return Maximized; }
    public static bool GetWindowRect(IntPtr window, out RECT rectangle)
    {
        rectangle = Maximized
            ? new RECT { Left = -8, Top = -8, Right = 1928, Bottom = 1040 }
            : new RECT { Left = 20, Top = 30, Right = 1300, Bottom = 750 };
        return true;
    }
    public static int DwmGetWindowAttribute(IntPtr window, uint attribute, out RECT rectangle, int size)
    {
        rectangle = new RECT { Left = 0, Top = 0, Right = 1920, Bottom = 1032 };
        return FrameError;
    }
}
'@
& {
    $getBounds = [scriptblock]::Create((Get-Command Get-UiReviewWindowBounds).Definition.Replace(
        '[UiReviewNativeWindow', '[UiReviewCaptureBoundsFixture'))
    foreach ($maximized in @($false, $true)) {
        [UiReviewCaptureBoundsFixture]::Maximized = $maximized
        $expected = if ($maximized) { [Drawing.Rectangle]::new(0, 0, 1920, 1032) }
            else { [Drawing.Rectangle]::new(20, 30, 1280, 720) }
        $actual = & $getBounds -WindowHandle ([IntPtr]::Zero)
        if ($actual -ne $expected) { throw "Capture must preserve restored bounds and exclude only the invisible maximized border." }
    }
    [UiReviewCaptureBoundsFixture]::FrameError = -2147467259
    $rejected = $false
    try { $null = & $getBounds -WindowHandle ([IntPtr]::Zero) }
    catch {
        if ($_.Exception.InnerException.HResult -ne -2147467259) { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw "Failed DWM bounds must not become a successful or clipped capture." }
}

$area = [System.Drawing.Rectangle]::new(0, 0, 1920, 1080)
$narrow = [System.Drawing.Rectangle]::new(0, 0, 480, 720)
try {
    Assert-UiReviewWindowBounds -Bounds $narrow -WorkingArea $area
    throw "Default capture bounds must still reject a 480-pixel window."
}
catch {
    if ($_.Exception.Message -notlike "*too small*") { throw }
}
Assert-UiReviewWindowBounds -Bounds $narrow -WorkingArea $area -MinimumWidth 480
foreach ($bounds in @(
    [System.Drawing.Rectangle]::new(0, 0, 479, 720),
    [System.Drawing.Rectangle]::new(0, 0, 480, 479),
    [System.Drawing.Rectangle]::new(1800, 0, 480, 720)
)) {
    $rejected = $false
    try { Assert-UiReviewWindowBounds -Bounds $bounds -WorkingArea $area -MinimumWidth 480 }
    catch {
        if ($_.Exception.Message -notlike "*too small*" -and
            $_.Exception.Message -notlike "*not inside the monitor working area*") { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw "Narrow capture must preserve minimum dimensions and complete-window containment." }
}

foreach ($size in @([System.Drawing.Size]::new(480, 720), [System.Drawing.Size]::new(640, 480), [System.Drawing.Size]::new(1024, 720))) {
    $bitmap = [System.Drawing.Bitmap]::new($size.Width, $size.Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $font = [System.Drawing.Font]::new("Segoe UI", 16)
    try {
        foreach ($background in @([System.Drawing.Color]::Black, [System.Drawing.Color]::White)) {
            $graphics.Clear($background)
            Assert-BlankCaptureRejected $bitmap
        }

        # A few isolated pixels are not evidence of a rendered page.
        $bitmap.SetPixel(0, 0, [System.Drawing.Color]::Black)
        $bitmap.SetPixel(8, 6, [System.Drawing.Color]::Black)
        Assert-BlankCaptureRejected $bitmap

        # A low-color stripe pattern has variation in only one direction.
        $graphics.Clear([System.Drawing.Color]::Black)
        for ($x = 0; $x -lt $bitmap.Width; $x += 32) {
            $graphics.FillRectangle([System.Drawing.Brushes]::White, $x, 0, 16, $bitmap.Height)
        }
        Assert-BlankCaptureRejected $bitmap

        foreach ($inverted in @($false, $true)) {
            $background = if ($inverted) { [System.Drawing.Color]::White } else { [System.Drawing.Color]::Black }
            $foreground = if ($inverted) { [System.Drawing.Brushes]::Black } else { [System.Drawing.Brushes]::White }
            $graphics.Clear($background)
            $graphics.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::SingleBitPerPixelGridFit
            for ($y = 30; $y -lt $bitmap.Height - 30; $y += 48) {
                $graphics.DrawString("FingVibe high contrast - Scan LAN - Devices", $font, $foreground, 30, $y)
            }
            $colors = [System.Collections.Generic.HashSet[int]]::new()
            for ($x = 0; $x -lt $bitmap.Width; $x += [int]($bitmap.Width / 20)) {
                for ($y = 0; $y -lt $bitmap.Height; $y += [int]($bitmap.Height / 20)) {
                    $null = $colors.Add($bitmap.GetPixel($x, $y).ToArgb())
                }
            }
            if ($colors.Count -ge 8) { throw "The monochrome fixture must reproduce the former color-count rejection." }
            Assert-UiReviewBitmapContent -Bitmap $bitmap
        }

        $graphics.Clear([System.Drawing.Color]::Black)
        for ($x = 0; $x -lt $bitmap.Width; $x += 16) {
            $brush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb($x % 256, 80, 120))
            try { $graphics.FillRectangle($brush, $x, 0, 16, $bitmap.Height) }
            finally { $brush.Dispose() }
        }
        Assert-UiReviewBitmapContent -Bitmap $bitmap
    }
    finally {
        $font.Dispose()
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

Write-Host "Screenshot content checks passed without desktop automation (blank, sparse, stripes, monochrome text, and color)."
