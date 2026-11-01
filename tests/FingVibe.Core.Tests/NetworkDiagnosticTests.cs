using System.Net;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class NetworkDiagnosticTests
{
    private static readonly LanNetwork Network = new("LAN", IPAddress.Parse("192.168.1.20"), IPAddress.Parse("192.168.1.0"), 24, true, IPAddress.Parse("192.168.1.1"));

    private static NetworkDiagnosticReport Report(params (DiagnosticCheckpoint Checkpoint, DiagnosticState State)[] changes)
    {
        var observations = NetworkDiagnosticService.CreateCheckpoints(Network, IPAddress.Parse("203.0.113.10"))
            .Select(item => item with { State = DiagnosticState.Responded }).ToDictionary(item => item.Checkpoint);
        foreach (var (checkpoint, state) in changes)
            observations[checkpoint] = observations[checkpoint] with { State = state };
        return new(observations.Values.ToArray(), [], true, false);
    }

    [Fact]
    public void OptionalWanAndMissingIntermediateResponsesDoNotMakeWorkingInternetRed()
    {
        var summary = NetworkDiagnosticInterpreter.Summarize(Network, Report(
            (DiagnosticCheckpoint.RouterWan, DiagnosticState.Unanswered),
            (DiagnosticCheckpoint.Hop2, DiagnosticState.Unanswered)));
        Assert.Equal(DiagnosticSummaryKind.Good, summary.Kind);
        Assert.Equal("All good", summary.Status);
    }

    [Theory]
    [InlineData(DiagnosticState.Unanswered)]
    [InlineData(DiagnosticState.Unavailable)]
    public void MissingGatewayWithWorkingInternetIsNotExactFaultVerdict(DiagnosticState state)
    {
        var summary = NetworkDiagnosticInterpreter.Summarize(Network, Report((DiagnosticCheckpoint.Gateway, state)));
        Assert.Equal(DiagnosticSummaryKind.Warning, summary.Kind);
        Assert.Contains("filtering", summary.Explanation);
    }

    [Theory]
    [InlineData(DiagnosticCheckpoint.ConfiguredDns, "configured-DNS")]
    [InlineData(DiagnosticCheckpoint.CloudflareDns, "direct public-resolver")]
    [InlineData(DiagnosticCheckpoint.GoogleDns, "direct public-resolver")]
    public void DnsAndNumericReachabilityAreIndependent(DiagnosticCheckpoint checkpoint, string explanation)
    {
        var summary = NetworkDiagnosticInterpreter.Summarize(Network, Report((checkpoint, DiagnosticState.Unanswered)));
        Assert.Equal("DNS issues", summary.Status);
        Assert.Contains(explanation, summary.Explanation);
    }

    [Fact]
    public void NoExternalIcmpResponseDoesNotProveBrokenInternet()
    {
        var summary = NetworkDiagnosticInterpreter.Summarize(Network, Report(
            (DiagnosticCheckpoint.CloudflarePing, DiagnosticState.Unanswered),
            (DiagnosticCheckpoint.GooglePing, DiagnosticState.Unanswered)));
        Assert.Equal(DiagnosticSummaryKind.Warning, summary.Kind);
        Assert.Contains("Filtering", summary.Explanation);
        Assert.Contains("DNS responded", summary.Explanation);
    }

    [Fact]
    public void NeutralPartialAndNoAdapterStatesAreExplicit()
    {
        Assert.Equal(DiagnosticSummaryKind.Neutral, NetworkDiagnosticInterpreter.Summarize(Network, null).Kind);
        Assert.Equal(DiagnosticSummaryKind.Problem, NetworkDiagnosticInterpreter.Summarize(null, null).Kind);
        Assert.Equal(DiagnosticSummaryKind.Neutral, NetworkDiagnosticInterpreter.Summarize(Network, Report() with { Cancelled = true }).Kind);
        Assert.Equal(DiagnosticSummaryKind.Neutral, NetworkDiagnosticInterpreter.Summarize(Network, Report((DiagnosticCheckpoint.LocalAddress, DiagnosticState.Error))).Kind);
        Assert.Equal(DiagnosticSummaryKind.Neutral, NetworkDiagnosticInterpreter.Summarize(Network, Report(
            (DiagnosticCheckpoint.LocalAddress, DiagnosticState.Untested), (DiagnosticCheckpoint.ConfiguredDns, DiagnosticState.Unanswered))).Kind);
    }

    [Fact]
    public async Task MissingConfigurationAndUnansweredHop2ArePreservedWithLaterDestinationResponse()
    {
        var probes = new FakeProbes();
        var report = await new NetworkDiagnosticService(probes).RunAsync(
            Network with { GatewayAddress = null, HasGateway = false }, null, null, CancellationToken.None);
        Assert.Equal(DiagnosticState.Unavailable, Find(report, DiagnosticCheckpoint.Gateway).State);
        Assert.Equal(DiagnosticState.Unavailable, Find(report, DiagnosticCheckpoint.RouterWan).State);
        Assert.Equal(DiagnosticState.Unanswered, Find(report, DiagnosticCheckpoint.Hop2).State);
        Assert.Equal(3, report.Hops.Count);
        Assert.True(report.TraceComplete);
        Assert.True(report.Hops[2].ReachedDestination);
        Assert.Equal(3, probes.DnsCalls.Count);
        Assert.Contains(probes.DnsCalls, item => item.Resolver is null);
        Assert.Contains(probes.DnsCalls, item => NetworkDiagnosticService.Cloudflare.Equals(item.Resolver));
        Assert.Contains(probes.DnsCalls, item => NetworkDiagnosticService.Google.Equals(item.Resolver));
    }

    [Fact]
    public async Task TraceIsBoundedAndIncompleteWhenDestinationNeverResponds()
    {
        var probes = new FakeProbes { ReachDestination = false };
        var report = await new NetworkDiagnosticService(probes).RunAsync(Network, null, null, CancellationToken.None);
        Assert.Equal(NetworkDiagnosticService.MaximumHops, report.Hops.Count);
        Assert.False(report.TraceComplete);
    }

    [Fact]
    public async Task DestinationAtFirstHopDoesNotInventHop2Router()
    {
        var report = await new NetworkDiagnosticService(new FakeProbes { DestinationHop = 1 })
            .RunAsync(Network, null, null, CancellationToken.None);
        Assert.Single(report.Hops);
        Assert.Equal(DiagnosticState.Unavailable, Find(report, DiagnosticCheckpoint.Hop2).State);
    }

    [Fact]
    public async Task ObservedHop2PreservesResponderRatherThanTraceTarget()
    {
        var report = await new NetworkDiagnosticService(new FakeProbes { Hop2Address = IPAddress.Parse("100.79.10.1") })
            .RunAsync(Network, null, null, CancellationToken.None);
        var hop2 = Find(report, DiagnosticCheckpoint.Hop2);
        Assert.Equal(IPAddress.Parse("100.79.10.1"), hop2.RespondingAddress);
        Assert.Equal("1.1.1.1", hop2.Target);
        Assert.False(report.Hops[1].ReachedDestination);
        Assert.Equal(hop2.RespondingAddress, report.Hops[1].Observation.RespondingAddress);
    }

    [Fact]
    public async Task ActualDestinationResponseAtHop2IsNotReplacedByGuessedRouter()
    {
        var report = await new NetworkDiagnosticService(new FakeProbes
        {
            Hop2Address = NetworkDiagnosticService.Cloudflare, DestinationHop = 2
        }).RunAsync(Network, null, null, CancellationToken.None);
        Assert.Equal(2, report.Hops.Count);
        Assert.True(report.TraceComplete);
        Assert.Equal(NetworkDiagnosticService.Cloudflare, Find(report, DiagnosticCheckpoint.Hop2).RespondingAddress);
    }

    [Fact]
    public async Task CancellationStopsActiveProbeAndMarksUntestedCheckpointsCancelled()
    {
        using var cancellation = new CancellationTokenSource();
        var probes = new FakeProbes { Block = true };
        var run = new NetworkDiagnosticService(probes).RunAsync(Network, null, null, cancellation.Token);
        await probes.Started.Task.WaitAsync(TimeSpan.FromSeconds(2));
        cancellation.Cancel();
        var report = await run.WaitAsync(TimeSpan.FromSeconds(2));
        Assert.True(report.Cancelled);
        Assert.Equal(DiagnosticState.Cancelled, Find(report, DiagnosticCheckpoint.Loopback).State);
        Assert.Equal(DiagnosticState.Cancelled, Find(report, DiagnosticCheckpoint.ConfiguredDns).State);
        Assert.Equal(DiagnosticState.Unavailable, Find(report, DiagnosticCheckpoint.RouterWan).State);
        Assert.Equal(1, probes.PingCalls);
        Assert.Empty(report.Hops);
    }

    [Fact]
    public async Task AlreadyCancelledRunSendsNoProbes()
    {
        var probes = new FakeProbes();
        var report = await new NetworkDiagnosticService(probes).RunAsync(Network, null, null, new CancellationToken(true));
        Assert.True(report.Cancelled);
        Assert.Equal(0, probes.PingCalls);
    }

    [Fact]
    public async Task CancellationDuringTraceRetainsCompletedDnsAndIpResults()
    {
        using var cancellation = new CancellationTokenSource();
        var probes = new FakeProbes { BlockTrace = true };
        var run = new NetworkDiagnosticService(probes).RunAsync(Network, null, null, cancellation.Token);
        await probes.Started.Task.WaitAsync(TimeSpan.FromSeconds(2));
        cancellation.Cancel();
        var report = await run.WaitAsync(TimeSpan.FromSeconds(2));
        Assert.True(report.Cancelled);
        Assert.Equal(DiagnosticState.Responded, Find(report, DiagnosticCheckpoint.CloudflarePing).State);
        Assert.Equal(DiagnosticState.Responded, Find(report, DiagnosticCheckpoint.ConfiguredDns).State);
        Assert.Equal(DiagnosticState.Cancelled, Find(report, DiagnosticCheckpoint.Hop2).State);
        Assert.Empty(report.Hops);
    }

    [Fact]
    public void MissingCheckpointReportCannotBeShownAsAllGood()
    {
        var report = Report();
        Assert.Equal(DiagnosticSummaryKind.Neutral, NetworkDiagnosticInterpreter.Summarize(Network,
            report with { Observations = report.Observations.Where(item => item.Checkpoint != DiagnosticCheckpoint.ConfiguredDns).ToArray() }).Kind);
    }

    [Fact]
    public async Task ProgressDistinguishesRunningAndObservedOutcomes()
    {
        var progress = new InlineProgress();
        await new NetworkDiagnosticService(new FakeProbes()).RunAsync(Network, null, progress, CancellationToken.None);
        Assert.Contains(progress.Items, item => item.Checkpoint == DiagnosticCheckpoint.CloudflareDns && item.State == DiagnosticState.Running);
        Assert.Contains(progress.Items, item => item.Checkpoint == DiagnosticCheckpoint.CloudflareDns && item.State == DiagnosticState.Responded);
    }

    private static DiagnosticObservation Find(NetworkDiagnosticReport report, DiagnosticCheckpoint checkpoint) =>
        Assert.Single(report.Observations, item => item.Checkpoint == checkpoint);

    private sealed class InlineProgress : IProgress<DiagnosticObservation>
    {
        public List<DiagnosticObservation> Items { get; } = [];
        public void Report(DiagnosticObservation value) => Items.Add(value);
    }

    private sealed class FakeProbes : INetworkDiagnosticProbes
    {
        public bool ReachDestination { get; init; } = true;
        public int DestinationHop { get; init; } = 3;
        public bool Block { get; init; }
        public bool BlockTrace { get; init; }
        public IPAddress? Hop2Address { get; init; }
        public int PingCalls { get; private set; }
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public List<(DiagnosticCheckpoint Checkpoint, IPAddress? Resolver)> DnsCalls { get; } = [];

        public async Task<DiagnosticObservation> PingAsync(DiagnosticCheckpoint checkpoint, IPAddress target, int ttl, CancellationToken cancellationToken)
        {
            PingCalls++;
            var isTrace = checkpoint == DiagnosticCheckpoint.Hop2;
            if (Block || BlockTrace && isTrace)
            {
                Started.TrySetResult();
                await Task.Delay(Timeout.Infinite, cancellationToken);
            }
            var responded = !isTrace || (ttl != 2 || Hop2Address is not null) && ReachDestination;
            var address = !isTrace || ttl >= DestinationHop ? target : IPAddress.Parse("192.168.1.1");
            if (isTrace && ttl == 2 && Hop2Address is not null) address = Hop2Address;
            return new(checkpoint, target.ToString(), responded ? DiagnosticState.Responded : DiagnosticState.Unanswered,
                responded ? "Response" : "TimedOut", responded ? address : null, responded ? 1 : null);
        }

        public Task<DiagnosticObservation> ResolveAsync(DiagnosticCheckpoint checkpoint, IPAddress? resolver, CancellationToken cancellationToken)
        {
            DnsCalls.Add((checkpoint, resolver));
            return Task.FromResult(new DiagnosticObservation(checkpoint, NetworkDiagnosticService.DnsHostname,
                DiagnosticState.Responded, "Resolved", IPAddress.Parse("93.184.215.14"), 1));
        }
    }
}
