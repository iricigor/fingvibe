
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

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr SendMessageTimeout(IntPtr window, uint message, UIntPtr parameter,
        string setting, uint flags, uint timeout, out UIntPtr result);

    public static void NotifyTextScaleChanged()
    {
        UIntPtr result;
        if (SendMessageTimeout(new IntPtr(0xffff), 0x001a, UIntPtr.Zero, "Accessibility", 2, 5000, out result) == IntPtr.Zero)
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
    $pageMarkerId = $null
    $ownerId = if ($Property -eq 'AutomationId' -and $Value -eq 'ResultsList') {
        $pageMarkerId = 'DevicesHeading'
        'TableViewport'
    } elseif ($Property -eq 'AutomationId' -and
        $Value -match '^(ResultSearchBox|ResultCountText|LastScanText|FilterExpander)$') {
        $pageMarkerId = 'DevicesHeading'
        'MainNavigation'
    } elseif ($Property -eq 'AutomationId' -and
        $Value -match '^(Scheduled|ScanIntervalPicker|ResetColumnsButton|Combine|ModePicker|ThemePicker|BackdropPicker)') {
        $pageMarkerId = 'SettingsPage'
        'SettingsPage'
    } else { $null }
    Find-UiRegressionElement -Condition $condition -Optional:$Optional -Description "visible sidebar element '$Value'" -Container {
        if (-not $ownerId) { return $root }
        Get-UiRegressionPageContainer -Root $root -PageMarkerId $pageMarkerId -ContainerId $ownerId
    }
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
    $element = Find-UiRegressionElement -Container { $root } -Condition $condition -Description "navigation '$Name'"
    if (-not $element -or $element.Current.IsOffscreen) { throw "Navigation '$Name' is not visible." }
    $selection = $element.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    $selection.Select()
    $null = Wait-UiRegressionState -Description "selected navigation '$Name'" -Condition { $selection.Current.IsSelected }
    $null = Find-SidebarElement Name $Sentinel
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
    $scan = Find-SidebarElement AutomationId ScanButton
    $scanBounds = $scan.Current.BoundingRectangle
    if ($scan.Current.Name -ne "Scan LAN" -or -not $scan.Current.IsEnabled -or
        -not $scan.Current.IsKeyboardFocusable -or
        -not $root.Current.BoundingRectangle.Contains($scanBounds) -or
        $scanBounds.Left -lt $bounds[1].Right -or
        (Find-SidebarElement AutomationId CancelButton -Optional)) {
        throw "Every page must share one accessible, usable Scan LAN action beside the network selector."
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
    Save-UiRegressionScreenshot -WindowHandle $windowHandle -Path $path
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

function Start-SidebarApp {
    $script:process = Start-Process -FilePath (Resolve-Path -LiteralPath $AppPath).Path -PassThru
    $script:windowHandle = Wait-UiRegressionWindow -Process $script:process
    $script:root = [System.Windows.Automation.AutomationElement]::FromHandle($script:windowHandle)
    $null = Find-SidebarElement AutomationId MainNavigation
    Focus-SidebarWindow
    Initialize-UiReviewWindow $script:windowHandle
    $script:scale = [UiReviewNativeWindow]::GetDpiForWindow($script:windowHandle) / 96.0
}

function Stop-SidebarApp {
    Stop-UiRegressionApp -Process $script:process
}
