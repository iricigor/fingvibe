$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class FullComparisonDesktop {
    [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct Contrast { public uint Size, Flags; public IntPtr Scheme; }
    [DllImport("user32.dll", SetLastError=true)] public static extern bool GetWindowRect(IntPtr window, out Rect bounds);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(Point point);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll", SetLastError=true)] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll", SetLastError=true)] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] private static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll", SetLastError=true)] private static extern bool SystemParametersInfo(uint action, uint parameter, ref Contrast value, uint flags);
    public static void Click() {
        mouse_event(2, 0, 0, 0, UIntPtr.Zero);
        mouse_event(4, 0, 0, 0, UIntPtr.Zero);
    }
    public static void MoveTo(int x, int y) {
        uint absoluteX = (uint)((long)(x - GetSystemMetrics(76)) * 65535 / (GetSystemMetrics(78) - 1));
        uint absoluteY = (uint)((long)(y - GetSystemMetrics(77)) * 65535 / (GetSystemMetrics(79) - 1));
        mouse_event(0xC001, absoluteX, absoluteY, 0, UIntPtr.Zero);
    }
    public static uint GetContrast() {
        var value = new Contrast { Size = (uint)Marshal.SizeOf(typeof(Contrast)) };
        if (!SystemParametersInfo(0x0042, value.Size, ref value, 0)) throw new Win32Exception(Marshal.GetLastWin32Error());
        return value.Flags;
    }
    public static void SetContrast(uint flags) {
        var value = new Contrast { Size = (uint)Marshal.SizeOf(typeof(Contrast)), Flags = flags };
        if (!SystemParametersInfo(0x0043, value.Size, ref value, 2)) throw new Win32Exception(Marshal.GetLastWin32Error());
    }
}
'@

function Assert-ComparisonDesktop {
    $window = [FullComparisonDesktop]::GetForegroundWindow()
    $ownerId = [uint32]0
    if ($window -eq [IntPtr]::Zero -or
        [FullComparisonDesktop]::GetWindowThreadProcessId($window, [ref] $ownerId) -eq 0) {
        throw 'Cannot identify an interactive foreground window for desktop automation.'
    }
    $owner = [Diagnostics.Process]::GetProcessById($ownerId)
    try {
        if ($owner.ProcessName -in @('LockApp', 'LogonUI')) {
            throw "Desktop is locked ($($owner.ProcessName) owns foreground). Unlock Windows before running the comparison."
        }
    }
    finally { $owner.Dispose() }
}

function Save-ComparisonClipboard {
    $current = [System.Windows.Forms.Clipboard]::GetDataObject()
    if ($null -eq $current) { return $null }
    $snapshot = [System.Windows.Forms.DataObject]::new()
    foreach ($format in $current.GetFormats($false)) {
        $snapshot.SetData($format, $false, $current.GetData($format, $false))
    }
    return $snapshot
}

function Restore-ComparisonClipboard {
    param($Snapshot)
    if ($null -eq $Snapshot) { [System.Windows.Forms.Clipboard]::Clear() }
    else { [System.Windows.Forms.Clipboard]::SetDataObject($Snapshot, $true) }
}

function Enter-ComparisonWindow {
    param([Parameter(Mandatory)][IntPtr] $WindowHandle)
    if ([FullComparisonDesktop]::GetForegroundWindow() -eq $WindowHandle) { return }
    $previous = [FullComparisonDesktop]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
    if ($previous -eq [IntPtr]::Zero) { throw 'Cannot establish physical-pixel activation coordinates.' }
    try {
        $null = [FullComparisonDesktop]::ShowWindow($WindowHandle, 9)
        $bounds = [FullComparisonDesktop+Rect]::new()
        if (-not [FullComparisonDesktop]::GetWindowRect($WindowHandle, [ref] $bounds)) {
            throw 'Cannot read the comparison app bounds.'
        }
        $area = [System.Windows.Forms.Screen]::FromHandle($WindowHandle).WorkingArea
        $width = [Math]::Min($bounds.Right - $bounds.Left, $area.Width)
        $height = [Math]::Min($bounds.Bottom - $bounds.Top, $area.Height)
        $x = $area.Left
        $y = $area.Top
        if (-not [FullComparisonDesktop]::SetWindowPos($WindowHandle, [IntPtr]::new(-1),
            $x, $y, $width, $height, 0x0050)) { throw 'Cannot present the comparison app.' }
        try {
            $point = [FullComparisonDesktop+Point]::new()
            $point.X = $x + [int]($width / 2)
            $point.Y = $y + 16
            [FullComparisonDesktop]::MoveTo($point.X, $point.Y)
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while (($hitWindow = [FullComparisonDesktop]::GetAncestor([FullComparisonDesktop]::WindowFromPoint($point), 2)) -ne $WindowHandle) {
                if ($clock.ElapsedMilliseconds -ge 2000) {
                    throw "Activation point ($($point.X),$($point.Y)) belongs to HWND $hitWindow, not comparison HWND $WindowHandle; no click was sent."
                }
                Start-Sleep -Milliseconds 50
            }
            [FullComparisonDesktop]::Click()
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while ([FullComparisonDesktop]::GetForegroundWindow() -ne $WindowHandle) {
                if ($clock.ElapsedMilliseconds -ge 2000) { throw 'The comparison app did not acquire foreground focus.' }
                Start-Sleep -Milliseconds 50
            }
        }
        finally {
            if (-not [FullComparisonDesktop]::SetWindowPos($WindowHandle, [IntPtr]::new(-2), 0, 0, 0, 0, 0x0013)) {
                throw 'Cannot remove temporary topmost state.'
            }
        }
    }
    finally { $null = [FullComparisonDesktop]::SetThreadDpiAwarenessContext($previous) }
}
