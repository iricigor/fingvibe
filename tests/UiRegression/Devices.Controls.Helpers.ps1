
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
    $pageMarkerId = $null
    $ownerId = if ($Id -match '^(ResultsList|DeviceTableHeader)$') {
        $pageMarkerId = 'DevicesHeading'
        'TableViewport'
    } elseif ($Id -match '^(DevicesHeading|ResultCountText|InventoryCountsText|LastScanText)$') {
        $pageMarkerId = 'DevicesHeading'
        'MainNavigation'
    } elseif ($Id -match '^(Combine|ColumnChoices|ResetColumnsButton|CompactRowsSwitch|EnlargedCellPreviews)') {
        $pageMarkerId = 'SettingsPage'
        'SettingsPage'
    } else { $null }
    Find-UiRegressionElement -Condition $condition -Description "visible device element '$Id'" -Container {
        if (-not $ownerId) { return $root }
        Get-UiRegressionPageContainer -Root $root -PageMarkerId $pageMarkerId -ContainerId $ownerId
    }
}

function Select-DevicePage([string] $Id) {
    $element = if ($Id -eq "Settings") {
        $condition = [System.Windows.Automation.AndCondition]::new(
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, "Settings"),
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::ListItem))
        Find-UiRegressionElement -Container { $root } -Condition $condition -Description "Settings navigation"
    } else { Find-DeviceElement $Id }
    if (-not $element) { throw "Navigation '$Id' was not found." }
    $element.GetCurrentPattern(
        [System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $pageId = switch ($Id) {
        Settings { 'SettingsPage' }
        DevicesNavItem { 'ResultsList' }
        OverviewNavItem { 'OnlineDevicesText' }
    }
    if ($pageId) { $null = Find-DeviceElement $pageId }
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
    Save-UiRegressionScreenshot -WindowHandle $windowHandle -Path $path
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
