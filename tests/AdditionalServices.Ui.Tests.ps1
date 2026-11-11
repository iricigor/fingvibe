param(
    [Parameter(Mandatory)][string] $AppPath,
    [Parameter(Mandatory)][string] $ScreenshotDirectory
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewScreenshot.ps1")
. (Join-Path $PSScriptRoot "..\.github\scripts\UiReviewAppearance.ps1")
Add-Type -TypeDefinition @"
using System;
using System.Net;
using System.Net.Sockets;
using System.Threading;
using System.Threading.Tasks;
public sealed class AdditionalServicesFixture : IDisposable
{
    private readonly TcpListener tcp = new TcpListener(IPAddress.Loopback, 1883);
    private readonly TcpListener[] web = {
        new TcpListener(IPAddress.Loopback, 8080),
        new TcpListener(IPAddress.Loopback, 8443)
    };
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
            endpoint = "8080/TCP";
            web[0].Start();
            endpoint = "8443/TCP";
            web[1].Start();
            workers = new[] { Reply(dns, true), Reply(ntp, false), Accept(web[0]), Accept(web[1]) };
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
        tcpWorker = Accept(tcp);
    }
    private async Task Accept(TcpListener listener)
    {
        try { while (!stopping) { using (await listener.AcceptTcpClientAsync()) {} } }
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
        foreach (var listener in web) listener.Stop();
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

function Assert-KeyboardCopy([string] $Label, [string] $Expected) {
    [System.Windows.Forms.SendKeys]::SendWait(" ")
    Wait-ServiceState {
        $texts = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.AndCondition]::new(
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $process.Id),
                [System.Windows.Automation.PropertyCondition]::new(
                    [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                    [System.Windows.Automation.ControlType]::Text)))
        $feedback = $texts | Where-Object {
            $_.Current.Name -eq "$Label copied." -or $_.Current.Name -like "Could not copy ${Label}:*"
        } | Select-Object -First 1
        if (-not $feedback) { return $false }
        if ($feedback.Current.Name -ne "$Label copied.") { throw $feedback.Current.Name }
        return $true
    } "$Label copy feedback"
    if ([System.Windows.Forms.Clipboard]::GetText() -ne $Expected) {
        throw "Keyboard copy must contain only the $Label value."
    }
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

function Show-ServiceScanSection([int] $ExtraSpace = 0) {
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
        $heading = (Find-ServiceControl DeviceIncludeUdpCheckBox).Current.BoundingRectangle
        if ($button.Width -gt 0 -and $heading.Width -gt 0 -and
            $button.Top -ge $top + 8 * $scale -and $heading.Bottom -le $bottom - (110 + $ExtraSpace) * $scale) {
            return
        }
    }
    throw "The scan controls could not fit the physical viewport: window=$window, scroll=$area, button=$button, UDP option=$heading."
}

function Show-ServiceCardFootnotes {
    $element = Find-ServiceControl DeviceDetailsScroll
    $scroll = $element.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    $scale = [UiReviewNativeWindow]::GetDpiForWindow($process.MainWindowHandle) / 96.0
    foreach ($percent in 0..100) {
        if ($scroll.Current.VerticallyScrollable) { $scroll.SetScrollPercent(-1, $percent) }
        Start-Sleep -Milliseconds 50
        $area = $element.Current.BoundingRectangle
        $window = Get-UiReviewWindowBounds $process.MainWindowHandle
        $bottom = [Math]::Min($area.Bottom, $window.Bottom - 48 * $scale)
        $networkNote = (Find-ServiceControl DeviceAddressSourceText).Current.BoundingRectangle
        $assignmentNote = (Find-ServiceControl DeviceAssignmentStatusText).Current.BoundingRectangle
        if ($networkNote.Width -gt 0 -and $assignmentNote.Width -gt 0 -and
            $networkNote.Top -ge $area.Top -and $assignmentNote.Top -ge $area.Top -and
            $networkNote.Bottom -le $bottom -and $assignmentNote.Bottom -le $bottom) {
            return
        }
    }
    throw "Both aligned card footnotes must fit the physical details viewport: window=$window, scroll=$area, network=$networkNote, assignments=$assignmentNote."
}

function Save-ServiceEvidence([string] $Name, [switch] $DevicesList) {
    if (-not $DevicesList) { Show-ServiceScanSection }
    Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "$Name.png")
}

function Open-IdentificationEditor {
    $edit = Find-ServiceControl "Edit device identification" -ByName
    Wait-ServiceState { $edit.Current.IsEnabled } "identification read mode"
    $edit.SetFocus()
    Invoke-ServiceControl "Edit device identification"
    Wait-ServiceState {
        -not $edit.Current.IsEnabled -and
        [System.Windows.Automation.AutomationElement]::FocusedElement.Current.Name -eq "Device type"
    } "first identification input focus"
}

function Test-DeviceDetailsEditing {
    $scroll = (Find-ServiceControl DeviceDetailsScroll).GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
    $scroll.SetScrollPercent(-1, 0)
    Wait-ServiceState {
        (Find-ServiceControl "Network overview" -ByName).Current.BoundingRectangle.Width -gt 0 -and
        (Find-ServiceControl Assignments -ByName).Current.BoundingRectangle.Width -gt 0
    } "top-row cards"
    $network = (Find-ServiceControl "Network overview" -ByName).Current.BoundingRectangle
    $assignment = (Find-ServiceControl Assignments -ByName).Current.BoundingRectangle
    if ([Math]::Abs($network.Top - $assignment.Top) -gt 3 -or $assignment.Left -le $network.Left + 300) {
        throw "Network overview and Assignments must share the top row in left/right order."
    }
    Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "device-details-wide.png")
    Show-ServiceCardFootnotes
    Wait-ServiceState {
        (Find-ServiceControl DeviceAddressSourceText).Current.BoundingRectangle.Width -gt 0 -and
        (Find-ServiceControl DeviceAssignmentStatusText).Current.BoundingRectangle.Width -gt 0
    } "aligned card footnotes"
    $networkNote = (Find-ServiceControl DeviceAddressSourceText).Current.BoundingRectangle
    $assignmentNote = (Find-ServiceControl DeviceAssignmentStatusText).Current.BoundingRectangle
    if ([Math]::Abs($networkNote.Bottom - $assignmentNote.Bottom) -gt 3) {
        throw "The assignments explanation must follow the aligned card bottom: network=$networkNote assignments=$assignmentNote."
    }
    Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "device-details-aligned-footnotes.png")
    Invoke-ServiceControl "Rename device"
    Wait-ServiceState {
        [System.Windows.Automation.AutomationElement]::FocusedElement.Current.Name -eq "Device name"
    } "name editor focus"
    Invoke-ServiceControl Done
    Wait-ServiceState {
        [System.Windows.Automation.AutomationElement]::FocusedElement.Current.Name -eq "Rename device"
    } "name editor closed"
    $copy = Find-ServiceControl "Copy IP address" -ByName
    $copy.SetFocus()
    Write-Host "Copy focus: $([System.Windows.Automation.AutomationElement]::FocusedElement.Current.Name); bounds: $($copy.Current.BoundingRectangle)."
    Wait-ServiceState { -not $copy.Current.IsOffscreen -and $copy.Current.BoundingRectangle.Width -ge 30 } "keyboard-accessible copy action"
    $value = (Find-ServiceControl "127.0.0.1" -ByName).Current.BoundingRectangle
    $copyBounds = $copy.Current.BoundingRectangle
    if ($value.Width -le 0 -or $copyBounds.Left - $value.Right -gt 16 -or $copyBounds.Left -lt $value.Right - 1) {
        throw "Copy must sit immediately after its value, not at the field edge: value=$value copy=$copyBounds."
    }
    $before = $copy.Current.BoundingRectangle
    Assert-KeyboardCopy "IP address" "127.0.0.1"
    $after = $copy.Current.BoundingRectangle
    if ($before -ne $after) { throw "Copy activation shifted its layout." }
    [System.Windows.Forms.SendKeys]::SendWait("{ESC}")

    Open-IdentificationEditor
    $brand = Find-ServiceControl DeviceBrandInput
    $brand.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue("Unsaved brand")
    Invoke-ServiceControl Cancel
    Open-IdentificationEditor
    if ($brand.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).Current.Value -ne "") {
        throw "Cancel retained unsaved identification values."
    }
    foreach ($field in @("Brand", "Family", "Model")) {
        (Find-ServiceControl "Device${field}Input").GetCurrentPattern(
            [System.Windows.Automation.ValuePattern]::Pattern).SetValue("Synthetic $field")
    }
    $save = Find-ServiceControl "Save changes" -ByName
    Wait-ServiceState { $save.Current.IsEnabled } "changed identification save action"
    $save.SetFocus()
    Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "device-identification-edit.png")
    Invoke-ServiceControl "Save changes"
    Wait-ServiceState { (Find-ServiceControl "Edit device identification" -ByName).Current.IsEnabled } "identification save"
    $modelCopy = Find-ServiceControl "Copy Model" -ByName
    $modelCopy.SetFocus()
    Wait-ServiceState { -not $modelCopy.Current.IsOffscreen -and $modelCopy.Current.BoundingRectangle.Width -ge 30 } "saved metadata copy focus"
    Assert-KeyboardCopy Model "Synthetic Model"
    [System.Windows.Forms.SendKeys]::SendWait("{ESC}")
    Show-ServiceScanSection
    (Find-ServiceControl "Edit device identification" -ByName).SetFocus()
    Wait-ServiceState {
        (Find-ServiceControl "Device type" -ByName).Current.BoundingRectangle.Width -gt 0 -and
        (Find-ServiceControl "Ports & services" -ByName).Current.BoundingRectangle.Width -gt 0
    } "wide identification fields"
    $ports = (Find-ServiceControl "Ports & services" -ByName).Current.BoundingRectangle
    $type = (Find-ServiceControl "Device type" -ByName).Current.BoundingRectangle
    $os = (Find-ServiceControl "Operating system" -ByName).Current.BoundingRectangle
    $brand = (Find-ServiceControl Brand -ByName).Current.BoundingRectangle
    $identification = (Find-ServiceControl "Device identification" -ByName).Current.BoundingRectangle
    if ($type.Width -le 0 -or $os.Left -le $type.Left -or $brand.Left -le $os.Left -or
        [Math]::Abs($type.Top - $os.Top) -gt 3 -or [Math]::Abs($type.Top - $brand.Top) -gt 3 -or
        [Math]::Abs($identification.Left - $network.Left) -gt 3 -or
        [Math]::Abs($ports.Left - $network.Left) -gt 3) {
        throw "Wide identification must span the page in three field columns, followed by full-width ports."
    }
    $imported = Find-ServiceControl DeviceImportedMetadata
    $evidence = Find-ServiceControl "How this device was identified" -ByName
    if ($imported.GetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern).Current.ExpandCollapseState -ne
        [System.Windows.Automation.ExpandCollapseState]::Collapsed -or
        $imported.Current.BoundingRectangle.Top -lt $evidence.Current.BoundingRectangle.Bottom -or
        $imported.Current.BoundingRectangle.Bottom -gt $ports.Top) {
        throw "Collapsed Imported Fing data must follow identification evidence, before Ports & services."
    }
    Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "device-identification-read-wide.png")
    Open-IdentificationEditor
    Invoke-ServiceControl "Reset saved identification"
    Wait-ServiceState { (Find-ServiceControl "Edit device identification" -ByName).Current.IsEnabled } "identification reset"
    Open-IdentificationEditor
    foreach ($field in @("Brand", "Family", "Model")) {
        if ((Find-ServiceControl "Device${field}Input").GetCurrentPattern(
                [System.Windows.Automation.ValuePattern]::Pattern).Current.Value -ne "") {
            throw "Reset retained the saved $field correction."
        }
    }
    Invoke-ServiceControl Cancel
    $window = Get-UiReviewWindowBounds $process.MainWindowHandle
    try {
        $null = [UiReviewNativeWindow]::SetWindowPos($process.MainWindowHandle, [IntPtr]::Zero,
            $window.Left, $window.Top, 760, $window.Height, 0x0044)
        Start-Sleep -Milliseconds 300
        Open-IdentificationEditor
        (Find-ServiceControl DeviceBrandInput).GetCurrentPattern(
            [System.Windows.Automation.ValuePattern]::Pattern).SetValue("Narrow draft")
        $save = Find-ServiceControl "Save changes" -ByName
        Wait-ServiceState { $save.Current.IsEnabled } "changed narrow identification save action"
        $save.SetFocus()
        Wait-ServiceState { -not $save.Current.IsOffscreen } "narrow inline editor"
        $scroll = (Find-ServiceControl DeviceDetailsScroll).GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern)
        if ($scroll.Current.HorizontallyScrollable) { throw "Narrow details require horizontal scrolling." }
        Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "device-identification-narrow.png")
        Invoke-ServiceControl Cancel
    }
    finally {
        $null = [UiReviewNativeWindow]::SetWindowPos($process.MainWindowHandle, [IntPtr]::Zero,
            $window.Left, $window.Top, $window.Width, $window.Height, 0x0044)
    }
    Show-ServiceScanSection
}

function Test-EndpointLinks {
    foreach ($case in @(@("Try HTTP", 8080), @("Try HTTPS", 8443))) {
        $link = Find-ServiceControl "$($case[0]): 127.0.0.1:$($case[1])" -ByName
        if ($link.Current.ControlType -ne [System.Windows.Automation.ControlType]::Hyperlink) {
            throw "Alternate browser actions must be native text hyperlinks, not boxed buttons."
        }
        $link.SetFocus()
        Wait-ServiceState { -not $link.Current.IsOffscreen -and $link.Current.BoundingRectangle.Width -gt 0 } "alternate browser link focus"
        $copies = $root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.PropertyCondition]::new(
                [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
                [System.Windows.Automation.ControlType]::Button))
        $portLabel = $copies | Where-Object { $_.Current.Name -like "Copy $($case[1])/TCP -*" } | Select-Object -First 1
        if (-not $portLabel) { throw "Missing endpoint copy action for port $($case[1])." }
        $portLabel.SetFocus()
        Wait-ServiceState { -not $portLabel.Current.IsOffscreen -and $portLabel.Current.BoundingRectangle.Width -ge 30 } "endpoint copy geometry"
        $copyBounds = $portLabel.Current.BoundingRectangle
        $linkBounds = $link.Current.BoundingRectangle
        if ($linkBounds.Left -lt $copyBounds.Right - 1 -or $linkBounds.Left - $copyBounds.Right -gt 16 -or
            [Math]::Abs($linkBounds.Top - $copyBounds.Top) -gt 10) {
            throw "Try links must stay beside endpoint copy actions: copy=$copyBounds link=$linkBounds."
        }
    }
    Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "device-endpoint-try-links.png")
    $primary = Find-ServiceControl "Open HTTP: 127.0.0.1:80" -ByName -Optional
    if ($primary) {
        if ($primary.Current.ControlType -ne [System.Windows.Automation.ControlType]::Hyperlink) {
            throw "A confirmed standard web endpoint must use a linked address."
        }
        $primary.SetFocus()
        Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "device-endpoint-linked-address.png")
    }
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
    Select-ServicePage Devices
    Wait-ServiceState { (Find-ServiceControl "Scan LAN" -ByName -Optional).Current.IsEnabled } "scan readiness"
    Invoke-ServiceControl "Scan LAN"
    Wait-ServiceState { (Find-ServiceControl "Scan LAN" -ByName -Optional).Current.IsEnabled -and (Test-Path $snapshot) } "loopback scan"
    Open-ServiceDetails
    Test-DeviceDetailsEditing
    $udp = (Find-ServiceControl DeviceIncludeUdpCheckBox).GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
    if ($udp.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::Off) { throw "UDP must start unchecked." }
    Save-ServiceEvidence "services-default"
    Invoke-ServiceControl "Scan additional ports"
    Wait-ServiceState { (Find-ServiceControl DeviceTcpScanStatus).Current.Name -like "TCP: complete*" } "TCP-only completion"
    if ($fixture.DnsRequests -ne 0 -or $fixture.NtpRequests -ne 0) { throw "Default scanning sent UDP requests." }
    if (Find-ServiceControl "1883/TCP - MQTT" -ByName -Optional) { throw "The TCP fixture unexpectedly responded before starting." }
    Wait-ServiceState { (Find-ServiceControl DevicePortScanButton).Current.Name -eq "Scan additional ports" } "usable TCP-only button"
    Show-ServiceScanSection -ExtraSpace 24
    $fixture.StartTcp()
    $udp.Toggle()
    Invoke-ServiceControl "Scan additional ports"
    Wait-ServiceState { Find-ServiceControl "1883/TCP - MQTT" -ByName -Optional } "new TCP endpoint before UDP" 2
    if ((Find-ServiceControl DeviceUdpScanStatus).Current.Name -notlike "UDP: checking*") {
        throw "A newly completed TCP endpoint was not exposed while UDP was still pending."
    }
    Invoke-ServiceControl "Scan LAN"
    if ((Find-ServiceControl ScanStatusText).Current.Name -notlike "Another network measurement is in progress.*" -or
        (Find-ServiceControl CancelButton -Optional) -or
        (Find-ServiceControl DeviceDetailsScroll).Current.IsOffscreen) {
        throw "The shared LAN action must report a conflicting measurement without leaving Device Details or starting another scan."
    }
    Save-ServiceEvidence "services-tcp-results-udp-pending"
    if ((Find-ServiceControl DeviceUdpScanStatus).Current.Name -notlike "UDP: checking*") {
        throw "UDP finished before the TCP-before-UDP screenshot was captured."
    }
    Wait-ServiceState { (Find-ServiceControl DeviceUdpScanStatus).Current.Name -like "*0 responded, 2 inconclusive, 0 error*" } "inconclusive UDP"
    if ($fixture.DnsRequests -ne 1 -or $fixture.NtpRequests -ne 1) { throw "UDP must send only one request per service." }
    Save-ServiceEvidence "services-inconclusive"
    Wait-ServiceState { (Find-ServiceControl DevicePortScanButton).Current.Name -eq "Scan additional ports" } "scan cleanup"
    Test-EndpointLinks
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
    foreach ($theme in $UiReviewAppearanceThemes) {
        Select-ServicePage Settings
        Set-UiReviewTheme -Root $root -Theme $theme
        Select-ServicePage Devices
        Save-ServiceEvidence "services-list-$theme" -DevicesList
        Open-ServiceDetails
        Save-ServiceEvidence "services-details-$theme"
        $endpointCopy = Find-ServiceControl "Copy 1883/TCP - MQTT" -ByName
        $endpointCopy.SetFocus()
        Wait-ServiceState { -not $endpointCopy.Current.IsOffscreen -and $endpointCopy.Current.BoundingRectangle.Width -ge 30 } "endpoint capture focus"
        Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "services-endpoints-$theme.png")
        (Find-ServiceControl "Edit device identification" -ByName).SetFocus()
        Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "device-identification-$theme.png")
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
catch {
    if ($process -and -not $process.HasExited -and $process.MainWindowHandle -ne 0) {
        Save-UiReviewWindowScreenshot $process.MainWindowHandle (Join-Path $ScreenshotDirectory "services-failure.png")
    }
    throw
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
