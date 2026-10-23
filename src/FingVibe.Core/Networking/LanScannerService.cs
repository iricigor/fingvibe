using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using FingVibe.Core.Models;

namespace FingVibe.Core.Networking;

public sealed class LanScannerService
{
    private readonly int _timeoutMilliseconds;
    private readonly int _maximumConcurrency;
    private readonly SsdpDiscoveryService _ssdpDiscovery;
    private readonly IScanResultEnricher _resultEnricher;

    public LanScannerService(
        int timeoutMilliseconds = 700,
        int maximumConcurrency = 256,
        DeviceNameResolver? nameResolver = null,
        SsdpDiscoveryService? ssdpDiscovery = null,
        PortScannerService? portScanner = null,
        MacAddressResolver? macAddressResolver = null,
        IeeeVendorRegistry? vendorRegistry = null,
        IScanResultEnricher? resultEnricher = null)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(timeoutMilliseconds);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maximumConcurrency);
        _timeoutMilliseconds = timeoutMilliseconds;
        _maximumConcurrency = maximumConcurrency;
        _ssdpDiscovery = ssdpDiscovery ?? new SsdpDiscoveryService();
        _resultEnricher = resultEnricher ?? new ScanResultEnricher(
            nameResolver,
            portScanner,
            macAddressResolver,
            vendorRegistry);
    }

    public async Task<ScanSummary> ScanAsync(
        LanNetwork network,
        IProgress<ScanResult> resultProgress,
        IProgress<ScanProgress>? scanProgress = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(network);
        ArgumentNullException.ThrowIfNull(resultProgress);

        var total = SubnetCalculator.GetUsableHostCount(network.PrefixLength);
        var addresses = SubnetCalculator.EnumerateUsableHosts(network.NetworkAddress, network.PrefixLength);
        var completed = 0;
        var alive = 0;
        var ssdpNamesTask = _ssdpDiscovery.DiscoverNamesAsync(cancellationToken);
        using var enrichmentSlots = new SemaphoreSlim(32, 32);

        await Parallel.ForEachAsync(
            addresses,
            new ParallelOptions
            {
                CancellationToken = cancellationToken,
                MaxDegreeOfParallelism = _maximumConcurrency
            },
            async (address, token) =>
            {
                var result = await ProbeAsync(
                    address,
                    ssdpNamesTask,
                    enrichmentSlots,
                    token).ConfigureAwait(false);
                if (result.Status == HostStatus.Alive)
                {
                    Interlocked.Increment(ref alive);
                }

                resultProgress.Report(result);
                var completedCount = Interlocked.Increment(ref completed);
                scanProgress?.Report(new ScanProgress(completedCount, total));
            }).ConfigureAwait(false);

        await ssdpNamesTask.ConfigureAwait(false);
        return new ScanSummary(total, alive, total - alive);
    }

    private async Task<ScanResult> ProbeAsync(
        IPAddress address,
        Task<IReadOnlyDictionary<IPAddress, string>> ssdpNamesTask,
        SemaphoreSlim enrichmentSlots,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var ping = new Ping();
        var stopwatch = Stopwatch.StartNew();

        try
        {
            var reply = await ping.SendPingAsync(address, _timeoutMilliseconds).ConfigureAwait(false);
            stopwatch.Stop();
            cancellationToken.ThrowIfCancellationRequested();

            if (reply.Status != IPStatus.Success)
            {
                return new ScanResult(address, HostStatus.Unreachable, null, stopwatch.Elapsed);
            }

            await enrichmentSlots.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                var enrichment = await _resultEnricher
                    .EnrichAsync(address, ssdpNamesTask, cancellationToken)
                    .ConfigureAwait(false);

                return new ScanResult(
                    address,
                    HostStatus.Alive,
                    reply.RoundtripTime,
                    stopwatch.Elapsed,
                    enrichment.DeviceName,
                    enrichment.MacAddress,
                    enrichment.VendorName,
                    enrichment.OpenPorts);
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
