[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $AppPath,

    [Parameter(Mandatory)]
    [string] $ScreenshotDirectory
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScreenshot.ps1")
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewAppearance.ps1")

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class DevicesReviewInput
{
    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")]
    private static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
    [DllImport("user32.dll")]
    private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    public static void Tap(byte key) {
        keybd_event(key, 0, 0, UIntPtr.Zero);
        keybd_event(key, 0, 2, UIntPtr.Zero);
    }
    public static void Click() {
        mouse_event(2, 0, 0, 0, UIntPtr.Zero);
        mouse_event(4, 0, 0, 0, UIntPtr.Zero);
    }
    public static void MoveTo(int x, int y) {
        uint absoluteX = (uint)((long)(x - GetSystemMetrics(76)) * 65535 / (GetSystemMetrics(78) - 1));
        uint absoluteY = (uint)((long)(y - GetSystemMetrics(77)) * 65535 / (GetSystemMetrics(79) - 1));
        mouse_event(0xC001, absoluteX, absoluteY, 0, UIntPtr.Zero);
    }
}
"@

function Find-DeviceElement([string] $Id) {
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $element = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if ($element -and -not $element.Current.IsOffscreen) { return $element }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Visible device element '$Id' was not found."
}

function Select-DevicePage([string] $Id) {
    $element = if ($Id -eq "Settings") {
        $condition = [System.Windows.Automation.AndCondition]::new(
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, "Settings"),
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::ListItem))
        $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    } else { Find-DeviceElement $Id }
    if (-not $element) { throw "Navigation '$Id' was not found." }
    $element.GetCurrentPattern(
        [System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 350
    if ($Id -eq "Settings") {
        $page = Find-DeviceElement SettingsPage
        $scroll = $page.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
        if ($scroll.Current.VerticallyScrollable) {
            # Scheduled scans follow the Devices card; keep the column footer at the viewport bottom.
            $reset = [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "ResetColumnsButton")
            $best = 100
            $scroll.SetScrollPercent(-1, $best)
            for ($percent = 98; $percent -ge 0; $percent -= 2) {
                $scroll.SetScrollPercent(-1, $percent)
                Start-Sleep -Milliseconds 100
                $bounds = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $reset).Current.BoundingRectangle
                if ($bounds.IsEmpty -or $bounds.Bottom -gt $page.Current.BoundingRectangle.Bottom) { break }
                $best = $percent
            }
            $scroll.SetScrollPercent(-1, $best)
            Start-Sleep -Milliseconds 150
        }
    }
}

function Set-DeviceWidth([int] $Width) {
    $bounds = Get-UiReviewWindowBounds $windowHandle
    $area = [System.Windows.Forms.Screen]::FromHandle($windowHandle).WorkingArea
    if ($Width * $scale -gt $area.Width) { throw "Desktop cannot fit $Width logical pixels." }
    if (-not [UiReviewNativeWindow]::SetWindowPos($windowHandle, [IntPtr]::Zero,
            $area.Left, $area.Top, [int]($Width * $scale),
            [int][Math]::Min(720 * $scale, $area.Height), 0x0044)) {
        throw [System.ComponentModel.Win32Exception]::new()
    }
    Start-Sleep -Milliseconds 500
}

function Get-DeviceRows {
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::ListItem)
    @((Find-DeviceElement ResultsList).FindAll(
        [System.Windows.Automation.TreeScope]::Children, $condition) |
        Where-Object { -not $_.Current.IsOffscreen -and $_.Current.BoundingRectangle.Height -ge 30 * $scale } |
        Sort-Object { $_.Current.BoundingRectangle.Top })
}

function Get-FilterBounds($Element) {
    $bounds = $Element.Current.BoundingRectangle
    return $bounds
}

function Focus-DeviceWindow {
    if ([UiReviewNativeWindow]::GetForegroundWindow() -eq $windowHandle) { return }
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        [DevicesReviewInput]::Tap(0x12)
        $null = [UiReviewNativeWindow]::SetForegroundWindow($windowHandle)
        Start-Sleep -Milliseconds 100
        if ([UiReviewNativeWindow]::GetForegroundWindow() -eq $windowHandle) { return }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Device review window could not be brought to the foreground."
}

function Save-DeviceCapture([string] $Name, [switch] $KeepPointer) {
    $bounds = Get-UiReviewWindowBounds $windowHandle
    if (-not $KeepPointer) {
        [DevicesReviewInput]::MoveTo(
            [int]($bounds.Left + $bounds.Width / 2), [int]($bounds.Top + 50 * $scale))
    }
    Focus-DeviceWindow
    Start-Sleep -Milliseconds 200
    $path = Join-Path $ScreenshotDirectory "$Name.png"
    Save-UiReviewWindowScreenshot $windowHandle $path
    return $path
}

function Get-RowColor($Bitmap, $Row) {
    $bounds = Get-UiReviewWindowBounds $windowHandle
    $rowBounds = $Row.Current.BoundingRectangle
    if ($rowBounds.IsEmpty -or $Row.Current.IsOffscreen) {
        throw "Cannot sample an unrealized or offscreen device row."
    }
    $Bitmap.GetPixel([int]($rowBounds.Left - $bounds.Left + 8 * $scale),
        [int]($rowBounds.Top - $bounds.Top + $rowBounds.Height / 2)).ToArgb()
}

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
            $rightColor = $bitmap.GetPixel(
                [int]($rowBounds.Right - $bounds.Left - 6 * $scale),
                [int]($rowBounds.Top - $bounds.Top + $rowBounds.Height / 2)).ToArgb()
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

function Set-SecondaryFiltersExpanded([bool] $Expanded) {
    $toggle = (Find-DeviceElement FilterExpander).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    if (($toggle.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) -ne $Expanded) {
        $toggle.Toggle()
        Start-Sleep -Milliseconds 150
    }
    $expected = if ($Expanded) { "Expanded" } else { "Collapsed" }
    if ((Find-DeviceElement FilterExpander).Current.HelpText -ne $expected) {
        throw "The funnel must expose its $expected state."
    }
}

function Open-DeviceFilter([string] $Id) {
    if ($Id -ne "InventoryStatusFilter") { Set-SecondaryFiltersExpanded $true }
    (Find-DeviceElement $Id).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 250
    return Find-DeviceElement "${Id}Choices"
}

function Set-DeviceFilterChecks([string] $Id, [string[]] $Labels) {
    $panel = Open-DeviceFilter $Id
    $checks = $panel.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::CheckBox))
    foreach ($label in $Labels) {
        if ($label -notin @($checks | ForEach-Object { $_.Current.Name })) {
            throw "Checkbox '$label' was not found in '$Id'."
        }
    }
    foreach ($check in $checks) {
        $toggle = $check.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        if (($toggle.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) -ne
            ($check.Current.Name -in $Labels)) { $toggle.Toggle() }
        if ($panel.Current.IsOffscreen) { throw "Checkbox selections must not close '$Id'." }
    }
    [DevicesReviewInput]::Tap(0x1B)
    Start-Sleep -Milliseconds 200
}

function Set-DeviceFilterChoice([string] $Id, [string] $Label) {
    if ($Id -eq "CompactRowsSwitch") {
        if ($Label -notin @("Standard", "Compact")) { throw "Unknown density '$Label'." }
        $toggle = (Find-DeviceElement $Id).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
        if (($toggle.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) -ne ($Label -eq "Compact")) {
            $toggle.Toggle()
        }
        return
    }
    if ($Id -in @("InventoryStatusFilter", "TypeFilter", "OperatingSystemFilter", "VendorFilter",
        "PersonFilter", "RoomFilter", "PortsFilter")) {
        $labels = if ($Label -like "All *") { @() } else { @($Label) }
        Set-DeviceFilterChecks $Id $labels
        return
    }
    $picker = Find-DeviceElement $Id
    $expand = $picker.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern)
    $expand.Expand()
    Start-Sleep -Milliseconds 150
    $condition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, $Label),
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::ListItem))
    $choice = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if (-not $choice) { throw "Filter option '$Label' was not found in '$Id'." }
    $choice.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    if ($expand.Current.ExpandCollapseState -ne [System.Windows.Automation.ExpandCollapseState]::Collapsed) {
        $expand.Collapse()
    }
    Start-Sleep -Milliseconds 200
}

function Assert-FilterPresentation([string] $Id, [string] $Category, [string] $Value = "") {
    $picker = Find-DeviceElement $Id
    $expected = if ($Value) { $Value } else { "All" }
    if ($picker.Current.Name -ne "${Category}: $expected") {
        throw "Native '$Id' must announce its category and selections; expected '${Category}: $expected'."
    }
    $null = Save-DeviceCapture "devices-filter-$Category-$expected"
}

function Test-ConditionalDeviceColumns {
    foreach ($case in @(
        @{ Status = $true; Response = $true; Type = $true; Grip = "Status / response" },
        @{ Status = $true; Response = $false; Type = $false; Grip = "Status" },
        @{ Status = $false; Response = $true; Type = $true; Grip = "Response" },
        @{ Status = $false; Response = $false; Type = $false; Grip = "" }
    )) {
        Select-DevicePage Settings
        $choices = (Find-DeviceElement SettingsPage).FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::CheckBox))
        foreach ($entry in @(@("Status", $case.Status), @("Response", $case.Response), @("Device type", $case.Type))) {
            $box = @($choices | Where-Object { $_.Current.Name -eq $entry[0] })[0]
            if (-not $box) { throw "Column choice '$($entry[0])' not found." }
            $toggle = $box.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
            if (($toggle.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) -ne $entry[1]) {
                $toggle.Toggle()
            }
        }
        Select-DevicePage DevicesNavItem
        $row = @(Get-DeviceRows)[0]
        $status = Get-VisibleDeviceChild $row Name "Online"
        $response = Get-VisibleDeviceChild $row AutomationId ResponseTimeText
        $type = Get-VisibleDeviceChild $row AutomationId DeviceTypeLabel
        if ([bool]$status -ne $case.Status -or [bool]$response -ne $case.Response -or [bool]$type -ne $case.Type) {
            throw "Conditional column content does not match Settings: $($case | ConvertTo-Json -Compress)."
        }
        $grip = Get-VisibleDeviceChild $root AutomationId ConnectionResizeGrip
        if ([bool]$grip -ne [bool]$case.Grip) { throw "Connection resize handle visibility is incorrect." }
        if ($grip) {
            if ($grip.Current.Name -ne "Resize $($case.Grip) column") { throw "Connection resize target is incorrect." }
            $left = $grip.Current.BoundingRectangle.Left
            $grip.SetFocus()
            [DevicesReviewInput]::Tap(0x27)
            Start-Sleep -Milliseconds 150
            if ([Math]::Abs($grip.Current.BoundingRectangle.Left - $left - 8 * $scale) -gt 1) {
                throw "Conditional connection column must resize by one keyboard step."
            }
        }
        if ($type) {
            $name = Get-VisibleDeviceChild $row AutomationId DeviceNameText
            if ($type.Current.BoundingRectangle.Top -lt $name.Current.BoundingRectangle.Bottom -or
                [Math]::Abs($type.Current.BoundingRectangle.Left - $name.Current.BoundingRectangle.Left) -gt $scale) {
                throw "Device type must be a secondary line within the Name column."
            }
            if ($case.Status -and $case.Response) {
                $bar = $row.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                    [System.Windows.Automation.PropertyCondition]::new(
                        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                        [System.Windows.Automation.ControlType]::ProgressBar))
                $badgeBounds = $status.Current.BoundingRectangle
                $timeBounds = $response.Current.BoundingRectangle
                $barBounds = $bar.Current.BoundingRectangle
                if ($badgeBounds.Left -ge $timeBounds.Right -or
                    $badgeBounds.Bottom -gt $barBounds.Top -or $timeBounds.Bottom -gt $barBounds.Top -or
                    $barBounds.Left -gt $badgeBounds.Left -or $barBounds.Right -lt $timeBounds.Right -or
                    $barBounds.Width / $scale -lt 150) {
                    throw "Combined connection must place status upper-left, time upper-right, and a shared full-width bar below both."
                }
            }
        }
        $null = Save-DeviceCapture "devices-columns-$($case.Status)-$($case.Response)"
    }
    Select-DevicePage Settings
    (Find-DeviceElement ResetColumnsButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Select-DevicePage DevicesNavItem
}

function Set-ColumnOption([string] $Name, [bool] $Enabled) {
    $condition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, $Name),
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::CheckBox))
    $box = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if (-not $box) { throw "Column option '$Name' is missing." }
    $toggle = $box.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    if (($toggle.Current.ToggleState -eq [System.Windows.Automation.ToggleState]::On) -ne $Enabled) {
        $toggle.Toggle()
    }
}

function Test-MergeOptions {
    Set-DeviceWidth 1880
    foreach ($merged in @($false, $true)) {
        Select-DevicePage Settings
        foreach ($label in @("Combine Name and Type", "Combine IP and MAC", "Combine Status and Response", "Combine Person and Room", "Combine Vendor and OS")) {
            Set-ColumnOption $label $merged
        }
        Select-DevicePage DevicesNavItem
        $row = @(Get-DeviceRows)[0]
        $ip = Get-VisibleDeviceChild $row Name "127.0.0.1"
        $mac = Get-VisibleDeviceChild $row Name "00-11-22-33-44-01"
        if (-not $ip -or -not $mac) { throw "IP and MAC must both remain accessible." }
        $stacked = $mac.Current.BoundingRectangle.Top -ge $ip.Current.BoundingRectangle.Bottom
        if ($stacked -ne $merged) { throw "IP/MAC placement does not match the merge setting." }
        $type = Get-VisibleDeviceChild $row AutomationId DeviceTypeLabel
        if ([bool]$type -ne $merged) { throw "Name/Type merge setting was not applied." }
        $responseGrip = Get-VisibleDeviceChild $root Name "Resize Response column"
        if ([bool]$responseGrip -eq $merged) { throw "Separate Response must have its own resize boundary." }
        $assignmentGrip = Get-VisibleDeviceChild $root Name "Resize Person / room column"
        if ([bool]$assignmentGrip -ne $merged) { throw "Person/Room merge setting was not applied." }
        $os = Get-VisibleDeviceChild $row AutomationId MergedOperatingSystemText
        if ([bool]$os -ne $merged) { throw "Vendor/OS merge setting was not applied." }
        if ($os -and $os.Current.Name -ne "Android (likely)") { throw "Merged OS must preserve inference qualifiers." }
        if ($merged) {
            $unknownOs = Get-VisibleDeviceChild (@(Get-DeviceRows)[1]) AutomationId MergedOperatingSystemText
            if ($unknownOs -and $unknownOs.Current.Name) { throw "Unknown merged OS must remain blank, not a dash." }
        }
        $osGrip = Get-VisibleDeviceChild $root Name "Resize OS column"
        if ([bool]$osGrip -eq $merged) { throw "Merged OS must not allocate a standalone column." }
        $null = Save-DeviceCapture "devices-all-merges-$merged"
        $height = $row.Current.BoundingRectangle.Height / $scale
        if ($height -gt 48) {
            throw "Denser two-line rows must not exceed 48 DIPs; got $height with merges=$merged."
        }
    }
    Select-DevicePage Settings
    (Find-DeviceElement ResetColumnsButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Select-DevicePage DevicesNavItem
    Set-DeviceWidth 1280
    $unknownRow = @(Get-DeviceRows)[2]
    if (Get-VisibleDeviceChild $unknownRow AutomationId DeviceTypeLabel) {
        throw "An unknown type must not reserve a secondary Name line."
    }
}

function Assert-ClearFiltersVisible([bool] $Expected) {
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $link = Get-VisibleDeviceChild $root AutomationId ClearFiltersLink
        if ([bool]$link -eq $Expected) {
            if ($Expected) {
                $clearBounds = $link.Current.BoundingRectangle
                $funnelBounds = (Find-DeviceElement FilterExpander).Current.BoundingRectangle
                if ([Math]::Abs($clearBounds.Left - $funnelBounds.Right) -gt 2 * $scale -or
                    [Math]::Abs($clearBounds.Top - $funnelBounds.Top) -gt $scale) {
                    throw "Clear filters must be the connected right-hand segment of the funnel control."
                }
            }
            return
        }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Clear filters visibility must match active restrictions; expected visible=$Expected."
}

function Clear-DeviceFilters {
    $expanded = (Find-DeviceElement FilterExpander).Current.HelpText -eq "Expanded"
    (Find-DeviceElement ClearFiltersLink).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 200
    Assert-ClearFiltersVisible $false
    if ((Find-DeviceElement ResultCountText).Current.Name -ne "Showing 80 devices") {
        throw "Clear filters must restore the full inventory."
    }
    foreach ($id in @("OnlineChip", "OfflineChip", "UnknownChip", "FingOnlyChip")) {
        if ((Find-DeviceElement $id).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne
            [System.Windows.Automation.ToggleState]::Off) { throw "Clear filters left '$id' active." }
    }
    if ((Find-DeviceElement FilterExpander).Current.Name -notlike "*0 active categories") {
        throw "Clear filters must clear hidden secondary categories."
    }
    if (((Find-DeviceElement FilterExpander).Current.HelpText -eq "Expanded") -ne $expanded) {
        throw "Clear filters must not change the secondary row's visibility."
    }
    Set-SecondaryFiltersExpanded $true
    foreach ($entry in @(@("TypeFilter", "Device type"), @("OperatingSystemFilter", "Operating system"),
        @("VendorFilter", "Vendor"), @("PersonFilter", "Person"), @("RoomFilter", "Room"), @("UsageCategoryFilter", "Usage category"))) {
        if ((Find-DeviceElement $entry[0]).Current.Name -ne "$($entry[1]): All") {
            throw "Clear filters left '$($entry[0])' restricted."
        }
    }
    if ((Find-DeviceElement PortsFilter).Current.Name -ne "Ports: All") { throw "Ports remained restricted." }
    Set-SecondaryFiltersExpanded $expanded
}

function Test-ExpandableDeviceFilters {
    if ((Find-DeviceElement FilterExpander).Current.HelpText -ne "Collapsed" -or
        (Get-VisibleDeviceChild $root AutomationId TypeFilter)) {
        throw "Secondary filters must start collapsed."
    }
    Set-DeviceFilterChecks InventoryStatusFilter @("Online", "Offline")
    if ((Find-DeviceElement ResultCountText).Current.Name -ne "Showing 80 devices" -or
        (Find-DeviceElement FilterExpander).Current.Name -notlike "*0 active categories") {
        throw "Multiple statuses use OR and do not contribute to the secondary count."
    }
    Set-DeviceFilterChecks TypeFilter @("Computer", "Phone")
    Set-DeviceFilterChecks OperatingSystemFilter @("Android", "Unknown")
    Set-DeviceFilterChecks VendorFilter @("Example Devices",
        "Example Devices with a deliberately long manufacturer name for hover inspection")
    Set-DeviceFilterChecks PersonFilter @("Unassigned", "UI · UI review person")
    Set-DeviceFilterChecks RoomFilter @("Unassigned", "UI · UI review room")
    Set-DeviceFilterChoice PortsFilter "With open ports"
    if ((Find-DeviceElement ResultCountText).Current.Name -ne "Showing 1 of 80 devices" -or
        (Find-DeviceElement FilterExpander).Current.Name -notlike "*6 active categories") {
        throw "Multi-select categories must combine with AND and count categories rather than selections."
    }
    Set-SecondaryFiltersExpanded $false
    if ((Find-DeviceElement ResultCountText).Current.Name -ne "Showing 1 of 80 devices" -or
        (Find-DeviceElement FilterExpander).Current.Name -notlike "*6 active categories" -or
        (Get-VisibleDeviceChild $root AutomationId TypeFilter)) {
        throw "Collapsing filters must hide the row without clearing its restrictions or count."
    }
    $null = Save-DeviceCapture "devices-collapsed-active-filters"
    Clear-DeviceFilters
    Set-SecondaryFiltersExpanded $true
    Set-DeviceFilterChecks TypeFilter @("Unknown", "Computer")
    if ((Find-DeviceElement ResultCountText).Current.Name -ne "Showing 80 devices") {
        throw "Unknown can combine with a concrete device type."
    }
    Set-DeviceFilterChecks TypeFilter @()
    Assert-ClearFiltersVisible $false
}

function Test-FilterChips {
    Assert-ClearFiltersVisible $false
    $search = (Find-DeviceElement ResultSearchBox).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    foreach ($apply in @(
        { $search.SetValue("Kitchen") },
        { Set-DeviceFilterChoice InventoryStatusFilter Unknown },
        { Set-DeviceFilterChoice PersonFilter Unassigned },
        { Set-DeviceFilterChoice RoomFilter Unassigned },
        { Set-DeviceFilterChoice UsageCategoryFilter Unclassified },
        { Set-DeviceFilterChoice PortsFilter "With open ports" }
    )) {
        & $apply
        Assert-ClearFiltersVisible $true
        Clear-DeviceFilters
    }
    $search.SetValue("Kitchen")
    Set-DeviceFilterChoice PersonFilter Unassigned
    Set-DeviceFilterChoice RoomFilter Unassigned
    Set-DeviceFilterChoice PortsFilter "With open ports"
    foreach ($case in @(@("OnlineChip", "Online", "1"), @("OfflineChip", "Offline", "0"),
        @("UnknownChip", "Unknown", "0"), @("FingOnlyChip", "Fing Only", "0"))) {
        Set-DeviceFilterChoice InventoryStatusFilter "All statuses"
        $chip = Find-DeviceElement $case[0]
        if ($case[0] -in @("OnlineChip", "OfflineChip")) {
            $chip.SetFocus()
            [DevicesReviewInput]::Tap(0x20)
        }
        else { $chip.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle() }
        Start-Sleep -Milliseconds 200
        if ((Find-DeviceElement InventoryStatusFilter).Current.Name -ne "Status: $($case[1])") {
            throw "Summary chip/dropdown synchronization failed."
        }
        if ($chip.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne
            [System.Windows.Automation.ToggleState]::On) { throw "Summary chip must expose its selected state." }
        if ($search.Current.Value -ne "Kitchen" -or
            (Find-DeviceElement ResultCountText).Current.Name -ne "Showing $($case[2]) of 80 devices") {
            throw "Summary shortcuts must retain other restrictions, including zero-match results."
        }
        if ((Find-DeviceElement OnlineChip).Current.Name -ne "80 Online") {
            throw "Summary counts must retain their full-inventory meaning."
        }
    }
    Set-DeviceFilterChoice InventoryStatusFilter Online
    (Find-DeviceElement OfflineChip).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    if ((Find-DeviceElement InventoryStatusFilter).Current.Name -ne "Status: Online, Offline") {
        throw "Summary chips must add statuses without replacing other selections."
    }
    if ((Find-DeviceElement OnlineChip).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne
        [System.Windows.Automation.ToggleState]::On) { throw "Dropdown must select the matching chip." }
    Clear-DeviceFilters
    $null = Save-DeviceCapture "devices-status-chips-cleared"
}

function Test-RowDensity {
    Set-DeviceWidth 1880
    $measurements = @{}
    foreach ($layout in @("Stacked", "Separate", "ConnectionOnly", "UsageOnly")) {
        $measurements[$layout] = @{}
        foreach ($density in @("Standard", "Compact")) {
            Select-DevicePage Settings
            foreach ($label in @("Combine Name and Type", "Combine IP and MAC", "Combine Person and Room", "Combine Vendor and OS")) {
                Set-ColumnOption $label ($layout -eq "Stacked")
            }
            Set-ColumnOption "Combine Status and Response" ($layout -ne "Separate")
            Set-ColumnOption "Usage category" ($layout -in @("Stacked", "UsageOnly"))
            Set-DeviceFilterChoice CompactRowsSwitch $density
            Select-DevicePage DevicesNavItem
            $rows = @(Get-DeviceRows)
            if ($rows.Count -lt 4) { throw "Density measurement requires four representative rows." }
            $listBounds = (Find-DeviceElement ResultsList).Current.BoundingRectangle
            $heights = @($rows | Select-Object -First 4 | ForEach-Object { $_.Current.BoundingRectangle.Height / $scale })
            $fullyVisible = @($rows | Where-Object { $_.Current.BoundingRectangle.Bottom -le $listBounds.Bottom }).Count
            $headerHeight = (Find-DeviceElement DeviceTableHeader).Current.BoundingRectangle.Height / $scale
            $measurements[$layout][$density] = @{ heights = $heights; visibleRows = $fullyVisible; headerHeight = $headerHeight; scale = $scale }
            $minimum = if ($layout -in @("Stacked", "UsageOnly")) {
                if ($density -eq "Compact") { 36 } else { 40 }
            } else {
                if ($density -eq "Compact") { 30 } else { 34 }
            }
            # Native two-line name/type metrics require 44 DIPs in Standard, above its 40-DIP minimum.
            $maximum = $minimum + $(if ($layout -in @("Stacked", "UsageOnly") -and $density -eq "Standard") { 4.5 } else { 0.5 })
            foreach ($height in $heights) {
                if ($height -lt $minimum - 0.5 -or $height -gt $maximum) {
                    throw "$layout/$density representative height must be $minimum-$maximum DIPs, got $height."
                }
            }
            foreach ($row in ($rows | Select-Object -First 4)) {
                $rowBounds = $row.Current.BoundingRectangle
                foreach ($child in $row.FindAll([System.Windows.Automation.TreeScope]::Descendants,
                    [System.Windows.Automation.Condition]::TrueCondition)) {
                    if ($child.Current.IsOffscreen) { continue }
                    $childBounds = $child.Current.BoundingRectangle
                    if ($childBounds.Height -gt 0 -and
                        ($childBounds.Top -lt $rowBounds.Top - 1 -or $childBounds.Bottom -gt $rowBounds.Bottom + 1)) {
                        throw "$layout/$density clips row content '$($child.Current.Name)'."
                    }
                }
            }
            $selected = $rows[0].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
            if ($density -eq "Compact" -and -not $selected.Current.IsSelected) {
                throw "Changing density must preserve the selected device."
            }
            $selected.Select()
            $null = Save-DeviceCapture "devices-density-$layout-$density"
        }
        if ($measurements[$layout].Compact.visibleRows -le $measurements[$layout].Standard.visibleRows) {
            throw "$layout Compact must display more complete rows at an identical viewport."
        }
        if ($measurements[$layout].Compact.headerHeight -ge $measurements[$layout].Standard.headerHeight) {
            throw "Column titles must retain the existing density distinction."
        }
    }
    $measurements | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath (Join-Path $ScreenshotDirectory "devices-density-measurements.json")
    Select-DevicePage Settings
    Set-DeviceFilterChoice CompactRowsSwitch Standard
    (Find-DeviceElement ResetColumnsButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Select-DevicePage DevicesNavItem
    Set-DeviceWidth 1280
}

function Test-MergedAssignments {
    Set-DeviceWidth 1880
    Select-DevicePage Settings
    Set-ColumnOption "Combine Person and Room" $true
    Select-DevicePage DevicesNavItem
    $initialRow = @(Get-DeviceRows)[0]
    $empty = Get-VisibleDeviceChild $initialRow AutomationId MergedAssignmentsEmpty
    if (-not $empty) { throw "Unassigned merged cell must show a single dash." }
    $emptyBounds = $empty.Current.BoundingRectangle
    $centerX = $emptyBounds.Left + $emptyBounds.Width / 2
    foreach ($case in @(
        @{ Person = $true; Room = $false },
        @{ Person = $false; Room = $true },
        @{ Person = $true; Room = $true },
        @{ Person = $false; Room = $false }
    )) {
        $row = @(Get-DeviceRows)[0]
        $row.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        $row.SetFocus()
        [DevicesReviewInput]::Tap(0x0D)
        Start-Sleep -Milliseconds 250
        $scroll = (Find-DeviceElement DeviceDetailsScroll).GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
        if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, 0) }
        Set-DeviceFilterChoice DevicePersonPicker $(if ($case.Person) { "UI · UI review person" } else { "Unassigned" })
        Set-DeviceFilterChoice DeviceRoomPicker $(if ($case.Room) { "UI · UI review room" } else { "Unassigned" })
        Select-DevicePage DevicesNavItem
        $row = @(Get-DeviceRows)[0]
        $person = Get-VisibleDeviceChild $row AutomationId MergedPersonValue
        $room = Get-VisibleDeviceChild $row AutomationId MergedRoomValue
        $empty = Get-VisibleDeviceChild $row AutomationId MergedAssignmentsEmpty
        if ([bool]$person -ne $case.Person -or [bool]$room -ne $case.Room -or
            [bool]$empty -ne (-not $case.Person -and -not $case.Room)) {
            throw "Merged assignments must omit missing lines and show one dash only when both are absent."
        }
        $bounds = @()
        foreach ($entry in @(@($person, "Person: UI review person"), @($room, "Room: UI review room"))) {
            if (-not $entry[0]) { continue }
            if ($entry[0].Current.Name -ne $entry[1]) { throw "Assignment must announce its category and full name." }
            $b = $entry[0].Current.BoundingRectangle
            $bounds += $b
            # The centered line includes a 12-DIP icon and a 4-DIP gap before the value.
            if ([Math]::Abs($b.Left + $b.Width / 2 - 8 * $scale - $centerX) -gt 2 * $scale) {
                throw "Each icon/value line must be horizontally centered."
            }
        }
        if ($empty) { $bounds += $empty.Current.BoundingRectangle }
        $top = ($bounds | Measure-Object Top -Minimum).Minimum
        $bottom = ($bounds | Measure-Object Bottom -Maximum).Maximum
        $rb = $row.Current.BoundingRectangle
        if ([Math]::Abs(($top + $bottom) / 2 - ($rb.Top + $rb.Bottom) / 2) -gt 2 * $scale) {
            throw "Merged assignment contents must be vertically centered."
        }
        if ($person -and $room -and $person.Current.BoundingRectangle.Bottom -gt $room.Current.BoundingRectangle.Top) {
            throw "Two assignments must occupy separate stacked lines."
        }
        if ($rb.Height / $scale -gt 48) { throw "Merged assignments must not increase the row envelope." }
        foreach ($entry in @(@($person, "Person: UI review person"), @($room, "Room: UI review room"))) {
            if ($entry[0]) {
                Move-ToDeviceElement (Find-DeviceElement DevicesHeading)
                $null = Assert-CellPreview $entry[0] $entry[1] ""
            }
        }
        $null = Save-DeviceCapture "devices-assignments-$($case.Person)-$($case.Room)"
    }
    Select-DevicePage Settings
    (Find-DeviceElement ResetColumnsButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Select-DevicePage DevicesNavItem
    Set-DeviceWidth 1280
}

function Invoke-DeviceSort([string] $ButtonId, [string] $GlyphId, [bool] $Ascending) {
    (Find-DeviceElement $ButtonId).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 350
    $expected = if ($Ascending) { [string][char]0x2191 } else { [string][char]0x2193 }
    if ((Find-DeviceElement $GlyphId).Current.Name -ne $expected) {
        throw "'$ButtonId' did not show the expected sort direction."
    }
}

function Assert-SortedFixture([string] $Column, [bool] $Ascending, [object[]] $ExpectedRows) {
    $ordered = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $ExpectedRows) { $ordered.Add($item) }
    $ordered.Sort([System.Comparison[object]] {
        param($left, $right)
        if ($Column -in @("Person", "Room")) {
            $missing = [string]::IsNullOrEmpty($left[$Column]).CompareTo([string]::IsNullOrEmpty($right[$Column]))
            if ($missing -ne 0) { return $missing }
        }
        $comparison = if ($Column -eq "OpenPorts") {
            $left.OpenPorts.CompareTo($right.OpenPorts)
        } else {
            [string]::Compare($left[$Column], $right[$Column], [StringComparison]::OrdinalIgnoreCase)
        }
        if ($comparison -eq 0) {
            $comparison = [string]::Compare($left.Mac, $right.Mac, [StringComparison]::Ordinal)
        }
        if (-not $Ascending) { $comparison = -$comparison }
        return $comparison
    })
    $scroll = (Find-DeviceElement ResultsList).GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, 0) }
    Start-Sleep -Milliseconds 350
    $rows = @(Get-DeviceRows)
    if ($rows.Count -lt 4) { throw "Sorting fixture must realize at least four rows." }
    for ($index = 0; $index -lt $rows.Count; $index++) {
        $address = ($rows[$index].Current.HelpText -split "`n" |
            Where-Object { $_.StartsWith("IP address: ") }) -replace "^IP address: ", ""
        if ($address -ne $ordered[$index].Address) {
            throw "$Column ascending=${Ascending}: row $index is '$address', expected '$($ordered[$index].Address)'."
        }
    }
}

function Test-DeviceColumnSorting {
    Set-DeviceWidth 1880
    Select-DevicePage Settings
    (Find-DeviceElement ResetColumnsButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Set-DeviceFilterChoice CompactRowsSwitch Standard
    Select-DevicePage DevicesNavItem
    $search = (Find-DeviceElement ResultSearchBox).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $search.SetValue("127.0.0.1")
    $expected = @($results | Where-Object { $_.address -eq "127.0.0.1" -or $_.address -match "^127\.0\.0\.1[0-9]$" } |
        ForEach-Object { @{
            Address = $_.address; Name = $_.deviceName; Vendor = $_.vendorName
            OpenPorts = $_.openPorts.Count; Mac = $_.macAddress; Person = ""; Room = ""; LastSeen = ""
        } })
    foreach ($merged in @($false, $true)) {
        Select-DevicePage Settings
        foreach ($label in @("Combine Name and Type", "Combine Vendor and OS", "Combine Person and Room")) {
            Set-ColumnOption $label $merged
        }
        Select-DevicePage DevicesNavItem
        foreach ($column in @("Name", "Vendor", "OpenPorts", "Person", "Room")) {
            $prefix = if ($merged -and $column -in @("Person", "Room")) { "Merged$column" } else { $column }
            foreach ($ascending in @($true, $false)) {
                Invoke-DeviceSort "${prefix}SortButton" "${prefix}SortGlyph" $ascending
                Assert-SortedFixture $column $ascending $expected
            }
        }
    }

    # Assignment edits must reorder an already-active sort without selecting it again.
    $search.SetValue("Fixture device 01")
    Start-Sleep -Milliseconds 350
    $row = @(Get-DeviceRows)[0]
    $row.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $row.SetFocus()
    [DevicesReviewInput]::Tap(0x0D)
    Start-Sleep -Milliseconds 350
    $detailsScroll = (Find-DeviceElement DeviceDetailsScroll).GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    if ($detailsScroll.Current.VerticallyScrollable) { $detailsScroll.SetScrollPercent(-1, 0) }
    Set-DeviceFilterChoice DevicePersonPicker "UI · UI review person"
    Set-DeviceFilterChoice DeviceRoomPicker "UI · UI review room"
    Select-DevicePage DevicesNavItem
    $search.SetValue("127.0.0.1")
    $first = $expected | Where-Object { $_.Address -eq "127.0.0.1" }
    $first.Person = "UI review person"
    $first.Room = "UI review room"
    Assert-SortedFixture Room $false $expected
    if ((Find-DeviceElement MergedRoomSortGlyph).Current.Name -ne [string][char]0x2193) {
        throw "Assignment updates lost the selected sort direction."
    }
    Invoke-DeviceSort MergedPersonSortButton MergedPersonSortGlyph $true
    Assert-SortedFixture Person $true $expected
    Invoke-DeviceSort MergedPersonSortButton MergedPersonSortGlyph $false
    Assert-SortedFixture Person $false $expected

    # Room-only uses the assignment slot, not the separate or merged Room header.
    Select-DevicePage Settings
    Set-ColumnOption "Person" $false
    Select-DevicePage DevicesNavItem
    Invoke-DeviceSort RoomOnlySortButton RoomOnlySortGlyph $true
    Assert-SortedFixture Room $true $expected
    Invoke-DeviceSort RoomOnlySortButton RoomOnlySortGlyph $false
    Assert-SortedFixture Room $false $expected
    Select-DevicePage Settings
    Set-ColumnOption "Person" $true
    Select-DevicePage DevicesNavItem
    if ((Find-DeviceElement MergedRoomSortGlyph).Current.Name -ne [string][char]0x2193) {
        throw "Switching assignment layout lost the selected sort."
    }

    # Every fixture row responded in the displayed scan, so equal Last seen values fall back to MAC order.
    foreach ($ascending in @($true, $false)) {
        Invoke-DeviceSort LastSeenSortButton LastSeenSortGlyph $ascending
        Assert-SortedFixture LastSeen $ascending $expected
    }
    foreach ($row in @(Get-DeviceRows)) {
        $lastSeen = Get-VisibleDeviceChild $row AutomationId DeviceLastSeenText
        if (-not $lastSeen -or $lastSeen.Current.Name -notlike "Last seen: Online - responded in the displayed scan (*)") {
            throw "Current responses must show Online with an exact accessible timestamp."
        }
        $rendered = $lastSeen.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(-1)
        if ($rendered -cne "Online") { throw "Current responses must render Online, not '$rendered'." }
        if ($row.Current.HelpText -notlike "*`nLast seen: Online - responded in the displayed scan (*)*") {
            throw "Row values must include the full Last seen value."
        }
    }

    Invoke-DeviceSort NameSortButton NameSortGlyph $true
    Invoke-DeviceSort NameSortButton NameSortGlyph $false
    $search.SetValue("Fixture device 01")
    Start-Sleep -Milliseconds 350
    $row = @(Get-DeviceRows)[0]
    $row.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $row.SetFocus()
    [DevicesReviewInput]::Tap(0x0D)
    Start-Sleep -Milliseconds 350
    (Find-DeviceElement DeviceRenameButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    (Find-DeviceElement DeviceNameInput).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue("ZZ sorting update")
    # The Save action is enabled by the asynchronous text-changed handler.
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Find-DeviceElement DeviceNameSaveButton).Current.IsEnabled -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    (Find-DeviceElement DeviceNameSaveButton).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 100
        $saved = (Find-DeviceElement DeviceNameSaveButton).Current.Name -like "*Saved"
    } while (-not $saved -and [DateTime]::UtcNow -lt $deadline)
    if (-not $saved) { throw "Sorting fixture name update was not saved." }
    Select-DevicePage DevicesNavItem
    $first.Name = "ZZ sorting update"
    $search.SetValue("127.0.0.1")
    Assert-SortedFixture Name $false $expected
    Clear-DeviceFilters
    if ((Find-DeviceElement NameSortGlyph).Current.Name -ne [string][char]0x2193) {
        throw "Clearing filters lost the selected sort direction."
    }
    $null = Save-DeviceCapture "devices-column-sorting"
}

$savedReview = $env:FINGVIBE_UI_REVIEW
$savedSnapshot = $env:FINGVIBE_UI_REVIEW_SNAPSHOT
$savedCurrentSnapshot = $env:FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT
$process = $null
$fixture = $null
$previousContext = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
try {
    $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
    $fixture = Join-Path (Resolve-Path -LiteralPath $ScreenshotDirectory).Path "devices-fixture-$([Guid]::NewGuid().ToString('N')).json"
    $results = @(
        @{
            address = "127.0.0.1"; status = 0; roundtripTimeMilliseconds = 12
            probeDuration = "00:00:00.002"; deviceName = "Fixture device 01"
            macAddress = "001122334401"
            vendorName = "Example Devices with a deliberately long manufacturer name for hover inspection"
            classification = @{ type = 1; operatingSystem = 2; operatingSystemIsInferred = $true }
            openPorts = @(@{ port = 443; serviceName = "HTTPS" })
        },
        @{
            address = "127.0.0.2"; status = 0; roundtripTimeMilliseconds = 24
            probeDuration = "00:00:00.002"; deviceName = "Kitchen display"
            macAddress = "001122334402"; vendorName = "Example Devices"
            openPorts = @(@{ port = 8009; serviceName = "Cast" })
        },
        @{
            address = "127.0.0.3"; status = 0; roundtripTimeMilliseconds = 36
            probeDuration = "00:00:00.002"; deviceName = $null
            macAddress = "001122334403"; vendorName = "Unknown"; openPorts = @()
        },
        @{
            address = "127.0.0.4"; status = 0; roundtripTimeMilliseconds = 48
            probeDuration = "00:00:00.002"; deviceName = $null
            macAddress = "001122334404"; vendorName = "Unknown"; openPorts = @()
        },
        @{
            address = "127.0.0.5"; status = 0; roundtripTimeMilliseconds = 60
            probeDuration = "00:00:00.002"; deviceName = $null
            macAddress = "001122334405"; vendorName = "Private"; openPorts = @()
        }
    )
    $results += @(6..80 | ForEach-Object {
        $device = @{
            address = "127.0.0.$_"; status = 0; roundtripTimeMilliseconds = $_ * 2
            probeDuration = "00:00:00.002"; deviceName = "Fixture device $('{0:D2}' -f $_)"
            macAddress = "0011223344$('{0:X2}' -f $_)"
            vendorName = "Fixture vendor"; openPorts = @()
        }
        if ($_ % 2 -eq 0) { $device.openPorts = @(@{ port = 443; serviceName = "HTTPS" }) }
        $device
    })
    @{ version = 3; subnet = "127.0.0.0/24"; completedAt = [DateTimeOffset]::UtcNow.ToString("O")
       duration = "00:00:02.500"; results = $results } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $fixture -Encoding UTF8
    $env:FINGVIBE_UI_REVIEW = "1"
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = $fixture
    $env:FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT = "1"
    $process = Start-Process -FilePath (Resolve-Path -LiteralPath $AppPath).Path -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $process.Refresh()
        if ($process.HasExited) { throw "Review app exited with code $($process.ExitCode)." }
        Start-Sleep -Milliseconds 100
    } while ($process.MainWindowHandle -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline)
    $windowHandle = $process.MainWindowHandle
    if ($windowHandle -eq [IntPtr]::Zero) { throw "Review app did not open a window." }
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
    $null = [UiReviewNativeWindow]::ShowWindow($windowHandle, 9)
    $scale = [UiReviewNativeWindow]::GetDpiForWindow($windowHandle) / 96.0
    Select-DevicePage OverviewNavItem
    $scanButtonCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "ScanButton")
    $scanButton = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $scanButtonCondition)
    if ($scanButton -and -not $scanButton.Current.IsOffscreen) {
        throw "Scan LAN must only be available on the Devices page."
    }
    Set-DeviceWidth 1280
    Focus-DeviceWindow
    Select-DevicePage DevicesNavItem
    $null = Find-DeviceElement ScanButton
    $networkLabelCondition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, "Network:"),
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Text))
    if (-not $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $networkLabelCondition)) {
        throw "The shared network selector must be labeled 'Network:'."
    }
    $heading = (Find-DeviceElement DevicesHeading).Current.BoundingRectangle
    $inventory = (Find-DeviceElement InventoryCountsText).Current.BoundingRectangle
    $deviceCount = (Find-DeviceElement ResultCountText).Current.BoundingRectangle
    $scanSummary = (Find-DeviceElement LastScanText).Current.BoundingRectangle
    foreach ($id in @("OnlineChip", "OfflineChip", "UnknownChip", "FingOnlyChip")) {
        $chip = (Find-DeviceElement $id).Current.BoundingRectangle
        if ([Math]::Abs($chip.Top - $inventory.Top) -gt $scale -or $chip.Height -gt 28 * $scale) {
            throw "Wide status totals must be compact, content-sized toggles in one horizontal row."
        }
    }
    if ($heading.Bottom -ge $inventory.Top -or
        [Math]::Abs($inventory.Left - $heading.Left - 16 * $scale) -gt 2 * $scale) {
        throw "Devices title must sit above the card contents, outside their 16-DIP inset."
    }
    if ($heading.Bottom -ge $deviceCount.Top -or $heading.Bottom -ge $scanSummary.Top -or
        [Math]::Abs(($inventory.Top + $inventory.Bottom - $deviceCount.Top - $deviceCount.Bottom) / 2) -gt 2 * $scale -or
        [Math]::Abs(($inventory.Top + $inventory.Bottom - $scanSummary.Top - $scanSummary.Bottom) / 2) -gt 2 * $scale) {
        throw "Inventory totals, Showing count, and Scan duration must share the summary row at wide widths."
    }
    if ((Find-DeviceElement ResultCountText).Current.Name -ne "Showing 80 devices") { throw "Multi-device fixture did not load." }
    if ((Find-DeviceElement LastScanText).Current.Name -ne "Scan duration 2.5s") {
        throw "The Devices summary must show duration without duplicating header freshness."
    }
    if (-not $root.FindFirst(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, "Private 00-11-22"))) {
        throw "The screenshot fixture must include a virtual device."
    }
    $virtualRow = @(Get-DeviceRows)[4]
    $virtualIcon = Get-VisibleDeviceChild $virtualRow AutomationId DeviceIcon
    $normalIcon = Get-VisibleDeviceChild (@(Get-DeviceRows)[0]) AutomationId DeviceIcon
    $virtualName = Get-VisibleDeviceChild $virtualRow AutomationId DeviceNameText
    if ($virtualRow.Current.HelpText -notlike "*Virtual device - inferred identity across changing MAC addresses.*" -or
        -not $virtualIcon -or $virtualIcon.Current.Name -ne "Virtual device - inferred identity across changing MAC addresses." -or
        -not $normalIcon -or $normalIcon.Current.Name -like "*Virtual device*" -or
        -not $virtualName -or $virtualName.Current.Name -ne "Private 00-11-22" -or
        (Get-VisibleDeviceChild $root AutomationId VirtualIdentityBadge)) {
        throw "Virtual identities must use the main device icon without a separate badge or name decoration."
    }
    if ([Math]::Abs($virtualIcon.Current.BoundingRectangle.Left - $normalIcon.Current.BoundingRectangle.Left) -gt $scale -or
        [Math]::Abs($virtualIcon.Current.BoundingRectangle.Width - $normalIcon.Current.BoundingRectangle.Width) -gt $scale) {
        throw "The virtual-device icon must occupy the same position and width as the normal device icon."
    }
    $virtualRow.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $virtualRow.SetFocus()
    [DevicesReviewInput]::Tap(0x0D)
    $null = Find-DeviceElement DeviceDetailsScroll
    if ((Find-DeviceElement DeviceTypeIcon).Current.Name -ne "Virtual device - inferred identity across changing MAC addresses.") {
        throw "Device details must use the same accessible virtual-device icon as the list."
    }
    $null = Save-DeviceCapture "devices-virtual-device-details"
    Select-DevicePage DevicesNavItem
    Test-ExpandableDeviceFilters
    Assert-FilterPresentation InventoryStatusFilter Status
    Assert-FilterPresentation PersonFilter Person
    Assert-FilterPresentation RoomFilter Room
    Set-DeviceFilterChoice InventoryStatusFilter Online
    Assert-FilterPresentation InventoryStatusFilter Status Online
    $null = Save-DeviceCapture "devices-selected-status-filter"
    Set-DeviceFilterChoice InventoryStatusFilter Unknown
    Assert-FilterPresentation InventoryStatusFilter Status Unknown
    if ((Find-DeviceElement ResultCountText).Current.Name -ne "Showing 0 of 80 devices") {
        throw "Unknown remains a meaningful status filter."
    }
    Set-DeviceFilterChoice InventoryStatusFilter "All statuses"
    Assert-FilterPresentation InventoryStatusFilter Status
    Set-DeviceFilterChoice PersonFilter Unassigned
    Assert-FilterPresentation PersonFilter Person Unassigned
    Set-DeviceFilterChoice PersonFilter "All people"
    Set-DeviceFilterChoice RoomFilter Unassigned
    Assert-FilterPresentation RoomFilter Room Unassigned
    Set-DeviceFilterChoice RoomFilter "All rooms"
    if ((Find-DeviceElement ResultCountText).Current.Name -ne "Showing 80 devices") { throw "All options must reset filters." }
    Test-FilterChips
    Test-ConditionalDeviceColumns
    Test-MergeOptions
    Test-RowDensity
    Test-MergedAssignments
    Test-CellPreviews

    Set-DeviceFilterChoice PersonFilter "UI · UI review person"
    Set-DeviceFilterChoice RoomFilter "UI · UI review room"
    Assert-FilterPresentation PersonFilter Person "UI · UI review person"
    Assert-FilterPresentation RoomFilter Room "UI · UI review room"
    $widths = @{}
    foreach ($width in @(1360, 1280, 1200, 1000, 640, 480)) {
        Set-DeviceWidth $width
        if ($width -ge 640) { $null = Save-DeviceCapture "devices-width-$width" }
        $chipBounds = @("OnlineChip", "OfflineChip", "UnknownChip", "FingOnlyChip") |
            ForEach-Object { (Find-DeviceElement $_).Current.BoundingRectangle }
        foreach ($bounds in $chipBounds) {
            if ($bounds.Left -lt $root.Current.BoundingRectangle.Left -or
                $bounds.Right -gt $root.Current.BoundingRectangle.Right) {
                throw "Summary chips must wrap inside the viewport at $width."
            }
        }
        $filters = @("ResultSearchBox", "InventoryStatusFilter", "FilterExpander", "TypeFilter",
            "OperatingSystemFilter", "VendorFilter", "PersonFilter", "RoomFilter", "PortsFilter", "UsageCategoryFilter") |
            ForEach-Object { Find-DeviceElement $_ }
        $widths[$width] = $filters[0].Current.BoundingRectangle.Width
        if ($widths[$width] -lt 180 * $scale) { throw "Search must remain usable before filters wrap at $width." }
        for ($index = 0; $index -lt $filters.Count; $index++) {
            $bounds = Get-FilterBounds $filters[$index]
            if ($bounds.Width -le 0) { throw "Filter has no width at $width." }
            $expectedWidth = if ($index -le 2) { @(0, 210, 64)[$index] } else { $filters[3].Current.BoundingRectangle.Width / $scale }
            if ($index -gt 0 -and [Math]::Abs($bounds.Width / $scale - $expectedWidth) -gt 1) {
                throw "Filter $index must remain ${expectedWidth}px wide at $width; got $($bounds.Width / $scale)px."
            }
            if ($index -ge 3 -and ([Math]::Abs($bounds.Top - $filters[3].Current.BoundingRectangle.Top) -gt $scale -or
                -not $root.Current.BoundingRectangle.Contains($bounds))) {
                throw "Secondary dropdowns must shrink in one row, without wrapping or leaving the viewport at $width."
            }
            foreach ($other in 0..($index - 1)) {
                if ($index -eq 0) { break }
                $intersection = [System.Windows.Rect]::Intersect($bounds, (Get-FilterBounds $filters[$other]))
                if (-not $intersection.IsEmpty -and $intersection.Width -gt 0 -and $intersection.Height -gt 0) {
                    throw "Filters overlap at $width."
                }
            }
        }
    }
    # Compare widths within the inline layout, not across its wrapping breakpoint.
    if ([Math]::Abs($widths[1360] - $widths[1280] - 80 * $scale) -gt 1) {
        throw "Search must absorb the full 80-DIP window expansion."
    }
    Set-DeviceWidth 1280
    Set-DeviceFilterChoice PersonFilter "All people"
    Set-DeviceFilterChoice RoomFilter "All rooms"
    $null = Open-DeviceFilter PortsFilter
    $checkbox = Find-DeviceElement OpenPortsFilter
    $bounds = $checkbox.Current.BoundingRectangle
    $null = [DevicesReviewInput]::SetCursorPos([int]($bounds.Left + 10 * $scale), [int]($bounds.Top + $bounds.Height / 2))
    [DevicesReviewInput]::Click()
    Start-Sleep -Milliseconds 200
    $toggle = $checkbox.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    if ($toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) {
        throw "Clicking the open-ports checkbox glyph must toggle it."
    }
    if ((Find-DeviceElement ResultCountText).Current.Name -ne "Showing 40 of 80 devices") { throw "Open-ports filter did not apply." }
    $component = Get-FilterBounds $checkbox
    $null = [DevicesReviewInput]::SetCursorPos([int]($component.Left + 60 * $scale), [int]($component.Top + $component.Height / 2))
    [DevicesReviewInput]::Click()
    Start-Sleep -Milliseconds 200
    if ($toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) {
        throw "Clicking the open-ports checkbox label must also toggle it."
    }
    $checkbox.SetFocus()
    [DevicesReviewInput]::Tap(0x20)
    Start-Sleep -Milliseconds 200
    if ($toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) { throw "Keyboard checkbox toggle regressed." }
    $toggle.Toggle()
    [DevicesReviewInput]::Tap(0x1B)
    $search = (Find-DeviceElement ResultSearchBox).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $search.SetValue("no-matching-fixture")
    Start-Sleep -Milliseconds 200
    if ((Find-DeviceElement ResultCountText).Current.Name -ne "Showing 0 of 80 devices") { throw "Search count regressed." }
    $search.SetValue("")
    Start-Sleep -Milliseconds 200
    Set-DeviceFilterChoice InventoryStatusFilter Online
    Set-DeviceFilterChoice RoomFilter Unassigned
    foreach ($theme in $UiReviewAppearanceThemes) {
        Select-DevicePage Settings
        Set-UiReviewTheme -Root $root -Theme $theme
        Select-DevicePage DevicesNavItem
        Assert-DeviceStripes "devices-$theme"
        Assert-HeaderUnderline $theme
        $row = @(Get-DeviceRows)[0]
        Assert-HoverText $row $theme
        $vendorValue = "Example Devices with a deliberately long manufacturer name for hover inspection"
        $name = Get-VisibleDeviceChild $row Name $vendorValue
        $null = Assert-CellPreview $name $vendorValue "devices-preview-$theme"
        Move-ToDeviceElement (Find-DeviceElement DevicesHeading)
    }
    Set-DeviceFilterChoice InventoryStatusFilter "All statuses"
    Set-DeviceFilterChoice RoomFilter "All rooms"
    $scroll = (Find-DeviceElement ResultsList).GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    $scroll.SetScrollPercent(-1, 100)
    Start-Sleep -Milliseconds 250
    Assert-DeviceStripes "devices-recycled-bottom"
    $scroll.SetScrollPercent(-1, 0)
    Start-Sleep -Milliseconds 250
    Assert-DeviceStripes "devices-recycled-top"
    $search.SetValue("Fixture device 1")
    Start-Sleep -Milliseconds 250
    Assert-DeviceStripes "devices-filtered"
    $search.SetValue("")
    Start-Sleep -Milliseconds 250
    $rows = @(Get-DeviceRows)
    $progressCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::ProgressBar)
    $bar = $rows[0].FindFirst([System.Windows.Automation.TreeScope]::Descendants, $progressCondition)
    if (-not $bar) { throw "Response bar was not found." }
    $labelCondition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::Text),
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, $bar.Current.Name))
    $label = $rows[0].FindFirst([System.Windows.Automation.TreeScope]::Descendants, $labelCondition)
    if (-not $label -or $label.Current.BoundingRectangle.Bottom -gt $bar.Current.BoundingRectangle.Top -or
        $bar.Current.BoundingRectangle.Width / $scale -lt 150) {
        throw "Combined response must use a readable number above a shared full-width bar."
    }
    $rowBounds = $rows[1].Current.BoundingRectangle
    Focus-DeviceWindow
    [DevicesReviewInput]::MoveTo([int]($rowBounds.Left + 100 * $scale),
        [int]($rowBounds.Top + $rowBounds.Height / 2))
    Start-Sleep -Milliseconds 250
    $path = Save-DeviceCapture "devices-hover" -KeepPointer
    $bitmap = [System.Drawing.Bitmap]::new($path)
    try {
        if ((Get-RowColor $bitmap $rows[1]) -eq (Get-RowColor $bitmap $rows[3])) {
            throw "Hover must override the alternate background."
        }
    }
    finally { $bitmap.Dispose() }
    $null = Save-DeviceCapture "devices-hover-cleared"
    $selection = $rows[1].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    $selection.Select()
    $path = Save-DeviceCapture "devices-selected"
    $bitmap = [System.Drawing.Bitmap]::new($path)
    try {
        $selectedColor = Get-RowColor $bitmap $rows[1]
        if ($selectedColor -eq (Get-RowColor $bitmap $rows[3])) {
            throw "Selection must override the alternate background."
        }
    }
    finally { $bitmap.Dispose() }
    $sort = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent((Find-DeviceElement AddressSortGlyph))
    while ($sort -and $sort.Current.ControlType -ne [System.Windows.Automation.ControlType]::Button) {
        $sort = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($sort)
    }
    if (-not $sort) { throw "Address sort button was not found." }
    $sort.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 250
    $listSelection = (Find-DeviceElement ResultsList).GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern)
    $selected = @($listSelection.Current.GetSelection())
    if ($selected.Count -ne 1) { throw "Sorting must preserve selection." }
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $selected = @($listSelection.Current.GetSelection())
        if ($selected.Count -ne 1) { throw "Scrolling must preserve the selected device." }
        $selectedBounds = $selected[0].Current.BoundingRectangle
        $listBounds = (Find-DeviceElement ResultsList).Current.BoundingRectangle
        $visible = -not $selected[0].Current.IsOffscreen -and -not $selectedBounds.IsEmpty -and
            $selectedBounds.Top -ge $listBounds.Top -and $selectedBounds.Bottom -le $listBounds.Bottom
        if ($visible) { break }
        # Density changes alter virtualization estimates; reacquire selection until scrolling realizes it.
        $selected[0].GetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()
        Start-Sleep -Milliseconds 150
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $visible) { throw "The selected device did not become fully visible after sorting." }
    $nameCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::NameProperty, "Kitchen display")
    if (-not $selected[0].FindFirst([System.Windows.Automation.TreeScope]::Descendants, $nameCondition)) {
        throw "Sorting changed the selected device."
    }
    $path = Save-DeviceCapture "devices-selected-recycled"
    $bitmap = [System.Drawing.Bitmap]::new($path)
    try {
        if ((Get-RowColor $bitmap $selected[0]) -ne $selectedColor) {
            throw "A selected row's background must survive sorting and container recycling."
        }
    }
    finally { $bitmap.Dispose() }
    $selected[0].GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).RemoveFromSelection()
    $scroll.SetScrollPercent(-1, 0)
    Assert-DeviceStripes "devices-sorted"
    $sort.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 250
    $scroll.SetScrollPercent(-1, 0)
    Start-Sleep -Milliseconds 250
    $rows = @(Get-DeviceRows)
    $rows[0].SetFocus()
    [DevicesReviewInput]::Tap(0x28)
    Start-Sleep -Milliseconds 250
    $selected = @($listSelection.Current.GetSelection())
    if ($selected.Count -ne 1 -or -not $selected[0].Current.HasKeyboardFocus) {
        throw "Keyboard navigation must focus and select a device row."
    }
    $keyboardPreview = Find-DeviceElement CellPreviewText
    if ($keyboardPreview.Current.Name -ne $selected[0].Current.HelpText -or
        $keyboardPreview.Current.Name -notlike "*IP address: *MAC address: *Vendor: *Person: *Room: *") {
        throw "Keyboard focus must reveal the row's equivalent full values."
    }
    Assert-PreviewFont $keyboardPreview (Get-VisibleDeviceChild $selected[0] AutomationId DeviceNameText)
    $null = Save-DeviceCapture "devices-keyboard-focus"
    $area = [System.Windows.Forms.Screen]::FromHandle($windowHandle).WorkingArea
    if ($area.Width / $scale -ge 1880) {
        Set-DeviceWidth 1880
        $grips = @("Resize Room column", "Resize Last seen column") | ForEach-Object {
            $condition = [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, $_)
            $grip = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
            if (-not $grip -or $grip.Current.IsOffscreen) { throw "Header grip '$_' was not visible." }
            $grip
        }
        $path = Save-DeviceCapture "devices-wide-header"
        $bitmap = [System.Drawing.Bitmap]::new($path)
        try {
            $windowBounds = Get-UiReviewWindowBounds $windowHandle
            for ($index = 0; $index -lt $grips.Count; $index++) {
                $bounds = $grips[$index].Current.BoundingRectangle
                $left = $bounds.Left - $windowBounds.Left
                $y = [int]($bounds.Top - $windowBounds.Top + $bounds.Height / 2)
                $background = $bitmap.GetPixel([int]($left - 1), $y).ToArgb()
                $center = $left + $bounds.Width / 2
                $hasLine = @([Math]::Floor($center), [Math]::Ceiling($center)) |
                    Where-Object { $bitmap.GetPixel([int]$_, $y).ToArgb() -ne $background }
                if (($index -eq 0 -and -not $hasLine) -or ($index -eq 1 -and $hasLine)) {
                    throw "Only the final visible header divider should be absent."
                }
            }
        }
        finally { $bitmap.Dispose() }
        $left = $grips[1].Current.BoundingRectangle.Left
        $grips[1].SetFocus()
        [DevicesReviewInput]::Tap(0x27)
        Start-Sleep -Milliseconds 200
        if ([Math]::Abs($grips[1].Current.BoundingRectangle.Left - $left - 8 * $scale) -gt 1) {
            throw "The final column must remain keyboard-resizable without a divider."
        }
        Write-Host "Full-header pixel check and final-column keyboard resizing passed."
    }
    else { Write-Host "Full-header pixel check not run: desktop is narrower than 1880 logical pixels." }
    Test-DeviceColumnSorting
    Write-Host "Device toolbar/dropdowns, conditional columns, six-theme stripes/header underline, recycling, sorting/filtering, metadata updates, hover, selection and keyboard checks passed."
}
catch {
    Write-Host $_
    Write-Host $_.ScriptStackTrace
    if ($windowHandle -and $process -and -not $process.HasExited) {
        $failureBounds = Get-UiReviewWindowBounds $windowHandle
        if ($failureBounds.Width -ge 640 -and $failureBounds.Height -ge 480) {
            $null = Save-DeviceCapture "devices-failure" -KeepPointer
        }
        else { Write-Host "Failure window $failureBounds is below the screenshot helper's minimum; retaining its automation tree." }
        $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition) | ForEach-Object {
                "$($_.Current.AutomationId) | $($_.Current.Name) | offscreen=$($_.Current.IsOffscreen) | $($_.Current.BoundingRectangle)"
            } | Set-Content -LiteralPath (Join-Path $ScreenshotDirectory "devices-failure-tree.txt")
    }
    throw
}
finally {
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id }
    $env:FINGVIBE_UI_REVIEW = $savedReview
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = $savedSnapshot
    $env:FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT = $savedCurrentSnapshot
    if ($fixture -and (Test-Path -LiteralPath $fixture)) { Remove-Item -LiteralPath $fixture }
    $null = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext($previousContext)
}
