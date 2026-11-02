[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $AppPath,

    [Parameter(Mandatory)]
    [string] $ScreenshotDirectory,

    [ValidateRange(1024, 1280)]
    [int] $ExpandedWindowWidth = 1280
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScreenshot.ps1")
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewAppearance.ps1")

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class SidebarReviewKeyboard
{
    [DllImport("user32.dll")]
    private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);

    public static void Tap(byte key)
    {
        keybd_event(key, 0, 0, UIntPtr.Zero);
        keybd_event(key, 0, 2, UIntPtr.Zero);
    }
}
"@

function Find-SidebarElement([string] $Property, [string] $Value) {
    $propertyId = switch ($Property) {
        "Name" { [System.Windows.Automation.AutomationElement]::NameProperty }
        "AutomationId" { [System.Windows.Automation.AutomationElement]::AutomationIdProperty }
        default { throw "Unsupported automation property '$Property'." }
    }
    $condition = [System.Windows.Automation.PropertyCondition]::new($propertyId, $Value)
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $element = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if ($element -and -not $element.Current.IsOffscreen) { return $element }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Visible sidebar test element '$Value' was not found."
}

function Select-SidebarPage([string] $Name, [string] $Sentinel) {
    $condition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, $Name),
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::ListItem))
    $element = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if (-not $element -or $element.Current.IsOffscreen) { throw "Navigation '$Name' is not visible." }
    $selection = $element.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    $selection.Select()
    if (-not $selection.Current.IsSelected) { throw "Navigation did not select '$Name'." }
    $null = Find-SidebarElement Name $Sentinel
    Start-Sleep -Milliseconds 350
}

function Assert-SharedNetworkHeader {
    $elements = @("DetectedNetworkLabel", "NetworkPicker", "ScanFreshnessText") |
        ForEach-Object { Find-SidebarElement AutomationId $_ }
    $bounds = @($elements | ForEach-Object { $_.Current.BoundingRectangle })
    for ($index = 1; $index -lt $bounds.Count; $index++) {
        $previousCenter = $bounds[$index - 1].Top + $bounds[$index - 1].Height / 2
        $center = $bounds[$index].Top + $bounds[$index].Height / 2
        if ([Math]::Abs($center - $previousCenter) -gt 3 * $scale) {
            throw "Shared network header elements must be vertically centered on one row."
        }
        if ($bounds[$index].Left -lt $bounds[$index - 1].Right) {
            throw "Shared network header elements overlap."
        }
    }
    if ([string]::IsNullOrWhiteSpace($elements[2].Current.Name)) {
        throw "Shared network freshness must not disappear on any page."
    }
}

function Set-SidebarAppearance([string] $Picker, [string] $Choice) {
    Select-SidebarPage Settings "Window backdrop"
    if ($Picker -eq "ThemePicker") {
        Set-UiReviewTheme -Root $root -Theme $Choice
    }
    else {
        Set-UiReviewAppearanceChoice -Root $root -Picker $Picker -Choice $Choice
    }
    Start-Sleep -Milliseconds 500
    Select-SidebarPage People "Search people"
}

function Focus-SidebarWindow {
    [SidebarReviewKeyboard]::Tap(0x12)
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $null = [UiReviewNativeWindow]::SetForegroundWindow($windowHandle)
        Start-Sleep -Milliseconds 100
        if ([UiReviewNativeWindow]::GetForegroundWindow() -eq $windowHandle) { return }
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Review app could not be brought to the foreground."
}

function Save-SidebarAppearance([string] $Name, [switch] $AssertMatchingSolid) {
    $path = Join-Path $ScreenshotDirectory "$Name.png"
    Focus-SidebarWindow
    Start-Sleep -Milliseconds 250
    Save-UiReviewWindowScreenshot $windowHandle $path
    if (-not $AssertMatchingSolid) { return }
    $menuBounds = (Find-SidebarElement AutomationId NetworkNavItem).Current.BoundingRectangle
    $windowBounds = Get-UiReviewWindowBounds $windowHandle
    $bitmap = [System.Drawing.Bitmap]::new($path)
    try {
        $x = [int] ($menuBounds.Left - $windowBounds.Left + 80 * $scale)
        $mainX = [int] ($windowBounds.Width - 20 * $scale)
        $y = [int] ($windowBounds.Height - 160 * $scale)
        if ($bitmap.GetPixel($x, $y).ToArgb() -ne $bitmap.GetPixel($mainX, $y).ToArgb()) {
            throw "The sidebar and main page background colors must match in '$Name'."
        }
    }
    finally { $bitmap.Dispose() }
}

function Set-SidebarWindowWidth([int] $LogicalWidth) {
    $bounds = Get-UiReviewWindowBounds $windowHandle
    $width = [int] ($LogicalWidth * $scale)
    $area = [System.Windows.Forms.Screen]::FromHandle($windowHandle).WorkingArea
    if ($width -gt $area.Width) { throw "This test requires a desktop at least $LogicalWidth logical pixels wide." }
    if (-not [UiReviewNativeWindow]::SetWindowPos(
            $windowHandle, [IntPtr]::Zero, $area.Left, $bounds.Top, $width,
            [Math]::Min($bounds.Height, [int] (720 * $scale)), 0x0044)) {
        throw [System.ComponentModel.Win32Exception]::new()
    }
    Start-Sleep -Milliseconds 750
}

function Switch-SidebarPane {
    $toggle = Find-SidebarElement AutomationId TogglePaneButton
    $toggle.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 500
}

function Test-SettingsLayout {
    Set-SidebarWindowWidth $expandedWidth
    Select-SidebarPage Settings "Window backdrop"
    $ribbon = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "BuildRibbon"))
    if ($ribbon -and -not $ribbon.Current.IsOffscreen) {
        $ribbon.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        Start-Sleep -Milliseconds 250
    }
    Set-UiReviewAppearanceChoice -Root $root -Picker BackdropPicker -Choice Solid
    foreach ($style in @("Standard", "Warm", "Colorful")) {
        Set-UiReviewAppearanceChoice -Root $root -Picker ModePicker -Choice Light
        Set-UiReviewAppearanceChoice -Root $root -Picker ThemePicker -Choice $style
        Set-UiReviewAppearanceChoice -Root $root -Picker ModePicker -Choice Dark
        $expected = if ($style -eq "Warm") { "True Black (OLED)" } else { $style }
        $picker = Find-SidebarElement AutomationId ThemePicker
        $selection = $picker.GetCurrentPattern([System.Windows.Automation.SelectionPattern]::Pattern)
        $actual = $selection.Current.GetSelection()[0].Current.Name
        Save-SidebarAppearance "settings-mode-$style"
        if ($actual -ne $expected) {
            throw "Mode switching did not preserve/map theme '$style' to '$expected'; got '$actual'."
        }
        Set-UiReviewAppearanceChoice -Root $root -Picker ModePicker -Choice Light
        if ($selection.Current.GetSelection()[0].Current.Name -ne $style) {
            throw "Mode switching did not restore theme '$style'."
        }
    }
    foreach ($theme in $UiReviewAppearanceThemes) {
        Set-UiReviewTheme -Root $root -Theme $theme
        Save-SidebarAppearance "settings-$theme"
    }
    foreach ($width in @($expandedWidth, 640, 480)) {
        Set-SidebarWindowWidth $width
        $scroll = (Find-SidebarElement AutomationId SettingsPage).GetCurrentPattern(
            [System.Windows.Automation.ScrollPattern]::Pattern)
        if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, 0) }
        Start-Sleep -Milliseconds 200
        $pickers = @("ModePicker", "ThemePicker", "BackdropPicker") |
            ForEach-Object { (Find-SidebarElement AutomationId $_).Current.BoundingRectangle }
        $inline = $width -eq $expandedWidth
        if ($inline) {
            if ([Math]::Abs($pickers[0].Top - $pickers[2].Top) -gt 2 * $scale -or
                $pickers[0].Right -gt $pickers[1].Left -or $pickers[1].Right -gt $pickers[2].Left) {
                throw "Appearance selectors must share a non-overlapping row at $width."
            }
        }
        elseif ($pickers[0].Bottom -gt $pickers[1].Top -or $pickers[1].Bottom -gt $pickers[2].Top) {
            throw "Appearance selectors must stack without overlap at $width."
        }
        $reset = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "ResetColumnsButton"))
        if (-not $reset) { throw "Reset columns is missing." }
        if ($inline -and ($reset.Current.IsOffscreen -or $scroll.Current.VerticallyScrollable)) {
            throw "The complete Settings page must fit at $width x 720 without scrolling."
        }
        if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, 100) }
        Start-Sleep -Milliseconds 200
        $choices = Find-SidebarElement AutomationId SettingsPage
        $checkboxes = $choices.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::CheckBox))
        $headers = @("Name", "IP address", "Vendor", "Open ports", "Status", "Response",
            "MAC address", "OS", "Device type", "Person", "Room")
        if ($checkboxes.Count -ne $headers.Count) { throw "Expected all eleven column choices at $width." }
        $columns = if ($inline) { 3 } elseif ($width -eq 640) { 2 } else { 1 }
        for ($index = 0; $index -lt $checkboxes.Count; $index++) {
            $box = $checkboxes[$index]
            if ($box.Current.Name -ne $headers[$index]) { throw "Column order changed at $width." }
            $bounds = $box.Current.BoundingRectangle
            $rowStart = $checkboxes[$index - $index % $columns].Current.BoundingRectangle
            if ([Math]::Abs($bounds.Top - $rowStart.Top) -gt 2 * $scale) {
                throw "Expected $columns columns at $width."
            }
            if ($index -ge $columns -and $bounds.Top -lt $checkboxes[$index - $columns].Current.BoundingRectangle.Bottom) {
                throw "Column choices overlap vertically at $width."
            }
            if ($index % $columns -gt 0 -and $bounds.Left -lt $checkboxes[$index - 1].Current.BoundingRectangle.Right) {
                throw "Column choices overlap horizontally at $width."
            }
        }
        foreach ($mandatory in @($checkboxes[0], $checkboxes[1])) {
        if ($mandatory.Current.IsEnabled -or $mandatory.GetCurrentPattern(
                [System.Windows.Automation.TogglePattern]::Pattern).Current.ToggleState -ne
                [System.Windows.Automation.ToggleState]::On) {
            throw "Name and IP address must remain checked and mandatory."
        }
        }
        if ($width -ge 640) { Save-SidebarAppearance "settings-layout-$width" }
    }
    Set-SidebarWindowWidth $expandedWidth
    if ((Find-SidebarElement AutomationId NetworkNavItem).Current.BoundingRectangle.Width / $scale -lt 80) {
        Switch-SidebarPane
    }
    $vendor = $checkboxes[2]
    $toggle = $vendor.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    $toggle.Toggle()
    if ($toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) {
        throw "Column visibility did not update."
    }
    (Find-SidebarElement AutomationId ResetColumnsButton).GetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    if ($toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) {
        throw "Reset columns did not restore visibility."
    }
    Set-UiReviewTheme -Root $root -Theme "Standard Dark"
    Select-SidebarPage People "Search people"
    Write-Host "Settings mode/theme mapping, six palettes, responsive bounds, mandatory IP, and column reset passed."
}

function Wait-DeviceScan {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Find-SidebarElement AutomationId ScanButton).Current.IsEnabled) {
        if ([DateTime]::UtcNow -ge $deadline) { throw "The device scan did not stop." }
        Start-Sleep -Milliseconds 50
    }
}

function Test-DeviceRefresh {
    $snapshotPath = if ($env:FINGVIBE_UI_REVIEW_SNAPSHOT) { $env:FINGVIBE_UI_REVIEW_SNAPSHOT }
        else { Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "FingVibe\latest-scan.json" }
    $snapshot = if (Test-Path -LiteralPath $snapshotPath) { [IO.File]::ReadAllBytes($snapshotPath) } else { $null }
    try {
        Set-SidebarWindowWidth $expandedWidth
        Select-SidebarPage Devices "Search devices"
        $scan = Find-SidebarElement AutomationId ScanButton
        $scan.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        Wait-DeviceScan
        if ((Find-SidebarElement AutomationId ResultCountText).Current.Name -ne "1 device") {
            throw "The loopback scan must display exactly one device."
        }
        $search = (Find-SidebarElement AutomationId ResultSearchBox).GetCurrentPattern(
            [System.Windows.Automation.ValuePattern]::Pattern)
        $search.SetValue("fingvibe-no-matching-device")
        Start-Sleep -Milliseconds 200
        if ((Find-SidebarElement AutomationId ResultCountText).Current.Name -ne "0 of 1 devices") {
            throw "Filtered device counts must include the unfiltered total."
        }
        $search.SetValue("")
        $scan.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        if ($scan.Current.IsEnabled) { throw "The refresh ended before retained results could be verified." }
        if ((Find-SidebarElement AutomationId ResultCountText).Current.Name -ne "1 device" -or
            (Find-SidebarElement AutomationId ScanStatusText).Current.Name -notlike "*Displaying retained results*") {
            throw "Refresh must retain the displayed devices and explain their status."
        }
        (Find-SidebarElement Name Cancel).GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        Wait-DeviceScan
        if ((Find-SidebarElement AutomationId ResultCountText).Current.Name -ne "1 device" -or
            (Find-SidebarElement AutomationId ScanStatusText).Current.Name -notlike "*cancelled*") {
            throw "Cancellation must preserve the displayed devices and report its outcome."
        }
        foreach ($width in @($expandedWidth, 1000, 640)) {
            Set-SidebarWindowWidth $width
            $filters = @("ResultSearchBox", "PersonFilter", "RoomFilter", "OpenPortsFilter") |
                ForEach-Object { Find-SidebarElement AutomationId $_ }
            for ($index = 0; $index -lt $filters.Count; $index++) {
                $bounds = $filters[$index].Current.BoundingRectangle
                if ($bounds.Width -le 0) { throw "A filter has no visible width at $width." }
                for ($other = 0; $other -lt $index; $other++) {
                    $intersection = [System.Windows.Rect]::Intersect($bounds, $filters[$other].Current.BoundingRectangle)
                    if (-not $intersection.IsEmpty -and $intersection.Width -gt 0 -and $intersection.Height -gt 0) {
                        throw "Device filters overlap at $width logical pixels."
                    }
                }
            }
        }
        Write-Host "Device refresh/cancellation, filtered counts, and responsive filter bounds passed."
    }
    finally {
        try {
            if ($scan) { Wait-DeviceScan }
        }
        finally {
            if ($null -ne $snapshot) { [IO.File]::WriteAllBytes($snapshotPath, $snapshot) }
            elseif (Test-Path -LiteralPath $snapshotPath) { Remove-Item -LiteralPath $snapshotPath }
        }
    }
}

$savedReviewMode = $env:FINGVIBE_UI_REVIEW
$process = $null
$previousContext = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
try {
    $env:FINGVIBE_UI_REVIEW = "1"
    $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
    $process = Start-Process -FilePath (Resolve-Path -LiteralPath $AppPath).Path -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $process.Refresh()
        if ($process.HasExited) { throw "Review app exited with code $($process.ExitCode)." }
        if ($process.MainWindowHandle -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    $windowHandle = $process.MainWindowHandle
    if ($windowHandle -eq [IntPtr]::Zero) { throw "Review app did not create a window." }
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($windowHandle)
    $null = Find-SidebarElement Name FingVibe
    Focus-SidebarWindow
    Initialize-UiReviewWindow $windowHandle
    $scale = [UiReviewNativeWindow]::GetDpiForWindow($windowHandle) / 96.0

    $area = [System.Windows.Forms.Screen]::FromHandle($windowHandle).WorkingArea
    $availableWidth = [int] [Math]::Floor($area.Width / $scale)
    $expandedWidth = [Math]::Min($ExpandedWindowWidth, $availableWidth)
    if ($expandedWidth -lt 1024) { throw "Expanded sidebar checks require a desktop at least 1024 logical pixels wide." }
    Write-Host "Testing expanded navigation at $expandedWidth logical pixels, within the available $availableWidth."
    Set-SidebarWindowWidth $expandedWidth
    $null = Find-SidebarElement Name FingVibe
    $null = Find-SidebarElement Name "LAN scanner"
    foreach ($page in @(
        @("Network", "Public IP address"),
        @("Devices", "Search devices"),
        @("Rooms", "Search rooms"),
        @("Tools", "Speed test"),
        @("Settings", "Window backdrop"),
        @("Overview", "Online devices"),
        @("People", "Search people")
    )) {
        Select-SidebarPage $page[0] $page[1]
        Assert-SharedNetworkHeader
    }
    $network = Find-SidebarElement AutomationId NetworkNavItem
    $menuBounds = $network.Current.BoundingRectangle
    if ([Math]::Abs($menuBounds.Width / $scale - 200) -gt 4) {
        throw "Expanded navigation rows must fit the 216px pane; got $($menuBounds.Width / $scale)px."
    }
    $settings = Find-SidebarElement Name Settings
    $tools = Find-SidebarElement AutomationId ToolsNavItem
    $windowBounds = Get-UiReviewWindowBounds $windowHandle
    if ($settings.Current.BoundingRectangle.Top -lt $windowBounds.Top + $windowBounds.Height / 2) {
        throw "Settings must remain pinned in the bottom of the sidebar."
    }
    if ($tools.Current.BoundingRectangle.Bottom -gt $settings.Current.BoundingRectangle.Top -or
        $tools.Current.BoundingRectangle.Top -lt $windowBounds.Top + $windowBounds.Height / 2) {
        throw "Tools must remain pinned directly above Settings."
    }
    Save-SidebarAppearance "sidebar-expanded" -AssertMatchingSolid
    Test-SettingsLayout
    foreach ($theme in $UiReviewAppearanceThemes) {
        Set-SidebarAppearance ThemePicker $theme
        Save-SidebarAppearance "sidebar-$theme" -AssertMatchingSolid
    }
    Set-SidebarAppearance ThemePicker "Standard Dark"
    foreach ($backdrop in @("Mica", "Mica Alt", "Acrylic", "Solid")) {
        Set-SidebarAppearance BackdropPicker $backdrop
        Save-SidebarAppearance "sidebar-$backdrop"
    }
    Set-SidebarAppearance BackdropPicker Mica

    Switch-SidebarPane
    $compactWidth = (Find-SidebarElement AutomationId NetworkNavItem).Current.BoundingRectangle.Width / $scale
    if ($compactWidth -ge 80) { throw "Closing the expanded pane must leave a compact icon rail." }
    Select-SidebarPage Network "Public IP address"
    $network = Find-SidebarElement AutomationId NetworkNavItem
    $network.SetFocus()
    [SidebarReviewKeyboard]::Tap(0x28)
    [SidebarReviewKeyboard]::Tap(0x0D)
    $null = Find-SidebarElement Name "Search devices"
    Start-Sleep -Milliseconds 350
    Save-SidebarAppearance "sidebar-compact"
    Switch-SidebarPane

    foreach ($width in @(800, 640)) {
        Set-SidebarWindowWidth $width
        Switch-SidebarPane
        $null = Find-SidebarElement Name "LAN scanner"
        Save-SidebarAppearance "sidebar-overlay-$width" -AssertMatchingSolid
        Select-SidebarPage People "Search people"
    }
    Write-Host "Sidebar navigation, expanded/compact/overlay layouts, and matching solid backgrounds in all six themes passed; material captures saved."
    Test-DeviceRefresh
}
finally {
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id }
    $env:FINGVIBE_UI_REVIEW = $savedReviewMode
    $null = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext($previousContext)
}
