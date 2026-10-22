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

    private readonly TimeSpan _timeout;

    public PortScannerService(TimeSpan? timeout = null)
    {
        _timeout = timeout ?? TimeSpan.FromMilliseconds(400);
    }

    public async Task<IReadOnlyList<OpenPort>> ScanAsync(
        IPAddress address,
        CancellationToken cancellationToken)
    {
        var probes = CommonPorts.Select(port => ProbeAsync(address, port, cancellationToken));
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
