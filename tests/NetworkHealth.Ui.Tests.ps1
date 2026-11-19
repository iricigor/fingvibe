param(
    [Parameter(Mandatory)][string] $AppPath,
    [string] $ScreenshotDirectory,
    [ValidateRange(1024, 1280)][int] $WindowWidth = 1280
)

$ErrorActionPreference = "Stop"
$diagramDocument = [System.Xml.XmlDocument]::new()
$diagramDocument.Load((Join-Path $PSScriptRoot "..\src\FingVibe.App\Tools\NetworkHealthPage.xaml"))
$diagramCard = $diagramDocument.SelectSingleNode("//*[local-name()='Border'][.//*[@*[local-name()='Name']='DiagramScroll']]")
$healthCard = $diagramDocument.SelectSingleNode("//*[local-name()='Border'][@*[local-name()='Name']='CurrentHealthCard']")
foreach ($name in @("RunButton", "CancelRunButton", "RunProgress", "ProgressText", "HealthStateText")) {
    if (-not $healthCard -or -not $healthCard.SelectSingleNode(".//*[@*[local-name()='Name']='$name']")) {
        throw "Run controls, progress and current health must belong to the top current-health card: $name."
    }
}
$cards = @($diagramDocument.SelectNodes("//*[local-name()='ScrollViewer']/*[local-name()='StackPanel']/*[local-name()='Border']"))
if ($cards.Count -lt 2 -or $cards[0] -ne $healthCard -or $cards[1] -ne $diagramCard) {
    throw "Current health must be the first card, directly followed by the manual diagnostic path and status."
}
$connectors = @($diagramDocument.SelectNodes("//*[local-name()='Canvas']/*[local-name()='Path']"))
if ($connectors.Count -ne 8 -or @($connectors | Where-Object { $_.GetAttribute("Data") -match '\bQ' }).Count -ne 2 -or
    $diagramDocument.SelectNodes("//*[local-name()='Polyline']").Count -ne 0) {
    throw "The provider and compact LAN-peer branches must use curved elbows, not square polyline corners."
}
foreach ($name in @("PcRouterConnector", "RouterHopConnector", "HopInternetConnector", "InternetGoogleConnector")) {
    $connector = $diagramDocument.SelectSingleNode("//*[@*[local-name()='Name']='$name']")
    if (-not $connector -or $connector.GetAttribute("Data") -notmatch '^M\d+,198 H\d+$') {
        throw "Main-path connector $name must be one straight horizontal segment on the shared device baseline."
    }
}
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScreenshot.ps1")
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewAppearance.ps1")
if (-not (Get-Command Wait-UiRegressionState -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot "UiRegression\Helpers.ps1")
}
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class NetworkHealthReviewKeyboard
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
$previousPeer = $env:FINGVIBE_UI_REVIEW_PEER
$peerDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "FingVibe-peer-review-$([Guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $peerDirectory
$peerPath = Join-Path $peerDirectory "peer.json"
@{ Address = $null; State = 4; Latency = $null } | ConvertTo-Json | Set-Content -LiteralPath $peerPath
$env:FINGVIBE_UI_REVIEW_PEER = $peerPath
$env:FINGVIBE_UI_REVIEW = "1"
$process = $null
$peerPhase = $null
$peerPhasePassed = $false

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
    throw "Missing Network health control: $Name."
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
    $scroll = Scroll-Control "NetworkHealthScroll"
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

function Start-ReviewProcess {
    $script:process = Start-Process -FilePath $AppPath -PassThru
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 200
        $process.Refresh()
        if ($process.HasExited) { throw "App exited with code $($process.ExitCode)." }
    } while ($process.MainWindowHandle -eq 0 -and [DateTime]::UtcNow -lt $deadline)
    if ($process.MainWindowHandle -eq 0) { throw "App did not open a window." }
    [NetworkHealthReviewKeyboard]::AllowForeground()
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
}

function Stop-ReviewProcess {
    if ($null -ne $process -and -not $process.HasExited) {
        $null = $process.CloseMainWindow()
        if (-not $process.WaitForExit(5000)) { Stop-Process -Id $process.Id }
    }
    $script:process = $null
}

try {
    Start-ReviewProcess
    Select-Page Tools
    Invoke-Control "Network health"
    foreach ($heading in @("Monitoring off", "Manual diagnostics", "Connection and checks", "Network path and status", "Detailed checkpoint diagnostics", "Traceroute")) {
        $null = Find-Control $heading ([System.Windows.Automation.ControlType]::Text)
    }
    $null = Find-Control "Background health checks are not running, so there is no current health result. This is not a healthy state." ([System.Windows.Automation.ControlType]::Text)
    $null = Find-Control "Back to Tools" ([System.Windows.Automation.ControlType]::Button)
    $run = Find-Control "Run network diagnostics" ([System.Windows.Automation.ControlType]::Button)
    $null = Wait-UiRegressionState -Description "Run diagnostics keyboard focus on open" -Condition { $run.Current.HasKeyboardFocus }
    $wan = Find-Control "Router WAN IPv4 address" ([System.Windows.Automation.ControlType]::Edit)
    $value = $wan.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
    $value.SetValue("bad-address")
    $null = Find-Control "WAN input/settings error: Enter an IPv4 address as four decimal octets (for example, 203.0.113.10), or leave it blank. The previously saved valid value was not replaced." ([System.Windows.Automation.ControlType]::Text)
    $value.SetValue("203.0.113.10")
    $value.SetValue("")
    $scroll = Scroll-Control "NetworkHealthScroll"
    Show-Controls @("Run network diagnostics")
    Invoke-Control "Run network diagnostics"
    $null = Find-Control "UI-review mode does not send diagnostic probes." ([System.Windows.Automation.ControlType]::Text)
    if ($script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "NetworkHealthScroll")).Current.ItemStatus -ne "Idle") {
        throw "The inactive diagnostic surface must publish an observable Idle state."
    }
    if ((Find-Control "Cancel network diagnostics" ([System.Windows.Automation.ControlType]::Button)).Current.IsEnabled) {
        throw "UI review incorrectly started diagnostic network activity."
    }
    if ($ScreenshotDirectory) {
        $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
        Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "network-health-ready.png")
    }
    if (-not $scroll.Current.VerticallyScrollable) { throw "Network health page must scroll at ordinary window sizes." }
    $scroll.SetScrollPercent(-1, 0)
    Start-Sleep -Milliseconds 200
    $state = Find-Control "Monitoring off" ([System.Windows.Automation.ControlType]::Text)
    $pathHeading = Find-Control "Network path and status" ([System.Windows.Automation.ControlType]::Text)
    if ($run.Current.IsOffscreen -or $state.Current.IsOffscreen -or
        $run.Current.BoundingRectangle.Bottom -ge $pathHeading.Current.BoundingRectangle.Top -or
        $state.Current.BoundingRectangle.Bottom -ge $pathHeading.Current.BoundingRectangle.Top) {
        throw "Current health and Run diagnostics must be visible at the top, above the manual diagnostic path."
    }
    Show-Controls @("Network path and status", "Ready / not tested")
    $null = Find-Control "LAN peers" ([System.Windows.Automation.ControlType]::Text)
    $peerHeading = Find-Control "Selected peer" ([System.Windows.Automation.ControlType]::Text)
    $peerBounds = (Find-Address LanPeer).Current.BoundingRectangle
    $gatewayBounds = (Find-Address Gateway).Current.BoundingRectangle
    $wanBounds = (Find-Address RouterWan).Current.BoundingRectangle
    if ($peerHeading.Current.BoundingRectangle.Bottom -ge $peerBounds.Top -or
        $peerBounds.Bottom -ge $gatewayBounds.Top -or
        [Math]::Abs(($peerBounds.Left - 15) - ($gatewayBounds.Right + $wanBounds.Left) / 2) -gt 2) {
        throw "The selected peer checkpoint must be below its icon/title and directly above the router, not on the decorative branch."
    }
    if ($ScreenshotDirectory) {
        Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "network-health-diagram.png")
        $bitmap = [System.Drawing.Bitmap]::new((Join-Path $ScreenshotDirectory "network-health-diagram.png"))
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
        LanPeer = "Not supplied"
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
    $scroll.SetScrollPercent(-1, 0)
    Start-Sleep -Milliseconds 300
    $narrowWindow = Get-UiReviewWindowBounds $process.MainWindowHandle
    $narrowRun = (Find-Control "Run network diagnostics" ([System.Windows.Automation.ControlType]::Button)).Current
    if ($narrowRun.IsOffscreen -or $narrowRun.BoundingRectangle.Right -gt $narrowWindow.X + $narrowWindow.Width) {
        throw "Run diagnostics must stay fully reachable in a narrow window."
    }
    $null = [UiReviewNativeWindow]::SetWindowPos(
        $process.MainWindowHandle, [IntPtr]::Zero, $bounds.X, $bounds.Y, $bounds.Width, $bounds.Height, 0x0044)
    Show-Controls @("Selected peer")
    $peerPhase = Start-UiRegressionPhase -Name "Network health selected-peer states and accessibility"
    foreach ($state in @(2, 3, 4)) {
        $address = if ($state -eq 4) { $null } else { "192.0.2.42" }
        $latency = if ($state -eq 2) { 3 } else { $null }
        @{ Address = $address; State = $state; Latency = $latency } |
            ConvertTo-Json | Set-Content -LiteralPath $peerPath
        Invoke-Control "Run network diagnostics"
        $expected = switch ($state) {
            2 { "Selected LAN peer: 192.0.2.42; Responded - 3 ms" }
            3 { "Selected LAN peer: 192.0.2.42; Unanswered" }
            4 { "Selected LAN peer: Not supplied; Unavailable" }
        }
        $null = Find-Control $expected ([System.Windows.Automation.ControlType]::Text)
        if ((Find-Address LanPeer).Current.Name -ne $(if ($address) { $address } else { "Not supplied" })) {
            throw "The peer must show only its selected IPv4 address or explicit unavailability."
        }
        $peerDetail = @($script:root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Text)) |
            Where-Object { $_.Current.Name.StartsWith("Selected LAN peer - ") })
        if ($peerDetail.Count -ne 1 -or
            ($state -eq 4 -and $peerDetail[0].Current.Name -notlike "*Scan the selected LAN first*") -or
            ($address -and $peerDetail[0].Current.Name -notlike "*$address*")) {
            throw "Detailed diagnostics must include the same peer or unavailable scan-first guidance."
        }
        if ($ScreenshotDirectory -and $state -ne 4) {
            Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "network-health-peer-$state.png")
        }
    }
    $scroll.SetScrollPercent(-1, 0)
    Start-Sleep -Milliseconds 400
    Invoke-Control "Back to Tools"
    Invoke-Control "Network health"
    if ((Find-Control "Router WAN IPv4 address" ([System.Windows.Automation.ControlType]::Edit)).
        GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -ne "") {
        throw "UI-review mode reused an unsaved WAN value."
    }
    Select-Page Overview
    Select-Page Tools
    $null = Find-Control "Network health" ([System.Windows.Automation.ControlType]::Button)
    Invoke-Control "Speed test"
    $null = Find-Control "Start Cloudflare speed test" ([System.Windows.Automation.ControlType]::Button)
    Select-Page Network
    $summaryState = (Find-Control "Monitoring off" ([System.Windows.Automation.ControlType]::Text)).Current.BoundingRectangle
    $publicLabel = (Find-Control "Public IP address" ([System.Windows.Automation.ControlType]::Text)).Current.BoundingRectangle
    $sizeLabel = (Find-Control "Network size" ([System.Windows.Automation.ControlType]::Text)).Current.BoundingRectangle
    $openHealth = (Find-Control "Open network health" ([System.Windows.Automation.ControlType]::Button)).Current.BoundingRectangle
    if ($summaryState.Top -le $publicLabel.Bottom -or $summaryState.Bottom -ge $sizeLabel.Top -or $openHealth.Bottom -ge $sizeLabel.Top) {
        throw "The Network health summary must be the second Network section, after identity and before network size."
    }
    Invoke-Control "Open network health"
    $summaryRun = Find-Control "Run network diagnostics" ([System.Windows.Automation.ControlType]::Button)
    $null = Wait-UiRegressionState -Description "Network summary opens Network health with keyboard focus" -Condition { $summaryRun.Current.HasKeyboardFocus }
    if (-not (Find-Control "Tools" ([System.Windows.Automation.ControlType]::ListItem)).
        GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected) {
        throw "Open network health must open the single Tools Network health destination."
    }
    Invoke-Control "Back to Tools"
    $null = Find-Control "Network health" ([System.Windows.Automation.ControlType]::Button)
    @{ Address = "192.0.2.42"; State = 2; Latency = 3 } |
        ConvertTo-Json | Set-Content -LiteralPath $peerPath
    foreach ($mode in @("Light", "Dark")) {
        Select-Page Settings
        Set-UiReviewAppearanceChoice -Root $script:root -Picker ModePicker -Choice $mode
        Select-Page Tools
        Invoke-Control "Network health"
        Show-Controls @("Selected peer")
        Invoke-Control "Run network diagnostics"
        $null = Find-Control "Selected LAN peer: 192.0.2.42; Responded - 3 ms" ([System.Windows.Automation.ControlType]::Text)
        if ($ScreenshotDirectory) {
            Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "network-health-peer-$mode.png")
        }
    }
    if ($env:GITHUB_ACTIONS -eq "true") {
        if (-not ("SidebarReviewKeyboard" -as [type])) {
            . (Join-Path $PSScriptRoot "UiRegression\Sidebar.Controls.Helpers.ps1")
        }
        $settings = [Windows.UI.ViewManagement.UISettings, Windows.UI.ViewManagement, ContentType = WindowsRuntime]::new()
        $normalPeerHeight = (Find-Address LanPeer).Current.BoundingRectangle.Height
        $originalScale = $settings.TextScaleFactor
        $contrast = [SidebarReviewKeyboard]::GetHighContrastFlags()
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Software\Microsoft\Accessibility')
        $originalValue = $key.GetValue('TextScaleFactor', $null)
        $originalKind = if ($null -ne $originalValue) { $key.GetValueKind('TextScaleFactor') } else { $null }
        $failed = $true
        try {
            Stop-ReviewProcess
            [SidebarReviewKeyboard]::SetHighContrastFlags($contrast -bor 1)
            $key.SetValue('TextScaleFactor', 200, [Microsoft.Win32.RegistryValueKind]::DWord)
            [SidebarReviewKeyboard]::NotifyTextScaleChanged()
            $null = Wait-UiRegressionState -Description "200 percent Network health text" -Condition {
                [Math]::Abs($settings.TextScaleFactor - 2) -lt 0.01
            }
            Start-ReviewProcess
            Select-Page Tools
            Invoke-Control "Network health"
            $null = Find-Control "Monitoring off" ([System.Windows.Automation.ControlType]::Text)
            Show-Controls @("Selected peer")
            Invoke-Control "Run network diagnostics"
            $null = Find-Control "Selected LAN peer: 192.0.2.42; Responded - 3 ms" ([System.Windows.Automation.ControlType]::Text)
            $scaled = (Find-Address LanPeer).Current.BoundingRectangle
            $gateway = (Find-Address Gateway).Current.BoundingRectangle
            if ($scaled.Height -lt $normalPeerHeight * 1.6 -or $scaled.Bottom -ge $gateway.Top) {
                throw "The selected peer must honor enlarged text without overlapping the router."
            }
            $window = Get-UiReviewWindowBounds $process.MainWindowHandle
            $null = [UiReviewNativeWindow]::SetWindowPos(
                $process.MainWindowHandle, [IntPtr]::Zero, $window.X, $window.Y, 640, 720, 0x0044)
            Start-Sleep -Milliseconds 400
            $diagramScroll = Scroll-Control "DiagramScroll"
            $diagramScroll.SetScrollPercent(35, -1)
            Show-Controls @("Selected peer", "Selected LAN peer: 192.0.2.42; Responded - 3 ms")
            $viewport = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "DiagramScroll"))
            if (-not (Test-UiRegressionElementWithin -Element (Find-Address LanPeer) -Viewport $viewport -Window $script:root)) {
                throw "The enlarged peer address must be fully reachable in the narrow diagram viewport."
            }
            if ($ScreenshotDirectory) {
                Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "network-health-peer-text-200-high-contrast.png")
            }
            $failed = $false
        }
        catch {
            $primary = $_
            if ($ScreenshotDirectory -and $process -and -not $process.HasExited) {
                try {
                    Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "network-health-peer-accessibility-failure.png")
                }
                catch { Write-Warning "Peer accessibility failure screenshot also failed: $_" }
            }
            throw $primary
        }
        finally {
            Invoke-UiRegressionCleanup -PrimaryFailed $failed -Steps @(
                { Stop-ReviewProcess },
                {
                    if ($null -eq $originalValue) { $key.DeleteValue('TextScaleFactor', $false) }
                    else { $key.SetValue('TextScaleFactor', $originalValue, $originalKind) }
                    [SidebarReviewKeyboard]::NotifyTextScaleChanged()
                    [SidebarReviewKeyboard]::SetHighContrastFlags($contrast)
                    $null = Wait-UiRegressionState -Description "restored Network health text scale" -Condition {
                        [Math]::Abs($settings.TextScaleFactor - $originalScale) -lt 0.01
                    }
                },
                { $key.Dispose() })
        }
    }
    $peerPhasePassed = $true
    Write-Host "Network health current state, checkpoints, peer outcomes/themes/accessibility, WAN validation, privacy, scrolling, Network summary/Tools navigation, and speed-test entry passed."
}
catch {
    if ($ScreenshotDirectory -and $process -and -not $process.HasExited -and
        [UiReviewNativeWindow]::GetForegroundWindow() -eq $process.MainWindowHandle) {
        $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
        Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "network-health-failure.png")
    }
    throw
}
finally {
    Stop-ReviewProcess
    if ($peerPhase -and $ScreenshotDirectory) {
        Complete-UiRegressionPhase -Phase $peerPhase -Directory $ScreenshotDirectory -Succeeded $peerPhasePassed
    }
    $env:FINGVIBE_UI_REVIEW = $previousReview
    $env:FINGVIBE_UI_REVIEW_PEER = $previousPeer
    Remove-Item -LiteralPath $peerPath
    Remove-Item -LiteralPath $peerDirectory
}
