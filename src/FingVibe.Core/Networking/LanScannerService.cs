using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using FingVibe.Core.Models;

namespace FingVibe.Core.Networking;

public sealed class LanScannerService
{
    private readonly int _timeoutMilliseconds;
    private readonly int _maximumConcurrency;

    public LanScannerService(int timeoutMilliseconds = 700, int maximumConcurrency = 256)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(timeoutMilliseconds);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(maximumConcurrency);
        _timeoutMilliseconds = timeoutMilliseconds;
        _maximumConcurrency = maximumConcurrency;
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

        await Parallel.ForEachAsync(
            addresses,
            new ParallelOptions
            {
                CancellationToken = cancellationToken,
                MaxDegreeOfParallelism = _maximumConcurrency
            },
            async (address, token) =>
            {
                var result = await ProbeAsync(address, token).ConfigureAwait(false);
                if (result.Status == HostStatus.Alive)
                {
                    Interlocked.Increment(ref alive);
                }

                resultProgress.Report(result);
                var completedCount = Interlocked.Increment(ref completed);
                scanProgress?.Report(new ScanProgress(completedCount, total));
            }).ConfigureAwait(false);

        return new ScanSummary(total, alive, total - alive);
    }

    private async Task<ScanResult> ProbeAsync(IPAddress address, CancellationToken cancellationToken)
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
                return new ScanResult(address, HostStatus.Unreachable, null, null, stopwatch.Elapsed);
            }

            var macAddress = MacAddressResolver.TryResolve(address);
            return new ScanResult(address, HostStatus.Alive, reply.RoundtripTime, macAddress, stopwatch.Elapsed);
        }
        catch (PingException)
        {
            stopwatch.Stop();
            return new ScanResult(address, HostStatus.Unreachable, null, null, stopwatch.Elapsed);
        }
    }
}
