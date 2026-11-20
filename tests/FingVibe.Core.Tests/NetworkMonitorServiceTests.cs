using System.Net;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class NetworkMonitorServiceTests
{
    private static readonly LanNetwork Network = new(
        "Ethernet",
        IPAddress.Parse("192.0.2.10"),
        IPAddress.Parse("192.0.2.0"),
        24,
        true,
        IPAddress.Parse("192.0.2.1"));

    [Fact]
    public async Task EachRoundUsesFiveSpacedPingsAndThenAllDnsSources()
    {
        var time = new FakeTimeProvider(new DateTimeOffset(2026, 11, 20, 1, 0, 0, TimeSpan.Zero));
        var probes = new RecordingProbes(time);
        var service = new NetworkMonitorService(probes, time);

        var run = service.RunAsync(Network, "network-id", CancellationToken.None);
        for (var sample = 1; sample <= NetworkMonitorService.SamplesPerTarget; sample++)
        {
            await WaitUntilAsync(() => probes.Pings.Count == sample * 3);
            if (sample < NetworkMonitorService.SamplesPerTarget)
            {
                time.Advance(NetworkMonitorService.SampleSpacing);
            }
        }

        var observation = await run.WaitAsync(ScanExecutionFixture.Timeout);

        Assert.False(observation.Cancelled);
        Assert.Equal("network-id", observation.NetworkId);
        Assert.Equal(Network.GatewayAddress, observation.Gateway);
        Assert.Equal(15, observation.PingSamples.Count);
        foreach (var target in Enum.GetValues<NetworkMonitorTarget>())
        {
            var samples = observation.PingSamples.Where(sample => sample.Target == target).ToArray();
            Assert.Equal(new[] { 1, 2, 3, 4, 5 }, samples.Select(sample => sample.Sequence));
            Assert.All(samples.Zip(samples.Skip(1)), pair =>
                Assert.Equal(TimeSpan.FromSeconds(1), pair.Second.StartedAt - pair.First.StartedAt));
        }
        Assert.Equal(
            [NetworkMonitorDnsSource.WindowsConfiguredOrCached, NetworkMonitorDnsSource.Cloudflare, NetworkMonitorDnsSource.Google],
            observation.DnsObservations.Select(item => item.Source));
        Assert.All(observation.DnsObservations, item => Assert.Equal(DiagnosticState.Responded, item.Observation.State));
    }

    [Fact]
    public async Task MissingGatewayIsUnavailableWithoutCancellingPublicChecks()
    {
        var time = new FakeTimeProvider();
        var service = new NetworkMonitorService(new RecordingProbes(time), time);
        var network = Network with { GatewayAddress = null };

        var run = service.RunAsync(network, null, CancellationToken.None);
        for (var second = 0; second < 4; second++)
        {
            await Task.Yield();
            time.Advance(NetworkMonitorService.SampleSpacing);
        }

        var observation = await run.WaitAsync(ScanExecutionFixture.Timeout);
        var gateway = observation.PingSamples.Where(item => item.Target == NetworkMonitorTarget.Gateway).ToArray();

        Assert.Equal(NetworkMonitorService.SamplesPerTarget, gateway.Length);
        Assert.All(gateway, item => Assert.Equal(DiagnosticState.Unavailable, item.Observation.State));
        Assert.Equal(IPAddress.None, observation.Gateway);
        Assert.Equal(2 * NetworkMonitorService.SamplesPerTarget,
            observation.PingSamples.Count(item => item.Target != NetworkMonitorTarget.Gateway));
    }

    [Fact]
    public async Task CancellationReturnsPartialRawEvidenceAsCancelled()
    {
        var time = new FakeTimeProvider();
        var probes = new RecordingProbes(time);
        var service = new NetworkMonitorService(probes, time);
        using var cancellation = new CancellationTokenSource();

        var run = service.RunAsync(Network, null, cancellation.Token);
        await WaitUntilAsync(() => probes.Pings.Count == 3);
        cancellation.Cancel();

        var observation = await run.WaitAsync(ScanExecutionFixture.Timeout);

        Assert.True(observation.Cancelled);
        Assert.Equal(3, observation.PingSamples.Count);
        Assert.Empty(observation.DnsObservations);
        Assert.Contains("no connectivity verdict", observation.Detail, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task CancellationKeepsSamplesCompletedWithinTheInterruptedRound()
    {
        var time = new FakeTimeProvider();
        var probes = new BlockingRoundProbes();
        var service = new NetworkMonitorService(probes, time);
        using var cancellation = new CancellationTokenSource();

        var run = service.RunAsync(Network, null, cancellation.Token);
        await WaitUntilAsync(() => probes.GatewayCompleted);
        cancellation.Cancel();

        var observation = await run.WaitAsync(ScanExecutionFixture.Timeout);

        Assert.True(observation.Cancelled);
        Assert.Single(observation.PingSamples);
        Assert.Equal(NetworkMonitorTarget.Gateway, observation.PingSamples[0].Target);
    }

    private static async Task WaitUntilAsync(Func<bool> condition)
    {
        for (var attempt = 0; attempt < 100 && !condition(); attempt++)
        {
            await Task.Yield();
        }

        Assert.True(condition());
    }

    private sealed class RecordingProbes(FakeTimeProvider time) : INetworkDiagnosticProbes
    {
        private readonly List<(DateTimeOffset At, IPAddress Target)> _pings = [];
        public IReadOnlyList<(DateTimeOffset At, IPAddress Target)> Pings
        {
            get
            {
                lock (_pings) return _pings.ToArray();
            }
        }

        public Task<DiagnosticObservation> PingAsync(
            DiagnosticCheckpoint checkpoint,
            IPAddress target,
            int ttl,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            lock (_pings) _pings.Add((time.GetUtcNow(), target));
            return Task.FromResult(
                new DiagnosticObservation(checkpoint, target.ToString(), DiagnosticState.Responded, "Reply.",
                    target, 1));
        }

        public Task<DiagnosticObservation> ResolveAsync(
            DiagnosticCheckpoint checkpoint,
            IPAddress? resolver,
            CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var target = $"{NetworkDiagnosticService.DnsHostname} via {resolver?.ToString() ?? "Windows configured or cached DNS"}";
            return Task.FromResult(
                new DiagnosticObservation(checkpoint, target, DiagnosticState.Responded, "Resolved.", IPAddress.Loopback, 1));
        }
    }

    private sealed class BlockingRoundProbes : INetworkDiagnosticProbes
    {
        public bool GatewayCompleted { get; private set; }

        public async Task<DiagnosticObservation> PingAsync(
            DiagnosticCheckpoint checkpoint,
            IPAddress target,
            int ttl,
            CancellationToken cancellationToken)
        {
            if (checkpoint == DiagnosticCheckpoint.Gateway)
            {
                GatewayCompleted = true;
                return new DiagnosticObservation(
                    checkpoint, target.ToString(), DiagnosticState.Responded, "Reply.", target, 1);
            }

            await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            throw new InvalidOperationException("Cancellation did not stop the blocked probe.");
        }

        public Task<DiagnosticObservation> ResolveAsync(
            DiagnosticCheckpoint checkpoint,
            IPAddress? resolver,
            CancellationToken cancellationToken) =>
            throw new InvalidOperationException("Pings should be cancelled before DNS starts.");
    }
}
