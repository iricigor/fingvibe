using System.Net;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class NetworkIncidentTrackerTests
{
    internal static readonly DateTimeOffset Start = new(2026, 11, 20, 9, 0, 0, TimeSpan.Zero);
    internal const string Context = "network|192.168.0.10|192.168.0.1";
    private const string Label = "Wi-Fi - 192.168.0.10 (192.168.0.0/24)";
    private int _check;

    internal static NetworkMonitorObservation Observation(DateTimeOffset at, long cloudflare = 12, long gateway = 3,
        bool cancelled = false, bool cloudflareUnanswered = false)
    {
        var samples = new List<NetworkMonitorPingSample>();
        Add(NetworkMonitorTarget.Gateway, "192.168.0.1", gateway, false);
        Add(NetworkMonitorTarget.Cloudflare, "1.1.1.1", cloudflare, cloudflareUnanswered);
        Add(NetworkMonitorTarget.Google, "8.8.8.8", 15, false);
        return new(at.AddSeconds(-6), at, "network", IPAddress.Parse("192.168.0.1"), samples,
        [
            new(NetworkMonitorDnsSource.WindowsConfiguredOrCached, at, at,
                new(DiagnosticCheckpoint.ConfiguredDns, "example.com", DiagnosticState.Responded, "", RoundtripMilliseconds: 9))
        ], cancelled, "");

        void Add(NetworkMonitorTarget target, string address, long latency, bool unanswered)
        {
            for (var index = 0; index < 5; index++)
                samples.Add(new(target, index + 1, at, at, new(DiagnosticCheckpoint.Gateway, address,
                    unanswered ? DiagnosticState.Unanswered : DiagnosticState.Responded, "",
                    RoundtripMilliseconds: unanswered ? null : latency)));
        }
    }

    private DateTimeOffset Next() => Start.AddSeconds(30 * ++_check);

    private NetworkIncidentUpdate Healthy(NetworkIncidentTracker tracker, string context = Context) =>
        tracker.Evaluate(Observation(Next()), context, Label, false);

    private NetworkIncidentUpdate Slow(NetworkIncidentTracker tracker, string context = Context, long cloudflare = 215,
        long gateway = 3) =>
        tracker.Evaluate(Observation(Next(), cloudflare, gateway), context, Label, false);

    private static NetworkIncidentTracker Loaded(params NetworkIncident[] saved)
    {
        var tracker = new NetworkIncidentTracker(new NetworkHealthEvaluator());
        tracker.Load(saved);
        return tracker;
    }

    [Fact]
    public void ConfirmationCreatesOneIncidentWithFirstObservedAndConfirmationTimes()
    {
        var tracker = Loaded();
        Healthy(tracker);
        var first = Slow(tracker);
        Assert.Empty(first.Changed);
        var confirmed = Slow(tracker);

        var incident = Assert.Single(confirmed.Changed);
        Assert.Equal((NetworkIncidentState.Ongoing, Start.AddSeconds(60), Start.AddSeconds(90), Label),
            (incident.State, incident.FirstObservedAt, incident.ConfirmedAt, incident.NetworkLabel));
        Assert.Equal(NetworkHealthSymptomKind.HighLatency, Assert.Single(incident.Symptoms).Kind);
        Assert.Equal(incident, Assert.Single(tracker.Incidents));
    }

    [Fact]
    public void ActiveIncidentAccumulatesSymptomsInsteadOfCreatingAnother()
    {
        var tracker = Loaded();
        Slow(tracker);
        var id = Assert.Single(Slow(tracker).Changed).Id;
        Slow(tracker, gateway: 40);
        var both = Assert.Single(Slow(tracker, gateway: 40).Changed);

        Assert.Equal(id, both.Id);
        Assert.Equal([NetworkMonitorTarget.Cloudflare, NetworkMonitorTarget.Gateway], both.Symptoms.Select(item => item.Target));
        Assert.Single(tracker.Incidents);
    }

    [Fact]
    public void FiveHealthyChecksRecoverAndALaterProblemIsANewIncident()
    {
        var tracker = Loaded();
        Slow(tracker);
        var incident = Assert.Single(Slow(tracker).Changed);
        for (var check = 1; check < NetworkHealthEvaluator.RecoveryCheckCount; check++)
            Assert.Equal(check, Assert.Single(Healthy(tracker).Changed).RecoveryChecks);
        var recovered = Assert.Single(Healthy(tracker).Changed);

        Assert.Equal((incident.Id, NetworkIncidentState.Recovered, (DateTimeOffset?)Start.AddSeconds(210), false, 0),
            (recovered.Id, recovered.State, recovered.RecoveredAt, recovered.RecoveryTimeUncertain, recovered.RecoveryChecks));
        Slow(tracker);
        var second = Assert.Single(Slow(tracker).Changed);
        Assert.NotEqual(incident.Id, second.Id);
        Assert.Equal([second.Id, incident.Id], tracker.Incidents.Select(item => item.Id));
    }

    [Fact]
    public void CompletedUnhealthyCheckResetsRecoveryProgress()
    {
        var tracker = Loaded();
        Slow(tracker);
        Slow(tracker);
        Healthy(tracker);
        Healthy(tracker);
        Assert.Equal(0, Assert.Single(Slow(tracker).Changed).RecoveryChecks);
        Assert.Equal(1, Assert.Single(Healthy(tracker).Changed).RecoveryChecks);
    }

    [Fact]
    public void CancelledAndUncertainChecksNeitherCountNorReset()
    {
        var tracker = Loaded();
        Slow(tracker);
        Slow(tracker);
        Healthy(tracker);
        Assert.Empty(tracker.Evaluate(Observation(Next(), cancelled: true), Context, Label, false).Changed);
        Assert.Empty(tracker.Evaluate(Observation(Next(), cloudflare: 215), Context, Label, true).Changed);
        Assert.Equal(2, Assert.Single(Healthy(tracker).Changed).RecoveryChecks);
    }

    [Fact]
    public void GapMakesRecoveryUnknownThenResumedChecksRecoverWithUncertainTime()
    {
        var tracker = Loaded();
        Slow(tracker);
        Slow(tracker);
        Healthy(tracker);
        Healthy(tracker);
        var paused = Assert.Single(tracker.BeginGap(NetworkObservationGapReason.Sleep, Start.AddMinutes(3)));
        Assert.Equal(NetworkIncidentState.RecoveryUnknown, paused.State);
        Assert.Empty(tracker.BeginGap(NetworkObservationGapReason.MonitoringOff, Start.AddMinutes(4)));
        tracker.Evaluator.Reset();

        _check = 20;
        var resumed = Assert.Single(Healthy(tracker).Changed);
        Assert.Equal((NetworkIncidentState.Ongoing, 3), (resumed.State, resumed.RecoveryChecks));
        Assert.Equal((Start.AddMinutes(3), (DateTimeOffset?)Start.AddSeconds(630)),
            (Assert.Single(resumed.Gaps).StartedAt, resumed.Gaps[0].EndedAt));
        Healthy(tracker);
        var recovered = Assert.Single(Healthy(tracker).Changed);
        Assert.Equal((NetworkIncidentState.Recovered, true), (recovered.State, recovered.RecoveryTimeUncertain));
    }

    [Fact]
    public void UnhealthyCheckAfterAGapRestoresExactRecoveryTiming()
    {
        var tracker = Loaded();
        Slow(tracker);
        Slow(tracker);
        tracker.BeginGap(NetworkObservationGapReason.Sleep, Start.AddMinutes(2));
        Slow(tracker);
        for (var check = 0; check < NetworkHealthEvaluator.RecoveryCheckCount - 1; check++) Healthy(tracker);
        Assert.False(Assert.Single(Healthy(tracker).Changed).RecoveryTimeUncertain);
    }

    [Fact]
    public void RestartMarksObservedIncidentsUnknownAndResumesTheFifthHealthyCheck()
    {
        var tracker = Loaded();
        Slow(tracker);
        Slow(tracker);
        for (var check = 0; check < 4; check++) Healthy(tracker);
        var saved = tracker.Incidents[0];
        Assert.Equal(4, saved.RecoveryChecks);

        var restarted = new NetworkIncidentTracker(new NetworkHealthEvaluator());
        var closed = Assert.Single(restarted.Load([saved]));
        Assert.Equal(NetworkIncidentState.RecoveryUnknown, closed.State);
        var gap = Assert.Single(closed.Gaps);
        Assert.Equal((NetworkObservationGapReason.AppClosed, saved.LastObservedAt, (DateTimeOffset?)null),
            (gap.Reason, gap.StartedAt, gap.EndedAt));

        _check = 40;
        var recovered = Assert.Single(Healthy(restarted).Changed);
        Assert.Equal((saved.Id, NetworkIncidentState.Recovered, true), (recovered.Id, recovered.State, recovered.RecoveryTimeUncertain));
        Assert.Equal(recovered.RecoveredAt, recovered.Gaps[0].EndedAt);
    }

    [Fact]
    public void NetworkChangeLeavesTheIncidentUnknownAndStartsFreshOnTheNewContext()
    {
        var tracker = Loaded();
        Slow(tracker);
        Slow(tracker);
        Healthy(tracker);

        var other = Healthy(tracker, "other|10.0.0.2|10.0.0.1");
        var left = Assert.Single(other.Changed);
        Assert.Equal((NetworkIncidentState.RecoveryUnknown, NetworkObservationGapReason.NetworkChanged),
            (left.State, Assert.Single(left.Gaps).Reason));
        Assert.Equal(NetworkHealthVerdict.Learning, other.Assessment!.Verdict);

        var back = Assert.Single(Healthy(tracker).Changed);
        Assert.Equal((NetworkIncidentState.Ongoing, 2), (back.State, back.RecoveryChecks));
    }

    [Fact]
    public void ResumedLatencyTargetThatStopsAnsweringIsNotCountedHealthy()
    {
        var tracker = Loaded();
        Slow(tracker);
        Slow(tracker);
        Healthy(tracker);
        tracker.Evaluator.Reset();

        var silent = tracker.Evaluate(Observation(Next(), cloudflareUnanswered: true), Context, Label, false);
        var incident = Assert.Single(silent.Changed);
        Assert.Equal((NetworkIncidentState.Ongoing, 0), (incident.State, incident.RecoveryChecks));
    }

    [Fact]
    public void EvaluatorResetDiscardsAnEarlierSuspiciousCheckAsFirstObservation()
    {
        var tracker = Loaded();
        Slow(tracker);
        tracker.Evaluator.Reset();
        _check = 100;
        Slow(tracker);
        var incident = Assert.Single(Slow(tracker).Changed);
        Assert.Equal((Start.AddSeconds(3030), Start.AddSeconds(3060)), (incident.FirstObservedAt, incident.ConfirmedAt));
    }

    [Fact]
    public void ProblemsBeforeHistoryLoadsAreNotTracked()
    {
        var tracker = new NetworkIncidentTracker(new NetworkHealthEvaluator());
        Slow(tracker);
        Assert.Empty(Slow(tracker).Changed);
        Assert.Empty(tracker.BeginGap(NetworkObservationGapReason.Sleep, Start));
        Assert.False(tracker.IsLoaded);
    }

    [Fact]
    public void LoadRejectsTwoActiveIncidentsForOneNetwork()
    {
        var incident = new NetworkIncident(Guid.NewGuid(), Context, Label, Start, Start)
        {
            Symptoms = [new(NetworkHealthSymptomKind.WindowsDnsFailed, null, "Windows DNS did not resolve example.com", Start)],
            LastObservedAt = Start
        };
        Assert.Throws<InvalidDataException>(() => Loaded(incident, incident with { Id = Guid.NewGuid() }));
    }
}
