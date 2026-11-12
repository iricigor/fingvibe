function Assert-DeviceStripes([string] $Name) {
    Start-Sleep -Milliseconds 750
    $rows = @(Get-DeviceRows)
    if ($rows.Count -lt 4) { throw "At least four fixture rows must be visible for '$Name'." }
    $path = Save-DeviceCapture $Name
    $bitmap = [System.Drawing.Bitmap]::new($path)
    try {
        $colors = @($rows | Select-Object -First 4 | ForEach-Object { Get-RowColor $bitmap $_ })
        if ($colors[0] -eq $colors[1] -or $colors[0] -ne $colors[2] -or $colors[1] -ne $colors[3]) {
            $rows | Select-Object -First 4 | ForEach-Object {
                Write-Host "$($_.Current.Name): $($_.Current.BoundingRectangle)"
            }
            throw "Rows do not have alternating full-width backgrounds in '$Name': $colors."
        }
        $bounds = Get-UiReviewWindowBounds $windowHandle
        foreach ($index in 0..3) {
            $rowBounds = $rows[$index].Current.BoundingRectangle
            # Sample top padding, not text exposed from the next horizontally clipped column.
            $rightColor = $bitmap.GetPixel(
                [int]($rowBounds.Right - $bounds.Left - 6 * $scale),
                [int]($rowBounds.Top - $bounds.Top + 2 * $scale)).ToArgb()
            if ($rightColor -ne $colors[$index]) { throw "Stripe is not full width in '$Name'." }
        }
    }
    finally { $bitmap.Dispose() }
}

function Assert-HeaderUnderline([string] $Theme) {
    $rows = @(Get-DeviceRows)
    $bounds = Get-UiReviewWindowBounds $windowHandle
    $rowBounds = $rows[0].Current.BoundingRectangle
    $bitmap = [System.Drawing.Bitmap]::new((Join-Path $ScreenshotDirectory "devices-$Theme.png"))
    try {
        $y = [int]($rowBounds.Top - $bounds.Top) - 1
        $left = [int]($rowBounds.Left - $bounds.Left + 8 * $scale)
        $right = [int]($rowBounds.Right - $bounds.Left - 6 * $scale)
        $line = $bitmap.GetPixel($left, $y)
        if ($line.ToArgb() -eq $bitmap.GetPixel($left, $y - 1).ToArgb()) {
            throw "Header underline must be distinct and only one pixel thick in '$Theme'."
        }
        foreach ($x in $left..$right) {
            if ($bitmap.GetPixel($x, $y).ToArgb() -ne $line.ToArgb()) {
                throw "Header underline must span the full table width in '$Theme'."
            }
        }
        $header = $bitmap.GetPixel($left, $y - 1)
        $lineBrightness = [int]$line.R + [int]$line.G + [int]$line.B
        $headerBrightness = [int]$header.R + [int]$header.G + [int]$header.B
        $isLight = $Theme -in @("Standard Light", "Warm Light", "Colorful Light")
        if (($isLight -and $lineBrightness -ge $headerBrightness) -or
            (-not $isLight -and $lineBrightness -le $headerBrightness)) {
            throw "Header underline must be darker in light themes and lighter in dark themes."
        }
    }
    finally { $bitmap.Dispose() }
}
