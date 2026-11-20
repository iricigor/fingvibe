using System.Net;
using FingVibe.Core.Models;

namespace FingVibe.Core.Networking;

public sealed class NetworkMonitorService(
    INetworkDiagnosticProbes probes,
    TimeProvider? timeProvider = null)
{
    public const int SamplesPerTarget = 5;
    public static readonly TimeSpan SampleSpacing = TimeSpan.FromSeconds(1);

    private readonly TimeProvider _time = timeProvider ?? TimeProvider.System;

    public async Task<NetworkMonitorObservation> RunAsync(
        LanNetwork? network,
        string? networkId,
        CancellationToken cancellationToken)
    {
        var startedAt = _time.GetUtcNow();
        var pingSamples = new List<NetworkMonitorPingSample>();
        var dnsObservations = new List<NetworkMonitorDnsObservation>();
        var cancelled = false;
        var detail = "Raw network observations completed.";

        try
        {
            for (var sequence = 1; sequence <= SamplesPerTarget; sequence++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var roundStartedAt = _time.GetUtcNow();
                var targets = new (NetworkMonitorTarget, DiagnosticCheckpoint, IPAddress?)[]
                {
                    (NetworkMonitorTarget.Gateway, DiagnosticCheckpoint.Gateway, network?.GatewayAddress),
                    (NetworkMonitorTarget.Cloudflare, DiagnosticCheckpoint.CloudflarePing, NetworkDiagnosticService.Cloudflare),
                    (NetworkMonitorTarget.Google, DiagnosticCheckpoint.GooglePing, NetworkDiagnosticService.Google)
                };
                await Task.WhenAll(targets.Select(async target =>
                {
                    var sample = await ProbeAsync(target.Item1, target.Item2, target.Item3, sequence,
                        cancellationToken).ConfigureAwait(false);
                    lock (pingSamples)
                    {
                        pingSamples.Add(sample);
                    }
                })).ConfigureAwait(false);
                if (sequence < SamplesPerTarget)
                {
                    var remaining = SampleSpacing - (_time.GetUtcNow() - roundStartedAt);
                    if (remaining > TimeSpan.Zero)
                    {
                        await Task.Delay(remaining, _time, cancellationToken).ConfigureAwait(false);
                    }
                }
            }

            var sources = new (NetworkMonitorDnsSource, DiagnosticCheckpoint, IPAddress?)[]
            {
                (NetworkMonitorDnsSource.WindowsConfiguredOrCached, DiagnosticCheckpoint.ConfiguredDns, null),
                (NetworkMonitorDnsSource.Cloudflare, DiagnosticCheckpoint.CloudflareDns, NetworkDiagnosticService.Cloudflare),
                (NetworkMonitorDnsSource.Google, DiagnosticCheckpoint.GoogleDns, NetworkDiagnosticService.Google)
            };
            await Task.WhenAll(sources.Select(async source =>
            {
                var observation = await ResolveAsync(
                    source.Item1, source.Item2, source.Item3, cancellationToken).ConfigureAwait(false);
                lock (dnsObservations)
                {
                    dnsObservations.Add(observation);
                }
            })).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            cancelled = true;
            detail = "Cancelled; completed raw observations are retained and no connectivity verdict was calculated.";
        }

        return new(
            startedAt,
            _time.GetUtcNow(),
            networkId,
            network?.GatewayAddress ?? IPAddress.None,
            pingSamples.OrderBy(item => item.Sequence).ThenBy(item => item.Target).ToArray(),
            dnsObservations.OrderBy(item => item.Source).ToArray(),
            cancelled,
            detail);
    }

    private async Task<NetworkMonitorPingSample> ProbeAsync(
        NetworkMonitorTarget target,
        DiagnosticCheckpoint checkpoint,
        IPAddress? address,
        int sequence,
        CancellationToken cancellationToken)
    {
        var startedAt = _time.GetUtcNow();
        DiagnosticObservation observation;
        if (address is null)
        {
            observation = new(
                checkpoint,
                "Not available",
                DiagnosticState.Unavailable,
                "The selected network did not report a gateway address.");
        }
        else
        {
            observation = await probes.PingAsync(
                checkpoint, address, 128, cancellationToken).ConfigureAwait(false);
        }

        return new(target, sequence, startedAt, _time.GetUtcNow(), observation);
    }

    private async Task<NetworkMonitorDnsObservation> ResolveAsync(
        NetworkMonitorDnsSource source,
        DiagnosticCheckpoint checkpoint,
        IPAddress? resolver,
        CancellationToken cancellationToken)
    {
        var startedAt = _time.GetUtcNow();
        var observation = await probes.ResolveAsync(checkpoint, resolver, cancellationToken).ConfigureAwait(false);
        return new(source, startedAt, _time.GetUtcNow(), observation);
    }
}
