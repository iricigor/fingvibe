$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing, System.Windows.Forms, UIAutomationClient, UIAutomationTypes
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class UiReviewNativeWindow
{
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr window, out RECT rectangle);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr window, IntPtr insertAfter,
        int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")]
    public static extern uint GetDpiForWindow(IntPtr window);
}
"@

function Get-UiReviewWindowBounds {
    param([Parameter(Mandatory)][IntPtr] $WindowHandle)

    $rectangle = [UiReviewNativeWindow+RECT]::new()
    if (-not [UiReviewNativeWindow]::GetWindowRect($WindowHandle, [ref] $rectangle)) {
        throw [System.ComponentModel.Win32Exception]::new()
    }
    [System.Drawing.Rectangle]::FromLTRB(
        $rectangle.Left, $rectangle.Top, $rectangle.Right, $rectangle.Bottom)
}

function Assert-UiReviewWindowBounds {
    param(
        [Parameter(Mandatory)][System.Drawing.Rectangle] $Bounds,
        [Parameter(Mandatory)][System.Drawing.Rectangle] $WorkingArea
    )

    if ($Bounds.Width -lt 640 -or $Bounds.Height -lt 480) {
        throw "The review window is too small: $Bounds (minimum 640x480)."
    }
    if (-not $WorkingArea.Contains($Bounds)) {
        throw "The complete review window $Bounds is not inside the monitor working area $WorkingArea."
    }
}

function Initialize-UiReviewWindow {
    param([Parameter(Mandatory)][IntPtr] $WindowHandle)

    # Use physical pixels for both Win32 bounds and screen capture, even on scaled desktops.
    $previousContext = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
    if ($previousContext -eq [IntPtr]::Zero) {
        throw [System.ComponentModel.Win32Exception]::new()
    }
    try {
        $null = [UiReviewNativeWindow]::ShowWindow($WindowHandle, 9)
        $bounds = Get-UiReviewWindowBounds -WindowHandle $WindowHandle
        $area = [System.Windows.Forms.Screen]::FromHandle($WindowHandle).WorkingArea
        Write-Host "Initial window: $bounds; monitor work area: $area; window DPI: $([UiReviewNativeWindow]::GetDpiForWindow($WindowHandle))."

        $width = [Math]::Min($bounds.Width, $area.Width)
        $height = [Math]::Min($bounds.Height, $area.Height)
        $x = $area.Left + [int] (($area.Width - $width) / 2)
        $y = $area.Top + [int] (($area.Height - $height) / 2)
        if (-not [UiReviewNativeWindow]::SetWindowPos(
                $WindowHandle, [IntPtr]::Zero, $x, $y, $width, $height, 0x0044)) {
            throw [System.ComponentModel.Win32Exception]::new()
        }
        [System.Windows.Automation.AutomationElement]::FromHandle($WindowHandle).SetFocus()
        Start-Sleep -Milliseconds 750

        $bounds = Get-UiReviewWindowBounds -WindowHandle $WindowHandle
        Assert-UiReviewWindowBounds -Bounds $bounds -WorkingArea $area
        Write-Host "Prepared full review window: $bounds."
    }
    finally {
        $null = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext($previousContext)
    }
}

function Save-UiReviewWindowScreenshot {
    param(
        [Parameter(Mandatory)][IntPtr] $WindowHandle,
        [Parameter(Mandatory)][string] $Path
    )

    $previousContext = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
    if ($previousContext -eq [IntPtr]::Zero) {
        throw [System.ComponentModel.Win32Exception]::new()
    }
    $bitmap = $null
    $graphics = $null
    try {
        $bounds = Get-UiReviewWindowBounds -WindowHandle $WindowHandle
        $area = [System.Windows.Forms.Screen]::FromHandle($WindowHandle).WorkingArea
        Assert-UiReviewWindowBounds -Bounds $bounds -WorkingArea $area

        if (-not [UiReviewNativeWindow]::IsWindowVisible($WindowHandle) -or
            [UiReviewNativeWindow]::IsIconic($WindowHandle) -or
            [UiReviewNativeWindow]::GetForegroundWindow() -ne $WindowHandle) {
            throw "The review window must be visible, restored, and in the foreground for capture."
        }
        $bitmap = [System.Drawing.Bitmap]::new($bounds.Width, $bounds.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $afterCapture = Get-UiReviewWindowBounds -WindowHandle $WindowHandle
        if ($afterCapture -ne $bounds -or
            [UiReviewNativeWindow]::GetForegroundWindow() -ne $WindowHandle) {
            throw "The review window moved, resized, or lost focus during capture."
        }

        $colors = [System.Collections.Generic.HashSet[int]]::new()
        $xStep = [Math]::Max([int] ($bitmap.Width / 20), 1)
        $yStep = [Math]::Max([int] ($bitmap.Height / 20), 1)
        for ($x = 0; $x -lt $bitmap.Width; $x += $xStep) {
            for ($y = 0; $y -lt $bitmap.Height; $y += $yStep) {
                $null = $colors.Add($bitmap.GetPixel($x, $y).ToArgb())
            }
        }
        if ($colors.Count -lt 8) {
            throw "The screenshot appears blank or failed to render."
        }

        $directory = Split-Path -Parent ([System.IO.Path]::GetFullPath($Path))
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        Write-Host "Captured complete window: $bounds; PNG: $($bitmap.Width)x$($bitmap.Height)."
    }
    finally {
        if ($graphics) { $graphics.Dispose() }
        if ($bitmap) { $bitmap.Dispose() }
        $null = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext($previousContext)
    }
}
