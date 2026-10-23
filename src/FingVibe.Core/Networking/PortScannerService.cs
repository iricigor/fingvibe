using System.Net;
using System.Net.Sockets;
using FingVibe.Core.Models;

namespace FingVibe.Core.Networking;

public sealed class PortScannerService
{
    public static readonly IReadOnlyDictionary<int, string> CommonPorts =
        new Dictionary<int, string>
        {
            [22] = "SSH",
            [53] = "DNS",
            [80] = "HTTP",
            [443] = "HTTPS",
            [445] = "SMB",
            [554] = "RTSP",
            [8008] = "Google Cast",
            [8009] = "Google Cast",
            [8080] = "HTTP alternate",
            [9100] = "Printer"
        };

    public static readonly IReadOnlyDictionary<int, string> AdditionalPorts =
        new Dictionary<int, string>
        {
            [21] = "FTP",
            [23] = "Telnet",
            [25] = "SMTP",
            [110] = "POP3",
            [135] = "MS RPC",
            [139] = "NetBIOS",
            [143] = "IMAP",
            [389] = "LDAP",
            [465] = "SMTPS",
            [587] = "SMTP submission",
            [993] = "IMAPS",
            [995] = "POP3S",
            [1433] = "Microsoft SQL Server",
            [1521] = "Oracle",
            [1883] = "MQTT",
            [3306] = "MySQL",
            [3389] = "Remote Desktop",
            [5432] = "PostgreSQL",
            [5672] = "AMQP",
            [5900] = "VNC",
            [6379] = "Redis",
            [8000] = "HTTP alternate",
            [8443] = "HTTPS alternate",
            [8883] = "Secure MQTT"
        };

    private readonly TimeSpan _timeout;

    public PortScannerService(TimeSpan? timeout = null)
    {
        _timeout = timeout ?? TimeSpan.FromMilliseconds(400);
    }

    public async Task<IReadOnlyList<OpenPort>> ScanAsync(
        IPAddress address,
        CancellationToken cancellationToken)
    {
        return await ScanPortsAsync(address, CommonPorts, cancellationToken).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<OpenPort>> ScanAdditionalAsync(
        IPAddress address,
        CancellationToken cancellationToken)
    {
        return await ScanPortsAsync(address, AdditionalPorts, cancellationToken).ConfigureAwait(false);
    }

    private async Task<IReadOnlyList<OpenPort>> ScanPortsAsync(
        IPAddress address,
        IReadOnlyDictionary<int, string> ports,
        CancellationToken cancellationToken)
    {
        var probes = ports.Select(port => ProbeAsync(address, port, cancellationToken));
        var results = await Task.WhenAll(probes).ConfigureAwait(false);
        return results.OfType<OpenPort>().OrderBy(port => port.Port).ToArray();
    }

    private async Task<OpenPort?> ProbeAsync(
        IPAddress address,
        KeyValuePair<int, string> port,
        CancellationToken cancellationToken)
    {
        using var client = new TcpClient(address.AddressFamily);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(_timeout);

        try
        {
            await client.ConnectAsync(address, port.Key, timeout.Token).ConfigureAwait(false);
            return new OpenPort(port.Key, port.Value);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return null;
        }
        catch (SocketException)
        {
            return null;
        }
    }
}
