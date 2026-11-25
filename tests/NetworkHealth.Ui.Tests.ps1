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
$serviceStatusCard = $diagramDocument.SelectSingleNode("//*[local-name()='Border'][@*[local-name()='Name']='ServiceStatusEntryCard']")
$incidentCard = $diagramDocument.SelectSingleNode("//*[local-name()='Border'][@*[local-name()='Name']='IncidentHistoryCard']")
foreach ($name in @("RunButton", "CancelRunButton", "RunProgress", "ProgressText", "HealthStateText")) {
    if (-not $healthCard -or -not $healthCard.SelectSingleNode(".//*[@*[local-name()='Name']='$name']")) {
        throw "Run controls, progress and current health must belong to the top current-health card: $name."
    }
}
$cards = @($diagramDocument.SelectNodes("//*[local-name()='ScrollViewer']/*[local-name()='StackPanel']/*[local-name()='Border']"))
if ($cards.Count -lt 4 -or $cards[0] -ne $healthCard -or $cards[1] -ne $serviceStatusCard -or $cards[2] -ne $incidentCard -or
    $cards[3] -ne $diagramCard) {
    throw "Current health must be the first card, followed by the Service status entry, saved incident history and then the manual diagnostic path and status."
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

function Invoke-Control([string] $Name,
    [System.Windows.Automation.ControlType] $Type = [System.Windows.Automation.ControlType]::Button) {
    (Find-Control $Name $Type).
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

function Find-ById([string] $Id) {
    $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $Id)
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    do {
        $element = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if ($element) { return $element }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Missing element with automation ID: $Id."
}

function Show-IncidentEvidenceLayout {
    # Containers such as the evidence StackPanel report no UI Automation bounds, so compare rendered leaves: the first
    # incident item and the evidence outcome line, scrolled into the Network health viewport together.
    $targets = {
        foreach ($id in @("NetworkIncidentStatus0", "NetworkIncidentEvidenceOutcome")) {
            $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id))
        }
    }
    $null = Show-UiRegressionScrollTargets -Description "Incident list and saved evidence" -GetWindow { $script:root } `
        -GetViewport {
            $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, "NetworkHealthScroll"))
        } -GetTargets $targets
    $item, $outcome = @(& $targets)
    $itemBounds = $item.Current.BoundingRectangle
    $outcomeBounds = $outcome.Current.BoundingRectangle
    if ($itemBounds.IsEmpty -or $outcomeBounds.IsEmpty) { throw "The incident list and saved evidence must both be rendered." }
    return $itemBounds, $outcomeBounds
}

function Assert-MonitorIndicatorContained {
    $window = Get-UiReviewWindowBounds $process.MainWindowHandle
    $indicator = (Find-ById "NetworkMonitorIndicator").Current
    $scan = (Find-ById "ScanButton").Current.BoundingRectangle
    $bounds = $indicator.BoundingRectangle
    if ($indicator.IsOffscreen -or $bounds.Left -lt $window.X -or $bounds.Right -gt $window.X + $window.Width -or
        ($bounds.Right -gt $scan.Left -and $bounds.Bottom -gt $scan.Top)) {
        throw "The monitoring dot must stay inside the title bar beside, not over, the scan action."
    }
}

function Find-Named([string] $Name) {
    $condition = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $Name)
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    do {
        $element = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if ($element) { return $element }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Missing Service status element: $Name."
}

function Get-ServiceStatusEntryIds {
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)
    @($script:root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $condition) |
        ForEach-Object { $_.Current.AutomationId } | Where-Object { $_ -like "ServiceStatusService-*" } |
        ForEach-Object { $_.Substring("ServiceStatusService-".Length) })
}

function Select-ServiceStatusFilter([string] $Name, [int] $Expected, [string] $Present, [string] $Absent) {
    $item = Find-Named $Name
    $pattern = $null
    if ($item.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref]$pattern)) { $pattern.Select() }
    elseif ($item.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)) { $pattern.Invoke() }
    else { throw "Service status filter '$Name' supports neither selection nor invocation." }
    $null = Wait-UiRegressionState -Description "$Name filter shows $Expected entries" -Condition {
        $ids = Get-ServiceStatusEntryIds
        $ids.Count -eq $Expected -and $Present -in $ids -and $Absent -notin $ids
    }
}

function Test-ServiceStatusPage([string] $ScreenshotName) {
    $scroll = Scroll-Control "NetworkHealthScroll"
    $scroll.SetScrollPercent(-1, 0)
    Start-Sleep -Milliseconds 200
    $open = Find-Control "Open service status" ([System.Windows.Automation.ControlType]::Hyperlink)
    $run = (Find-Control "Run network diagnostics" ([System.Windows.Automation.ControlType]::Button)).Current.BoundingRectangle
    $manual = (Find-Control "Manual diagnostics" ([System.Windows.Automation.ControlType]::Text)).Current.BoundingRectangle
    if ($open.Current.IsOffscreen -or $open.Current.BoundingRectangle.Top -le $run.Bottom -or
        $open.Current.BoundingRectangle.Bottom -ge $manual.Top) {
        throw "The Service status entry must be visible below current health and above Manual diagnostics."
    }
    $null = Find-Control "Provider reports are separate from this network's measured health." ([System.Windows.Automation.ControlType]::Text)
    Invoke-Control "Open service status" ([System.Windows.Automation.ControlType]::Hyperlink)
    $refresh = Find-Control "Refresh provider reports" ([System.Windows.Automation.ControlType]::Button)
    $null = Wait-UiRegressionState -Description "Refresh reports keyboard focus on open" -Condition { $refresh.Current.HasKeyboardFocus }
    $null = Find-Control "Back to Network health" ([System.Windows.Automation.ControlType]::Button)
    $null = Wait-UiRegressionState -Description "controlled provider reports" -Condition { (Get-ServiceStatusEntryIds).Count -eq 12 }
    $null = Find-Control "1 reported issue | 3 feeds without current data | 4 entries not monitored" ([System.Windows.Automation.ControlType]::Text)
    foreach ($headline in @("No incidents reported", "Degraded service", "Source pending", "Official page only",
        "Feed unavailable", "Report outdated", "Feed unreadable")) {
        $null = Find-Control $headline ([System.Windows.Automation.ControlType]::Text)
    }
    foreach ($link in @("View incident for Google Google Cloud (opens in browser)",
        "Open storefront for Amazon Amazon.de shopping (opens in browser)", "Status page for Apple iCloud (opens in browser)")) {
        $null = Find-Control $link ([System.Windows.Automation.ControlType]::Hyperlink)
    }
    if ($ScreenshotDirectory) {
        Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "$ScreenshotName.png")
    }
    $window = Get-UiReviewWindowBounds $process.MainWindowHandle
    $refreshBounds = $refresh.Current.BoundingRectangle
    if ($refresh.Current.IsOffscreen -or $refreshBounds.Right -gt $window.X + $window.Width) {
        throw "Refresh reports must stay fully reachable at this window size."
    }
}

function Test-ServiceStatusTextContrast([string] $Mode) {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) "fingvibe-service-status-contrast-$([Guid]::NewGuid().ToString('N')).png"
    Save-UiReviewWindowScreenshot $process.MainWindowHandle $path
    $bitmap = [System.Drawing.Bitmap]::new($path)
    try {
        $window = Get-UiReviewWindowBounds $process.MainWindowHandle
        foreach ($id in @("ServiceStatusReport-microsoft-outlook", "ServiceStatusDetail-microsoft-outlook", "ServiceStatusTimestamp-microsoft-azure")) {
            $element = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id))
            if (-not $element -or $element.Current.IsOffscreen) { throw "$Mode Service status text is not visible: $id." }
            $bounds = $element.Current.BoundingRectangle
            $left = [Math]::Max(0, [int]($bounds.Left - $window.Left)); $top = [Math]::Max(0, [int]($bounds.Top - $window.Top))
            $right = [Math]::Min($bitmap.Width - 1, [int]($bounds.Right - $window.Left)); $bottom = [Math]::Min($bitmap.Height - 1, [int]($bounds.Bottom - $window.Top))
            $darkest = 1.0; $lightest = 0.0
            for ($y = $top; $y -le $bottom; $y++) {
                for ($x = $left; $x -le $right; $x++) {
                    $pixel = $bitmap.GetPixel($x, $y)
                    $channels = foreach ($channel in @($pixel.R, $pixel.G, $pixel.B)) {
                        $value = $channel / 255.0
                        if ($value -le 0.04045) { $value / 12.92 } else { [Math]::Pow(($value + 0.055) / 1.055, 2.4) }
                    }
                    $luminance = 0.2126 * $channels[0] + 0.7152 * $channels[1] + 0.0722 * $channels[2]
                    $darkest = [Math]::Min($darkest, $luminance); $lightest = [Math]::Max($lightest, $luminance)
                }
            }
            $ratio = ($lightest + 0.05) / ($darkest + 0.05)
            if ($ratio -lt 3) { throw "$Mode Service status text $id renders at contrast $([Math]::Round($ratio, 2)):1, below 3:1." }
        }
    }
    finally {
        $bitmap.Dispose()
        Remove-Item -LiteralPath $path
    }
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
    if ((Find-ById "NetworkMonitorIndicator").Current.Name -notlike "Network monitoring: Monitoring off. No raw check has completed yet.*") {
        throw "The header dot must announce Monitoring off without implying health."
    }
    Assert-MonitorIndicatorContained
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
    Test-ServiceStatusPage "service-status"
    Select-ServiceStatusFilter "Consumer services" 6 "microsoft-outlook" "microsoft-azure"
    Select-ServiceStatusFilter "Infrastructure services" 6 "github-actions" "github-website"
    Select-ServiceStatusFilter "All services" 12 "apple-icloud" "none"
    $refresh = Find-Control "Refresh provider reports" ([System.Windows.Automation.ControlType]::Button)
    $refresh.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
    $retrieval = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::AutomationIdProperty, "ServiceStatusRetrieval"))
    $null = Wait-UiRegressionState -Description "Refresh reports completes with a retrieval time" -Condition {
        $refresh.Current.IsEnabled -and $retrieval.Current.Name -like "Feed refresh: today, *" -and (Get-ServiceStatusEntryIds).Count -eq 12
    }
    $bounds = Get-UiReviewWindowBounds $process.MainWindowHandle
    $null = [UiReviewNativeWindow]::SetWindowPos(
        $process.MainWindowHandle, [IntPtr]::Zero, $bounds.X, $bounds.Y, 640, 600, 0x0044)
    $null = Find-Control "Microsoft - Outlook.com" ([System.Windows.Automation.ControlType]::Text)
    $narrowWindow = Get-UiReviewWindowBounds $process.MainWindowHandle
    foreach ($id in @("ServiceStatusService-microsoft-outlook", "ServiceStatusLink-microsoft-outlook")) {
        $element = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id))
        if (-not $element -or $element.Current.BoundingRectangle.Right -gt $narrowWindow.X + $narrowWindow.Width) {
            throw "Narrow Service status entries must stack within the window: $id."
        }
    }
    if ($ScreenshotDirectory) {
        Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "service-status-narrow.png")
    }
    $null = [UiReviewNativeWindow]::SetWindowPos(
        $process.MainWindowHandle, [IntPtr]::Zero, $bounds.X, $bounds.Y, $bounds.Width, $bounds.Height, 0x0044)
    Start-Sleep -Milliseconds 300
    Invoke-Control "Back to Network health"
    $openServiceStatus = Find-Control "Open service status" ([System.Windows.Automation.ControlType]::Hyperlink)
    $null = Wait-UiRegressionState -Description "Back to Network health restores Service status focus" -Condition {
        $openServiceStatus.Current.HasKeyboardFocus
    }
    if ((Find-Control "Cancel network diagnostics" ([System.Windows.Automation.ControlType]::Button)).Current.IsEnabled) {
        throw "Service status interactions must not start local diagnostics."
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
    $openHealth = (Find-Control "Open network health" ([System.Windows.Automation.ControlType]::Hyperlink)).Current.BoundingRectangle
    if ($summaryState.Top -le $publicLabel.Bottom -or $summaryState.Bottom -ge $sizeLabel.Top -or $openHealth.Bottom -ge $sizeLabel.Top) {
        throw "The Network health summary must be the second Network section, after identity and before network size."
    }
    Invoke-Control "Open network health" ([System.Windows.Automation.ControlType]::Hyperlink)
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
        (Scroll-Control "NetworkHealthScroll").SetScrollPercent(-1, 0)
        Invoke-Control "Open service status" ([System.Windows.Automation.ControlType]::Hyperlink)
        $null = Wait-UiRegressionState -Description "$mode controlled provider reports" -Condition { (Get-ServiceStatusEntryIds).Count -eq 12 }
        Test-ServiceStatusTextContrast $mode
        if ($ScreenshotDirectory) {
            Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "service-status-$mode.png")
        }
        Invoke-Control "Back to Network health"
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
            Assert-MonitorIndicatorContained
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
            (Scroll-Control "NetworkHealthScroll").SetScrollPercent(-1, 0)
            Invoke-Control "Open service status" ([System.Windows.Automation.ControlType]::Hyperlink)
            $null = Find-Control "Refresh provider reports" ([System.Windows.Automation.ControlType]::Button)
            foreach ($text in @("Microsoft - Outlook.com", "Degraded service", "Feed unavailable")) {
                $null = Find-Control $text ([System.Windows.Automation.ControlType]::Text)
            }
            if ($ScreenshotDirectory) {
                Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "service-status-text-200-high-contrast.png")
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
    $monitorPath = Join-Path $peerDirectory "network-monitor.json"
    '{"isEnabled":true}' | Set-Content -LiteralPath $monitorPath
    $monitorEnvironment = @{}
    foreach ($name in @("FINGVIBE_UI_REVIEW_NETWORK_MONITOR", "FINGVIBE_UI_REVIEW_NETWORK_MONITOR_TIME_SCALE", "FINGVIBE_UI_REVIEW_NETWORK_MONITOR_FIXTURE")) {
        $monitorEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    try {
        # A 20x monitor clock checks every 3 seconds; the fixture delivers synthetic raw observations without probes.
        $env:FINGVIBE_UI_REVIEW_NETWORK_MONITOR = $monitorPath
        $env:FINGVIBE_UI_REVIEW_NETWORK_MONITOR_TIME_SCALE = "20"
        $env:FINGVIBE_UI_REVIEW_NETWORK_MONITOR_FIXTURE = "1"
        Stop-ReviewProcess
        Start-ReviewProcess
        $indicator = Find-ById "NetworkMonitorIndicator"
        $null = Wait-UiRegressionState -Description "monitoring dot marks a new check" -Condition {
            $indicator.Current.ItemStatus -like "Check started*"
        }
        $null = Wait-UiRegressionState -Description "monitoring dot announces the learning or healthy verdict" -Condition {
            $indicator.Current.Name -like "Network monitoring: Learning - no problems found. Last raw check: today *" -or
                $indicator.Current.Name -like "Network monitoring: Healthy. Last raw check: today *"
        }
        Select-Page Network
        $null = Wait-UiRegressionState -Description "Network summary shows the latest raw observations" -Condition {
            $result = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, "NetworkSummaryRawResult5"))
            $result -and $result.Current.Name -eq "Google DNS: Error: Timed out after 2 seconds"
        }
        $null = Find-Control "Gateway 192.0.2.1: 5/5 ping responses, 2-4 ms" ([System.Windows.Automation.ControlType]::Text)
        if ((Find-ById "NetworkHealthSummaryDetail").Current.Name -notlike "No problems found*") {
            throw "The Network summary must explain the current verdict in text."
        }
        if ($ScreenshotDirectory) {
            Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "network-summary-monitoring.png")
        }
        $indicator.SetFocus()
        $null = Wait-UiRegressionState -Description "monitoring dot keyboard focus" -Condition { $indicator.Current.HasKeyboardFocus }
        $indicator.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        $null = Find-Control "Run network diagnostics" ([System.Windows.Automation.ControlType]::Button)
        if (-not (Find-Control "Tools" ([System.Windows.Automation.ControlType]::ListItem)).
            GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected) {
            throw "The monitoring dot must open the Tools Network health page."
        }
        $null = Find-Control "Latest raw observations" ([System.Windows.Automation.ControlType]::Text)
        $null = Wait-UiRegressionState -Description "Network health shows raw ping and DNS observations" -Condition {
            $result = $script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, "NetworkHealthRawResult2"))
            $result -and $result.Current.Name -eq "Google 8.8.8.8: 4/5 ping responses, 15-17 ms"
        }
        if ((Find-ById "NetworkHealthState").Current.Name -notin @("Learning - no problems found", "Healthy")) {
            throw "Network health must show the learning or healthy verdict for the healthy fixture."
        }
        if ((Find-ById "NetworkIncidentEmpty").Current.Name -notlike "No confirmed incidents are saved.*") {
            throw "Network health must state that no incidents are saved before a problem is confirmed."
        }
        if ($ScreenshotDirectory) {
            Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "network-health-monitoring.png")
        }
        $bounds = Get-UiReviewWindowBounds $process.MainWindowHandle
        $null = [UiReviewNativeWindow]::SetWindowPos($process.MainWindowHandle, [IntPtr]::Zero, $bounds.X, $bounds.Y, 640, 600, 0x0044)
        Start-Sleep -Milliseconds 400
        Assert-MonitorIndicatorContained

        # Fixture latencies above the absolute limits: the second consecutive suspicious check (30 s cadence, 1.5 s
        # at 20x) confirms a problem on the dot, Network health and the Network summary.
        $env:FINGVIBE_UI_REVIEW_NETWORK_MONITOR_FIXTURE = "problem"
        Stop-ReviewProcess
        Start-ReviewProcess
        $indicator = Find-ById "NetworkMonitorIndicator"
        $null = Wait-UiRegressionState -Description "monitoring dot announces a possible problem" -TimeoutMilliseconds 15000 -Condition {
            $indicator.Current.Name -like "Network monitoring: Possible problem - verifying.*" -or
                $indicator.Current.Name -like "Network monitoring: Problem confirmed.*"
        }
        $null = Wait-UiRegressionState -Description "monitoring dot announces the confirmed problem" -TimeoutMilliseconds 15000 -Condition {
            $indicator.Current.Name -like "Network monitoring: Problem confirmed. Last raw check: today *"
        }
        Select-Page Network
        $null = Wait-UiRegressionState -Description "Network summary shows the confirmed problem" -Condition {
            (Find-ById "NetworkHealthSummaryState").Current.Name -eq "Problem confirmed" -and
                (Find-ById "NetworkHealthSummaryDetail").Current.Name -like "*High latency: Cloudflare 1.1.1.1 215 ms median (limit 150 ms)*"
        }
        # The confirmed problem is recorded once as an ongoing incident, labelled as history rather than current health.
        $null = Wait-UiRegressionState -Description "Network summary shows the ongoing incident from saved history" -Condition {
            (Find-ById "NetworkHealthSummaryIncident").Current.Name -like "Incident history: ongoing incident since today *High latency: Cloudflare 1.1.1.1*"
        }
        $indicator.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        $null = Wait-UiRegressionState -Description "Network health explains the confirmed problem and recovery" -Condition {
            (Find-ById "NetworkHealthState").Current.Name -eq "Problem confirmed" -and
                (Find-ById "NetworkHealthStateDetail").Current.Name -like "*Recovery: 0 of 5 consecutive healthy checks*"
        }
        $null = Wait-UiRegressionState -Description "Network health lists the ongoing incident newest first" -Condition {
            (Find-ById "NetworkIncidentStatus0").Current.Name -like "Ongoing incident. *High latency: Cloudflare 1.1.1.1*First observed today *confirmed today *Recovery: 0 of 5 consecutive healthy checks.*"
        }
        if ($script:root.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, "NetworkIncidentStatus1"))) {
            throw "Repeated suspicious checks must accumulate in one active incident, not create another."
        }
        $incidentBounds = (Find-ById "NetworkIncidentStatus0").Current.BoundingRectangle
        $windowBounds = Get-UiReviewWindowBounds $process.MainWindowHandle
        if (-not $incidentBounds.IsEmpty -and
            ($incidentBounds.Left -lt $windowBounds.X -or $incidentBounds.Right -gt $windowBounds.X + $windowBounds.Width)) {
            throw "Incident history text must wrap within the window instead of overflowing horizontally."
        }
        # The confirmed incident's single automatic deeper check (synthetic probes in UI review) is saved with it.
        $null = Wait-UiRegressionState -Description "the incident reports its saved deeper diagnostics" -Condition {
            (Find-ById "NetworkIncidentStatus0").Current.Name -like "*Deeper diagnostics: complete."
        }
        (Find-ById "NetworkIncidentStatus0").GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        $null = Wait-UiRegressionState -Description "selected incident shows its timestamped saved evidence" -Condition {
            (Find-ById "NetworkIncidentEvidenceOutcome").Current.Name -eq "Complete: every check finished within the 45-second limit." -and
                (Find-ById "NetworkIncidentEvidenceContext").Current.Name -like "Saved evidence from *, collected today *. This is history, not current status; viewing it sends no probes."
        }
        if ((Find-ById "NetworkIncidentEvidenceTrace").Current.Name -notlike "Traceroute toward 1.1.1.1: destination reached at hop 3.*" -or
            (Find-ById "NetworkIncidentEvidenceCheck0").Current.Name -notlike "Loopback: 127.0.0.1 | Responded | Synthetic UI-review evidence*") {
            throw "Saved evidence must list its checkpoints and traceroute."
        }
        if ((Find-ById "NetworkHealthState").Current.Name -ne "Problem confirmed") {
            throw "Viewing saved evidence must not replace the current health status."
        }
        $listBounds, $evidenceBounds = Show-IncidentEvidenceLayout
        if ($evidenceBounds.Left -lt $listBounds.Right) {
            throw "On a wide window, saved evidence must sit alongside the incident list."
        }
        $windowBounds = Get-UiReviewWindowBounds $process.MainWindowHandle
        if ($listBounds.Left -lt $windowBounds.X -or $evidenceBounds.Right -gt $windowBounds.X + $windowBounds.Width) {
            throw "Incident history and saved evidence must wrap within the window instead of overflowing horizontally."
        }
        if ($ScreenshotDirectory) {
            Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "network-health-problem.png")
        }
        $bounds = Get-UiReviewWindowBounds $process.MainWindowHandle
        $null = [UiReviewNativeWindow]::SetWindowPos($process.MainWindowHandle, [IntPtr]::Zero, $bounds.X, $bounds.Y, 640, 700, 0x0044)
        $null = Wait-UiRegressionState -Description "narrow saved evidence stacks below the incident list" -Condition {
            $list, $panel = Show-IncidentEvidenceLayout
            $panel.Top -ge $list.Bottom -and $panel.Height -ge $evidenceBounds.Height
        }
        if ((Find-ById "NetworkIncidentStatus0").GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected -ne $true) {
            throw "Narrowing the window must keep the selected incident and its evidence."
        }
        if ($ScreenshotDirectory) {
            Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "network-health-problem-narrow.png")
        }
    }
    finally {
        Stop-ReviewProcess
        foreach ($name in $monitorEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $monitorEnvironment[$name]) }
        Remove-Item -LiteralPath $monitorPath -ErrorAction SilentlyContinue
    }
    $peerPhasePassed = $true
    Write-Host "Network health current state, monitoring dot/learning and problem verdicts/raw observations/navigation/containment, Service status entry/states/filters/refresh/narrow/focus, checkpoints, peer outcomes/themes/accessibility, WAN validation, privacy, scrolling, Network summary/Tools navigation, and speed-test entry passed."
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
