function Get-VisibleDeviceChild($Parent, [string] $Property, [string] $Value) {
    $propertyId = if ($Property -eq "Name") {
        [System.Windows.Automation.AutomationElement]::NameProperty
    } else { [System.Windows.Automation.AutomationElement]::AutomationIdProperty }
    $condition = [System.Windows.Automation.PropertyCondition]::new($propertyId, $Value)
    @($Parent.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition) |
        Where-Object { -not $_.Current.IsOffscreen }) | Select-Object -First 1
}

function Move-ToDeviceElement($Element) {
    $b = $Element.Current.BoundingRectangle
    [DevicesReviewInput]::MoveTo([int]($b.Left + $b.Width / 2), [int]($b.Top + $b.Height / 2))
    # Let the desktop process intermediate moves instead of coalescing an exit and re-entry.
    Start-Sleep -Milliseconds 75
}

function Assert-NoCellPreview {
    if (Get-VisibleDeviceChild $root AutomationId CellPreviewText) {
        throw "Cell preview must not remain visible."
    }
}

function Get-HoverColorPixels([string] $Path, $Cell, [int[]] $Rgb) {
    $window = Get-UiReviewWindowBounds $windowHandle
    $cellBounds = $Cell.Current.BoundingRectangle
    $bitmap = [System.Drawing.Bitmap]::new($Path)
    try {
        $count = 0
        $left = [int]($cellBounds.Left - $window.Left)
        $right = [int]($cellBounds.Right - $window.Left) - 1
        $top = [int]($cellBounds.Top - $window.Top)
        $bottom = [int]($cellBounds.Bottom - $window.Top) - 1
        foreach ($y in $top..$bottom) {
            foreach ($x in $left..$right) {
                $pixel = $bitmap.GetPixel($x, $y)
                if ([Math]::Abs($pixel.R - $Rgb[0]) -le 8 -and
                    [Math]::Abs($pixel.G - $Rgb[1]) -le 8 -and
                    [Math]::Abs($pixel.B - $Rgb[2]) -le 8) { $count++ }
            }
        }
        return $count
    }
    finally { $bitmap.Dispose() }
}

function Assert-HoverText($Row, [string] $Theme) {
    $cell = Get-VisibleDeviceChild $Row AutomationId DeviceNameText
    $bounds = $cell.Current.BoundingRectangle
    $rgb = if ($Theme -in @("Standard Light", "Warm Light", "Colorful Light")) {
        @(0, 90, 158)
    } else { @(168, 223, 255) }
    $baseline = Save-DeviceCapture "devices-text-idle-$Theme"
    $before = Get-HoverColorPixels $baseline $cell $rgb
    Move-ToDeviceElement $cell
    $hover = Save-DeviceCapture "devices-text-hover-$Theme" -KeepPointer
    $after = Get-HoverColorPixels $hover $cell $rgb
    if ($after -lt $before + 10) {
        throw "Hover must immediately emphasize the value foreground in '$Theme' ($before -> $after pixels)."
    }
    if (-not $bounds.Equals($cell.Current.BoundingRectangle)) { throw "Text hover changed cell geometry." }
    Start-Sleep -Milliseconds 600
    Assert-NoCellPreview
    $restored = Save-DeviceCapture "devices-text-restored-$Theme"
    if ([Math]::Abs((Get-HoverColorPixels $restored $cell $rgb) - $before) -gt 3) {
        throw "Leaving the value must restore its original foreground in '$Theme'."
    }
}

function Assert-PreviewFont($Preview, $Cell) {
    $pattern = $Preview.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
    $font = $pattern.DocumentRange.GetAttributeValue([System.Windows.Automation.TextPattern]::FontSizeAttribute)
    $sourcePattern = $Cell.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern)
    $sourceFont = $sourcePattern.DocumentRange.GetAttributeValue([System.Windows.Automation.TextPattern]::FontSizeAttribute)
    if ([Math]::Abs([double]$font / [double]$sourceFont - 1) -gt 0.02) {
        throw "Cell preview text must retain the original font size ($font / $sourceFont)."
    }
    $family = $pattern.DocumentRange.GetAttributeValue([System.Windows.Automation.TextPattern]::FontNameAttribute)
    $sourceFamily = $sourcePattern.DocumentRange.GetAttributeValue([System.Windows.Automation.TextPattern]::FontNameAttribute)
    if ($family -ne $sourceFamily) {
        throw "Preview text must retain the value's font family, not a decorative icon font ($family / $sourceFamily)."
    }
}

function Assert-CellPreview($Cell, [string] $Value, [string] $Capture) {
    Write-Host "Checking full-value preview '$Value' at $($Cell.Current.BoundingRectangle)."
    Move-ToDeviceElement (Find-DeviceElement DevicesHeading)
    Move-ToDeviceElement $Cell
    Start-Sleep -Milliseconds 750
    $preview = Find-DeviceElement CellPreviewText
    if ($preview.Current.Name -ne $Value) {
        throw "Cell preview must reveal '$Value', got '$($preview.Current.Name)'."
    }
    Assert-PreviewFont $preview $Cell
    $viewport = (Find-DeviceElement TableViewport).Current.BoundingRectangle
    $bounds = $preview.Current.BoundingRectangle
    if ($bounds.Left -lt $viewport.Left -or $bounds.Right -gt $viewport.Right -or
        $bounds.Top -lt $viewport.Top -or $bounds.Bottom -gt $viewport.Bottom) {
        throw "Cell preview escaped the visible table."
    }
    $sourceBounds = $Cell.Current.BoundingRectangle
    if ($Capture -ne "devices-narrow-preview" -and
        [Math]::Abs($bounds.Left - $sourceBounds.Left) -gt $scale) {
        throw "Unconstrained previews must align their text with the original value."
    }
    if ($Capture) {
        $path = Save-DeviceCapture $Capture -KeepPointer
        if ($Value -like "Example Devices with a deliberately long*") {
            $window = Get-UiReviewWindowBounds $windowHandle
            $bitmap = [System.Drawing.Bitmap]::new($path)
            try {
                foreach ($y in [int]($bounds.Top - $window.Top)..([int]($bounds.Bottom - $window.Top) - 1)) {
                    foreach ($x in [int]($bounds.Left - $window.Left)..([int]($bounds.Right - $window.Left) - 1)) {
                        $pixel = $bitmap.GetPixel($x, $y)
                        if ($pixel.G -gt $pixel.R * 1.2 -and $pixel.G -gt $pixel.B * 1.15) {
                            throw "Underlying green port/status content must not bleed through the full-value preview."
                        }
                    }
                }
            }
            finally { $bitmap.Dispose() }
        }
    }
    return $preview
}

function Test-CellPreviews {
    Set-DeviceWidth 1280
    $rows = @(Get-DeviceRows)
    $vendorValue = "Example Devices with a deliberately long manufacturer name for hover inspection"
    $name = Get-VisibleDeviceChild $rows[0] Name $vendorValue
    $fittingName = Get-VisibleDeviceChild $rows[0] AutomationId DeviceNameText
    $second = Get-VisibleDeviceChild $rows[1] AutomationId DeviceNameText
    $originalBounds = $rows[0].Current.BoundingRectangle
    Move-ToDeviceElement $fittingName
    Start-Sleep -Milliseconds 750
    Assert-NoCellPreview
    Move-ToDeviceElement (Find-DeviceElement DevicesHeading)
    Move-ToDeviceElement $name
    Start-Sleep -Milliseconds 200
    Assert-NoCellPreview
    Move-ToDeviceElement (Find-DeviceElement DevicesHeading)
    Start-Sleep -Milliseconds 600
    Assert-NoCellPreview
    Move-ToDeviceElement $name
    Start-Sleep -Milliseconds 300
    Move-ToDeviceElement $second
    Start-Sleep -Milliseconds 250
    Assert-NoCellPreview
    Start-Sleep -Milliseconds 400
    Assert-NoCellPreview
    Move-ToDeviceElement $name
    Start-Sleep -Milliseconds 200
    Assert-NoCellPreview
    Start-Sleep -Milliseconds 450
    if ((Find-DeviceElement CellPreviewText).Current.Name -ne $vendorValue) {
        throw "Moving between cells must restart the dwell and replace the value."
    }
    Move-ToDeviceElement (Find-DeviceElement DevicesHeading)
    Start-Sleep -Milliseconds 100
    $null = Assert-CellPreview $name $vendorValue "devices-cell-preview"
    if (-not $originalBounds.Equals($rows[0].Current.BoundingRectangle)) {
        throw "Preview changed the row geometry."
    }
    $previewBounds = (Find-DeviceElement CellPreviewText).Current.BoundingRectangle
    [DevicesReviewInput]::MoveTo([int]($previewBounds.Right - 1), [int]($previewBounds.Top + $previewBounds.Height / 2))
    Start-Sleep -Milliseconds 150
    $null = Find-DeviceElement CellPreviewText
    Move-ToDeviceElement $name
    [DevicesReviewInput]::Click()
    $null = Find-DeviceElement DeviceDetailsScroll
    Select-DevicePage DevicesNavItem
    Assert-NoCellPreview
    $scroll = (Find-DeviceElement ResultsList).GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    $name = Get-VisibleDeviceChild (@(Get-DeviceRows)[0]) Name $vendorValue
    $null = Assert-CellPreview $name $vendorValue ""
    $scroll.SetScrollPercent(-1, 100)
    Start-Sleep -Milliseconds 150
    Assert-NoCellPreview
    $scroll.SetScrollPercent(-1, 0)
    Start-Sleep -Milliseconds 200

    $name = Get-VisibleDeviceChild (@(Get-DeviceRows)[0]) Name $vendorValue
    $null = Assert-CellPreview $name $vendorValue ""
    Select-DevicePage OverviewNavItem
    Assert-NoCellPreview
    Select-DevicePage DevicesNavItem
    Assert-NoCellPreview
    Select-DevicePage Settings
    $toggle = (Find-DeviceElement EnlargedCellPreviews).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    if ($toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) {
        throw "Hover emphasis and full-value previews must default to enabled."
    }
    $toggle.Toggle()
    Select-DevicePage DevicesNavItem
    $name = Get-VisibleDeviceChild (@(Get-DeviceRows)[0]) Name $vendorValue
    Move-ToDeviceElement (Find-DeviceElement DevicesHeading)
    Move-ToDeviceElement $name
    Start-Sleep -Milliseconds 800
    Assert-NoCellPreview
    $tipCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::ToolTip)
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    do {
        $tip = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $tipCondition)
        if ($tip -and -not $tip.Current.IsOffscreen) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $tip -or $tip.Current.Name -notlike "*$vendorValue*") {
        throw "Disabling previews must restore the ordinary full-value tooltip."
    }
    Select-DevicePage Settings
    (Find-DeviceElement EnlargedCellPreviews).GetCurrentPattern(
        [System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    Select-DevicePage DevicesNavItem
    Move-ToDeviceElement (Find-DeviceElement DevicesHeading)
    $name = Get-VisibleDeviceChild (@(Get-DeviceRows)[0]) Name $vendorValue
    $null = Assert-CellPreview $name $vendorValue ""
    $search = (Find-DeviceElement ResultSearchBox).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $search.SetValue("Kitchen")
    Start-Sleep -Milliseconds 150
    Assert-NoCellPreview
    $search.SetValue("")
    Start-Sleep -Milliseconds 150
    $row = @(Get-DeviceRows)[0]
    if ($row.Current.HelpText -notlike "*IP address: 127.0.0.1*") {
        throw "Keyboard-focused rows must expose full-value accessible help."
    }
    $vendor = Get-VisibleDeviceChild $row Name $vendorValue
    $null = Assert-CellPreview $vendor $vendorValue "devices-full-vendor-preview"
    foreach ($value in @("127.0.0.1", "00-11-22-33-44-01")) {
        $cell = Get-VisibleDeviceChild $row Name $value
        Move-ToDeviceElement (Find-DeviceElement DevicesHeading)
        Move-ToDeviceElement $cell
        Start-Sleep -Milliseconds 750
        Assert-NoCellPreview
    }
    $nameGrip = Get-VisibleDeviceChild $root Name "Resize Name column"
    $nameGrip.SetFocus()
    foreach ($step in 1..12) { [DevicesReviewInput]::Tap(0x25) }
    Start-Sleep -Milliseconds 250
    try {
        $name = Get-VisibleDeviceChild (@(Get-DeviceRows)[0]) AutomationId DeviceNameText
        $null = Assert-CellPreview $name "Fixture device 01" "devices-truncated-name-preview"
    }
    finally {
        $nameGrip.SetFocus()
        foreach ($step in 1..12) { [DevicesReviewInput]::Tap(0x27) }
        Start-Sleep -Milliseconds 250
    }
    Move-ToDeviceElement (Find-DeviceElement DevicesHeading)
    Set-DeviceWidth 480
    $name = Get-VisibleDeviceChild (@(Get-DeviceRows)[0]) AutomationId DeviceNameText
    Move-ToDeviceElement $name
    Start-Sleep -Milliseconds 750
    Assert-NoCellPreview
    Move-ToDeviceElement (Find-DeviceElement DevicesHeading)
    Set-DeviceWidth 640
    $name = Get-VisibleDeviceChild (@(Get-DeviceRows)[0]) Name $vendorValue
    $null = Assert-CellPreview $name $vendorValue "devices-narrow-preview"
    Move-ToDeviceElement (Find-DeviceElement DevicesHeading)
    Set-DeviceWidth 1280
    Move-ToDeviceElement (Find-DeviceElement DevicesHeading)
}
