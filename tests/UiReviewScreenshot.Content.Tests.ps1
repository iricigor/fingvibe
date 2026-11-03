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

foreach ($size in @([System.Drawing.Size]::new(640, 480), [System.Drawing.Size]::new(1024, 720))) {
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
