using System.Net;
using System.Net.Sockets;
using FingVibe.Core.Models;

namespace FingVibe.Core.Networking;

// Verifies TCP endpoints advertised through DNS-SD for one scan. Only the responding, in-subnet address that
// advertised the service is probed; other advertised hosts and UDP endpoints are never contacted.
internal sealed class AdvertisedEndpointVerifier
{
    // 64 probes at 16 at a time and 400 ms each bound the worst case to four waves, 1.6 seconds per scan.
    internal const int MaximumEndpointsPerScan = 64;
    internal const int MaximumEndpointsPerDevice = 8;
    internal const int MaximumConcurrency = 16;
    internal static readonly TimeSpan ConnectTimeout = TimeSpan.FromMilliseconds(400);

    private readonly Func<IPAddress, int, CancellationToken, Task<bool>> _connect;
    private readonly SemaphoreSlim _slots = new(MaximumConcurrency, MaximumConcurrency);
    private readonly Dictionary<(IPAddress, int), Task<bool>> _probes = new();
    private readonly object _gate = new();

    public AdvertisedEndpointVerifier(Func<IPAddress, int, CancellationToken, Task<bool>>? connect = null) =>
        _connect = connect ?? ConnectAsync;

    public int Started { get; private set; }

    public async Task<(IReadOnlyList<ServiceAdvertisement> Advertisements, IReadOnlyList<OpenPort> OpenPorts)> VerifyAsync(
        IPAddress address, IReadOnlyList<ServiceAdvertisement> advertisements, IReadOnlyList<OpenPort> openPorts,
        CancellationToken cancellationToken)
    {
        var known = openPorts.Where(port => port.Protocol == EndpointProtocol.Tcp).Select(port => port.Port).ToHashSet();
        var ports = advertisements.Where(item => item.Protocol == ServiceDiscoveryProtocol.Mdns
                && item.Transport == EndpointProtocol.Tcp && item.Port is not null)
            .Select(item => item.Port!.Value).Distinct().Where(port => !known.Contains(port))
            .Take(MaximumEndpointsPerDevice).ToArray();
        var probes = ports.Select(port => (Port: port, Probe: Reserve(address, port, cancellationToken)))
            .Where(item => item.Probe is not null).ToArray();
        var results = new Dictionary<int, bool>();
        foreach (var (port, probe) in probes)
        {
            results[port] = await probe!.ConfigureAwait(false);
        }
        cancellationToken.ThrowIfCancellationRequested();

        var updated = advertisements.Select(item =>
            item.Protocol != ServiceDiscoveryProtocol.Mdns || item.Transport != EndpointProtocol.Tcp || item.Port is not { } port
                ? item
                : item with
                {
                    Verification = known.Contains(port) || results.GetValueOrDefault(port)
                        ? AdvertisedEndpointState.Open
                        : results.ContainsKey(port) ? AdvertisedEndpointState.NoResponse : AdvertisedEndpointState.NotChecked
                }).ToArray();
        var added = updated.Where(item => item.Verification == AdvertisedEndpointState.Open && !known.Contains(item.Port!.Value))
            .GroupBy(item => item.Port!.Value)
            .Select(group => new OpenPort(group.Key, $"{group.First().ServiceLabel} (advertised)"));
        return (updated, openPorts.Concat(added).OrderBy(port => port.Port).ThenBy(port => port.Protocol).ToArray());
    }

    private Task<bool>? Reserve(IPAddress address, int port, CancellationToken cancellationToken)
    {
        lock (_gate)
        {
            if (_probes.TryGetValue((address, port), out var existing)) return existing;
            if (Started >= MaximumEndpointsPerScan) return null;
            Started++;
            var probe = ProbeAsync(address, port, cancellationToken);
            _probes[(address, port)] = probe;
            return probe;
        }
    }

    private async Task<bool> ProbeAsync(IPAddress address, int port, CancellationToken cancellationToken)
    {
        await _slots.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await _connect(address, port, cancellationToken).ConfigureAwait(false);
        }
        finally { _slots.Release(); }
    }

    private static async Task<bool> ConnectAsync(IPAddress address, int port, CancellationToken cancellationToken)
    {
        using var client = new TcpClient(address.AddressFamily);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(ConnectTimeout);
        try
        {
            await client.ConnectAsync(address, port, timeout.Token).ConfigureAwait(false);
            return true;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return false;
        }
        catch (SocketException)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return false;
        }
    }
}
