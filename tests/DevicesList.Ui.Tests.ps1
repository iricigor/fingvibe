[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $AppPath,

    [Parameter(Mandatory)]
    [string] $ScreenshotDirectory
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScreenshot.ps1")

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
    if ($Element.Current.ControlType -eq [System.Windows.Automation.ControlType]::ComboBox) {
        # WinUI exposes the ComboBox's 4px outer focus margin in its automation bounds.
        return [System.Windows.Rect]::new($bounds.X + 4 * $scale, $bounds.Y + 4 * $scale,
            $bounds.Width - 8 * $scale, $bounds.Height - 8 * $scale)
    }
    if ($Element.Current.AutomationId -eq "OpenPortsFilter") {
        return [System.Windows.Rect]::new($bounds.X - 11 * $scale, $bounds.Y - 4 * $scale,
            $bounds.Width + 22 * $scale, $bounds.Height + 8 * $scale)
    }
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
        $isLight = $Theme -in @("Standard Light", "Warm Light")
        if (($isLight -and $lineBrightness -ge $headerBrightness) -or
            (-not $isLight -and $lineBrightness -le $headerBrightness)) {
            throw "Header underline must be darker in light themes and lighter in dark themes."
        }
    }
    finally { $bitmap.Dispose() }
}

$savedReview = $env:FINGVIBE_UI_REVIEW
$savedSnapshot = $env:FINGVIBE_UI_REVIEW_SNAPSHOT
$process = $null
$fixture = $null
$previousContext = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
try {
    $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
    $fixture = Join-Path (Resolve-Path -LiteralPath $ScreenshotDirectory).Path "devices-fixture-$([Guid]::NewGuid().ToString('N')).json"
    $results = @(1..80 | ForEach-Object {
        $device = @{
            address = "192.0.2.$_"; status = 0; roundtripTimeMilliseconds = $_ * 2
            probeDuration = "00:00:00.002"; deviceName = "Fixture device $('{0:D2}' -f $_)"
            vendorName = "Fixture vendor"; openPorts = @()
        }
        if ($_ % 2 -eq 0) { $device.openPorts = @(@{ port = 443; serviceName = "HTTPS" }) }
        $device
    })
    @{ version = 1; subnet = "192.0.2.0/24"; completedAt = [DateTimeOffset]::UtcNow.ToString("O"); results = $results } |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $fixture -Encoding UTF8
    $env:FINGVIBE_UI_REVIEW = "1"
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = $fixture
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
    Set-DeviceWidth 1280
    Focus-DeviceWindow
    Select-DevicePage DevicesNavItem
    if ((Find-DeviceElement ResultCountText).Current.Name -ne "80 devices") { throw "Isolated fixture did not load." }

    $widths = @{}
    foreach ($width in @(1280, 1200, 1000, 640)) {
        Set-DeviceWidth $width
        $null = Save-DeviceCapture "devices-width-$width"
        $filters = @("ResultSearchBox", "PersonFilter", "RoomFilter", "OpenPortsFilter") |
            ForEach-Object { Find-DeviceElement $_ }
        $widths[$width] = $filters[0].Current.BoundingRectangle.Width
        for ($index = 0; $index -lt $filters.Count; $index++) {
            $bounds = Get-FilterBounds $filters[$index]
            if ($bounds.Width -le 0) { throw "Filter has no width at $width." }
            if ($index -gt 0 -and [Math]::Abs($bounds.Width / $scale - 180) -gt 1) {
                throw "Filter $index must remain 180px wide at $width; got $($bounds.Width / $scale)px."
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
    if ($widths[1280] -le $widths[1200]) { throw "Search does not expand with the window." }
    Set-DeviceWidth 1280
    $checkbox = Find-DeviceElement OpenPortsFilter
    $bounds = $checkbox.Current.BoundingRectangle
    $null = [DevicesReviewInput]::SetCursorPos([int]($bounds.Right - 8 * $scale), [int]($bounds.Top + $bounds.Height / 2))
    [DevicesReviewInput]::Click()
    Start-Sleep -Milliseconds 200
    $toggle = $checkbox.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    if ($toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) {
        throw "Clicking the open-ports component outside its label must toggle it."
    }
    if ((Find-DeviceElement ResultCountText).Current.Name -ne "40 of 80 devices") { throw "Open-ports filter did not apply." }
    $component = Get-FilterBounds $checkbox
    $null = [DevicesReviewInput]::SetCursorPos([int]($component.Left + 5 * $scale), [int]($component.Top + $component.Height / 2))
    [DevicesReviewInput]::Click()
    Start-Sleep -Milliseconds 200
    if ($toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) {
        throw "Clicking the bordered component's padding must also toggle it."
    }
    $checkbox.SetFocus()
    [DevicesReviewInput]::Tap(0x20)
    Start-Sleep -Milliseconds 200
    if ($toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) { throw "Keyboard checkbox toggle regressed." }
    $toggle.Toggle()
    $search = (Find-DeviceElement ResultSearchBox).GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $search.SetValue("no-matching-fixture")
    Start-Sleep -Milliseconds 200
    if ((Find-DeviceElement ResultCountText).Current.Name -ne "0 of 80 devices") { throw "Search count regressed." }
    $search.SetValue("")
    Start-Sleep -Milliseconds 200
    foreach ($theme in @("Standard Light", "Warm Light", "Standard Dark", "True Black (OLED)")) {
        Select-DevicePage Settings
        $picker = Find-DeviceElement ThemePicker
        $picker.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
        $condition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, $theme)
        $choice = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if (-not $choice) { throw "Theme '$theme' not found." }
        $choice.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        $picker.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse()
        Select-DevicePage DevicesNavItem
        Assert-DeviceStripes "devices-$theme"
        Assert-HeaderUnderline $theme
    }
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
        $bar.Current.BoundingRectangle.Width / $scale -gt 100) {
        throw "Response must use a readable number above a compact bar."
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
    $selected[0].GetCurrentPattern([System.Windows.Automation.ScrollItemPattern]::Pattern).ScrollIntoView()
    Start-Sleep -Milliseconds 250
    $selected = @($listSelection.Current.GetSelection())
    $nameCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::NameProperty, "Fixture device 02")
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
    $rows = @(Get-DeviceRows)
    $rows[0].SetFocus()
    [DevicesReviewInput]::Tap(0x28)
    Start-Sleep -Milliseconds 250
    $selected = @($listSelection.Current.GetSelection())
    if ($selected.Count -ne 1 -or -not $selected[0].Current.HasKeyboardFocus) {
        throw "Keyboard navigation must focus and select a device row."
    }
    $null = Save-DeviceCapture "devices-keyboard-focus"
    $area = [System.Windows.Forms.Screen]::FromHandle($windowHandle).WorkingArea
    if ($area.Width / $scale -ge 1880) {
        Set-DeviceWidth 1880
        $grips = @("Resize Person column", "Resize Room column") | ForEach-Object {
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
    Write-Host "Device toolbar, compact response, four-theme stripes/header underline, recycling, sorting/filtering, hover, selection and keyboard checks passed."
}
finally {
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id }
    $env:FINGVIBE_UI_REVIEW = $savedReview
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = $savedSnapshot
    if ($fixture -and (Test-Path -LiteralPath $fixture)) { Remove-Item -LiteralPath $fixture }
    $null = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext($previousContext)
}
