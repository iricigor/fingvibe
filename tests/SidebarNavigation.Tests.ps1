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
    [StructLayout(LayoutKind.Sequential)]
    private struct HIGHCONTRAST
    {
        public uint Size;
        public uint Flags;
        public IntPtr Scheme;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SystemParametersInfo(uint action, uint parameter, ref HIGHCONTRAST value, uint flags);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SystemParametersInfo(uint action, uint parameter, ref int value, uint flags);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SystemParametersInfo(uint action, uint parameter, IntPtr value, uint flags);

    public static uint GetHighContrastFlags()
    {
        var value = new HIGHCONTRAST { Size = (uint)Marshal.SizeOf<HIGHCONTRAST>() };
        if (!SystemParametersInfo(0x0042, value.Size, ref value, 0))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return value.Flags;
    }

    public static void SetHighContrastFlags(uint flags)
    {
        var value = new HIGHCONTRAST { Size = (uint)Marshal.SizeOf<HIGHCONTRAST>(), Flags = flags };
        if (!SystemParametersInfo(0x0043, value.Size, ref value, 2))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }

    public static bool GetAnimations()
    {
        int value = 0;
        if (!SystemParametersInfo(0x1042, 0, ref value, 0))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        return value != 0;
    }

    public static void SetAnimations(bool enabled)
    {
        if (!SystemParametersInfo(0x1043, 0, new IntPtr(enabled ? 1 : 0), 2))
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
    }

    [DllImport("user32.dll")]
    private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);

    public static void Tap(byte key)
    {
        keybd_event(key, 0, 0, UIntPtr.Zero);
        keybd_event(key, 0, 2, UIntPtr.Zero);
    }

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")]
    private static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);

    public static void Drag(int startX, int y, int[] targets)
    {
        PressAt(startX, y);
        try
        {
            foreach (int target in targets)
            {
                for (int step = 1; step <= 20; step++)
                {
                    MoveTo(startX + (target - startX) * step / 20, y);
                    System.Threading.Thread.Sleep(20);
                }
                startX = target;
                System.Threading.Thread.Sleep(150);
            }
        }

        finally
        {
            Release();
        }
    }

    public static void PressAt(int x, int y)
    {
        MoveTo(x, y);
        System.Threading.Thread.Sleep(200);
        mouse_event(0x0002, 0, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(100);
    }

    public static void Release()
    {
        mouse_event(0x0004, 0, 0, 0, UIntPtr.Zero);
    }

    public static void MoveTo(int x, int y)
    {
        uint absoluteX = (uint)((long)(x - GetSystemMetrics(76)) * 65535 / (GetSystemMetrics(78) - 1));
        uint absoluteY = (uint)((long)(y - GetSystemMetrics(77)) * 65535 / (GetSystemMetrics(79) - 1));
        mouse_event(0xC001, absoluteX, absoluteY, 0, UIntPtr.Zero);
    }
}
"@

function Find-SidebarElement([string] $Property, [string] $Value, [switch] $Optional) {
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
        if ($Optional) { return $null }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Visible sidebar test element '$Value' was not found."
}

function Show-SettingsSection([string] $Id) {
    $page = Find-SidebarElement AutomationId SettingsPage
    $scroll = $page.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    if (-not $scroll.Current.VerticallyScrollable) { return }
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)
    $targetTop = $root.Current.BoundingRectangle.Top + 200 * $scale
    # Small steps keep the 80-pixel alignment window reachable on the taller narrow layout.
    foreach ($percent in 0..50) {
        $scroll.SetScrollPercent(-1, $percent * 2)
        Start-Sleep -Milliseconds 200
        $heading = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if ($heading -and -not $heading.Current.IsOffscreen -and
            $heading.Current.BoundingRectangle.Top -ge $targetTop -and
            $heading.Current.BoundingRectangle.Top -le $targetTop + 80 * $scale) { return }
        if ($percent -eq 50 -and $heading -and -not $heading.Current.IsOffscreen) {
            $pageBounds = $page.Current.BoundingRectangle
            $resetCondition = [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "ResetColumnsButton")
            $reset = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $resetCondition)
            # A shorter Settings card can reach the scroll limit before the old alignment target.
            if ($reset -and -not $reset.Current.IsOffscreen -and
                $heading.Current.BoundingRectangle.Top -ge $pageBounds.Top -and
                $reset.Current.BoundingRectangle.Bottom -le $pageBounds.Bottom) { return }
        }
    }
    Save-SidebarAppearance "settings-section-failure"
    throw "Settings section '$Id' could not be brought into the viewport. Heading: $($heading.Current.BoundingRectangle); page: $($page.Current.BoundingRectangle); window: $($root.Current.BoundingRectangle); scroll: $($scroll.Current.VerticalScrollPercent)."
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
    for ($index = 1; $index -lt 2; $index++) {
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
    # Native ComboBox automation includes a four-DIP outer focus margin.
    if ($bounds[2].Top -lt $bounds[1].Bottom -or
        [Math]::Abs($bounds[2].Left - $bounds[1].Left) -gt 5 * $scale) {
        Save-SidebarAppearance "header-layout-failure"
        throw "Secondary freshness must sit immediately below the network selector. Picker=$($bounds[1]); freshness=$($bounds[2])."
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

function Get-SidebarPaneWidth {
    $grip = (Find-SidebarElement AutomationId NavigationResizeGrip).Current.BoundingRectangle
    $navigation = (Find-SidebarElement AutomationId MainNavigation).Current.BoundingRectangle
    return ($grip.Left + $grip.Width / 2 - $navigation.Left) / $scale
}

function Assert-SidebarPaneWidth([double] $Expected) {
    $actual = Get-SidebarPaneWidth
    if ([Math]::Abs($actual - $Expected) -gt 1) {
        Save-SidebarAppearance "sidebar-resize-failure"
        throw "Expected a $Expected-DIP navigation pane; got $actual DIPs."
    }
    $branding = Find-SidebarElement Name "LAN scanner" -Optional
    if (($Expected -ge 160) -ne ($null -ne $branding)) {
        throw "Navigation labels/branding must appear at 160 DIPs and disappear below the threshold."
    }
}

function Resize-SidebarPane([double[]] $Widths) {
    Focus-SidebarWindow
    $grip = (Find-SidebarElement AutomationId NavigationResizeGrip).Current.BoundingRectangle
    $startX = [int] [Math]::Round($grip.Left + $grip.Width / 2)
    $startWidth = Get-SidebarPaneWidth
    $targets = [int[]] @($Widths | ForEach-Object {
        [int] [Math]::Round($startX + ($_ - $startWidth) * $scale)
    })
    Write-Host "Dragging navigation from $startWidth DIPs to $($Widths -join ', ') DIPs at $grip."
    [SidebarReviewKeyboard]::Drag($startX, [int]($grip.Top + $grip.Height / 2), $targets)
    Start-Sleep -Milliseconds 500
}

function Test-SidebarDividerAppearance {
    Focus-SidebarWindow
    (Find-SidebarElement AutomationId NetworkNavItem).SetFocus()
    $grip = (Find-SidebarElement AutomationId NavigationResizeGrip).Current.BoundingRectangle
    $x = [int]($grip.Left + $grip.Width / 2)
    $y = [int]($grip.Top + $grip.Height / 2)
    [SidebarReviewKeyboard]::MoveTo($x + [int](100 * $scale), $y)
    Save-SidebarAppearance "sidebar-divider-hidden"
    [SidebarReviewKeyboard]::MoveTo($x + [int](5 * $scale), $y)
    Save-SidebarAppearance "sidebar-divider-hover"
    [SidebarReviewKeyboard]::MoveTo($x + [int](100 * $scale), $y)
    Save-SidebarAppearance "sidebar-divider-hidden-again"
    $window = Get-UiReviewWindowBounds $windowHandle
    $hidden = [System.Drawing.Bitmap]::new((Join-Path $ScreenshotDirectory "sidebar-divider-hidden.png"))
    $hover = [System.Drawing.Bitmap]::new((Join-Path $ScreenshotDirectory "sidebar-divider-hover.png"))
    $again = [System.Drawing.Bitmap]::new((Join-Path $ScreenshotDirectory "sidebar-divider-hidden-again.png"))
    try {
        $changed = 0
        $sampleY = [int]($grip.Top - $window.Top + 16 * $scale)
        foreach ($sampleX in ([int]($x - $window.Left - 2 * $scale))..([int]($x - $window.Left + 2 * $scale))) {
            $background = $hidden.GetPixel($sampleX, $sampleY)
            $line = $hover.GetPixel($sampleX, $sampleY)
            if ($background.ToArgb() -ne $again.GetPixel($sampleX, $sampleY).ToArgb()) {
                throw "The divider must disappear when the pointer leaves its hit area."
            }
            $contrast = [Math]::Max([Math]::Abs([int]$line.R - $background.R),
                [Math]::Max([Math]::Abs([int]$line.G - $background.G), [Math]::Abs([int]$line.B - $background.B)))
            if ($contrast -ge 3) { $changed++ }
            if ($contrast -gt 40) { throw "The normal-theme divider must use a subtle color, not a strong border." }
        }
        if ($changed -eq 0) { throw "The divider must appear when the pointer is within five DIPs of its edge." }
    }
    finally {
        $hidden.Dispose()
        $hover.Dispose()
        $again.Dispose()
    }
}

function Test-SidebarIconDragGuide {
    Focus-SidebarWindow
    $grip = (Find-SidebarElement AutomationId NavigationResizeGrip).Current.BoundingRectangle
    $navigation = (Find-SidebarElement AutomationId MainNavigation).Current.BoundingRectangle
    $y = [int]($grip.Top + $grip.Height / 2)
    [SidebarReviewKeyboard]::PressAt([int]($grip.Left + $grip.Width / 2), $y)
    try {
        foreach ($width in @(96, 140, 120)) {
            [SidebarReviewKeyboard]::MoveTo([int]($navigation.Left + $width * $scale), $y)
            Start-Sleep -Milliseconds 300
            Assert-SidebarPaneWidth $width
            if ((Find-SidebarElement AutomationId NetworkNavItem).Current.BoundingRectangle.Width / $scale -ge 80) {
                throw "Following the pointer below 160 DIPs must not expand the icon rail."
            }
        }
        Save-SidebarAppearance "sidebar-resize-icon-guide"
    }
    finally {
        [SidebarReviewKeyboard]::Release()
    }
    Start-Sleep -Milliseconds 300
    Assert-SidebarPaneWidth 48
}

function Test-SidebarResizing {
    Select-SidebarPage Network "Public IP address"
    Assert-SidebarPaneWidth 216
    Test-SidebarDividerAppearance
    Resize-SidebarPane @(320)
    Assert-SidebarPaneWidth 320
    Resize-SidebarPane @(500)
    Assert-SidebarPaneWidth 320
    Resize-SidebarPane @(160)
    Assert-SidebarPaneWidth 160
    $brand = Find-SidebarElement AutomationId NavigationBrandName
    if ($brand.Current.Name -ne "FingVibe" -or $brand.Current.BoundingRectangle.Height / $scale -gt 30) {
        throw "FingVibe must stay on one line at the minimum expanded width."
    }
    $selection = (Find-SidebarElement AutomationId NetworkNavItem).GetCurrentPattern(
        [System.Windows.Automation.SelectionItemPattern]::Pattern)
    if (-not $selection.Current.IsSelected) { throw "Resizing must retain the selected navigation destination." }
    Resize-SidebarPane @(159)
    Assert-SidebarPaneWidth 48
    Resize-SidebarPane @(1)
    Assert-SidebarPaneWidth 48
    Test-SidebarIconDragGuide
    foreach ($page in @(
        @("Overview", "Online devices"), @("Network", "Public IP address"),
        @("Devices", "Search devices"), @("People", "Search people"),
        @("Rooms", "Search rooms"), @("Tools", "Speed test"), @("Settings", "Window backdrop")
    )) {
        Select-SidebarPage $page[0] $page[1]
        Assert-SidebarPaneWidth 48
    }
    Save-SidebarAppearance "sidebar-resize-icons"
    Switch-SidebarPane
    Assert-SidebarPaneWidth 160
    Resize-SidebarPane @(280)
    Switch-SidebarPane
    Assert-SidebarPaneWidth 48
    Switch-SidebarPane
    Assert-SidebarPaneWidth 280
    # Cross the snap boundary in both directions without releasing pointer capture.
    Resize-SidebarPane @(100, 240)
    Assert-SidebarPaneWidth 240
    Resize-SidebarPane @(159)
    Assert-SidebarPaneWidth 48
    Resize-SidebarPane @(160)
    Assert-SidebarPaneWidth 160
    $grip = Find-SidebarElement AutomationId NavigationResizeGrip
    $grip.SetFocus()
    [SidebarReviewKeyboard]::Tap(0x25)
    Start-Sleep -Milliseconds 250
    Assert-SidebarPaneWidth 48
    [SidebarReviewKeyboard]::Tap(0x27)
    Start-Sleep -Milliseconds 250
    Assert-SidebarPaneWidth 160
    Save-SidebarAppearance "sidebar-resize-threshold"
    Resize-SidebarPane @(216)
    Assert-SidebarPaneWidth 216
    Save-SidebarAppearance "sidebar-resize-expanded"
    Write-Host "Navigation drag bounds, exact snap threshold, continuous drag, all compact destinations, toggle restoration and keyboard resizing passed."
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
        Show-SettingsSection DevicesSettingsHeading
        $footer = Find-SidebarElement AutomationId AppearanceSaveStatus
        if ($footer.Current.Name -ne "Appearance changes apply immediately and save automatically, with material effects depending on Windows transparency settings.") {
            throw "Normal Appearance feedback must be one consolidated sentence."
        }
        foreach ($id in @("CompactRowsSwitch", "EnlargedCellPreviews")) {
            $switch = Find-SidebarElement AutomationId $id
            $toggle = $switch.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
            $original = $toggle.Current.ToggleState
            $switch.SetFocus()
            [SidebarReviewKeyboard]::Tap(0x20)
            Start-Sleep -Milliseconds 200
            if ($toggle.Current.ToggleState -eq $original) { throw "$id must toggle with Space." }
            if ($theme -eq "Standard Dark") { Save-SidebarAppearance "settings-$id-toggled" }
            $toggle.Toggle()
            if ($toggle.Current.ToggleState -ne $original) { throw "$id must restore through native TogglePattern." }
        }
        Save-SidebarAppearance "settings-$theme"
        $scroll = (Find-SidebarElement AutomationId SettingsPage).GetCurrentPattern(
            [System.Windows.Automation.ScrollPattern]::Pattern)
        Show-SettingsSection VisibleColumnsHeading
        Start-Sleep -Milliseconds 200
        $null = Find-SidebarElement AutomationId VisibleColumnsHeading
        $null = Find-SidebarElement AutomationId CombinedColumnsHeading
        Save-SidebarAppearance "settings-grouped-columns-$theme"
        if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, 0) }
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
        Show-SettingsSection DevicesSettingsHeading
        $heading = (Find-SidebarElement AutomationId DevicesSettingsHeading).Current.BoundingRectangle
        $compact = (Find-SidebarElement AutomationId CompactRowsSwitch).Current.BoundingRectangle
        $hover = (Find-SidebarElement AutomationId EnlargedCellPreviews).Current.BoundingRectangle
        if ($heading.Bottom -gt $compact.Top) { throw "Preferences must follow the Devices page title." }
        if ($width -ge 640) {
            if ([Math]::Abs($compact.Top - $hover.Top) -gt 2 * $scale -or $compact.Right -gt $hover.Left) {
                throw "Devices switches must share a non-overlapping row at $width."
            }
        } elseif ($compact.Bottom -gt $hover.Top) {
            throw "Devices switches must stack at narrow widths."
        }
        if ($width -ge 640) { Save-SidebarAppearance "settings-switches-$width" }
        Show-SettingsSection VisibleColumnsHeading
        Start-Sleep -Milliseconds 200
        $choices = Find-SidebarElement AutomationId SettingsPage
        $headers = @("Name", "IP address", "Vendor", "Device type", "MAC address", "Open ports",
            "Status", "Response", "OS", "Person", "Room", "Last seen")
        $checkboxes = @($choices.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::CheckBox)) |
            Where-Object { $_.Current.Name -in $headers })
        if ($checkboxes.Count -ne $headers.Count) { throw "Expected all twelve column choices at $width." }
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
            if ($inline) {
                $visibleHeading = (Find-SidebarElement AutomationId VisibleColumnsHeading).Current.BoundingRectangle
                $combinedHeading = (Find-SidebarElement AutomationId CombinedColumnsHeading).Current.BoundingRectangle
                $description = (Find-SidebarElement AutomationId CombinedColumnsDescription).Current.BoundingRectangle
                $combinations = @("CombineNameType", "CombineAddresses", "CombineStatusResponse", "CombinePersonRoom", "CombineVendorOs") |
                    ForEach-Object { (Find-SidebarElement AutomationId $_).Current.BoundingRectangle }
                if ($visibleHeading.Bottom -gt $checkboxes[0].Current.BoundingRectangle.Top -or
                    $checkboxes[-1].Current.BoundingRectangle.Bottom -ge $combinedHeading.Top -or
                    $combinedHeading.Bottom -gt $description.Top -or $description.Bottom -gt $combinations[0].Top) {
                    throw "Visibility and combination controls must have distinct, correctly ordered sections."
                }
                for ($index = 0; $index -lt $combinations.Count; $index++) {
                    $column = $index % 3
                    if ([Math]::Abs($combinations[$index].Left - $checkboxes[$column].Current.BoundingRectangle.Left) -gt 2 * $scale -or
                        [Math]::Abs($combinations[$index].Top - $combinations[$index - $column].Top) -gt 2 * $scale -or
                        ($column -gt 0 -and $combinations[$index - 1].Right -gt $combinations[$index].Left) -or
                        ($index -ge 3 -and $combinations[$index - 3].Bottom -gt $combinations[$index].Top)) {
                        throw "Combination choices must align with the visible three-column grid."
                    }
                }
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
    Show-SettingsSection DevicesSettingsHeading
    $density = (Find-SidebarElement AutomationId CompactRowsSwitch).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    $hoverPreference = (Find-SidebarElement AutomationId EnlargedCellPreviews).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    $densityBefore = $density.Current.ToggleState
    $hoverBefore = $hoverPreference.Current.ToggleState
    Show-SettingsSection ResetColumnsButton
    (Find-SidebarElement AutomationId ResetColumnsButton).GetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    if ($toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) {
        throw "Reset columns did not restore visibility."
    }
    if ($density.Current.ToggleState -ne $densityBefore -or $hoverPreference.Current.ToggleState -ne $hoverBefore) {
        throw "Reset columns must preserve both Devices preferences."
    }
    if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, 0) }
    Set-UiReviewTheme -Root $root -Theme "Standard Dark"
    Select-SidebarPage People "Search people"
    Write-Host "Settings mode/theme mapping, six palettes, responsive bounds, mandatory IP, and column reset passed."
}

function Wait-DeviceScan {
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Find-SidebarElement AutomationId ScanButton -Optional).Current.IsEnabled) {
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
        if ((Find-SidebarElement AutomationId ResultCountText).Current.Name -ne "Showing 1 device") {
            throw "The loopback scan must display exactly one device."
        }
        foreach ($page in @(
            @("Devices", "Search devices"),
            @("Overview", "Online devices"),
            @("Network", "Public IP address"),
            @("People", "Search people"),
            @("Rooms", "Search rooms"),
            @("Tools", "Speed test"),
            @("Settings", "Window backdrop")
        )) {
            Select-SidebarPage $page[0] $page[1]
            Assert-SharedNetworkHeader
            if ((Find-SidebarElement AutomationId ScanStatusText -Optional) -or
                (Find-SidebarElement AutomationId ScanProgressBar -Optional)) {
                throw "Successful completion must leave no scan message or progress on $($page[0])."
            }
            if ($page[0] -eq "Devices" -and
                (Find-SidebarElement AutomationId LastScanText).Current.Name -notmatch '^Scan duration \d') {
                throw "Devices must retain the completed scan duration."
            }
            if ($page[0] -eq "Overview" -and
                (Find-SidebarElement AutomationId OnlineDevicesText).Current.Name -ne "1") {
                throw "Overview must retain its online-device count after successful completion."
            }
        }
        Select-SidebarPage Devices "Search devices"
        $search = (Find-SidebarElement AutomationId ResultSearchBox).GetCurrentPattern(
            [System.Windows.Automation.ValuePattern]::Pattern)
        $search.SetValue("fingvibe-no-matching-device")
        Start-Sleep -Milliseconds 200
        if ((Find-SidebarElement AutomationId ResultCountText).Current.Name -ne "Showing 0 of 1 devices") {
            throw "Filtered device counts must include the unfiltered total."
        }
        $search.SetValue("")
        [IO.File]::WriteAllText($scanHoldPath, "Hold the refresh until retained results have been observed.")
        $scan.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        if (Find-SidebarElement AutomationId ScanButton -Optional) { throw "Scan LAN must be replaced, not left disabled, during refresh." }
        if ((Find-SidebarElement AutomationId ResultCountText).Current.Name -ne "Showing 1 device" -or
            (Find-SidebarElement AutomationId ScanStatusText).Current.Name -notlike "*Displaying retained results*") {
            throw "Refresh must retain the displayed devices and explain their status."
        }
        Select-SidebarPage Overview "Online devices"
        if ((Find-SidebarElement AutomationId ScanStatusText).Current.Name -notlike "Scanning*") {
            throw "Live scan progress must remain visible after navigation."
        }
        (Find-SidebarElement Name "Cancel scan").GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        Select-SidebarPage Devices "Search devices"
        Wait-DeviceScan
        if ((Find-SidebarElement AutomationId ResultCountText).Current.Name -ne "Showing 1 device" -or
            (Find-SidebarElement AutomationId ScanStatusText).Current.Name -notlike "*cancelled*") {
            throw "Cancellation must preserve the displayed devices and report its outcome."
        }
        Remove-Item -LiteralPath $scanHoldPath
        [IO.File]::WriteAllText($scanHoldPath + ".progress", '{"Completed":2,"Total":1}')
        [IO.File]::WriteAllText($scanHoldPath, "Exercise explicit scan failure.")
        $scan.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        Wait-DeviceScan
        if ((Find-SidebarElement AutomationId ScanStatusText).Current.Name -notlike "*Unable to scan*") {
            throw "A failed scan must retain its error instead of clearing the scan message."
        }
        Remove-Item -LiteralPath $scanHoldPath, ($scanHoldPath + ".progress")
        Remove-Item -LiteralPath $snapshotPath
        $null = New-Item -ItemType Directory -Path $snapshotPath
        try {
            $scan.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
            Wait-DeviceScan
            Select-SidebarPage Overview "Online devices"
            if ((Find-SidebarElement AutomationId ScanStatusText).Current.Name -notlike "*latest-scan cache could not be updated*") {
                throw "A successful scan must preserve persistence errors across navigation."
            }
            Select-SidebarPage Devices "Search devices"
        }
        finally { Remove-Item -LiteralPath $snapshotPath }
        $filterExpander = (Find-SidebarElement AutomationId FilterExpander).GetCurrentPattern(
            [System.Windows.Automation.TogglePattern]::Pattern)
        $filterExpander.Toggle()
        Start-Sleep -Milliseconds 250
        $expanderElement = Find-SidebarElement AutomationId FilterExpander
        if ($expanderElement.Current.HelpText -ne "Expanded") {
            throw "The funnel must expose its expanded state."
        }
        foreach ($width in @($expandedWidth, 1000, 640)) {
            Set-SidebarWindowWidth $width
            $filters = @("ResultSearchBox", "InventoryStatusFilter", "FilterExpander", "TypeFilter",
                "OperatingSystemFilter", "VendorFilter", "PersonFilter", "RoomFilter", "PortsFilter") |
                ForEach-Object { Find-SidebarElement AutomationId $_ }
            for ($index = 0; $index -lt $filters.Count; $index++) {
                $bounds = $filters[$index].Current.BoundingRectangle
                if ($bounds.Width -le 0) {
                    $filters | ForEach-Object { Write-Host "$($_.Current.AutomationId): $($_.Current.BoundingRectangle)" }
                    Save-SidebarAppearance "filters-layout-failure"
                    throw "Filter '$($filters[$index].Current.AutomationId)' has no visible width at $width."
                }
                for ($other = 0; $other -lt $index; $other++) {
                    $intersection = [System.Windows.Rect]::Intersect($bounds, $filters[$other].Current.BoundingRectangle)
                    if (-not $intersection.IsEmpty -and $intersection.Width -gt 0 -and $intersection.Height -gt 0) {
                        throw "Device filters overlap at $width logical pixels."
                    }
                }
            }
        }
        $filterExpander.Toggle()
        Write-Host "Device success/navigation, refresh/cancellation, scan/save errors, filtered counts, and responsive filter bounds passed."
    }
    finally {
        try {
            if (Test-Path -LiteralPath $scanHoldPath) { Remove-Item -LiteralPath $scanHoldPath }
            if ($scan) { Wait-DeviceScan }
        }
        finally {
            if ($null -ne $snapshot) { [IO.File]::WriteAllBytes($snapshotPath, $snapshot) }
            elseif (Test-Path -LiteralPath $snapshotPath) { Remove-Item -LiteralPath $snapshotPath }
        }
    }
}

function Test-ScanPresentation {
    $highContrast = $null
    $animations = $null
    $captureTopmost = $false
    try {
        foreach ($theme in $UiReviewAppearanceThemes) {
            Set-SidebarWindowWidth $expandedWidth
            Select-SidebarPage Settings "Window backdrop"
            Set-UiReviewTheme -Root $root -Theme $theme
            Select-SidebarPage Devices "Search devices"
            $cases = @(@($expandedWidth, 5), @($expandedWidth, 90), @(640, 90), @(480, 90))
            if ($env:GITHUB_ACTIONS -eq "true" -and $theme -eq "Standard Dark") {
                $cases += @(@(640, 90, "NoAnimation"), @(640, 90, "HighContrast"))
            }
            foreach ($case in $cases) {
                if ($case[2] -eq "NoAnimation") {
                    $animations = [SidebarReviewKeyboard]::GetAnimations()
                    [SidebarReviewKeyboard]::SetAnimations($false)
                    if ([SidebarReviewKeyboard]::GetAnimations()) { throw "Reduced animation did not activate." }
                    Start-Sleep -Seconds 2
                }
                elseif ($case[2] -eq "HighContrast") {
                    $highContrast = [SidebarReviewKeyboard]::GetHighContrastFlags()
                    [SidebarReviewKeyboard]::SetHighContrastFlags($highContrast -bor 1)
                    if (([SidebarReviewKeyboard]::GetHighContrastFlags() -band 1) -eq 0) {
                        throw "High contrast did not activate."
                    }
                    Start-Sleep -Seconds 2
                }
                Set-SidebarWindowWidth $case[0]
                $scan = Find-SidebarElement AutomationId ScanButton
                [IO.File]::WriteAllText($scanHoldPath + ".progress",
                    ('{"Completed":' + $case[1] + ',"Total":100}'))
                [IO.File]::WriteAllText($scanHoldPath, "Hold synthetic progress for native geometry/pixel assertions.")
                $scan.SetFocus()
                Start-Sleep -Milliseconds 100
                $idleBounds = $scan.Current.BoundingRectangle
                $scan.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                $cancel = Find-SidebarElement AutomationId CancelButton
                Start-Sleep -Milliseconds 400
                if ($cancel.Current.Name -ne "Cancel scan" -or -not $cancel.Current.IsEnabled -or
                    (Find-SidebarElement AutomationId ScanButton -Optional)) {
                    throw "Exactly one usable scan action must be visible while scanning."
                }
                $cancelBounds = $cancel.Current.BoundingRectangle
                if ([Math]::Abs($idleBounds.Left - $cancelBounds.Left) -gt $scale -or
                    [Math]::Abs($idleBounds.Top - $cancelBounds.Top) -gt $scale -or
                    [Math]::Abs($idleBounds.Width - $cancelBounds.Width) -gt $scale) {
                    throw "Scan LAN and Cancel scan must share one fixed position and width. Idle=$idleBounds; active=$cancelBounds; theme=$theme; case=$case."
                }
                $bar = Find-SidebarElement AutomationId ScanProgressBar
                $value = $bar.GetCurrentPattern([System.Windows.Automation.RangeValuePattern]::Pattern).Current
                if ($value.Value -ne $case[1] -or $value.Maximum -ne 100) {
                    throw "The native progress indicator must preserve the fixture's exact measured fraction."
                }
                $pickerBounds = (Find-SidebarElement AutomationId NetworkPicker).Current.BoundingRectangle
                $statusBounds = (Find-SidebarElement AutomationId ScanStatusText).Current.BoundingRectangle
                $barBounds = $bar.Current.BoundingRectangle
                $windowBounds = Get-UiReviewWindowBounds $windowHandle
                foreach ($bounds in @($pickerBounds, $statusBounds, $barBounds, $cancelBounds)) {
                    if (-not $root.Current.BoundingRectangle.Contains($bounds)) {
                        throw "Scan context, action and progress must not clip at $($case[0]) DIPs."
                    }
                }
                if ($statusBounds.Top -lt $pickerBounds.Bottom -or $barBounds.Top -lt $statusBounds.Bottom) {
                    throw "Scan text and progress must stay together below the network selector."
                }
                if ($case[0] -ge 640) {
                    $path = Join-Path $ScreenshotDirectory "scan-$theme-$($case[0])-$($case[1])-$($case[2]).png"
                    if ($env:GITHUB_ACTIONS -eq "true") {
                        # Contrast changes can raise the runner's console over the foreground app.
                        if (-not [UiReviewNativeWindow]::SetWindowPos(
                                $windowHandle, [IntPtr]::new(-1), 0, 0, 0, 0, 0x0053)) {
                            throw [System.ComponentModel.Win32Exception]::new()
                        }
                        $captureTopmost = $true
                        Start-Sleep -Milliseconds 250
                    }
                    Focus-SidebarWindow
                    Save-UiReviewWindowScreenshot $windowHandle $path
                    $bitmap = [System.Drawing.Bitmap]::new($path)
                    try {
                        $left = $barBounds.Left - $windowBounds.Left
                        $top = $barBounds.Top - $windowBounds.Top
                        $filledX = [int]($left + $barBounds.Width * $case[1] / 200)
                        $emptyX = [int]($left + $barBounds.Width * 0.98)
                        $thickPixels = 0
                        for ($y = [int][Math]::Ceiling($top); $y -lt [Math]::Floor($top + $barBounds.Height); $y++) {
                            $fill = $bitmap.GetPixel($filledX, $y)
                            $empty = $bitmap.GetPixel($emptyX, $y)
                            $difference = [Math]::Abs([int]$fill.R - $empty.R) +
                                [Math]::Abs([int]$fill.G - $empty.G) + [Math]::Abs([int]$fill.B - $empty.B)
                            if ($difference -gt 40) { $thickPixels++ }
                        }
                        if ($thickPixels -lt 7 * $scale) {
                            throw "The completed segment must actually paint at least 7 of its 8 DIPs, not just occupy a taller container."
                        }
                        if ($case[2]) {
                            Start-Sleep -Milliseconds 650
                            $staticPath = Join-Path $ScreenshotDirectory "scan-static-$($case[2]).png"
                            Save-UiReviewWindowScreenshot $windowHandle $staticPath
                            $static = [System.Drawing.Bitmap]::new($staticPath)
                            try {
                                for ($x = [int]($left + 2 * $scale); $x -lt $left + $barBounds.Width - 2 * $scale; $x++) {
                                    for ($y = [int][Math]::Ceiling($top); $y -lt [Math]::Floor($top + $barBounds.Height); $y++) {
                                        if ($bitmap.GetPixel($x, $y).ToArgb() -ne $static.GetPixel($x, $y).ToArgb()) {
                                            throw "Progress must be static with $($case[2]), not just visually dimmed."
                                        }
                                    }
                                }
                            }
                            finally { $static.Dispose() }
                        }
                    }
                    finally { $bitmap.Dispose() }
                    if ($captureTopmost) {
                        if (-not [UiReviewNativeWindow]::SetWindowPos(
                                $windowHandle, [IntPtr]::new(-2), 0, 0, 0, 0, 0x0053)) {
                            throw [System.ComponentModel.Win32Exception]::new()
                        }
                        $captureTopmost = $false
                    }
                }
                else {
                    Write-Host "480-DIP scan geometry/value/focus assertions enabled; capture helper requires at least 640 physical pixels."
                }
                $cancel.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                Wait-DeviceScan
                $restored = Find-SidebarElement AutomationId ScanButton
                if (-not $restored.Current.HasKeyboardFocus -or
                    (Find-SidebarElement AutomationId ScanProgressBar -Optional) -or
                    (Find-SidebarElement AutomationId CancelButton -Optional)) {
                    throw "Cancellation must restore keyboard focus and clear active progress/action presentation."
                }
                Remove-Item -LiteralPath $scanHoldPath, ($scanHoldPath + ".progress")
                if ($null -ne $highContrast) {
                    [SidebarReviewKeyboard]::SetHighContrastFlags($highContrast)
                    $highContrast = $null
                    Start-Sleep -Seconds 2
                }
                if ($null -ne $animations) {
                    [SidebarReviewKeyboard]::SetAnimations($animations)
                    $animations = $null
                }
            }
        }
        Write-Host "Single-position action, actual filled thickness, low/90% progress, cancellation/focus and narrow layouts passed in every theme."
    }
    finally {
        if ($null -ne $highContrast) { [SidebarReviewKeyboard]::SetHighContrastFlags($highContrast) }
        if ($null -ne $animations) { [SidebarReviewKeyboard]::SetAnimations($animations) }
        if (Test-Path -LiteralPath $scanHoldPath) { Remove-Item -LiteralPath $scanHoldPath }
        if (Test-Path -LiteralPath ($scanHoldPath + ".progress")) { Remove-Item -LiteralPath ($scanHoldPath + ".progress") }
        if ($captureTopmost -and -not [UiReviewNativeWindow]::SetWindowPos(
                $windowHandle, [IntPtr]::new(-2), 0, 0, 0, 0, 0x0053)) {
            throw [System.ComponentModel.Win32Exception]::new()
        }
        Wait-DeviceScan
    }
}

function Start-SidebarApp {
    $script:process = Start-Process -FilePath (Resolve-Path -LiteralPath $AppPath).Path -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        $script:process.Refresh()
        if ($script:process.HasExited) { throw "Review app exited with code $($script:process.ExitCode)." }
        if ($script:process.MainWindowHandle -ne [IntPtr]::Zero) { break }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    $script:windowHandle = $script:process.MainWindowHandle
    if ($script:windowHandle -eq [IntPtr]::Zero) { throw "Review app did not create a window." }
    $script:root = [System.Windows.Automation.AutomationElement]::FromHandle($script:windowHandle)
    $null = Find-SidebarElement AutomationId MainNavigation
    Focus-SidebarWindow
    Initialize-UiReviewWindow $script:windowHandle
    $script:scale = [UiReviewNativeWindow]::GetDpiForWindow($script:windowHandle) / 96.0
}

function Stop-SidebarApp {
    if ($script:process -and -not $script:process.HasExited) {
        Stop-Process -Id $script:process.Id
        $null = $script:process.WaitForExit(10000)
    }
}

function Assert-SidebarNavigationPreference([double] $Width, [bool] $IsCollapsed) {
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $saved = $null
        try { $saved = Get-Content -LiteralPath $navigationPreferencePath -Raw | ConvertFrom-Json }
        catch [System.IO.IOException], [System.Management.Automation.ItemNotFoundException] { }
        if ($saved -and [Math]::Abs($saved.expandedWidth - $Width) -le 1 -and $saved.isCollapsed -eq $IsCollapsed) {
            return
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Expected saved navigation of $Width DIPs with collapsed=$IsCollapsed; got $($saved | ConvertTo-Json -Compress)."
}

function Test-SidebarPersistence {
    Stop-SidebarApp
    Set-Content -LiteralPath $navigationPreferencePath -Value '{"expandedWidth":280,"isCollapsed":false}' -Encoding ASCII
    $env:FINGVIBE_UI_REVIEW_NAVIGATION = $navigationPreferencePath
    Start-SidebarApp
    Set-SidebarWindowWidth $expandedWidth
    Assert-SidebarPaneWidth 280
    Switch-SidebarPane
    Assert-SidebarPaneWidth 48
    Assert-SidebarNavigationPreference 280 $true

    Stop-SidebarApp
    Start-SidebarApp
    Set-SidebarWindowWidth $expandedWidth
    Assert-SidebarPaneWidth 48
    Switch-SidebarPane
    Assert-SidebarPaneWidth 280
    Assert-SidebarNavigationPreference 280 $false
    Resize-SidebarPane @(240)
    Assert-SidebarPaneWidth 240
    Assert-SidebarNavigationPreference 240 $false
    Set-SidebarWindowWidth 800
    if ((Find-SidebarElement AutomationId NetworkNavItem).Current.BoundingRectangle.Width / $scale -ge 80) {
        throw "A small window must collapse navigation automatically."
    }
    Assert-SidebarNavigationPreference 240 $false

    Stop-SidebarApp
    Start-SidebarApp
    Set-SidebarWindowWidth $expandedWidth
    Assert-SidebarPaneWidth 240
    Write-Host "Navigation width and icon-only choice were restored after restart; automatic small-window collapse was not saved."
}

function Wait-SidebarText([string] $Id, [string] $Pattern, [int] $Seconds = 30) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $element = Find-SidebarElement AutomationId $Id -Optional
        $text = if ($element) { $element.Current.Name } else { $null }
        if ($null -ne $text -and $text -like $Pattern) { return $element }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    Save-ScheduledScanFailure "scheduled-scans-wait-failure"
    throw "Expected '$Id' to match '$Pattern'; got '$text'."
}

function Save-ScheduledScanFailure([string] $Name) {
    try { Save-SidebarAppearance $Name }
    catch { Write-Warning "Could not capture '$Name': $($_.Exception.Message)" }
}

function Assert-ScheduledScanSettings([bool] $IsEnabled, [int] $IntervalMinutes) {
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $saved = $null
        try { $saved = Get-Content -LiteralPath $periodicScanPath -Raw | ConvertFrom-Json }
        catch [System.IO.IOException], [System.Management.Automation.ItemNotFoundException] { }
        if ($saved -and $saved.isEnabled -eq $IsEnabled -and $saved.intervalMinutes -eq $IntervalMinutes) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Expected saved scheduled scans enabled=$IsEnabled every $IntervalMinutes minutes; got $($saved | ConvertTo-Json -Compress)."
}

function Show-ScheduledScansCard {
    $page = Find-SidebarElement AutomationId SettingsPage
    $scroll = $page.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, 100) }
        Start-Sleep -Milliseconds 300
        $pageBounds = $page.Current.BoundingRectangle
        $ready = $true
        foreach ($id in @("ScheduledScansHeading", "ScheduledScansSwitch", "ScanIntervalPicker",
            "ScheduledScanStatus", "ScheduledScanEvidenceNote")) {
            $element = Find-SidebarElement AutomationId $id -Optional
            if (-not $element) { $ready = $false; break }
            $bounds = $element.Current.BoundingRectangle
            if ($bounds.Left -lt $pageBounds.Left -or $bounds.Right -gt $pageBounds.Right + 1 -or
                $bounds.Top -lt $pageBounds.Top -or $bounds.Bottom -gt $pageBounds.Bottom + 1) {
                $ready = $false
                break
            }
        }
        if ($ready) { return }
    } while ([DateTime]::UtcNow -lt $deadline)
    Save-ScheduledScanFailure "scheduled-scans-clipped"
    throw "Scheduled scan control '$id' did not become fully visible in Settings."
}

function Hide-ScheduledScansCard {
    $scroll = (Find-SidebarElement AutomationId SettingsPage).GetCurrentPattern(
        [System.Windows.Automation.ScrollPattern]::Pattern)
    if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, 0) }
    Start-Sleep -Milliseconds 200
}

function Switch-ScheduledScansWithKeyboard([bool] $Expected) {
    Focus-SidebarWindow
    # Cancelling from the header can scroll Settings, so bring the card back into view before using the keyboard.
    Show-ScheduledScansCard
    $switch = Find-SidebarElement AutomationId ScheduledScansSwitch
    $switch.SetFocus()
    [SidebarReviewKeyboard]::Tap(0x20)
    $toggle = $switch.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    $expectedState = if ($Expected) { [System.Windows.Automation.ToggleState]::On } else { [System.Windows.Automation.ToggleState]::Off }
    $deadline = [DateTime]::UtcNow.AddSeconds(2)
    while ($toggle.Current.ToggleState -ne $expectedState) {
        if ([DateTime]::UtcNow -ge $deadline) { throw "Scheduled scans must toggle with Space." }
        Start-Sleep -Milliseconds 50
    }
}

function Assert-ScheduledScansSelection([string] $State, [string] $Interval) {
    $toggle = (Find-SidebarElement AutomationId ScheduledScansSwitch).GetCurrentPattern(
        [System.Windows.Automation.TogglePattern]::Pattern)
    $picker = (Find-SidebarElement AutomationId ScanIntervalPicker).GetCurrentPattern(
        [System.Windows.Automation.SelectionPattern]::Pattern)
    if ($toggle.Current.ToggleState -ne $State -or $picker.Current.GetSelection()[0].Current.Name -ne $Interval) {
        throw "Expected scheduled scans $State every $Interval."
    }
}

function Test-ScheduledScans {
    # Windows PowerShell reads this BOM-less script as ANSI, so build the separator explicitly.
    $dot = [char] 0x00B7
    $highContrast = $null
    $captureTopmost = $false
    try {
        Stop-SidebarApp
        $null = New-Item -ItemType Directory -Path $periodicScanDirectory -Force
        $env:FINGVIBE_UI_REVIEW_PERIODIC_SCAN = $periodicScanPath
        # Each minute takes a third of a second, so 15 minutes is 5 seconds and 1 hour is 20 seconds.
        $env:FINGVIBE_UI_REVIEW_PERIODIC_SCAN_TIME_SCALE = "180"
        $env:FINGVIBE_UI_REVIEW_SNAPSHOT = Join-Path $periodicScanDirectory "latest-scan.json"
        $env:FINGVIBE_UI_REVIEW_INVENTORY = Join-Path $periodicScanDirectory "device-inventory.sqlite"
        Start-SidebarApp
        Set-SidebarWindowWidth $expandedWidth
        Select-SidebarPage Settings "Window backdrop"
        Show-ScheduledScansCard
        Assert-ScheduledScansSelection Off "1 hour"
        if ((Find-SidebarElement AutomationId ScheduledScansSwitch).Current.Name -ne "Scheduled scans" -or
            (Find-SidebarElement AutomationId ScanIntervalPicker).Current.Name -ne "Scheduled scan interval") {
            throw "Scheduled scan controls must expose descriptive accessible names."
        }
        $null = Wait-SidebarText ScheduledScanStatus "Off. Scans run only when you select Scan LAN."
        if ((Find-SidebarElement AutomationId ScheduledScanEvidenceNote).Current.Name -notlike
            "Each scheduled scan samples which devices answer at that moment.*not proof that a device was offline*") {
            throw "Scheduled scans must be explained as sampled evidence, not continuous uptime."
        }
        if ((Find-SidebarElement AutomationId ScanFreshnessText).Current.Name -like "*Scheduled*") {
            throw "The header must not mention scheduling while it is off."
        }
        if (Test-Path -LiteralPath $periodicScanPath) { throw "Loading default scheduled-scan settings must not save them." }

        foreach ($width in @($expandedWidth, 640, 480)) {
            Set-SidebarWindowWidth $width
            Show-ScheduledScansCard
            $switch = (Find-SidebarElement AutomationId ScheduledScansSwitch).Current.BoundingRectangle
            $picker = (Find-SidebarElement AutomationId ScanIntervalPicker).Current.BoundingRectangle
            $status = (Find-SidebarElement AutomationId ScheduledScanStatus).Current.BoundingRectangle
            $note = (Find-SidebarElement AutomationId ScheduledScanEvidenceNote).Current.BoundingRectangle
            $overlap = [System.Windows.Rect]::Intersect($switch, $picker)
            if (-not $overlap.IsEmpty -and $overlap.Width -gt 0 -and $overlap.Height -gt 0) {
                throw "Scheduled scan controls overlap at $width."
            }
            if ($width -ge 640 -and ($switch.Right -gt $picker.Left -or $picker.Top -ge $switch.Bottom)) {
                throw "Scheduled scan controls must share a row at $width."
            }
            if ($width -lt 640 -and $switch.Bottom -gt $picker.Top) {
                throw "Scheduled scan controls must stack at narrow widths."
            }
            if ([Math]::Max($switch.Bottom, $picker.Bottom) -gt $status.Top -or $status.Bottom -gt $note.Top) {
                throw "Scheduled scan status and evidence note must follow the controls at $width."
            }
            if ($width -ge 640) { Save-SidebarAppearance "scheduled-scans-off-$width" }
        }
        Set-SidebarWindowWidth $expandedWidth
        Show-ScheduledScansCard

        Switch-ScheduledScansWithKeyboard $true
        Assert-ScheduledScanSettings $true 60
        $null = Wait-SidebarText ScheduledScanStatus "First scheduled scan around *."
        $null = Wait-SidebarText ScanFreshnessText "* $dot Scheduled every 1 hour"

        # The hold keeps scheduled scans in progress until they are cancelled or disabled.
        [IO.File]::WriteAllText($scanHoldPath, "Hold scheduled scans for cancellation checks.")
        Set-UiReviewAppearanceChoice -Root $root -Picker ScanIntervalPicker -Choice "15 minutes"
        Assert-ScheduledScanSettings $true 15
        $null = Wait-SidebarText ScanFreshnessText "* $dot Scheduled every 15 minutes"
        $null = Wait-SidebarText ScanStatusText "Scheduled scan $dot Scanning *"
        $null = Wait-SidebarText ScheduledScanStatus "Scheduled scan in progress."
        Show-ScheduledScansCard
        Save-SidebarAppearance "scheduled-scans-running"
        (Find-SidebarElement AutomationId CancelButton).GetCurrentPattern(
            [System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        $null = Wait-SidebarText ScanStatusText "Scheduled scan of 127.0.0.1/32 cancelled*"
        Show-ScheduledScansCard
        $null = Wait-SidebarText ScheduledScanStatus "Last scheduled scan was cancelled; committed checkpoints are retained as incomplete. Next around *."
        $null = Wait-SidebarText ScanFreshnessText "* $dot Scheduled every 15 minutes"

        $null = Wait-SidebarText ScanStatusText "Scheduled scan $dot Scanning *"
        Switch-ScheduledScansWithKeyboard $false
        $null = Wait-SidebarText ScanStatusText "Scheduled scan of 127.0.0.1/32 stopped*"
        $null = Wait-SidebarText ScheduledScanStatus "Off. Scans run only when you select Scan LAN."
        Assert-ScheduledScanSettings $false 15
        if ((Find-SidebarElement AutomationId ScanFreshnessText).Current.Name -like "*Scheduled*") {
            throw "Disabling scheduled scans must remove the header schedule."
        }
        if (Test-Path -LiteralPath $env:FINGVIBE_UI_REVIEW_SNAPSHOT) {
            throw "Cancelled or stopped scheduled scans must not save results."
        }

        Remove-Item -LiteralPath $scanHoldPath
        Switch-ScheduledScansWithKeyboard $true
        Assert-ScheduledScanSettings $true 15
        $null = Wait-SidebarText ScheduledScanStatus "Last scheduled scan completed. Next around *."
        $null = Wait-SidebarText ScanFreshnessText "*127.0.0.1/32 $dot Scheduled every 15 minutes"
        if (-not (Test-Path -LiteralPath $env:FINGVIBE_UI_REVIEW_SNAPSHOT)) {
            throw "A completed scheduled scan must save its results."
        }
        # A longer interval keeps the completed state stable while every theme is captured.
        Set-UiReviewAppearanceChoice -Root $root -Picker ScanIntervalPicker -Choice "4 hours"
        Assert-ScheduledScanSettings $true 240
        $null = Wait-SidebarText ScheduledScanStatus "Last scheduled scan completed. Next around *."
        foreach ($theme in $UiReviewAppearanceThemes) {
            Hide-ScheduledScansCard
            Set-UiReviewTheme -Root $root -Theme $theme
            Show-ScheduledScansCard
            Save-SidebarAppearance "scheduled-scans-$theme"
        }
        if ($env:GITHUB_ACTIONS -eq "true") {
            $highContrast = [SidebarReviewKeyboard]::GetHighContrastFlags()
            [SidebarReviewKeyboard]::SetHighContrastFlags($highContrast -bor 1)
            if (([SidebarReviewKeyboard]::GetHighContrastFlags() -band 1) -eq 0) { throw "High contrast did not activate." }
            Start-Sleep -Seconds 2
            # Contrast changes can raise the runner's console over the foreground app.
            if (-not [UiReviewNativeWindow]::SetWindowPos($windowHandle, [IntPtr]::new(-1), 0, 0, 0, 0, 0x0053)) {
                throw [System.ComponentModel.Win32Exception]::new()
            }
            $captureTopmost = $true
            Show-ScheduledScansCard
            Save-SidebarAppearance "scheduled-scans-high-contrast"
            [SidebarReviewKeyboard]::SetHighContrastFlags($highContrast)
            $highContrast = $null
            Start-Sleep -Seconds 2
            if (-not [UiReviewNativeWindow]::SetWindowPos($windowHandle, [IntPtr]::new(-2), 0, 0, 0, 0, 0x0053)) {
                throw [System.ComponentModel.Win32Exception]::new()
            }
            $captureTopmost = $false
        }

        # Restarting restores the saved choice and waits a full interval before the first scan.
        Hide-ScheduledScansCard
        Set-UiReviewTheme -Root $root -Theme "Standard Dark"
        Show-ScheduledScansCard
        Set-UiReviewAppearanceChoice -Root $root -Picker ScanIntervalPicker -Choice "2 hours"
        Assert-ScheduledScanSettings $true 120
        Stop-SidebarApp
        Start-SidebarApp
        Set-SidebarWindowWidth $expandedWidth
        Select-SidebarPage Settings "Window backdrop"
        Show-ScheduledScansCard
        Assert-ScheduledScansSelection On "2 hours"
        $null = Wait-SidebarText ScheduledScanStatus "First scheduled scan around *."
        $null = Wait-SidebarText ScanFreshnessText "*127.0.0.1/32 $dot Scheduled every 2 hours"
        (Find-SidebarElement AutomationId ScheduledScansSwitch).GetCurrentPattern(
            [System.Windows.Automation.TogglePattern]::Pattern).Toggle()
        Assert-ScheduledScanSettings $false 120
        $null = Wait-SidebarText ScheduledScanStatus "Off. Scans run only when you select Scan LAN."
        Hide-ScheduledScansCard
        Write-Host "Scheduled scan defaults, keyboard toggle, interval, cancellation, disabling, completion, persistence, responsive layout, and themes passed."
    }
    finally {
        if ($null -ne $highContrast) {
            [SidebarReviewKeyboard]::SetHighContrastFlags($highContrast)
            Start-Sleep -Seconds 2
        }
        if ($captureTopmost -and $process -and -not $process.HasExited -and
            -not [UiReviewNativeWindow]::SetWindowPos($windowHandle, [IntPtr]::new(-2), 0, 0, 0, 0, 0x0053)) {
            throw [System.ComponentModel.Win32Exception]::new()
        }
        if (Test-Path -LiteralPath $scanHoldPath) { Remove-Item -LiteralPath $scanHoldPath }
    }
}

$savedReviewMode = $env:FINGVIBE_UI_REVIEW
$savedScanHold = $env:FINGVIBE_UI_REVIEW_SCAN_HOLD
$savedNavigationPreference = $env:FINGVIBE_UI_REVIEW_NAVIGATION
$savedPeriodicScan = $env:FINGVIBE_UI_REVIEW_PERIODIC_SCAN
$savedPeriodicScanTimeScale = $env:FINGVIBE_UI_REVIEW_PERIODIC_SCAN_TIME_SCALE
$savedSnapshot = $env:FINGVIBE_UI_REVIEW_SNAPSHOT
$savedInventory = $env:FINGVIBE_UI_REVIEW_INVENTORY
$scanHoldPath = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-refresh-$([Guid]::NewGuid().ToString('N')).hold"
$navigationPreferencePath = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-navigation-$([Guid]::NewGuid().ToString('N')).json"
$periodicScanDirectory = Join-Path ([IO.Path]::GetTempPath()) "fingvibe-periodic-$([Guid]::NewGuid().ToString('N'))"
$periodicScanPath = Join-Path $periodicScanDirectory "periodic-scan.json"
$process = $null
$previousContext = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
try {
    $env:FINGVIBE_UI_REVIEW = "1"
    $env:FINGVIBE_UI_REVIEW_SCAN_HOLD = $scanHoldPath
    $env:FINGVIBE_UI_REVIEW_NAVIGATION = $null
    $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
    Start-SidebarApp
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
    Test-SidebarResizing
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
        Resize-SidebarPane @(280)
        Assert-SidebarPaneWidth 280
        Resize-SidebarPane @(216)
        Save-SidebarAppearance "sidebar-overlay-$width" -AssertMatchingSolid
        Select-SidebarPage People "Search people"
        if ($width -eq 640 -and (Find-SidebarElement AutomationId NavigationResizeGrip -Optional)) {
            throw "A closed minimal-mode pane must not leave a resize divider over page content."
        }
    }
    Write-Host "Sidebar navigation, expanded/compact/overlay layouts, and matching solid backgrounds in all six themes passed; material captures saved."
    Test-DeviceRefresh
    Test-ScanPresentation
    Test-SidebarPersistence
    Test-ScheduledScans
}
finally {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id
        $null = $process.WaitForExit(10000)
    }
    $env:FINGVIBE_UI_REVIEW = $savedReviewMode
    $env:FINGVIBE_UI_REVIEW_SCAN_HOLD = $savedScanHold
    $env:FINGVIBE_UI_REVIEW_NAVIGATION = $savedNavigationPreference
    $env:FINGVIBE_UI_REVIEW_PERIODIC_SCAN = $savedPeriodicScan
    $env:FINGVIBE_UI_REVIEW_PERIODIC_SCAN_TIME_SCALE = $savedPeriodicScanTimeScale
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = $savedSnapshot
    $env:FINGVIBE_UI_REVIEW_INVENTORY = $savedInventory
    if (Test-Path -LiteralPath $scanHoldPath) { Remove-Item -LiteralPath $scanHoldPath }
    if (Test-Path -LiteralPath $navigationPreferencePath) { Remove-Item -LiteralPath $navigationPreferencePath }
    if (Test-Path -LiteralPath $periodicScanDirectory) { Remove-Item -LiteralPath $periodicScanDirectory -Recurse -Force }
    $null = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext($previousContext)
}
