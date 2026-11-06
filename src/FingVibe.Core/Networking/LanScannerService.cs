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
    internal static readonly TimeSpan RetryPause = TimeSpan.FromSeconds(1);

    private readonly int _timeoutMilliseconds;
    private readonly int _maximumConcurrency;
    private readonly IScanResultEnricher _resultEnricher;
    private readonly Func<IPAddress, CancellationToken, Task<ScanDiscovery>> _discover;
    private readonly Func<IPAddress, int, Task<IcmpEchoReply>> _sendEcho;
    private readonly TimeProvider _timeProvider;

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
            TimeProvider.System)
    {
    }

    internal LanScannerService(
        int timeoutMilliseconds,
        int maximumConcurrency,
        IScanResultEnricher resultEnricher,
        Func<IPAddress, CancellationToken, Task<ScanDiscovery>> discover,
        Func<IPAddress, int, Task<IcmpEchoReply>> sendEcho,
        TimeProvider timeProvider)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(timeoutMilliseconds);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maximumConcurrency);
        _timeoutMilliseconds = timeoutMilliseconds;
        _maximumConcurrency = maximumConcurrency;
        _resultEnricher = resultEnricher;
        _discover = discover;
        _sendEcho = sendEcho;
        _timeProvider = timeProvider;
    }

    // Probes every usable address once, then, after a cancellable pause, probes each first-pass miss exactly once
    // more with the same settings. Each address is reported once with its final outcome: first-pass responders
    // immediately, misses only after their retry. Only a fresh reply during this scan counts as Alive.
    public async Task<ScanSummary> ScanAsync(
        LanNetwork network,
        IProgress<ScanResult> resultProgress,
        IProgress<LanScanProgress>? scanProgress = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(network);
        ArgumentNullException.ThrowIfNull(resultProgress);

        var total = SubnetCalculator.GetUsableHostCount(network.PrefixLength);
        var addresses = SubnetCalculator.EnumerateUsableHosts(network.NetworkAddress, network.PrefixLength).ToArray();
        var missed = new bool[addresses.Length];
        var alive = 0;
        var discoveryTask = _discover(network.LocalAddress, cancellationToken);
        using var enrichmentSlots = new SemaphoreSlim(32, 32);

        await ProbePhaseAsync(LanScanPhase.FirstPass, Enumerable.Range(0, addresses.Length).ToArray(), total, (index, result) =>
        {
            if (result.Status == HostStatus.Alive)
            {
                Interlocked.Increment(ref alive);
                resultProgress.Report(result);
            }
            else
            {
                missed[index] = true;
            }
        }).ConfigureAwait(false);

        var retries = Enumerable.Range(0, addresses.Length).Where(index => missed[index]).ToArray();
        if (retries.Length > 0)
        {
            // The pause timer starts before the phase is announced, so observers never race the wait.
            var pause = Task.Delay(RetryPause, _timeProvider, cancellationToken);
            scanProgress?.Report(new LanScanProgress(LanScanPhase.Retry, 0, retries.Length));
            await pause.ConfigureAwait(false);
            await ProbePhaseAsync(LanScanPhase.Retry, retries, retries.Length, (_, result) =>
            {
                if (result.Status == HostStatus.Alive)
                {
                    Interlocked.Increment(ref alive);
                }

                resultProgress.Report(result);
            }).ConfigureAwait(false);
        }

        await discoveryTask.ConfigureAwait(false);
        return new ScanSummary(total, alive, total - alive);

        Task ProbePhaseAsync(LanScanPhase phase, int[] indexes, int phaseTotal, Action<int, ScanResult> record)
        {
            var completed = 0;
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

            await enrichmentSlots.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                var responseTtl = address.Equals(network.GatewayAddress) ? null : reply.Ttl;
                var enrichment = await _resultEnricher
                    .EnrichAsync(address, discoveryTask, cancellationToken, responseTtl)
                    .ConfigureAwait(false);

                return new ScanResult(
                    address,
                    HostStatus.Alive,
                    reply.RoundtripTimeMilliseconds,
                    stopwatch.Elapsed,
                    enrichment.DeviceName,
                    enrichment.MacAddress,
                    enrichment.VendorName,
                    enrichment.OpenPorts,
                    DeviceClassifier.ApplyNetworkContext(
                        enrichment.Classification ?? DeviceClassification.Unknown, address, network));
            }
            finally
            {
                enrichmentSlots.Release();
            }
        }
        catch (PingException)
        {
            stopwatch.Stop();
            return new ScanResult(address, HostStatus.Unreachable, null, stopwatch.Elapsed);
        }
    }
}
