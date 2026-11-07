using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using FingVibe.Core.Models;

namespace FingVibe.Core.Networking;

internal readonly record struct IcmpEchoReply(IPStatus Status, long RoundtripTimeMilliseconds, int? Ttl);

public sealed class LanScannerService
{
    internal const int DefaultTimeoutMilliseconds = 700;
    internal const int DefaultMaximumConcurrency = 256;
    internal static readonly TimeSpan RetryPause = TimeSpan.FromSeconds(10);

    private readonly int _timeoutMilliseconds;
    private readonly int _maximumConcurrency;
    private readonly IScanResultEnricher _resultEnricher;
    private readonly Func<IPAddress, CancellationToken, Task<ScanDiscovery>> _discover;
    private readonly Func<IPAddress, int, Task<IcmpEchoReply>> _sendEcho;
    private readonly TimeProvider _timeProvider;
    private readonly Func<IPAddress, LanNetwork, CancellationToken, Task<PhysicalAddress?>> _arp;

    public LanScannerService(
        int timeoutMilliseconds = DefaultTimeoutMilliseconds,
        int maximumConcurrency = DefaultMaximumConcurrency,
        DeviceNameResolver? nameResolver = null,
        SsdpDiscoveryService? ssdpDiscovery = null,
        PortScannerService? portScanner = null,
        MacAddressResolver? macAddressResolver = null,
        IeeeVendorRegistry? vendorRegistry = null,
        IScanResultEnricher? resultEnricher = null,
        MdnsDeviceDiscoveryService? mdnsDiscovery = null)
        : this(
            timeoutMilliseconds,
            maximumConcurrency,
            resultEnricher ?? new ScanResultEnricher(nameResolver, portScanner, macAddressResolver, vendorRegistry),
            CreateDiscovery(ssdpDiscovery ?? new SsdpDiscoveryService(), mdnsDiscovery ?? new MdnsDeviceDiscoveryService()),
            SendPingAsync,
            TimeProvider.System,
            FreshArpProbe.ResolveAsync)
    {
    }

    internal LanScannerService(
        int timeoutMilliseconds,
        int maximumConcurrency,
        IScanResultEnricher resultEnricher,
        Func<IPAddress, CancellationToken, Task<ScanDiscovery>> discover,
        Func<IPAddress, int, Task<IcmpEchoReply>> sendEcho,
        TimeProvider timeProvider,
        Func<IPAddress, LanNetwork, CancellationToken, Task<PhysicalAddress?>>? arp = null)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(timeoutMilliseconds);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maximumConcurrency);
        _timeoutMilliseconds = timeoutMilliseconds;
        _maximumConcurrency = maximumConcurrency;
        _resultEnricher = resultEnricher;
        _discover = discover;
        _sendEcho = sendEcho;
        _timeProvider = timeProvider;
        _arp = arp ?? ((_, _, _) => Task.FromResult<PhysicalAddress?>(null));
    }

    public async Task<ScanSummary> ScanAsync(
        LanNetwork network,
        IProgress<ScanResult> resultProgress,
        IProgress<LanScanProgress>? scanProgress = null,
        CancellationToken cancellationToken = default,
        Func<IReadOnlyList<ScanResult>, ScanCheckpointState, Task>? checkpoint = null)
    {
        ArgumentNullException.ThrowIfNull(network);
        ArgumentNullException.ThrowIfNull(resultProgress);

        var total = SubnetCalculator.GetUsableHostCount(network.PrefixLength);
        var addresses = SubnetCalculator.EnumerateUsableHosts(network.NetworkAddress, network.PrefixLength).ToArray();
        var confirmed = new ScanResult?[addresses.Length];
        var alive = 0;
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        cancellationToken = lifetime.Token;
        var discoveryTask = _discover(network.LocalAddress, cancellationToken);
        using var enrichmentSlots = new SemaphoreSlim(32, 32);

        try
        {
            await ProbePhaseAsync(LanScanPhase.FirstPass, Enumerable.Range(0, addresses.Length).ToArray(), total, (index, result) =>
            {
                if (result.Status == HostStatus.Alive)
                {
                    confirmed[index] = result;
                    Interlocked.Increment(ref alive);
                    resultProgress.Report(result);
                }
            }).ConfigureAwait(false);

            await discoveryTask.ConfigureAwait(false);
            await CheckpointAsync().ConfigureAwait(false);
            var arpAddresses = Remaining();
            var arpCompleted = 0;
            if (arpAddresses.Length > 0)
                scanProgress?.Report(new LanScanProgress(LanScanPhase.Arp, 0, arpAddresses.Length));
            await Parallel.ForEachAsync(arpAddresses, new ParallelOptions
            {
                CancellationToken = cancellationToken,
                MaxDegreeOfParallelism = 8
            }, async (index, token) =>
            {
                var stopwatch = Stopwatch.StartNew();
                var mac = await _arp(addresses[index], network, token).ConfigureAwait(false);
                token.ThrowIfCancellationRequested();
                if (mac is not null)
                {
                    if (!MacAddressResolver.IsUsableNeighbor(mac.GetAddressBytes(), 5))
                        throw new InvalidOperationException($"Fresh ARP returned an invalid MAC for {addresses[index]}.");
                    var result = await EnrichAsync(addresses[index], network, discoveryTask, enrichmentSlots,
                        token, stopwatch.Elapsed, null, null, mac).ConfigureAwait(false);
                    token.ThrowIfCancellationRequested();
                    confirmed[index] = result;
                    Interlocked.Increment(ref alive);
                    resultProgress.Report(result);
                }
                var completedCount = Interlocked.Increment(ref arpCompleted);
                scanProgress?.Report(new LanScanProgress(LanScanPhase.Arp, completedCount, arpAddresses.Length));
            }).ConfigureAwait(false);

            if (arpAddresses.Length > 0)
                await CheckpointAsync().ConfigureAwait(false);
            for (var round = 0; round < 2 && Remaining().Length > 0; round++)
            {
                var retries = Remaining();
                var pause = Task.Delay(RetryPause, _timeProvider, cancellationToken);
                scanProgress?.Report(new LanScanProgress(
                    round == 0 ? LanScanPhase.RetryWait : LanScanPhase.FinalRetryWait, 0, retries.Length));
                await pause.ConfigureAwait(false);
                await ProbePhaseAsync(round == 0 ? LanScanPhase.Retry : LanScanPhase.FinalRetry,
                    retries, retries.Length, (index, result) =>
                {
                    if (result.Status == HostStatus.Alive)
                    {
                        confirmed[index] = result;
                        Interlocked.Increment(ref alive);
                        resultProgress.Report(result);
                    }
                }).ConfigureAwait(false);
                await CheckpointAsync(final: round == 1).ConfigureAwait(false);
            }

            cancellationToken.ThrowIfCancellationRequested();
            foreach (var index in Remaining())
                resultProgress.Report(new ScanResult(addresses[index], HostStatus.Unreachable, null, TimeSpan.Zero));
            return new ScanSummary(total, alive, total - alive);
        }
        finally
        {
            lifetime.Cancel();
            try { await discoveryTask.ConfigureAwait(false); }
            catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        }

        int[] Remaining() => Enumerable.Range(0, addresses.Length).Where(index => confirmed[index] is null).ToArray();

        async Task CheckpointAsync(bool final = false)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (checkpoint is not null)
                await checkpoint(confirmed.OfType<ScanResult>().ToArray(),
                    final || Remaining().Length == 0 ? ScanCheckpointState.Complete : ScanCheckpointState.Pending)
                    .ConfigureAwait(false);
        }

        Task ProbePhaseAsync(LanScanPhase phase, int[] indexes, int phaseTotal, Action<int, ScanResult> record)
        {
            var completed = 0;
            if (phase != LanScanPhase.FirstPass)
                scanProgress?.Report(new LanScanProgress(phase, 0, phaseTotal));
            return Parallel.ForEachAsync(
                indexes,
                new ParallelOptions
                {
                    CancellationToken = cancellationToken,
                    MaxDegreeOfParallelism = _maximumConcurrency
                },
                async (index, token) =>
                {
                    var result = await ProbeAsync(
                        addresses[index],
                        network,
                        discoveryTask,
                        enrichmentSlots,
                        token).ConfigureAwait(false);
                    token.ThrowIfCancellationRequested();
                    record(index, result);
                    var completedCount = Interlocked.Increment(ref completed);
                    scanProgress?.Report(new LanScanProgress(phase, completedCount, phaseTotal));
                });
        }
    }

    private static Func<IPAddress, CancellationToken, Task<ScanDiscovery>> CreateDiscovery(
        SsdpDiscoveryService ssdpDiscovery,
        MdnsDeviceDiscoveryService mdnsDiscovery) => async (localAddress, cancellationToken) =>
    {
        var ssdp = ssdpDiscovery.DiscoverDevicesAsync(cancellationToken, localAddress);
        var mdns = mdnsDiscovery.DiscoverNetworkAsync(localAddress, cancellationToken);
        await Task.WhenAll(ssdp, mdns).ConfigureAwait(false);
        return new ScanDiscovery(ssdp.Result, mdns.Result);
    };

    private static async Task<IcmpEchoReply> SendPingAsync(IPAddress address, int timeoutMilliseconds)
    {
        using var ping = new Ping();
        var reply = await ping.SendPingAsync(address, timeoutMilliseconds).ConfigureAwait(false);
        return new IcmpEchoReply(reply.Status, reply.RoundtripTime, reply.Options?.Ttl);
    }

    private async Task<ScanResult> ProbeAsync(
        IPAddress address,
        LanNetwork network,
        Task<ScanDiscovery> discoveryTask,
        SemaphoreSlim enrichmentSlots,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var stopwatch = Stopwatch.StartNew();

        try
        {
            var reply = await _sendEcho(address, _timeoutMilliseconds).ConfigureAwait(false);
            stopwatch.Stop();
            cancellationToken.ThrowIfCancellationRequested();

            if (reply.Status != IPStatus.Success)
            {
                return new ScanResult(address, HostStatus.Unreachable, null, stopwatch.Elapsed);
            }

            return await EnrichAsync(address, network, discoveryTask, enrichmentSlots, cancellationToken,
                stopwatch.Elapsed, reply.RoundtripTimeMilliseconds,
                address.Equals(network.GatewayAddress) ? null : reply.Ttl).ConfigureAwait(false);
        }
        catch (PingException)
        {
            stopwatch.Stop();
            return new ScanResult(address, HostStatus.Unreachable, null, stopwatch.Elapsed);
        }

    }

    private async Task<ScanResult> EnrichAsync(
        IPAddress address, LanNetwork network, Task<ScanDiscovery> discoveryTask,
        SemaphoreSlim enrichmentSlots, CancellationToken cancellationToken, TimeSpan duration,
        long? latency, int? ttl, PhysicalAddress? confirmedMac = null)
    {
        await enrichmentSlots.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var enrichment = await _resultEnricher.EnrichAsync(address, discoveryTask, cancellationToken,
                ttl, confirmedMac).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            return new ScanResult(address, HostStatus.Alive, latency, duration, enrichment.DeviceName,
                confirmedMac ?? enrichment.MacAddress, enrichment.VendorName, enrichment.OpenPorts,
                DeviceClassifier.ApplyNetworkContext(enrichment.Classification ?? DeviceClassification.Unknown, address, network));
        }
        finally { enrichmentSlots.Release(); }
    }
}
