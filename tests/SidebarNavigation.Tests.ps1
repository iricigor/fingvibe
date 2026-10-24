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

function Set-SidebarAppearance([string] $Picker, [string] $Choice) {
    Select-SidebarPage Settings "Window backdrop"
    $combo = Find-SidebarElement AutomationId $Picker
    $combo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    $item = Find-SidebarElement Name $Choice
    $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $combo.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse()
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
    $menuBounds = (Find-SidebarElement AutomationId NetworkNavItem).Current.BoundingRectangle
    $windowBounds = Get-UiReviewWindowBounds $windowHandle
    $path = Join-Path $ScreenshotDirectory "$Name.png"
    Focus-SidebarWindow
    Start-Sleep -Milliseconds 250
    Save-UiReviewWindowScreenshot $windowHandle $path
    if (-not $AssertMatchingSolid) { return }
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
            $windowHandle, [IntPtr]::Zero, $area.Left, $bounds.Top, $width, $bounds.Height, 0x0044)) {
        throw [System.ComponentModel.Win32Exception]::new()
    }
    Start-Sleep -Milliseconds 750
}

function Switch-SidebarPane {
    $toggle = Find-SidebarElement AutomationId TogglePaneButton
    $toggle.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 500
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

    Set-SidebarWindowWidth 1280
    $null = Find-SidebarElement Name FingVibe
    $null = Find-SidebarElement Name "LAN scanner"
    foreach ($page in @(
        @("Network", "Public IP address"),
        @("Devices", "Filter scan results"),
        @("Rooms", "Search rooms"),
        @("Tools", "Speed test"),
        @("Settings", "Window backdrop"),
        @("Overview", "Online devices"),
        @("People", "Search people")
    )) {
        Select-SidebarPage $page[0] $page[1]
    }
    $network = Find-SidebarElement AutomationId NetworkNavItem
    $menuBounds = $network.Current.BoundingRectangle
    if ([Math]::Abs($menuBounds.Width / $scale - 264) -gt 4) {
        throw "Expanded navigation rows must fit the 280px pane; got $($menuBounds.Width / $scale)px."
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
    foreach ($theme in @("Standard Light", "Warm Light", "Standard Dark", "True Black (OLED)")) {
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
    $null = Find-SidebarElement Name "Filter scan results"
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
    Write-Host "Sidebar navigation, expanded/compact/overlay layouts, and matching solid backgrounds in all four themes passed; material captures saved."
}
finally {
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id }
    $env:FINGVIBE_UI_REVIEW = $savedReviewMode
    $null = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext($previousContext)
}
