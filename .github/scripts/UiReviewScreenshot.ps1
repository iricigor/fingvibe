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
    public static extern bool SetForegroundWindow(IntPtr window);
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
        $null = [UiReviewNativeWindow]::SetForegroundWindow($WindowHandle)
        Start-Sleep -Milliseconds 750

        if ([UiReviewNativeWindow]::GetForegroundWindow() -ne $WindowHandle) {
            throw "The review window could not be brought to the foreground."
        }
        $bounds = Get-UiReviewWindowBounds -WindowHandle $WindowHandle
        Assert-UiReviewWindowBounds -Bounds $bounds -WorkingArea $area
        Write-Host "Prepared full review window: $bounds."
    }
    finally {
        $null = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext($previousContext)
    }
}

function Assert-UiReviewBitmapContent {
    param([Parameter(Mandatory)][System.Drawing.Bitmap] $Bitmap)

    $colors = [System.Collections.Generic.HashSet[int]]::new()
    $horizontalTransitions = 0
    $verticalTransitions = 0
    $previousRow = @{}
    $xStep = [Math]::Max([int] ($Bitmap.Width / 80), 1)
    $yStep = [Math]::Max([int] ($Bitmap.Height / 80), 1)
    for ($y = 0; $y -lt $Bitmap.Height; $y += $yStep) {
        $previousPixel = $null
        for ($x = 0; $x -lt $Bitmap.Width; $x += $xStep) {
            $pixel = $Bitmap.GetPixel($x, $y).ToArgb()
            $null = $colors.Add($pixel)
            if ($null -ne $previousPixel -and $pixel -ne $previousPixel) {
                $horizontalTransitions++
            }
            if ($previousRow.ContainsKey($x) -and $pixel -ne $previousRow[$x]) {
                $verticalTransitions++
            }
            $previousPixel = $pixel
            $previousRow[$x] = $pixel
        }
    }

    # High-contrast UIs can use only two colors; require spatial detail instead of a rich palette.
    if ($colors.Count -lt 8 -and
        ($colors.Count -lt 2 -or $horizontalTransitions -lt 16 -or $verticalTransitions -lt 16)) {
        throw "The screenshot appears blank or failed to render (colors: $($colors.Count); horizontal transitions: $horizontalTransitions; vertical transitions: $verticalTransitions)."
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

        $directory = Split-Path -Parent ([System.IO.Path]::GetFullPath($Path))
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        # Retain rejected captures as diagnostics rather than losing the image that failed validation.
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        Assert-UiReviewBitmapContent -Bitmap $bitmap
        Write-Host "Captured complete window: $bounds; PNG: $($bitmap.Width)x$($bitmap.Height)."
    }
    finally {
        if ($graphics) { $graphics.Dispose() }
        if ($bitmap) { $bitmap.Dispose() }
        $null = [UiReviewNativeWindow]::SetThreadDpiAwarenessContext($previousContext)
    }
}
