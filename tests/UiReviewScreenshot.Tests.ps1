$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScreenshot.ps1")

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock] $Action, [string] $Pattern)
    try { & $Action }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected failure matching '$Pattern'."
}

$context = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
if ($context -eq [IntPtr]::Zero) {
    throw [System.ComponentModel.Win32Exception]::new()
}
$form = [System.Windows.Forms.Form]::new()
$pattern = [System.Drawing.Bitmap]::new(900, 600)
$graphics = [System.Drawing.Graphics]::FromImage($pattern)
$path = Join-Path ([System.IO.Path]::GetTempPath()) "ui-review-test-$([Guid]::NewGuid()).png"
try {
    # A nonblank image with distinct corner markers detects missing right/bottom edges.
    for ($x = 0; $x -lt 900; $x += 30) {
        for ($y = 0; $y -lt 600; $y += 30) {
            $color = [System.Drawing.Color]::FromArgb(
                [int] ($x / 4), [int] ($y / 3), [int] (($x + $y) / 6))
            $brush = [System.Drawing.SolidBrush]::new($color)
            try { $graphics.FillRectangle($brush, $x, $y, 30, 30) }
            finally { $brush.Dispose() }
        }
    }
    $graphics.FillRectangle([System.Drawing.Brushes]::Red, 0, 0, 16, 16)
    $graphics.FillRectangle([System.Drawing.Brushes]::Lime, 884, 0, 16, 16)
    $graphics.FillRectangle([System.Drawing.Brushes]::Blue, 0, 584, 16, 16)
    $graphics.FillRectangle([System.Drawing.Brushes]::Yellow, 884, 584, 16, 16)
    $graphics.Dispose()
    $graphics = $null

    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $form.BackgroundImage = $pattern
    $form.BackgroundImageLayout = [System.Windows.Forms.ImageLayout]::Stretch
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Size = [System.Drawing.Size]::new(900, 600)
    $form.Location = [System.Drawing.Point]::new($area.Right - 200, $area.Bottom - 100)
    $form.Show()
    $form.Activate()
    [System.Windows.Forms.Application]::DoEvents()

    Assert-Throws {
        Save-UiReviewWindowScreenshot -WindowHandle $form.Handle -Path $path
    } "*not inside the monitor working area*"

    foreach ($oversized in @($false, $true)) {
        if ($oversized) {
            $form.Size = [System.Drawing.Size]::new($area.Width + 200, $area.Height + 200)
        }
        Initialize-UiReviewWindow -WindowHandle $form.Handle
        $form.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
        $bounds = Get-UiReviewWindowBounds -WindowHandle $form.Handle
        Assert-True ($area.Contains($bounds)) "Prepared window must fit entirely on-screen."
        if ($oversized) {
            Assert-True ($bounds.Size -eq $area.Size) "Oversized window must fit the working area."
        }
        Save-UiReviewWindowScreenshot -WindowHandle $form.Handle -Path $path
        $image = [System.Drawing.Bitmap]::new($path)
        try {
            Assert-True ($image.Size -eq $bounds.Size) "PNG must match the complete physical window bounds."
            Assert-True ($image.GetPixel(2, 2).ToArgb() -eq [System.Drawing.Color]::Red.ToArgb()) "Top-left corner missing."
            Assert-True ($image.GetPixel($image.Width - 3, 2).ToArgb() -eq [System.Drawing.Color]::Lime.ToArgb()) "Top-right corner missing."
            Assert-True ($image.GetPixel(2, $image.Height - 3).ToArgb() -eq [System.Drawing.Color]::Blue.ToArgb()) "Bottom-left corner missing."
            Assert-True ($image.GetPixel($image.Width - 3, $image.Height - 3).ToArgb() -eq [System.Drawing.Color]::Yellow.ToArgb()) "Bottom-right corner missing."
        }
        finally { $image.Dispose() }
    }

    $form.BackgroundImage = $null
    $form.BackColor = [System.Drawing.Color]::Black
    $form.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
    Assert-Throws {
        Save-UiReviewWindowScreenshot -WindowHandle $form.Handle -Path $path
    } "*appears blank*"

    $form.Hide()
    Assert-Throws {
        Save-UiReviewWindowScreenshot -WindowHandle $form.Handle -Path $path
    } "*must be visible*"

    $negativeArea = [System.Drawing.Rectangle]::new(-1920, -100, 1920, 1080)
    Assert-UiReviewWindowBounds `
        -Bounds ([System.Drawing.Rectangle]::new(-1800, 0, 1100, 720)) `
        -WorkingArea $negativeArea
    Assert-Throws {
        Assert-UiReviewWindowBounds `
            -Bounds ([System.Drawing.Rectangle]::new(-600, 0, 1100, 720)) `
            -WorkingArea $negativeArea
    } "*not inside the monitor working area*"
    Assert-Throws {
        Assert-UiReviewWindowBounds `
            -Bounds ([System.Drawing.Rectangle]::new(0, 0, 639, 480)) `
            -WorkingArea $area
    } "*too small*"
    Assert-Throws {
        Assert-UiReviewWindowBounds `
            -Bounds ([System.Drawing.Rectangle]::new(0, 0, 640, 479)) `
            -WorkingArea $area
    } "*too small*"

    Write-Host "Full-window screenshot regression tests passed."
}
finally {
    $form.Dispose()
    if ($graphics) { $graphics.Dispose() }
    $pattern.Dispose()
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    $null = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext($context)
}
