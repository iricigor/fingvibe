param(
    [Parameter(Mandatory)][string] $AppPath,
    [string] $ScreenshotDirectory,
    [ValidateRange(1024, 1280)][int] $WindowWidth = 1280
)

$ErrorActionPreference = "Stop"
$diagramDocument = [System.Xml.XmlDocument]::new()
$diagramDocument.Load((Join-Path $PSScriptRoot "..\src\FingVibe.App\Tools\NetworkTroubleshootingPage.xaml"))
$diagramCard = $diagramDocument.SelectSingleNode("//*[local-name()='Border'][.//*[@*[local-name()='Name']='DiagramScroll']]")
foreach ($name in @("RunButton", "CancelRunButton", "RunProgress", "ProgressText")) {
    if (-not $diagramCard.SelectSingleNode(".//*[@*[local-name()='Name']='$name']")) {
        throw "Run controls and progress must belong to the diagram card: $name."
    }
}
$connectors = @($diagramDocument.SelectNodes("//*[local-name()='Canvas']/*[local-name()='Path']"))
if ($connectors.Count -ne 8 -or @($connectors | Where-Object { $_.GetAttribute("Data") -match '\bQ' }).Count -ne 4 -or
    $diagramDocument.SelectNodes("//*[local-name()='Polyline']").Count -ne 0) {
    throw "The four branch connectors must use explicit curved elbows, not square polyline corners."
}
foreach ($name in @("PcRouterConnector", "RouterHopConnector", "HopInternetConnector", "InternetGoogleConnector")) {
    $connector = $diagramDocument.SelectSingleNode("//*[@*[local-name()='Name']='$name']")
    if (-not $connector -or $connector.GetAttribute("Data") -notmatch '^M\d+,198 H\d+$') {
        throw "Main-path connector $name must be one straight horizontal segment on the shared device baseline."
    }
}
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

function Show-Controls([string[]] $Names) {
    $scroll = Scroll-Control "TroubleshootingScroll"
    foreach ($percent in 0..20) {
        $scroll.SetScrollPercent(-1, $percent * 5)
        Start-Sleep -Milliseconds 100
        $visible = $true
        foreach ($name in $Names) {
            $condition = [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::NameProperty, $name)
            $element = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
            if (-not $element -or $element.Current.IsOffscreen) { $visible = $false; break }
        }
        if ($visible) { return }
    }
    throw "Could not scroll the logical section into view: $($Names -join ', ')."
}

function Find-Address([string] $Checkpoint) {
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "DiagramAddress$Checkpoint")
    $element = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if (-not $element) { throw "Missing diagram checkpoint address: $Checkpoint." }
    return $element
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
    foreach ($heading in @("Connection and checks", "Network path and status", "Detailed checkpoint diagnostics", "Traceroute")) {
        $null = Find-Control $heading ([System.Windows.Automation.ControlType]::Text)
    }
    $null = Find-Control "Back to Tools" ([System.Windows.Automation.ControlType]::Button)
    $wan = Find-Control "Router WAN IPv4 address" ([System.Windows.Automation.ControlType]::Edit)
    $value = $wan.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $value.SetValue("bad-address")
    $null = Find-Control "WAN input/settings error: Enter an IPv4 address as four decimal octets (for example, 203.0.113.10), or leave it blank. The previously saved valid value was not replaced." ([System.Windows.Automation.ControlType]::Text)
    $value.SetValue("203.0.113.10")
    $value.SetValue("")
    $scroll = Scroll-Control "TroubleshootingScroll"
    Show-Controls @("Run network troubleshooting")
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
    Show-Controls @("Network path and status", "Ready / not tested")
    $run = Find-Control "Run network troubleshooting" ([System.Windows.Automation.ControlType]::Button)
    $pathHeading = Find-Control "Network path and status" ([System.Windows.Automation.ControlType]::Text)
    $illustration = Find-Control "Illustrative network diagram - logical checkpoints, not discovered physical topology" ([System.Windows.Automation.ControlType]::Text)
    if ($run.Current.IsOffscreen -or $run.Current.BoundingRectangle.Top -le $pathHeading.Current.BoundingRectangle.Bottom -or
        $run.Current.BoundingRectangle.Bottom -ge $illustration.Current.BoundingRectangle.Top) {
        throw "Run checks must be visible near the top of the diagram card, below its heading and above the illustration."
    }
    if ($ScreenshotDirectory) {
        Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "troubleshooting-diagram.png")
        $bitmap = [System.Drawing.Bitmap]::new((Join-Path $ScreenshotDirectory "troubleshooting-diagram.png"))
        try {
            $windowBounds = Get-UiReviewWindowBounds $process.MainWindowHandle
            $addressBounds = (Find-Address Loopback).Current.BoundingRectangle
            $scale = [UiReviewNativeWindow]::GetDpiForWindow($process.MainWindowHandle) / 96.0
            $x = [int][Math]::Round($addressBounds.Right - $windowBounds.Left)
            $y = [int][Math]::Round($addressBounds.Bottom - 20 * $scale - $windowBounds.Top)
            $center = $bitmap.GetPixel($x + [int](11 * $scale), $y).ToArgb()
            $outline = $bitmap.GetPixel($x + [int](5 * $scale), $y).ToArgb()
            $background = $bitmap.GetPixel($x + [int](23 * $scale), $y).ToArgb()
            if ($center -ne $background -or $outline -eq $background) {
                throw "The left untested port must be a hollow circle immediately after its IP label."
            }
            $rightBounds = (Find-Address LocalAddress).Current.BoundingRectangle
            $rightX = [int][Math]::Round($rightBounds.Left - $windowBounds.Left)
            $rightY = [int][Math]::Round($rightBounds.Bottom - 20 * $scale - $windowBounds.Top)
            $rightCenter = $bitmap.GetPixel($rightX - [int](11 * $scale), $rightY).ToArgb()
            $rightOutline = $bitmap.GetPixel($rightX - [int](17 * $scale), $rightY).ToArgb()
            $rightBackground = $bitmap.GetPixel($rightX - [int](11 * $scale), $rightY - [int](11 * $scale)).ToArgb()
            if ($rightCenter -ne $rightBackground -or $rightOutline -eq $rightBackground -or
                $addressBounds.Right -ge $rightBounds.Left -or [Math]::Abs($addressBounds.Top - $rightBounds.Top) -gt 2 * $scale) {
                throw "The right untested port must be a hollow circle before its IP label, horizontally opposite the left port."
            }
            if ($addressBounds.Top -le $windowBounds.Top + $y -or $rightBounds.Top -le $windowBounds.Top + $rightY) {
                throw "Port IP text must sit below the straight connector baseline."
            }
            $foundStraightLine = $false
            foreach ($delta in -2..2) {
                $continuous = $true
                foreach ($offset in @(25, 90, 150)) {
                    $lineX = $rightX + [int]($offset * $scale)
                    $line = $bitmap.GetPixel($lineX, $rightY + [int]($delta * $scale)).ToArgb()
                    $aboveLine = $bitmap.GetPixel($lineX, $rightY - [int](11 * $scale)).ToArgb()
                    if ($line -eq $aboveLine) { $continuous = $false; break }
                }
                if ($continuous) { $foundStraightLine = $true; break }
            }
            if (-not $foundStraightLine) {
                throw "The rendered PC-to-router connector must be straight across the IP-label and device-gap columns."
            }
        }
        finally { $bitmap.Dispose() }
    }
    $expectedAddresses = @{
        Loopback = "127.0.0.1"; LocalAddress = "127.0.0.1"; Gateway = "Not supplied"; RouterWan = "Not supplied"
        Hop2 = "Not observed"; CloudflarePing = "1.1.1.1"; CloudflareDns = "1.1.1.1"; GooglePing = "8.8.8.8"; GoogleDns = "8.8.8.8"
    }
    foreach ($checkpoint in $expectedAddresses.Keys) {
        if ((Find-Address $checkpoint).Current.Name -ne $expectedAddresses[$checkpoint]) {
            throw "Diagram $checkpoint uses the wrong target/responder address."
        }
        $condition = [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "DiagramCheckpoint$checkpoint")
        $description = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if (-not $description) { throw "Missing port description: $checkpoint." }
        $text = $description.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(-1)
        if ($text -match '\((left|right)\)') { throw "Visible port descriptions must not include left/right suffixes: $checkpoint." }
    }
    Show-Controls @("Network path and status", "Ready / not tested")
    $local = (Find-Address LocalAddress).Current.BoundingRectangle
    $diagramScroll = Scroll-Control "DiagramScroll"
    if ($diagramScroll.Current.HorizontallyScrollable) { $diagramScroll.SetScrollPercent(100, -1); Start-Sleep -Milliseconds 200 }
    $google = (Find-Address GooglePing).Current.BoundingRectangle
    $cloudflare = (Find-Address CloudflarePing).Current.BoundingRectangle
    if ([Math]::Abs($google.Bottom - $local.Bottom) -gt 2 -or $cloudflare.Top -ge $google.Top) {
        throw "Provider checkpoints must be raised, with Google aligned to the local checkpoint baseline."
    }
    if ($diagramScroll.Current.HorizontallyScrollable) { $diagramScroll.SetScrollPercent(0, -1); Start-Sleep -Milliseconds 200 }
    Show-Controls @("Ready / not tested", "Detailed checkpoint diagnostics")
    $summary = Find-Control "Ready / not tested" ([System.Windows.Automation.ControlType]::Text)
    $details = Find-Control "Detailed checkpoint diagnostics" ([System.Windows.Automation.ControlType]::Text)
    if ($summary.Current.IsOffscreen -or $details.Current.IsOffscreen -or
        $summary.Current.BoundingRectangle.Bottom -ge $details.Current.BoundingRectangle.Top) {
        throw "The status summary must be visible above detailed diagnostics."
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
    Write-Host "Troubleshooting section containers, port addresses/provider alignment, WAN validation, privacy, scrolling, navigation, and speed-test entry passed."
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
