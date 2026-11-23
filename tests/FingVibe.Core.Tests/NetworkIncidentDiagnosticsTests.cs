using System.Net;
using FingVibe.App;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class NetworkIncidentDiagnosticsTests
{
    private static readonly DateTimeOffset Start = NetworkIncidentTrackerTests.Start;
    private static readonly LanNetwork Network = new("Wi-Fi", IPAddress.Parse("192.0.2.10"), IPAddress.Parse("192.0.2.0"), 24,
        true, IPAddress.Parse("192.0.2.1"));

    private static readonly NetworkIncident Incident = new(Guid.NewGuid(), NetworkIncidentTrackerTests.Context, "Wi-Fi",
        Start, Start.AddSeconds(30))
    {
        Symptoms = [new(NetworkHealthSymptomKind.WindowsDnsFailed, null, "Windows DNS did not resolve example.com", Start)],
        LastObservedAt = Start.AddSeconds(30)
    };

    [Fact]
    public async Task CompletedRunRecordsEveryCheckpointTraceAndSummaryWithoutProbingAPeer()
    {
        var time = new FakeTimeProvider(Start);
        var diagnostics = new NetworkIncidentDiagnostics(
            new NetworkDiagnosticService(NetworkMonitorReviewFixture.DiagnosticProbes), time);
        var started = diagnostics.Begin(Incident);
        Assert.Equal((NetworkEvidenceOutcome.Running, Incident.Id, Start, (DateTimeOffset?)null),
            (started.Outcome, started.IncidentId, started.StartedAt, started.CompletedAt));

        var evidence = await diagnostics.RunAsync(started, Network, () => "unused", CancellationToken.None);

        Assert.Equal((NetworkEvidenceOutcome.Complete, "", true, 3), (evidence.Outcome, evidence.Detail, evidence.TraceComplete, evidence.Hops.Count));
        Assert.Equal(Enum.GetValues<DiagnosticCheckpoint>().Length, evidence.Observations.Count);
        Assert.Equal(DiagnosticState.Unavailable,
            evidence.Observations.Single(item => item.Checkpoint == DiagnosticCheckpoint.LanPeer).State);
        Assert.Equal((DiagnosticSummaryKind.Good, "Checks passed"), (evidence.SummaryKind, evidence.SummaryStatus));
        Assert.Equal((Incident.ContextKey, Incident.NetworkLabel), (evidence.ContextKey, evidence.NetworkLabel));
    }

    [Fact]
    public async Task FortyFiveSecondLimitKeepsCompletedChecksAsPartial()
    {
        var time = new FakeTimeProvider(Start);
        var probes = new BlockingTraceProbes();
        var diagnostics = new NetworkIncidentDiagnostics(new NetworkDiagnosticService(probes), time);
        var run = diagnostics.RunAsync(diagnostics.Begin(Incident), Network, () => "unused", CancellationToken.None);
        await probes.TraceStarted.Task.WaitAsync(TimeSpan.FromSeconds(10));
        time.Advance(NetworkIncidentDiagnostics.Limit - TimeSpan.FromSeconds(1));
        Assert.False(run.IsCompleted);
        time.Advance(TimeSpan.FromSeconds(1));
        var evidence = await run.WaitAsync(TimeSpan.FromSeconds(10));

        Assert.Equal((NetworkEvidenceOutcome.Partial, NetworkIncidentDiagnostics.LimitReason, (DateTimeOffset?)Start.AddSeconds(45)),
            (evidence.Outcome, evidence.Detail, evidence.CompletedAt));
        Assert.Equal(DiagnosticState.Responded,
            evidence.Observations.Single(item => item.Checkpoint == DiagnosticCheckpoint.GooglePing).State);
        Assert.Equal(DiagnosticState.Cancelled,
            evidence.Observations.Single(item => item.Checkpoint == DiagnosticCheckpoint.Hop2).State);
        Assert.Equal("Cancelled / partial results", evidence.SummaryStatus);
    }

    [Fact]
    public async Task InterruptionRecordsItsReasonAndPublishesProgress()
    {
        var probes = new BlockingTraceProbes();
        var diagnostics = new NetworkIncidentDiagnostics(new NetworkDiagnosticService(probes), new FakeTimeProvider(Start));
        using var stop = new CancellationTokenSource();
        var snapshots = new List<NetworkIncidentEvidence>();
        var run = diagnostics.RunAsync(diagnostics.Begin(Incident), Network, () => "a manual LAN scan took priority",
            stop.Token, snapshots.Add);
        await probes.TraceStarted.Task.WaitAsync(TimeSpan.FromSeconds(10));
        stop.Cancel();
        var evidence = await run.WaitAsync(TimeSpan.FromSeconds(10));

        Assert.Equal(NetworkEvidenceOutcome.Partial, evidence.Outcome);
        Assert.Equal("Interrupted because a manual LAN scan took priority. Completed checks were saved; it is not retried automatically.",
            evidence.Detail);
        Assert.Contains(snapshots, item => item.Observations.Any(observation =>
            observation.Checkpoint == DiagnosticCheckpoint.ConfiguredDns && observation.State == DiagnosticState.Responded));
    }

    [Fact]
    public async Task ProbeErrorIsSavedAsFailedWithCompletedChecks()
    {
        var diagnostics = new NetworkIncidentDiagnostics(new NetworkDiagnosticService(new BlockingTraceProbes { Fail = true }),
            new FakeTimeProvider(Start));
        var evidence = await diagnostics.RunAsync(diagnostics.Begin(Incident), Network, () => "unused", CancellationToken.None);

        Assert.Equal(NetworkEvidenceOutcome.Failed, evidence.Outcome);
        Assert.StartsWith("Deeper diagnostics failed: Trace unavailable.", evidence.Detail);
        Assert.Contains(evidence.Observations, item => item.Checkpoint == DiagnosticCheckpoint.GoogleDns
            && item.State == DiagnosticState.Responded);
        Assert.Contains(evidence.Observations, item => item.State == DiagnosticState.Error);
    }

    [Fact]
    public async Task ABackwardClockStepNeverEndsEvidenceBeforeItStarted()
    {
        var diagnostics = new NetworkIncidentDiagnostics(
            new NetworkDiagnosticService(NetworkMonitorReviewFixture.DiagnosticProbes), new SteppingBackClock(Start));
        var started = diagnostics.Begin(Incident);
        var evidence = await diagnostics.RunAsync(started, Network, () => "unused", CancellationToken.None);
        Assert.Equal((NetworkEvidenceOutcome.Complete, (DateTimeOffset?)started.StartedAt), (evidence.Outcome, evidence.CompletedAt));
    }

    private sealed class SteppingBackClock(DateTimeOffset start) : TimeProvider
    {
        private int _calls;
        public override DateTimeOffset GetUtcNow() => start.AddSeconds(-5 * _calls++);
    }

    [Fact]
    public void ARunningRecordFromAClosedAppBecomesPartial()
    {
        var running = new NetworkIncidentEvidence(Incident.Id, Incident.ContextKey, "Wi-Fi", Start)
        {
            Observations = [new(DiagnosticCheckpoint.Gateway, "192.0.2.1", DiagnosticState.Running, "Checking...")]
        };
        var closed = running.Interrupted("FingVibe closed", Start.AddSeconds(5));
        Assert.Equal((NetworkEvidenceOutcome.Partial, (DateTimeOffset?)Start.AddSeconds(5), DiagnosticState.Cancelled),
            (closed.Outcome, closed.CompletedAt, closed.Observations[0].State));
    }

    private sealed class BlockingTraceProbes : INetworkDiagnosticProbes
    {
        public bool Fail { get; init; }
        public TaskCompletionSource TraceStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public async Task<DiagnosticObservation> PingAsync(
            DiagnosticCheckpoint checkpoint, IPAddress target, int ttl, CancellationToken cancellationToken)
        {
            if (checkpoint == DiagnosticCheckpoint.Hop2)
            {
                if (Fail) throw new InvalidOperationException("Trace unavailable.");
                TraceStarted.TrySetResult();
                await Task.Delay(Timeout.Infinite, cancellationToken);
            }
            return new(checkpoint, target.ToString(), DiagnosticState.Responded, "Response", target, 2);
        }

        public Task<DiagnosticObservation> ResolveAsync(
            DiagnosticCheckpoint checkpoint, IPAddress? resolver, CancellationToken cancellationToken) =>
            Task.FromResult(new DiagnosticObservation(checkpoint, NetworkDiagnosticService.DnsHostname,
                DiagnosticState.Responded, "Resolved", IPAddress.Parse("192.0.2.80"), 3));
    }
}
