param(
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $ScreenshotDirectory
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScreenshot.ps1")
Add-Type -TypeDefinition @"
using System;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
public sealed class AdditionalServicesFixture : IDisposable
{
    private readonly TcpListener tcp = new TcpListener(IPAddress.Loopback, 1883);
    private UdpClient dns;
    private UdpClient ntp;
    private Task[] workers = new Task[0];
    private Task tcpWorker = Task.CompletedTask;
    private volatile bool stopping;
    public volatile int DnsMode;
    public volatile int NtpMode;
    public int DnsRequests;
    public int NtpRequests;
    public void Start()
    {
        string endpoint = "53/UDP";
        try
        {
            dns = new UdpClient(new IPEndPoint(IPAddress.Loopback, 53));
            endpoint = "123/UDP";
            ntp = new UdpClient(new IPEndPoint(IPAddress.Loopback, 123));
            workers = new[] { Reply(dns, true), Reply(ntp, false) };
        }
        catch (SocketException exception)
        {
            Dispose();
            throw new InvalidOperationException("Cannot bind synthetic loopback " + endpoint + ": " + exception.Message, exception);
        }
    }
    public void StartTcp()
    {
        tcp.Start();
        tcpWorker = Accept();
    }
    private async Task Accept()
    {
        try { while (!stopping) { using (await tcp.AcceptTcpClientAsync()) {} } }
        catch (ObjectDisposedException) when (stopping) {}
        catch (SocketException) when (stopping) {}
    }
    private async Task Reply(UdpClient client, bool isDns)
    {
        try
        {
            while (!stopping)
            {
                var request = await client.ReceiveAsync();
                if (isDns) Interlocked.Increment(ref DnsRequests); else Interlocked.Increment(ref NtpRequests);
                int mode = isDns ? DnsMode : NtpMode;
                if (mode == 0) continue;
                byte[] reply;
                if (isDns)
                {
                    reply = request.Buffer;
                    reply[2] = 0x80;
                    reply[3] = 5;
                    if (mode == 2) reply[0] ^= 1;
                }
                else
                {
                    reply = new byte[48];
                    reply[0] = 0x24;
                    reply[1] = 2;
                    Array.Copy(request.Buffer, 40, reply, 24, 8);
                    Array.Copy(request.Buffer, 40, reply, 32, 8);
                    Array.Copy(request.Buffer, 40, reply, 40, 8);
                    if (mode == 2) reply[24] ^= 1;
                }
                await client.SendAsync(reply, reply.Length, request.RemoteEndPoint);
            }
        }
        catch (ObjectDisposedException) when (stopping) {}
        catch (SocketException) when (stopping) {}
    }
    public void Dispose()
    {
        stopping = true;
        tcp.Stop();
        if (dns != null) dns.Dispose();
        if (ntp != null) ntp.Dispose();
        if (!Task.WaitAll(workers, 5000)) throw new TimeoutException("Fixture workers failed to stop.");
        if (!tcpWorker.Wait(5000)) throw new TimeoutException("TCP fixture worker failed to stop.");
    }
}
"@

function Find-ServiceControl([string] $Value, [switch] $ByName, [switch] $Optional) {
    $property = if ($ByName) {
        [System.Windows.Automation.AutomationElement]::NameProperty
    } else { [System.Windows.Automation.AutomationElement]::AutomationIdProperty }
    $condition = [System.Windows.Automation.PropertyCondition]::new($property, $Value)
    $element = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
    if (-not $element -and -not $Optional) { throw "Missing service-scan control '$Value'." }
    return $element
}

function Wait-ServiceState([scriptblock] $Predicate, [string] $Description, [int] $Seconds = 10) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if (& $Predicate) { return }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out waiting for $Description."
}

function Invoke-ServiceControl([string] $Name) {
    (Find-ServiceControl $Name -ByName).GetCurrentPattern(
        [System.Windows.Automation.InvokePattern]::Pattern).Invoke()
}

function Select-ServicePage([string] $Name) {
    $condition = [System.Windows.Automation.AndCondition]::new(
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::NameProperty, $Name),
        [System.Windows.Automation.PropertyCondition]::new(
            [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
            [System.Windows.Automation.ControlType]::ListItem))
    Wait-ServiceState {
        $item = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
        if (-not $item) { return $false }
        $item.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        return $true
    } "navigation to $Name"
    Start-Sleep -Milliseconds 200
}

function Open-ServiceDetails {
    Select-ServicePage Devices
    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::ListItem)
    $row = (Find-ServiceControl ResultsList).FindFirst([System.Windows.Automation.TreeScope]::Children, $condition)
    if (-not $row) { throw "The loopback scan did not provide an online fixture device." }
    $row.SetFocus()
    [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
    Wait-ServiceState {
        $back = Find-ServiceControl "Back to devices" -ByName -Optional
        $back -and -not $back.Current.IsOffscreen
    } "device details"
    Show-ServiceScanSection
}

function Show-ServiceScanSection {
    $element = Find-ServiceControl DeviceDetailsScroll
    $scroll = $element.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    $center = [Math]::Clamp([int][Math]::Round($scroll.Current.VerticalScrollPercent), 0, 100)
    $positions = [System.Collections.Generic.List[int]]::new()
    $positions.Add($center)
    foreach ($distance in 1..100) {
        if ($center + $distance -le 100) { $positions.Add($center + $distance) }
        if ($center - $distance -ge 0) { $positions.Add($center - $distance) }
    }
    foreach ($percent in $positions) {
        $scroll.SetScrollPercent(-1, $percent)
        Start-Sleep -Milliseconds 50
        $area = $element.Current.BoundingRectangle
        $window = Get-UiReviewWindowBounds $process.MainWindowHandle
        $scale = [UiReviewNativeWindow]::GetDpiForWindow($process.MainWindowHandle) / 96.0
        $top = [Math]::Max($area.Top, $window.Top + 190 * $scale)
        $bottom = [Math]::Min($area.Bottom, $window.Bottom - 8 * $scale)
        $button = (Find-ServiceControl DevicePortScanButton).Current.BoundingRectangle
        $heading = (Find-ServiceControl "UDP observations (silence is not an open or closed port)" -ByName).Current.BoundingRectangle
        if ($button.Width -gt 0 -and $heading.Width -gt 0 -and
            $button.Top -ge $top + 8 * $scale -and $heading.Bottom -le $bottom - 110 * $scale) {
            return
        }
    }
    throw "The scan section could not fit the physical viewport: window=$window, scroll=$area, button=$button, observations=$heading."
}

function Save-ServiceEvidence([string] $Name, [switch] $DevicesList) {
    if (-not $DevicesList) { Show-ServiceScanSection }
    Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "$Name.png")
}

$previousReview = $env:FINGVIBE_UI_REVIEW
$previousSnapshot = $env:FINGVIBE_UI_REVIEW_SNAPSHOT
$snapshot = Join-Path ([System.IO.Path]::GetTempPath()) "fingvibe-services-$([Guid]::NewGuid().ToString('N')).json"
$process = $null
$fixture = $null
$restartTimeService = $false
try {
    $null = New-Item -ItemType Directory -Path $ScreenshotDirectory -Force
    $env:FINGVIBE_UI_REVIEW = "1"
    $env:FINGVIBE_UI_REVIEW_SNAPSHOT = $snapshot
    if ($env:GITHUB_ACTIONS -eq "true") {
        Get-NetUDPEndpoint | Where-Object LocalPort -In 53, 123 |
            Format-Table LocalAddress, LocalPort, OwningProcess
        if ((Get-Service W32Time).Status -eq "Running") {
            $restartTimeService = $true
            Stop-Service W32Time
        }
    }
    $fixture = [AdditionalServicesFixture]::new()
    $fixture.Start()
    $process = Start-Process -FilePath $AppPath -PassThru
    Wait-ServiceState { $process.Refresh(); $process.MainWindowHandle -ne 0 } "application window" 20
    Initialize-UiReviewWindow $process.MainWindowHandle
    $null = [UiReviewNativeWindow]::SetForegroundWindow($process.MainWindowHandle)
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
    Wait-ServiceState { (Find-ServiceControl "Scan LAN" -ByName -Optional).Current.IsEnabled } "scan readiness"
    Invoke-ServiceControl "Scan LAN"
    Wait-ServiceState { (Find-ServiceControl "Scan LAN" -ByName).Current.IsEnabled -and (Test-Path $snapshot) } "loopback scan"
    Open-ServiceDetails
    $udp = (Find-ServiceControl DeviceIncludeUdpCheckBox).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    if ($udp.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) { throw "UDP must start unchecked." }
    Save-ServiceEvidence "services-default"
    Invoke-ServiceControl "Scan additional ports"
    Wait-ServiceState { (Find-ServiceControl DeviceTcpScanStatus).Current.Name -like "TCP: complete*" } "TCP-only completion"
    if ($fixture.DnsRequests -ne 0 -or $fixture.NtpRequests -ne 0) { throw "Default scanning sent UDP requests." }
    if (Find-ServiceControl "1883/TCP - MQTT" -ByName -Optional) { throw "The TCP fixture unexpectedly responded before starting." }
    Wait-ServiceState { (Find-ServiceControl DevicePortScanButton).Current.Name -eq "Scan additional ports" } "usable TCP-only button"
    $fixture.StartTcp()
    $udp.Toggle()
    Invoke-ServiceControl "Scan additional ports"
    Wait-ServiceState { Find-ServiceControl "1883/TCP - MQTT" -ByName -Optional } "new TCP endpoint before UDP" 2
    if ((Find-ServiceControl DeviceUdpScanStatus).Current.Name -notlike "UDP: checking*") {
        throw "A newly completed TCP endpoint was not exposed while UDP was still pending."
    }
    Save-ServiceEvidence "services-tcp-results-udp-pending"
    if ((Find-ServiceControl DeviceUdpScanStatus).Current.Name -notlike "UDP: checking*") {
        throw "UDP finished before the TCP-before-UDP screenshot was captured."
    }
    Wait-ServiceState { (Find-ServiceControl DeviceUdpScanStatus).Current.Name -like "*0 responded, 2 inconclusive, 0 error*" } "inconclusive UDP"
    if ($fixture.DnsRequests -ne 1 -or $fixture.NtpRequests -ne 1) { throw "UDP must send only one request per service." }
    Save-ServiceEvidence "services-inconclusive"
    Wait-ServiceState { (Find-ServiceControl DevicePortScanButton).Current.Name -eq "Scan additional ports" } "scan cleanup"
    if ((Find-ServiceControl DeviceTcpScanStatus).Current.Name -notlike "TCP: complete*") { throw "TCP completion was not independently reported." }
    $fixture.DnsMode = 1
    $fixture.NtpMode = 1
    Invoke-ServiceControl "Scan additional ports"
    Wait-ServiceState { (Find-ServiceControl DeviceUdpScanStatus).Current.Name -like "*2 responded, 0 inconclusive, 0 error*" } "confirmed UDP"
    $null = Find-ServiceControl "53/UDP - DNS" -ByName
    $null = Find-ServiceControl "123/UDP - NTP" -ByName
    Save-ServiceEvidence "services-confirmed"
    Wait-ServiceState { (Find-ServiceControl DevicePortScanButton).Current.Name -eq "Scan additional ports" } "confirmed cleanup"
    $fixture.DnsMode = 2
    $fixture.NtpMode = 0
    Invoke-ServiceControl "Scan additional ports"
    Wait-ServiceState { (Find-ServiceControl DeviceUdpScanStatus).Current.Name -like "*0 responded, 1 inconclusive, 1 error*" } "visible protocol error"
    Save-ServiceEvidence "services-error"
    Wait-ServiceState { (Find-ServiceControl DevicePortScanButton).Current.Name -eq "Scan additional ports" } "error cleanup"
    Invoke-ServiceControl "Scan additional ports"
    Invoke-ServiceControl "Cancel additional scan"
    Wait-ServiceState { (Find-ServiceControl DeviceUdpScanStatus).Current.Name -like "UDP: canceled*" } "UDP cancellation"
    Wait-ServiceState { (Find-ServiceControl DevicePortScanButton).Current.Name -eq "Scan additional ports" } "cancellation cleanup"
    Save-ServiceEvidence "services-canceled"
    $fixture.DnsMode = 0
    Invoke-ServiceControl "Scan additional ports"
    Select-ServicePage Overview
    Wait-ServiceState { (Find-ServiceControl NetworkPicker).Current.IsEnabled } "navigation cancellation cleanup"
    Open-ServiceDetails
    $udp = (Find-ServiceControl DeviceIncludeUdpCheckBox).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    if ($udp.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) { throw "Returning to details must reset opt-in UDP." }
    $udp.Toggle()
    $fixture.DnsMode = $fixture.NtpMode = 1
    Invoke-ServiceControl "Scan additional ports"
    Wait-ServiceState { (Find-ServiceControl DeviceUdpScanStatus).Current.Name -like "*2 responded, 0 inconclusive, 0 error*" } "theme fixture confirmation"
    Wait-ServiceState { (Find-ServiceControl DevicePortScanButton).Current.Name -eq "Scan additional ports" } "theme fixture results"
    foreach ($theme in @("Standard Light", "Warm Light", "Standard Dark", "True Black (OLED)")) {
        Select-ServicePage Settings
        (Find-ServiceControl ThemePicker).GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
        (Find-ServiceControl $theme -ByName).GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select()
        (Find-ServiceControl ThemePicker).GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Collapse()
        Select-ServicePage Devices
        Save-ServiceEvidence "services-list-$theme" -DevicesList
        Open-ServiceDetails
        Save-ServiceEvidence "services-details-$theme"
    }
    $saved = Get-Content -LiteralPath $snapshot -Raw | ConvertFrom-Json
    if (@($saved.results[0].openPorts | Where-Object protocol -eq 1).Count -ne 2) {
        throw "Confirmed protocol-aware UDP endpoints were not saved."
    }
    $fixture.DnsMode = $fixture.NtpMode = 0
    (Find-ServiceControl DeviceIncludeUdpCheckBox).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern).Toggle()
    Invoke-ServiceControl "Scan additional ports"
    $null = $process.CloseMainWindow()
    if (-not $process.WaitForExit(5000)) { throw "Closing the window did not cancel and drain the additional scan." }
    Write-Host "Additional services native UI checks passed using loopback-only synthetic responders."
}
finally {
    try {
        if ($process -and -not $process.HasExited) {
            $null = $process.CloseMainWindow()
            if (-not $process.WaitForExit(5000)) { Stop-Process -Id $process.Id -Force }
        }
    }
    finally {
        try { if ($fixture) { $fixture.Dispose() } }
        finally {
            try { if ($restartTimeService) { Start-Service W32Time } }
            finally {
                if (Test-Path -LiteralPath $snapshot) { Remove-Item -LiteralPath $snapshot }
                $env:FINGVIBE_UI_REVIEW = $previousReview
                $env:FINGVIBE_UI_REVIEW_SNAPSHOT = $previousSnapshot
            }
        }
    }
}
