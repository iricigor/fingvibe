using System.Net;
using System.Net.Sockets;
using FingVibe.Core.Models;

namespace FingVibe.Core.Networking;

// Probe set, per-port timeout, fixed concurrency and progress cadence for one manual per-device TCP scan.
public sealed record PortScanPlan(
    IEnumerable<KeyValuePair<int, string>> Ports, int Count, TimeSpan Timeout, int Concurrency, int ProgressInterval);

public sealed class PortScannerService
{
    // 32 keeps the 193-port optional scan near the former 100-port duration (measured in docs/reference.md).
    public const int AdditionalConcurrency = 32;
    public const int FullScanConcurrency = 128;
    public const int FullScanProgressInterval = 256;
    public const int LastTcpPort = 65_535;
    public const string UnlistedServiceName = "Unlisted service";
    public static readonly TimeSpan DefaultTimeout = TimeSpan.FromMilliseconds(400);
    public static readonly TimeSpan FullScanTimeout = TimeSpan.FromMilliseconds(200);

    // Probed for every alive host during each LAN scan, all at once with the default timeout.
    public static readonly IReadOnlyDictionary<int, string> CommonPorts = Catalog(
    [
        (22, "SSH"), (53, "DNS"), (80, "HTTP"), (139, "NetBIOS"), (443, "HTTPS"), (445, "SMB"), (515, "LPD"),
        (554, "RTSP"), (631, "IPP"), (1883, "MQTT"), (5357, "WSD"), (8008, "Google Cast"), (8009, "Google Cast"),
        (8080, "HTTP alternate"), (8123, "Home Assistant"), (8888, "Web/application"), (9100, "Printer")
    ]);

    // Manually requested for one device. Grouped by service family; see docs/reference.md for the rationale.
    public static readonly IReadOnlyDictionary<int, string> AdditionalPorts = Catalog(
    [
        // Remote shells and administration
        (23, "Telnet"), (992, "Telnet over TLS"), (2222, "SSH alternate"), (5555, "Android Debug Bridge"),
        (5985, "WinRM"), (5986, "Secure WinRM"),
        // Remote desktop and screen sharing
        (3283, "Apple Remote Desktop"), (3389, "Remote Desktop"), (4899, "Radmin"), (5800, "VNC web access"),
        (5900, "VNC"), (5901, "VNC"), (5902, "VNC"), (5903, "VNC"), (5938, "TeamViewer"), (6568, "AnyDesk"),
        // Web applications and dashboards
        (81, "HTTP alternate"), (3000, "Web/application"), (3001, "Web/application"), (4000, "Web/application"),
        (5000, "Web/application"), (5050, "Web/application"), (5601, "Kibana"), (7080, "HTTP alternate"),
        (8000, "HTTP alternate"), (8001, "Web/application"), (8006, "Proxmox management"), (8081, "HTTP alternate"),
        (8082, "HTTP alternate"), (8083, "HTTP alternate"), (8088, "HTTP alternate"), (8090, "HTTP alternate"),
        (8112, "Deluge web UI"), (8180, "HTTP alternate"), (9000, "Web/application"), (9090, "Prometheus/administration"),
        (9091, "Transmission web UI"),
        // HTTPS and secure management
        (943, "OpenVPN Access Server"), (4443, "HTTPS alternate"), (5001, "Secure web/application"),
        (5989, "Secure CIM/WBEM"), (7443, "HTTPS alternate"), (8443, "HTTPS alternate"), (8843, "HTTPS alternate"),
        (9443, "HTTPS alternate"), (10000, "Webmin"), (10443, "HTTPS alternate"), (16993, "Intel AMT HTTPS"),
        // Network infrastructure, VPN, proxies and platform APIs
        (111, "RPC port mapper"), (135, "MS RPC"), (179, "BGP"), (593, "RPC over HTTP"), (853, "DNS over TLS"),
        (902, "VMware ESXi"), (1080, "SOCKS proxy"), (1194, "OpenVPN"), (1723, "PPTP VPN"), (2375, "Docker API"),
        (2376, "Secure Docker API"), (2377, "Docker Swarm"), (2379, "etcd"), (3128, "HTTP proxy"),
        (5335, "Unbound DNS"), (5358, "Secure WSD"), (5988, "CIM/WBEM"), (6443, "Kubernetes API"),
        (6789, "UniFi speed test"), (7547, "TR-069 remote management"), (8118, "Privoxy"), (8291, "MikroTik Winbox"),
        (8728, "MikroTik API"), (8729, "Secure MikroTik API"), (10250, "Kubernetes kubelet"), (16992, "Intel AMT"),
        // Directory and authentication
        (49, "TACACS+"), (88, "Kerberos"), (389, "LDAP"), (464, "Kerberos password changes"), (636, "LDAPS"),
        (749, "Kerberos administration"), (3268, "AD Global Catalog"), (3269, "Secure AD Global Catalog"),
        // File transfer and sharing
        (20, "FTP data"), (21, "FTP"), (115, "Simple File Transfer Protocol"), (548, "AFP"), (873, "rsync"),
        (989, "FTPS data"), (990, "FTPS"), (2121, "FTP alternate"), (5005, "Synology WebDAV"),
        (5006, "Secure Synology WebDAV"), (6690, "Synology Drive"), (6800, "aria2 RPC"), (6881, "BitTorrent"),
        (8384, "Syncthing UI"), (9418, "Git"), (22000, "Syncthing sync"), (51413, "Transmission peer"),
        // Network storage
        (860, "iSCSI system"), (2049, "NFS"), (3260, "iSCSI"),
        // Mail and news
        (25, "SMTP"), (109, "POP2"), (110, "POP3"), (119, "NNTP"), (143, "IMAP"), (465, "SMTPS"),
        (563, "Secure NNTP"), (587, "SMTP submission"), (993, "IMAPS"), (995, "POP3S"), (2525, "SMTP alternate"),
        (4190, "ManageSieve"),
        // Databases and caches
        (1433, "Microsoft SQL Server"), (1521, "Oracle"), (3050, "Firebird"), (3306, "MySQL"), (3307, "MySQL alternate"),
        (5432, "PostgreSQL"), (5433, "PostgreSQL alternate"), (5984, "CouchDB"), (6379, "Redis"), (7474, "Neo4j HTTP"),
        (7687, "Neo4j Bolt"), (8086, "InfluxDB"), (8529, "ArangoDB"), (9042, "Cassandra"), (9160, "Cassandra Thrift"),
        (9200, "Elasticsearch"), (9300, "Elasticsearch transport"), (11211, "Memcached"), (27017, "MongoDB"),
        (28015, "RethinkDB"),
        // Messaging and chat
        (2181, "ZooKeeper"), (4222, "NATS"), (4369, "Erlang port mapper"), (5222, "XMPP client"),
        (5269, "XMPP server"), (5671, "Secure AMQP"), (5672, "AMQP"), (6650, "Pulsar"), (6667, "IRC"),
        (8883, "Secure MQTT"), (9092, "Kafka"), (15672, "RabbitMQ management"), (61613, "STOMP"),
        (61616, "ActiveMQ"),
        // Monitoring
        (4949, "Munin"), (5666, "Nagios NRPE"), (9093, "Alertmanager"), (10050, "Zabbix agent"), (19999, "Netdata"),
        // Home automation and industrial IoT
        (502, "Modbus TCP"), (1880, "Node-RED"), (4840, "OPC UA"), (6053, "ESPHome API"),
        (6668, "Tuya local control"), (8581, "Homebridge UI"),
        // Media, TVs, speakers and cameras
        (1400, "Sonos control"), (1925, "Philips TV control"), (1935, "RTMP"), (2020, "ONVIF camera"),
        (2869, "UPnP events"), (3483, "Squeezebox control"), (3689, "DAAP"), (5004, "HDHomeRun HTTP streaming"),
        (6466, "Android TV remote"), (6600, "Music Player Daemon"), (7000, "AirPlay-associated service"),
        (7100, "AirPlay mirroring"), (8002, "Samsung TV remote"), (8060, "Roku control"), (8096, "Jellyfin/Emby"),
        (8200, "MiniDLNA web status"), (8554, "RTSP alternate"), (8920, "Secure Jellyfin/Emby"),
        (10243, "Windows Media sharing"), (32400, "Plex"), (32469, "Plex DLNA"), (34567, "DVR/NVR control"),
        (37777, "Dahua camera/DVR"),
        // Phones and tablets
        (62078, "Apple device sync"),
        // Game consoles and game servers
        (3074, "Xbox Live"), (3478, "PlayStation Network"), (9295, "PlayStation Remote Play"), (25565, "Minecraft"),
        (27015, "Steam/Source game server"), (27036, "Steam In-Home Streaming"),
        // Voice over IP
        (5060, "SIP"), (5061, "SIP over TLS"),
        // Printers
        (9101, "Printer alternate"), (9102, "Printer alternate")
    ]);

    private readonly TimeSpan _timeout;
    private readonly Func<IPAddress, KeyValuePair<int, string>, TimeSpan, CancellationToken, Task<OpenPort?>>? _probe;

    public PortScannerService(TimeSpan? timeout = null)
    {
        _timeout = timeout ?? DefaultTimeout;
    }

    // Test seam: replaces every TCP connection attempt made by this instance.
    internal PortScannerService(Func<IPAddress, KeyValuePair<int, string>, TimeSpan, CancellationToken, Task<OpenPort?>> probe)
        : this() => _probe = probe;

    public static PortScanPlan AdditionalPlan { get; } =
        new(AdditionalPorts, AdditionalPorts.Count, DefaultTimeout, AdditionalConcurrency, 1);

    // Every TCP port exactly once, in ascending order. Only started after explicit per-device confirmation.
    public static PortScanPlan FullTcpPlan { get; } = new(
        Enumerable.Range(1, LastTcpPort).Select(port => new KeyValuePair<int, string>(port, ServiceName(port))),
        LastTcpPort, FullScanTimeout, FullScanConcurrency, FullScanProgressInterval);

    public static string ServiceName(int port) =>
        CommonPorts.TryGetValue(port, out var name) || AdditionalPorts.TryGetValue(port, out name)
            ? name
            : UnlistedServiceName;

    public async Task<IReadOnlyList<OpenPort>> ScanAsync(
        IPAddress address,
        CancellationToken cancellationToken)
    {
        var probes = CommonPorts.Select(port => _probe is null
            ? ProbeAsync(address, port, cancellationToken)
            : _probe(address, port, _timeout, cancellationToken));
        var results = await Task.WhenAll(probes).ConfigureAwait(false);
        return results.OfType<OpenPort>().OrderBy(port => port.Port).ToArray();
    }

    public Task<IReadOnlyList<OpenPort>> ScanAdditionalAsync(
        IPAddress address,
        CancellationToken cancellationToken,
        IPAddress? localAddress = null,
        IProgress<ScanProgress>? progress = null,
        IProgress<OpenPort>? resultProgress = null) =>
        RunProbesAsync(AdditionalPlan with { Timeout = _timeout },
            (port, timeout, token) => _probe?.Invoke(address, port, timeout, token)
                ?? ProbeAsync(address, port, token, localAddress, timeout),
            cancellationToken, progress, resultProgress);

    public Task<IReadOnlyList<OpenPort>> ScanFullTcpAsync(
        IPAddress address,
        CancellationToken cancellationToken,
        IPAddress? localAddress = null,
        IProgress<ScanProgress>? progress = null,
        IProgress<OpenPort>? resultProgress = null) =>
        RunProbesAsync(FullTcpPlan,
            (port, timeout, token) => _probe?.Invoke(address, port, timeout, token)
                ?? ProbeAsync(address, port, token, localAddress, timeout),
            cancellationToken, progress, resultProgress);

    // Cancellation stops further dispatch and cancels in-flight probes. Completed open ports were already
    // reported through resultProgress, so callers retain them when this throws.
    internal static async Task<IReadOnlyList<OpenPort>> RunProbesAsync(
        PortScanPlan plan,
        Func<KeyValuePair<int, string>, TimeSpan, CancellationToken, Task<OpenPort?>> probe,
        CancellationToken cancellationToken, IProgress<ScanProgress>? progress = null,
        IProgress<OpenPort>? resultProgress = null)
    {
        var results = new System.Collections.Concurrent.ConcurrentBag<OpenPort>();
        var completed = 0;
        await Parallel.ForEachAsync(plan.Ports,
            new ParallelOptions { MaxDegreeOfParallelism = plan.Concurrency, CancellationToken = cancellationToken },
            async (port, token) =>
            {
                if (await probe(port, plan.Timeout, token).ConfigureAwait(false) is { } openPort)
                {
                    results.Add(openPort);
                    resultProgress?.Report(openPort);
                }
                var count = Interlocked.Increment(ref completed);
                if (count % plan.ProgressInterval == 0 || count == plan.Count)
                    progress?.Report(new ScanProgress(count, plan.Count));
            }).ConfigureAwait(false);
        return results.OrderBy(port => port.Port).ToArray();
    }

    internal async Task<OpenPort?> ProbeAsync(
        IPAddress address,
        KeyValuePair<int, string> port,
        CancellationToken cancellationToken,
        IPAddress? localAddress = null,
        TimeSpan? timeoutOverride = null)
    {
        using var client = new TcpClient(address.AddressFamily);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(timeoutOverride ?? _timeout);

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

    // Throws on a duplicate port so the catalogues cannot silently overwrite an entry.
    private static IReadOnlyDictionary<int, string> Catalog((int Port, string Name)[] entries) =>
        entries.ToDictionary(entry => entry.Port, entry => entry.Name);
}
