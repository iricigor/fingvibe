param(
    [Parameter(Mandatory)][string] $AppPath,
    [string] $ScreenshotDirectory,
    [ValidateRange(1024, 1280)][int] $WindowWidth = 1280
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScreenshot.ps1")
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class TroubleshootingReviewKeyboard
{
    [DllImport("user32.dll")]
    private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    public static void AllowForeground()
    {
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(0x12, 0, 2, UIntPtr.Zero);
    }
}
"@
$previousReview = $env:FINGVIBE_UI_REVIEW
$env:FINGVIBE_UI_REVIEW = "1"
$process = $null

function Find-Control([string] $Name, [System.Windows.Automation.ControlType] $Type) {
    $condition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $Name),
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, $Type))
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    do {
        $element = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if ($element) { return $element }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Missing troubleshooting control: $Name."
}

function Invoke-Control([string] $Name) {
    (Find-Control $Name ([System.Windows.Automation.ControlType]::Button)).
        GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    Start-Sleep -Milliseconds 300
}

function Select-Page([string] $Name) {
    (Find-Control $Name ([System.Windows.Automation.ControlType]::ListItem)).
        GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
    Start-Sleep -Milliseconds 400
}

function Scroll-Control([string] $Id) {
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)
    $element = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if (-not $element) { throw "Missing scroll control: $Id." }
    return $element.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
}

try {
    $process = Start-Process -FilePath $AppPath -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 200
        $process.Refresh()
        if ($process.HasExited) { throw "App exited with code $($process.ExitCode)." }
    } while ($process.MainWindowHandle -eq 0 -and [DateTime]::UtcNow -lt $deadline)
    if ($process.MainWindowHandle -eq 0) { throw "App did not open a window." }
    [TroubleshootingReviewKeyboard]::AllowForeground()
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $null = [UiReviewNativeWindow]::SetForegroundWindow($process.MainWindowHandle)
        Start-Sleep -Milliseconds 100
    } while ([UiReviewNativeWindow]::GetForegroundWindow() -ne $process.MainWindowHandle -and [DateTime]::UtcNow -lt $deadline)
    Initialize-UiReviewWindow $process.MainWindowHandle
    $area = [System.Windows.Forms.Screen]::FromHandle($process.MainWindowHandle).WorkingArea
    $null = [UiReviewNativeWindow]::SetWindowPos(
        $process.MainWindowHandle, [IntPtr]::Zero, $area.Left, $area.Top,
        [Math]::Min($WindowWidth, $area.Width), [Math]::Min(720, $area.Height), 0x0044)
    Start-Sleep -Milliseconds 400
    $script:root = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
    Select-Page Tools
    Invoke-Control "Network troubleshooting"
    $null = Find-Control "Back to Tools" ([System.Windows.Automation.ControlType]::Button)
    $wan = Find-Control "Router WAN IPv4 address" ([System.Windows.Automation.ControlType]::Edit)
    $value = $wan.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $value.SetValue("bad-address")
    $null = Find-Control "WAN input/settings error: Enter an IPv4 address as four decimal octets (for example, 203.0.113.10), or leave it blank. The previously saved valid value was not replaced." ([System.Windows.Automation.ControlType]::Text)
    $value.SetValue("203.0.113.10")
    $value.SetValue("")
    $scroll = Scroll-Control "TroubleshootingScroll"
    $scroll.SetScrollPercent(-1, 20)
    Start-Sleep -Milliseconds 300
    Invoke-Control "Run network troubleshooting"
    $null = Find-Control "UI-review mode does not send diagnostic probes." ([System.Windows.Automation.ControlType]::Text)
    if ((Find-Control "Cancel network troubleshooting" ([System.Windows.Automation.ControlType]::Button)).Current.IsEnabled) {
        throw "UI review incorrectly started diagnostic network activity."
    }
    if ($ScreenshotDirectory) {
        $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
        Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "troubleshooting-ready.png")
    }
    if (-not $scroll.Current.VerticallyScrollable) { throw "Troubleshooting page must scroll at ordinary window sizes." }
    $scroll.SetScrollPercent(-1, 55)
    Start-Sleep -Milliseconds 400
    $summary = Find-Control "Ready / not tested" ([System.Windows.Automation.ControlType]::Text)
    $details = Find-Control "Detailed checkpoint diagnostics" ([System.Windows.Automation.ControlType]::Text)
    if ($summary.Current.IsOffscreen -or $details.Current.IsOffscreen -or
        $summary.Current.BoundingRectangle.Bottom -ge $details.Current.BoundingRectangle.Top) {
        throw "The status summary must be visible above detailed diagnostics."
    }
    if ($ScreenshotDirectory) {
        Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "troubleshooting-diagram.png")
    }
    $bounds = Get-UiReviewWindowBounds $process.MainWindowHandle
    $null = [UiReviewNativeWindow]::SetWindowPos(
        $process.MainWindowHandle, [IntPtr]::Zero, $bounds.X, $bounds.Y, 640, 600, 0x0044)
    Start-Sleep -Milliseconds 400
    if (-not (Scroll-Control "DiagramScroll").Current.HorizontallyScrollable) {
        throw "The illustrative diagram must remain horizontally scrollable in a narrow window."
    }
    $null = [UiReviewNativeWindow]::SetWindowPos(
        $process.MainWindowHandle, [IntPtr]::Zero, $bounds.X, $bounds.Y, $bounds.Width, $bounds.Height, 0x0044)
    $scroll.SetScrollPercent(-1, 0)
    Start-Sleep -Milliseconds 400
    Invoke-Control "Back to Tools"
    Invoke-Control "Network troubleshooting"
    if ((Find-Control "Router WAN IPv4 address" ([System.Windows.Automation.ControlType]::Edit)).
        GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -ne "") {
        throw "UI-review mode reused an unsaved WAN value."
    }
    Select-Page Overview
    Select-Page Tools
    $null = Find-Control "Network troubleshooting" ([System.Windows.Automation.ControlType]::Button)
    Invoke-Control "Speed test"
    $null = Find-Control "Start Cloudflare speed test" ([System.Windows.Automation.ControlType]::Button)
    Write-Host "Troubleshooting controls, WAN validation, privacy, diagram/summary ordering, narrow scrolling, navigation, and speed-test entry passed."
}
catch {
    if ($ScreenshotDirectory -and $process -and -not $process.HasExited -and
        [UiReviewNativeWindow]::GetForegroundWindow() -eq $process.MainWindowHandle) {
        $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
        Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "troubleshooting-failure.png")
    }
    throw
}
finally {
    if ($null -ne $process -and -not $process.HasExited) {
        $null = $process.CloseMainWindow()
        if (-not $process.WaitForExit(5000)) { Stop-Process -Id $process.Id }
    }
    $env:FINGVIBE_UI_REVIEW = $previousReview
}
