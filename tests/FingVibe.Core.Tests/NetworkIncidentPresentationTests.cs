using System.Globalization;
using FingVibe.App;
using FingVibe.Core.Networking;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class NetworkIncidentPresentationTests
{
    private static readonly DateTimeOffset Start = new(2026, 11, 20, 9, 0, 0, TimeSpan.Zero);
    private static readonly CultureInfo Culture = CultureInfo.GetCultureInfo("en-GB");

    private static NetworkIncident Incident(NetworkIncidentState state) =>
        new(Guid.NewGuid(), "context", "Wi-Fi - 192.168.0.10 (192.168.0.0/24)", Start, Start.AddSeconds(30))
        {
            State = state,
            Symptoms = [new(NetworkHealthSymptomKind.HighLatency, FingVibe.Core.Models.NetworkMonitorTarget.Cloudflare,
                "High latency: Cloudflare 1.1.1.1 215 ms median (limit 150 ms)", Start.AddSeconds(30))],
            LastObservedAt = Start.AddMinutes(2),
            RecoveryChecks = state == NetworkIncidentState.Recovered ? 0 : 2,
            RecoveredAt = state == NetworkIncidentState.Recovered ? Start.AddMinutes(12) : null
        };

    private static NetworkIncidentRow Row(NetworkIncident incident) =>
        Assert.Single(NetworkIncidentPresentation.Rows([incident], Start.AddHours(1), TimeZoneInfo.Utc, Culture));

    [Theory]
    [InlineData(0, "12:00:00 AM")]
    [InlineData(7, "07:00:00 AM")]
    [InlineData(12, "12:00:00 PM")]
    [InlineData(22, "10:00:00 PM")]
    public void ReviewIncidentAndEvidenceAlwaysExerciseTwoDigitEnUsHours(int hour, string expected)
    {
        var time = new DateTimeOffset(2026, 11, 20, hour, 0, 0, TimeSpan.Zero);
        var incident = Incident(NetworkIncidentState.Ongoing) with
        {
            FirstObservedAt = time, ConfirmedAt = time, LastObservedAt = time
        };
        var culture = NetworkMonitorReviewFixture.IncidentCulture;
        var row = Assert.Single(NetworkIncidentPresentation.Rows([incident], time, TimeZoneInfo.Utc, culture));
        var evidence = new NetworkIncidentEvidence(incident.Id, incident.ContextKey, incident.NetworkLabel, time)
        {
            Outcome = NetworkEvidenceOutcome.Complete, CompletedAt = time
        };
        var view = NetworkIncidentPresentation.Evidence(incident, evidence, time, TimeZoneInfo.Utc, culture);

        Assert.Equal($"First observed today {expected}; confirmed today {expected}.", row.Times);
        Assert.Contains($"last checked today {expected}.", row.Recovery);
        Assert.Contains($"collected today {expected} to today {expected}.", view.Context);
    }

    [Fact]
    public void OngoingShowsProgressAndLastCheckWithoutACurrentVerdict()
    {
        var row = Row(Incident(NetworkIncidentState.Ongoing));
        Assert.Equal("Ongoing", row.Status);
        Assert.Equal("First observed today 09:00:00; confirmed today 09:00:30.", row.Times);
        Assert.Equal("Not recovered when last checked today 09:02:00. Recovery: 2 of 5 consecutive healthy checks.", row.Recovery);
        Assert.DoesNotContain("Healthy", row.AccessibleName, StringComparison.Ordinal);
    }

    [Fact]
    public void RecoveredStatesTheObservedRecoveryWithoutClaimingAnOutageDuration()
    {
        var row = Row(Incident(NetworkIncidentState.Recovered));
        Assert.Equal("Recovery observed today 09:12:00, 12 min after it was first observed " +
            "(time until recovery was observed, not an exact outage duration).", row.Recovery);

        var uncertain = Row(Incident(NetworkIncidentState.Recovered) with
        {
            RecoveryTimeUncertain = true,
            Gaps = [new(Guid.NewGuid(), NetworkObservationGapReason.Sleep, Start.AddMinutes(3), Start.AddMinutes(9))]
        });
        Assert.Equal("Recovery observed today 09:12:00 after an observation gap, so the exact recovery time is unknown.", uncertain.Recovery);
        Assert.Equal("Observation gaps: Sleep from today 09:03:00 to today 09:09:00.", uncertain.Gaps);
    }

    [Fact]
    public void RecoveryUnknownNamesTheOpenGapAndKeepsProgress()
    {
        var row = Row(Incident(NetworkIncidentState.RecoveryUnknown) with
        {
            Gaps = [new(Guid.NewGuid(), NetworkObservationGapReason.AppClosed, Start.AddMinutes(2), null)]
        });
        Assert.Equal("Recovery unknown", row.Status);
        Assert.Equal("Recovery unknown: not observed since today 09:02:00 because FingVibe was closed. Recovery so far: " +
            "2 of 5 consecutive healthy checks; counting resumes when monitoring checks this network again.", row.Recovery);
        Assert.Equal("Observation gaps: App closed from today 09:02:00 until now.", row.Gaps);
    }

    [Fact]
    public void SummaryPrefersTheActiveIncidentOverANewerRecoveredOne()
    {
        var recovered = Incident(NetworkIncidentState.Recovered) with { FirstObservedAt = Start.AddMinutes(30), ConfirmedAt = Start.AddMinutes(31) };
        var ongoing = Incident(NetworkIncidentState.Ongoing);
        var now = Start.AddHours(1);

        Assert.StartsWith("Incident history: ongoing incident since today 09:00:00. High latency",
            NetworkIncidentPresentation.Summary([recovered, ongoing], now, TimeZoneInfo.Utc, Culture));
        Assert.StartsWith("Incident history: most recent incident first observed today 09:30:00.",
            NetworkIncidentPresentation.Summary([recovered], now, TimeZoneInfo.Utc, Culture));
        Assert.Equal("Incident history: no confirmed incidents saved.",
            NetworkIncidentPresentation.Summary([], now, TimeZoneInfo.Utc, Culture));
    }

    [Fact]
    public void EvidenceIsLabelledAsTimestampedHistoryWithChecksAndTrace()
    {
        var incident = Incident(NetworkIncidentState.Ongoing);
        var evidence = new NetworkIncidentEvidence(incident.Id, incident.ContextKey, incident.NetworkLabel, Start.AddSeconds(31))
        {
            Outcome = NetworkEvidenceOutcome.Complete,
            CompletedAt = Start.AddSeconds(52),
            Observations = [new(FingVibe.Core.Models.DiagnosticCheckpoint.Gateway, "192.168.0.1",
                FingVibe.Core.Models.DiagnosticState.Responded, "Reply", System.Net.IPAddress.Parse("192.168.0.1"), 3)],
            Hops = [new(1, new(FingVibe.Core.Models.DiagnosticCheckpoint.Hop2, "1.1.1.1",
                FingVibe.Core.Models.DiagnosticState.Responded, "Reply", System.Net.IPAddress.Parse("1.1.1.1"), 9), true)],
            TraceComplete = true,
            SummaryStatus = "All good",
            SummaryExplanation = "The checks passed."
        };
        var view = NetworkIncidentPresentation.Evidence(incident, evidence, Start.AddHours(1), TimeZoneInfo.Utc, Culture);

        Assert.Equal("Saved evidence from Wi-Fi - 192.168.0.10 (192.168.0.0/24), collected today 09:00:31 to today 09:00:52. " +
            "This is history, not current status; viewing it sends no probes.", view.Context);
        Assert.Equal("Complete: every check finished within the 45-second limit.", view.Outcome);
        Assert.Equal("All good: The checks passed.", view.Summary);
        Assert.Equal(("Default gateway LAN IPv4", "192.168.0.1 | Responded | Reply | response from 192.168.0.1 | 3 ms"),
            (view.Checks[0].Label, view.Checks[0].Result));
        Assert.StartsWith("Traceroute toward 1.1.1.1: destination reached at hop 1.", view.Trace);
        Assert.Equal(("Hop 1", "Responded: 1.1.1.1, 9 ms"), (view.Hops[0].Label, view.Hops[0].Result));
        Assert.EndsWith("Deeper diagnostics: complete.",
            Assert.Single(NetworkIncidentPresentation.Rows([incident],
                new Dictionary<Guid, NetworkIncidentEvidence> { [incident.Id] = evidence }, Start, TimeZoneInfo.Utc, Culture))
                .AccessibleName);
    }

    [Fact]
    public void PartialNotRunAndMissingEvidenceExplainThemselves()
    {
        var incident = Incident(NetworkIncidentState.Recovered);
        var started = new NetworkIncidentEvidence(incident.Id, incident.ContextKey, incident.NetworkLabel, Start);
        var partial = NetworkIncidentPresentation.Evidence(incident, started with
        {
            Outcome = NetworkEvidenceOutcome.Partial, CompletedAt = Start, Detail = NetworkIncidentDiagnostics.LimitReason
        }, Start, TimeZoneInfo.Utc, Culture);
        Assert.Equal($"Partial: {NetworkIncidentDiagnostics.LimitReason}", partial.Outcome);
        Assert.Equal("Traceroute toward 1.1.1.1: no hops were observed.", partial.Trace);
        Assert.DoesNotContain(" to today", partial.Context, StringComparison.Ordinal);

        var notRun = NetworkIncidentPresentation.Evidence(incident, started with
        {
            Outcome = NetworkEvidenceOutcome.NotRun, CompletedAt = Start, Detail = "Not run because a LAN scan was in progress."
        }, Start, TimeZoneInfo.Utc, Culture);
        Assert.Equal(("Not run because a LAN scan was in progress.", (string?)null), (notRun.Outcome, notRun.Trace));

        var none = NetworkIncidentPresentation.Evidence(incident, null, Start, TimeZoneInfo.Utc, Culture);
        Assert.StartsWith("No deeper diagnostic evidence is saved for this incident.", none.Outcome);
        Assert.Empty(none.Checks);
    }

    [Theory]
    [InlineData(30, "under a minute")]
    [InlineData(90, "1 min")]
    [InlineData(3600, "1 h")]
    [InlineData(3900, "1 h 5 min")]
    [InlineData(90000, "1 d 1 h")]
    public void DurationsAreCompact(int seconds, string expected) =>
        Assert.Equal(expected, NetworkIncidentPresentation.Duration(TimeSpan.FromSeconds(seconds)));
}
