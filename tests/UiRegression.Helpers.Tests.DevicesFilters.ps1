# Devices filter feature helpers: transitions and label emphasis.
& {
    . (Join-Path $PSScriptRoot 'UiRegression\Devices.Filters.Helpers.ps1')
    $transition = @{ Reads = 0; Focused = 0; ChangedAt = $null }
    function Focus-DeviceWindow { $transition.Focused++ }
    $observe = {
        $transition.Reads++
        if ($transition.Reads -le 6) { $transition.ChangedAt = [Diagnostics.Stopwatch]::StartNew() }
        [pscustomobject]@{
            Enabled = $transition.Reads -ge 2
            Foreground = $transition.Reads -ne 3
            Visible = $transition.Reads -ne 4
            Window = [Windows.Rect]::new($(if ($transition.Reads -lt 5) { 0 } else { 1 }), 0, 100, 100)
            Label = [Windows.Rect]::new($(if ($transition.Reads -lt 6) { 5 } else { 6 }), 5, 20, 20)
        }
    }
    Wait-DeviceFilterContrastReady -Enabled $true -Observe $observe
    Assert-Regression ($transition.Focused -eq 1 -and $transition.Reads -gt 6 -and
        $transition.ChangedAt.ElapsedMilliseconds -ge 500) 'HC capture must wait through flag, foreground, visibility, window and label transitions before stable observation.'
    $stable = & $observe
    foreach ($property in @('Enabled', 'Foreground', 'Visible')) {
        $unready = $stable.PSObject.Copy()
        $unready.$property = $false
        Assert-RegressionFailure {
            Wait-DeviceFilterContrastReady -Enabled $true -TimeoutMilliseconds 20 -Observe { $unready }
        } '*Timed out*stable foreground and geometry*'
    }
    foreach ($property in @('Window', 'Label')) {
        $unready = $stable.PSObject.Copy()
        $unready.$property = [Windows.Rect]::new(0, 0, 0, 0)
        Assert-RegressionFailure {
            Wait-DeviceFilterContrastReady -Enabled $true -TimeoutMilliseconds 20 -Observe { $unready }
        } '*Timed out*stable foreground and geometry*'
    }
    $stable.Enabled = $false
    Wait-DeviceFilterContrastReady -Enabled $false -Observe { $stable }
    Assert-RegressionFailure {
        Wait-DeviceFilterContrastReady -Enabled $true -Observe { throw 'contrast observation failed' }
    } 'contrast observation failed'
}
& {
    . (Join-Path $PSScriptRoot 'UiRegression\Devices.Filters.Helpers.ps1')
    $directory = New-UiRegressionFixtureDirectory -Suite filter-emphasis
    $capture = Join-Path $directory 'label.png'
    $scale = 1
    $windowHandle = [IntPtr]::Zero
    $renderState = @{ Background = 254; Foreground = 0; Opacity = 0.6; Left = 0; Ink = $null }
    function Find-DeviceElement([string] $Id) {
        [pscustomobject]@{ Current = [pscustomobject]@{
            Name = 'Status: All'
            BoundingRectangle = [Windows.Rect]::new($renderState.Left, 0, 20, 20)
        } }
    }
    function Get-FilterLabelColor { return $renderState.Foreground * 0x010101 }
    function Get-UiReviewWindowBounds { [pscustomobject]@{ Left = 0; Top = 0 } }
    function Save-DeviceCapture {
        param($Name)
        $bitmap = [Drawing.Bitmap]::new(24, 24)
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $ink = if ($null -ne $renderState.Ink) { $renderState.Ink }
            else { [Drawing.Color]::FromArgb($renderState.Foreground, $renderState.Foreground, $renderState.Foreground) }
        $brush = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb([int](255 * $renderState.Opacity), $ink))
        try {
            $graphics.Clear([Drawing.Color]::FromArgb($renderState.Background, $renderState.Background, $renderState.Background))
            $graphics.FillRectangle($brush, 4, 4, 4, 12)
            $bitmap.Save($capture, [Drawing.Imaging.ImageFormat]::Png)
        }
        finally { $brush.Dispose(); $graphics.Dispose(); $bitmap.Dispose() }
        return $capture
    }
    try {
        foreach ($theme in @(@(254, 0), @(40, 255))) {
            $renderState.Background, $renderState.Foreground = $theme
            $renderState.Opacity = 0.6
            $quiet = Get-FilterLabelEmphasis InventoryStatusFilter
            $renderState.Opacity = 0.9
            $active = Get-FilterLabelEmphasis InventoryStatusFilter
            Assert-Regression ([Math]::Abs($quiet - 0.6) -lt 0.01 -and [Math]::Abs($active - 0.9) -lt 0.01) 'Rendered emphasis must retain brush alpha when UIA foreground RGB is identical.'
            Assert-Regression ($active - $quiet -ge 0.1) 'Active ink must be stronger in both Light and Dark.'
            $renderState.Background = 100
            Assert-Regression ([Math]::Abs((Get-FilterLabelEmphasis InventoryStatusFilter) - $active) -lt 0.01) 'Emphasis must normalize the button background instead of treating its color as label emphasis.'
            $renderState.Opacity = 0
            Assert-RegressionFailure { Get-FilterLabelEmphasis InventoryStatusFilter } '*visible rendered ink*'
        }
        $renderState.Left = -1
        Assert-RegressionFailure { Get-FilterLabelEmphasis InventoryStatusFilter } '*visible inside its capture*'
        Assert-RegressionFailure { Test-FilterRenderedForeground InventoryStatusFilter 0 } '*visible inside its capture*'
        $renderState.Left = 0
        $renderState.Opacity = 1
        function Get-FilterLabelColor { return 0xFFFFFF }
        foreach ($theme in @(@(255, 0), @(0, 255))) {
            $renderState.Background, $renderState.Foreground = $theme
            Assert-Regression (Test-FilterRenderedForeground InventoryStatusFilter ($renderState.Foreground * 0x010101)) 'HC must verify actual system-colored ink, not stale UIA foreground metadata.'
        }
        $renderState.Foreground = 100
        Assert-Regression (-not (Test-FilterRenderedForeground InventoryStatusFilter 0xFFFFFF)) 'A visibly wrong HC foreground must fail.'
        $renderState.Background = 255
        $renderState.Opacity = 0
        Assert-Regression (-not (Test-FilterRenderedForeground InventoryStatusFilter 0)) 'A blank label must not count as HC foreground.'
        Assert-Regression (-not (Test-FilterRenderedForeground InventoryStatusFilter 0xFFFFFF)) 'The expected color in the background is not glyph evidence.'
        $renderState.Opacity = 1
        $renderState.Ink = [Drawing.Color]::Blue
        Assert-Regression (-not (Test-FilterRenderedForeground InventoryStatusFilter 0x0000FF)) 'Different HC hues must fail even when their channel sums match.'
        Assert-Regression (Test-FilterRenderedForeground InventoryStatusFilter 0xFF0000) 'COLORREF blue must be compared in the correct RGB channel order.'
        $renderState.Background = 0
        $renderState.Ink = [Drawing.Color]::FromArgb(245, 245, 245)
        Assert-Regression (Test-FilterRenderedForeground InventoryStatusFilter 0xFFFFFF) 'Small glyph rasterization differences must not mask correct HC ink.'
    }
    finally { Remove-Item -LiteralPath $directory -Recurse -Force }
}
