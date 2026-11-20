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

    [Theory]
    [InlineData(30, "under a minute")]
    [InlineData(90, "1 min")]
    [InlineData(3600, "1 h")]
    [InlineData(3900, "1 h 5 min")]
    [InlineData(90000, "1 d 1 h")]
    public void DurationsAreCompact(int seconds, string expected) =>
        Assert.Equal(expected, NetworkIncidentPresentation.Duration(TimeSpan.FromSeconds(seconds)));
}
