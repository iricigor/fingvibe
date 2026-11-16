using System.Net;
using FingVibe.App;
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

    [Fact]
    public void OnlinePeersUseScopedInventoryEvidenceNotNamesOrOtherNetworks()
    {
        const string profile = "selected-network";
        DeviceObservation Observation(string address, string? id = profile, bool present = true, string? subnet = null) =>
            new(id, subnet ?? Network.Cidr, address, "Never display this device name", "", new(), [], null,
                TimeSpan.Zero, DateTimeOffset.UnixEpoch, DateTimeOffset.UnixEpoch, DateTimeOffset.UnixEpoch, present);
        InventoryDevice Device(string mac, params DeviceObservation[] observations) => new(mac, new(), observations);
        var devices = new[]
        {
            Device("online", Observation("192.168.1.30")),
            Device("duplicate", Observation("192.168.1.30")),
            Device("offline", Observation("192.168.1.31", present: false)),
            Device("self", Observation(Network.LocalAddress.ToString())),
            Device("gateway", Observation(Network.GatewayAddress!.ToString())),
            Device("other-profile", Observation("192.168.1.32", id: "another-network")),
            Device("unscoped", Observation("192.168.1.33", id: null)),
            Device("other-subnet", Observation("192.168.2.34", subnet: "192.168.2.0/24")),
            Device("outside", Observation("192.168.2.35")),
            Device("ipv6", Observation("2001:db8::1")),
            Device("import-only"),
            Device("latest-offline", Observation("192.168.1.36"),
                Observation("192.168.1.37", present: false) with { LastChecked = DateTimeOffset.UnixEpoch.AddDays(1) }),
            Device("online-here", Observation("192.168.1.38"),
                Observation("192.168.1.39", id: "another-network", present: false) with
                { LastChecked = DateTimeOffset.UnixEpoch.AddDays(2) })
        };
        var inventory = DeviceInventoryData.Empty with { Devices = devices.ToDictionary(device => device.Mac) };
        Assert.Equal(new[] { "192.168.1.30", "192.168.1.38" },
            NetworkDiagnosticService.GetOnlinePeers(inventory, Network, profile).Select(address => address.ToString()).Order());
        Assert.Empty(NetworkDiagnosticService.GetOnlinePeers(inventory, Network, null));
    }

    [Fact]
    public async Task OnePeerIsFixedBeforeProgressAndPoolChangesAndSelectedAfreshEachRun()
    {
        var peers = new List<IPAddress> { IPAddress.Parse("192.168.1.30"), IPAddress.Parse("192.168.1.31") };
        var random = new SelectionRandom(0, 1, 1);
        var probes = new FakeProbes();
        var service = new NetworkDiagnosticService(probes, random);
        var progress = new InlineProgress
        {
            OnReport = item =>
            {
                if (item.Checkpoint == DiagnosticCheckpoint.Loopback && item.State == DiagnosticState.Running)
                    peers[0] = IPAddress.Parse("192.168.1.99");
            }
        };
        var first = await service.RunAsync(Network, null, progress, CancellationToken.None, peerCandidates: peers);
        Assert.Equal("192.168.1.30", Find(first, DiagnosticCheckpoint.LanPeer).Target);
        Assert.All(progress.Items.Where(item => item.Checkpoint == DiagnosticCheckpoint.LanPeer),
            item => Assert.Equal("192.168.1.30", item.Target));
        var second = await service.RunAsync(Network, null, null, CancellationToken.None, peerCandidates: peers);
        var third = await service.RunAsync(Network, null, null, CancellationToken.None, peerCandidates: peers);
        Assert.Equal("192.168.1.31", Find(second, DiagnosticCheckpoint.LanPeer).Target);
        Assert.Equal(Find(second, DiagnosticCheckpoint.LanPeer).Target, Find(third, DiagnosticCheckpoint.LanPeer).Target);
        Assert.Equal(3, random.Calls);
        Assert.Equal(new[] { "192.168.1.30", "192.168.1.31", "192.168.1.31" },
            probes.Targets.Where(item => item.Checkpoint == DiagnosticCheckpoint.LanPeer).Select(item => item.Address.ToString()));
        Assert.Equal(1, Find(first, DiagnosticCheckpoint.LanPeer).RoundtripMilliseconds);
    }

    [Fact]
    public async Task EmptyOrIneligiblePoolIsExplicitAndDoesNotStopOtherDiagnostics()
    {
        var probes = new FakeProbes();
        var report = await new NetworkDiagnosticService(probes).RunAsync(Network, null, null, CancellationToken.None,
            peerCandidates: [Network.LocalAddress, Network.GatewayAddress!, IPAddress.IPv6Loopback,
                IPAddress.Loopback, IPAddress.Parse("192.168.2.30"), Network.NetworkAddress, IPAddress.Parse("192.168.1.255")]);
        var peer = Find(report, DiagnosticCheckpoint.LanPeer);
        Assert.Equal(DiagnosticState.Unavailable, peer.State);
        Assert.Contains("Scan the selected LAN first", peer.Detail);
        Assert.DoesNotContain(probes.Targets, item => item.Checkpoint == DiagnosticCheckpoint.LanPeer);
        Assert.Equal(3, probes.DnsCalls.Count);
        Assert.Equal(DiagnosticSummaryKind.Good, NetworkDiagnosticInterpreter.Summarize(Network, report).Kind);
    }

    [Theory]
    [InlineData(DiagnosticState.Unanswered)]
    [InlineData(DiagnosticState.Error)]
    [InlineData(DiagnosticState.Unavailable)]
    public async Task PeerFailureAloneDoesNotMakeWorkingNetworkUnhealthy(DiagnosticState state)
    {
        var probes = new FakeProbes { PeerState = state };
        var report = await new NetworkDiagnosticService(probes).RunAsync(Network, null, null, CancellationToken.None,
            peerCandidates: [IPAddress.Parse("192.168.1.30")]);
        var peer = Find(report, DiagnosticCheckpoint.LanPeer);
        Assert.Equal(state, peer.State);
        Assert.Contains("Inconclusive", peer.Detail);
        Assert.Contains("asleep", peer.Detail);
        Assert.Contains("filter ICMP", peer.Detail);
        Assert.Contains("client isolation", peer.Detail);
        Assert.Null(peer.RoundtripMilliseconds);
        Assert.Single(probes.Targets, item => item.Checkpoint == DiagnosticCheckpoint.LanPeer);
        Assert.Equal(DiagnosticSummaryKind.Good, NetworkDiagnosticInterpreter.Summarize(Network, report).Kind);
    }

    [Fact]
    public async Task CancellationAtPeerRetainsPriorResultsAndStopsRemainingChecks()
    {
        using var cancellation = new CancellationTokenSource();
        var probes = new FakeProbes { BlockPeer = true };
        var run = new NetworkDiagnosticService(probes).RunAsync(Network, null, null, cancellation.Token,
            peerCandidates: [IPAddress.Parse("192.168.1.30")]);
        await probes.Started.Task.WaitAsync(TimeSpan.FromSeconds(2));
        cancellation.Cancel();
        var report = await run.WaitAsync(TimeSpan.FromSeconds(2));
        Assert.True(report.Cancelled);
        Assert.Equal(DiagnosticState.Responded, Find(report, DiagnosticCheckpoint.Gateway).State);
        Assert.Equal(DiagnosticState.Cancelled, Find(report, DiagnosticCheckpoint.LanPeer).State);
        Assert.Equal(DiagnosticState.Cancelled, Find(report, DiagnosticCheckpoint.ConfiguredDns).State);
        Assert.Single(probes.Targets, item => item.Checkpoint == DiagnosticCheckpoint.LanPeer);
        Assert.Empty(probes.DnsCalls);
        Assert.Empty(report.Hops);
    }

    [Fact]
    public async Task ReplacedNetworkRequestCannotRenderThePreviousPeerOutcome()
    {
        using var session = new AsyncSurfaceSession();
        var oldRequest = session.Start(Network.Cidr)!;
        var probes = new FakeProbes { BlockPeer = true };
        var oldRun = new NetworkDiagnosticService(probes).RunAsync(Network, null, null, oldRequest.CancellationToken,
            peerCandidates: [IPAddress.Parse("192.168.1.30")]);
        await probes.Started.Task.WaitAsync(TimeSpan.FromSeconds(2));
        var nextNetwork = Network with
        {
            LocalAddress = IPAddress.Parse("192.168.2.20"), NetworkAddress = IPAddress.Parse("192.168.2.0"),
            GatewayAddress = IPAddress.Parse("192.168.2.1")
        };
        var nextRequest = session.Start(nextNetwork.Cidr)!;
        var oldReport = await oldRun.WaitAsync(TimeSpan.FromSeconds(2));
        Assert.True(oldReport.Cancelled);
        Assert.False(session.Complete(oldRequest, AsyncSurfaceState.Ready,
            () => throw new InvalidOperationException("Stale peer rendering is forbidden.")));
        var nextReport = await new NetworkDiagnosticService(new FakeProbes()).RunAsync(
            nextNetwork, null, null, nextRequest.CancellationToken, peerCandidates: [IPAddress.Parse("192.168.2.40")]);
        string? rendered = null;
        Assert.True(session.Complete(nextRequest, AsyncSurfaceState.Ready,
            () => rendered = Find(nextReport, DiagnosticCheckpoint.LanPeer).Target));
        Assert.Equal("192.168.2.40", rendered);
        Assert.Contains(nextNetwork.Cidr, session.Status);
    }

    private static DiagnosticObservation Find(NetworkDiagnosticReport report, DiagnosticCheckpoint checkpoint) =>
        Assert.Single(report.Observations, item => item.Checkpoint == checkpoint);

    private sealed class InlineProgress : IProgress<DiagnosticObservation>
    {
        public List<DiagnosticObservation> Items { get; } = [];
        public Action<DiagnosticObservation>? OnReport { get; init; }
        public void Report(DiagnosticObservation value)
        {
            Items.Add(value);
            OnReport?.Invoke(value);
        }
    }

    private sealed class SelectionRandom(params int[] selections) : Random
    {
        public int Calls { get; private set; }
        public override int Next(int maxValue)
        {
            var value = selections[Calls++];
            Assert.InRange(value, 0, maxValue - 1);
            return value;
        }
    }

    private sealed class FakeProbes : INetworkDiagnosticProbes
    {
        public bool ReachDestination { get; init; } = true;
        public int DestinationHop { get; init; } = 3;
        public bool Block { get; init; }
        public bool BlockTrace { get; init; }
        public bool BlockPeer { get; init; }
        public DiagnosticState PeerState { get; init; } = DiagnosticState.Responded;
        public IPAddress? Hop2Address { get; init; }
        public int PingCalls { get; private set; }
        public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public List<(DiagnosticCheckpoint Checkpoint, IPAddress? Resolver)> DnsCalls { get; } = [];
        public List<(DiagnosticCheckpoint Checkpoint, IPAddress Address)> Targets { get; } = [];

        public async Task<DiagnosticObservation> PingAsync(DiagnosticCheckpoint checkpoint, IPAddress target, int ttl, CancellationToken cancellationToken)
        {
            PingCalls++;
            Targets.Add((checkpoint, target));
            var isTrace = checkpoint == DiagnosticCheckpoint.Hop2;
            if (Block || BlockTrace && isTrace || BlockPeer && checkpoint == DiagnosticCheckpoint.LanPeer)
            {
                Started.TrySetResult();
                await Task.Delay(Timeout.Infinite, cancellationToken);
            }
            var responded = !isTrace || (ttl != 2 || Hop2Address is not null) && ReachDestination;
            var address = !isTrace || ttl >= DestinationHop ? target : IPAddress.Parse("192.168.1.1");
            if (isTrace && ttl == 2 && Hop2Address is not null) address = Hop2Address;
            if (checkpoint == DiagnosticCheckpoint.LanPeer && PeerState != DiagnosticState.Responded)
                return new(checkpoint, target.ToString(), PeerState, "No peer response");
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
