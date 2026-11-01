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
            [20] = "FTP data",
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
            [8883] = "Secure MQTT",
            [115] = "Simple File Transfer Protocol",
            [548] = "AFP",
            [873] = "rsync",
            [989] = "FTPS data",
            [990] = "FTPS",
            [2049] = "NFS",
            [3260] = "iSCSI",
            [593] = "RPC over HTTP",
            [5800] = "VNC web access",
            [5901] = "VNC",
            [5902] = "VNC",
            [5985] = "WinRM",
            [5986] = "Secure WinRM",
            [109] = "POP2",
            [119] = "NNTP",
            [563] = "Secure NNTP",
            [2525] = "SMTP alternate",
            [4190] = "ManageSieve",
            [88] = "Kerberos",
            [636] = "LDAPS",
            [464] = "Kerberos password changes",
            [749] = "Kerberos administration",
            [3268] = "AD Global Catalog",
            [3269] = "Secure AD Global Catalog",
            [3050] = "Firebird",
            [7474] = "Neo4j HTTP",
            [7687] = "Neo4j Bolt",
            [8529] = "ArangoDB",
            [9042] = "Cassandra",
            [9160] = "Cassandra Thrift",
            [11211] = "Memcached",
            [27017] = "MongoDB",
            [28015] = "RethinkDB",
            [4222] = "NATS",
            [4369] = "Erlang port mapper",
            [5671] = "Secure AMQP",
            [6650] = "Pulsar",
            [9092] = "Kafka",
            [15672] = "RabbitMQ management",
            [61613] = "STOMP",
            [3000] = "Web/application",
            [3001] = "Web/application",
            [5000] = "Web/application",
            [5001] = "Secure web/application",
            [8001] = "Web/application",
            [8081] = "HTTP alternate",
            [8088] = "HTTP alternate",
            [8888] = "Web/application",
            [9000] = "Web/application",
            [9443] = "HTTPS alternate",
            [5601] = "Kibana",
            [8006] = "Proxmox management",
            [9090] = "Prometheus/administration",
            [10000] = "Webmin",
            [1880] = "Node-RED",
            [3689] = "DAAP",
            [5004] = "HDHomeRun HTTP streaming",
            [6600] = "Music Player Daemon",
            [7000] = "AirPlay-associated service",
            [8060] = "Roku control",
            [8096] = "Jellyfin/Emby",
            [8920] = "Secure Jellyfin/Emby",
            [8123] = "Home Assistant",
            [8200] = "MiniDLNA web status",
            [8384] = "Syncthing UI",
            [32400] = "Plex",
            [111] = "RPC port mapper",
            [179] = "BGP",
            [515] = "LPD",
            [631] = "IPP",
            [2375] = "Docker API",
            [2376] = "Secure Docker API",
            [6443] = "Kubernetes API",
            [9101] = "Printer alternate",
            [9200] = "Elasticsearch"
        };

    private readonly TimeSpan _timeout;
    public const int AdditionalConcurrency = 16;

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
        CancellationToken cancellationToken,
        IPAddress? localAddress = null,
        IProgress<ScanProgress>? progress = null)
    {
        return await RunAdditionalProbesAsync(
            (port, token) => ProbeAsync(address, port, token, localAddress), cancellationToken, progress).ConfigureAwait(false);
    }

    internal static async Task<IReadOnlyList<OpenPort>> RunAdditionalProbesAsync(
        Func<KeyValuePair<int, string>, CancellationToken, Task<OpenPort?>> probe,
        CancellationToken cancellationToken, IProgress<ScanProgress>? progress = null)
    {
        var results = new System.Collections.Concurrent.ConcurrentBag<OpenPort>();
        var completed = 0;
        await Parallel.ForEachAsync(AdditionalPorts,
            new ParallelOptions { MaxDegreeOfParallelism = AdditionalConcurrency, CancellationToken = cancellationToken },
            async (port, token) =>
            {
                if (await probe(port, token).ConfigureAwait(false) is { } openPort)
                    results.Add(openPort);
                progress?.Report(new ScanProgress(Interlocked.Increment(ref completed), AdditionalPorts.Count));
            }).ConfigureAwait(false);
        return results.OrderBy(port => port.Port).ToArray();
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

    internal async Task<OpenPort?> ProbeAsync(
        IPAddress address,
        KeyValuePair<int, string> port,
        CancellationToken cancellationToken,
        IPAddress? localAddress = null)
    {
        using var client = new TcpClient(address.AddressFamily);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(_timeout);

        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (localAddress is not null)
                client.Client.Bind(new IPEndPoint(localAddress, 0));
            await client.ConnectAsync(address, port.Key, timeout.Token).ConfigureAwait(false);
            return new OpenPort(port.Key, port.Value);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return null;
        }
        catch (SocketException exception) when (localAddress is null
            || exception.SocketErrorCode is SocketError.ConnectionRefused or SocketError.TimedOut
                or SocketError.ConnectionReset)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return null;
        }
    }
}
