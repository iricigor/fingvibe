[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $AppPath,

    [Parameter(Mandatory)]
    [string] $ScreenshotPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $AppPath -PathType Leaf)) {
    throw "The published application was not found at '$AppPath'."
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class NativeWindow {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    public static extern void mouse_event(
        uint dwFlags,
        uint dx,
        uint dy,
        uint dwData,
        UIntPtr dwExtraInfo);
}
"@

function Find-NamedElement {
    param(
        [System.Windows.Automation.AutomationElement] $Root,
        [string] $Name
    )

    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::NameProperty,
        $Name)
    return $Root.FindFirst(
        [System.Windows.Automation.TreeScope]::Subtree,
        $condition)
}

function Find-ElementNameMatching {
    param(
        [System.Windows.Automation.AutomationElement] $Root,
        [string] $Pattern
    )

    $elements = $Root.FindAll(
        [System.Windows.Automation.TreeScope]::Subtree,
        [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($element in $elements) {
        if ($element.Current.Name -like $Pattern) {
            return $element
        }
    }

    return $null
}

function Save-WindowScreenshot {
    param(
        [IntPtr] $WindowHandle,
        [string] $Path
    )

    $rect = [NativeWindow+RECT]::new()
    if (-not [NativeWindow]::GetWindowRect($WindowHandle, [ref] $rect)) {
        throw "Could not determine the application window bounds."
    }

    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -lt 640 -or $height -lt 480) {
        throw "The main window rendered at an invalid size: ${width}x${height}."
    }

    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null

    $bitmap = [System.Drawing.Bitmap]::new($width, $height)
    try {
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $deviceContext = $graphics.GetHdc()
            try {
                if (-not [NativeWindow]::PrintWindow($WindowHandle, $deviceContext, 2)) {
                    throw "Windows could not render the application window for capture."
                }
            }
            finally {
                $graphics.ReleaseHdc($deviceContext)
            }
        }
        finally {
            $graphics.Dispose()
        }

        $colors = [System.Collections.Generic.HashSet[int]]::new()
        $xStep = [Math]::Max([int] ($width / 20), 1)
        $yStep = [Math]::Max([int] ($height / 20), 1)
        for ($x = 0; $x -lt $width; $x += $xStep) {
            for ($y = 0; $y -lt $height; $y += $yStep) {
                $null = $colors.Add($bitmap.GetPixel($x, $y).ToArgb())
            }
        }

        if ($colors.Count -lt 8) {
            throw "The screenshot appears blank or failed to render."
        }

        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $bitmap.Dispose()
    }
}

function Invoke-UiElement {
    param(
        [System.Windows.Automation.AutomationElement] $Element,
        [IntPtr] $WindowHandle
    )

    try {
        $invokePattern = $Element.GetCurrentPattern(
            [System.Windows.Automation.InvokePattern]::Pattern)
        $invokePattern.Invoke()
        return
    }
    catch {
        try {
            $legacyPattern = $Element.GetCurrentPattern(
                [System.Windows.Automation.LegacyIAccessiblePattern]::Pattern)
            $legacyPattern.DoDefaultAction()
            return
        }
        catch {
            $null = [NativeWindow]::SetForegroundWindow($WindowHandle)
            Start-Sleep -Milliseconds 250
            if ([NativeWindow]::GetForegroundWindow() -ne $WindowHandle) {
                throw "Refusing pointer input because the FingVibe window is not in the foreground."
            }

            $bounds = $Element.Current.BoundingRectangle
            if ($bounds.IsEmpty) {
                throw "The UI element cannot be invoked and has no clickable bounds."
            }

            $x = [int] ($bounds.Left + ($bounds.Width / 2))
            $y = [int] ($bounds.Top + ($bounds.Height / 2))
            if (-not [NativeWindow]::SetCursorPos($x, $y)) {
                throw "Could not position the pointer over the UI element."
            }

            [NativeWindow]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
            [NativeWindow]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
        }
    }
}

$process = Start-Process -FilePath $AppPath -PassThru
try {
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    while ($process.MainWindowHandle -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $deadline) {
        if ($process.HasExited) {
            throw "The application exited with code $($process.ExitCode) before displaying its main window."
        }

        Start-Sleep -Milliseconds 500
        $process.Refresh()
    }

    if ($process.MainWindowHandle -eq [IntPtr]::Zero) {
        throw "The application did not display a main window within 45 seconds."
    }

    $null = [NativeWindow]::SetForegroundWindow($process.MainWindowHandle)
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)

    foreach ($expectedName in @("FingVibe", "Detected network", "Scan LAN", "Cancel")) {
        if (-not (Find-NamedElement -Root $root -Name $expectedName)) {
            throw "Critical UI element '$expectedName' was not exposed to UI Automation."
        }
    }

    $scanButton = Find-NamedElement -Root $root -Name "Scan LAN"
    if (-not $scanButton.Current.IsEnabled) {
        throw "The primary 'Scan LAN' action is disabled."
    }

    Invoke-UiElement -Element $scanButton -WindowHandle $process.MainWindowHandle

    $cancelButton = Find-NamedElement -Root $root -Name "Cancel"
    $interactionDeadline = [DateTime]::UtcNow.AddSeconds(10)
    $scanCompleted = $false
    while (-not $cancelButton.Current.IsEnabled -and [DateTime]::UtcNow -lt $interactionDeadline) {
        if (Find-ElementNameMatching -Root $root -Pattern "Complete in *") {
            $scanCompleted = $true
            break
        }

        Start-Sleep -Milliseconds 250
        $cancelButton = Find-NamedElement -Root $root -Name "Cancel"
    }

    if (-not $cancelButton.Current.IsEnabled -and -not $scanCompleted) {
        throw "Invoking 'Scan LAN' did not enter or complete the expected scanning state."
    }

    $resultsDeadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Find-NamedElement -Root $root -Name "Online") -and
           -not (Find-NamedElement -Root $root -Name "Offline") -and
           [DateTime]::UtcNow -lt $resultsDeadline) {
        Start-Sleep -Milliseconds 250
    }

    if (-not (Find-NamedElement -Root $root -Name "Online") -and
        -not (Find-NamedElement -Root $root -Name "Offline")) {
        throw "The scan did not render a result with an accessible Online or Offline badge."
    }

    Save-WindowScreenshot -WindowHandle $process.MainWindowHandle -Path $ScreenshotPath

    if ($cancelButton.Current.IsEnabled) {
        Invoke-UiElement -Element $cancelButton -WindowHandle $process.MainWindowHandle
    }
}
finally {
    if (-not $process.HasExited) {
        Stop-Process -Id $process.Id
        $null = $process.WaitForExit(10000)
    }
}

Write-Host "UI smoke test passed and screenshot saved to '$ScreenshotPath'."
