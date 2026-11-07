using System.Globalization;
using FingVibe.App;
using FingVibe.Core.Models;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class PeriodicScanPresentationTests
{
    private static readonly PeriodicScanSettings Enabled = new(true, 60);
    private static readonly DateTimeOffset Now = new(2026, 11, 6, 8, 0, 0, TimeSpan.Zero);
    private static readonly DateTimeOffset Next = new(2026, 11, 6, 9, 0, 0, TimeSpan.Zero);

    [Fact]
    public void IntervalLabelsAreReadable()
    {
        Assert.Equal(
            new[] { "15 minutes", "30 minutes", "1 hour", "2 hours", "4 hours" },
            PeriodicScanSettings.IntervalChoices.Select(PeriodicScanPresentation.IntervalLabel));
    }

    [Fact]
    public void StatusExplainsOffPausedLoadingAndRunningStates()
    {
        Assert.Equal(
            "Off. Scans run only when you select Scan LAN.",
            Status(PeriodicScanSettings.Default, new PeriodicScanStatus(PeriodicScanState.Stopped)));
        Assert.Equal(
            "Paused while Windows sleeps. The next scan runs one full interval after Windows resumes.",
            Status(Enabled, new PeriodicScanStatus(PeriodicScanState.Stopped), suspended: true));
        Assert.Equal(
            "Starts once FingVibe finishes loading.",
            Status(Enabled, new PeriodicScanStatus(PeriodicScanState.Stopped)));
        Assert.Equal(
            "Scheduled scan in progress.",
            Status(Enabled, new PeriodicScanStatus(PeriodicScanState.Running)));
    }

    [Theory]
    [InlineData(null, null, "First scheduled scan around 09:00.")]
    [InlineData(nameof(ScanRunStatus.Completed), null, "Last scheduled scan completed. Next around 09:00.")]
    [InlineData(nameof(ScanRunStatus.Cancelled), null, "Last scheduled scan was cancelled; committed checkpoints are retained as incomplete. Next around 09:00.")]
    [InlineData(nameof(ScanRunStatus.Unavailable), "Wi-Fi (192.168.1.0/24) is not connected.",
        "Paused: Wi-Fi (192.168.1.0/24) is not connected. Checking again around 09:00.")]
    [InlineData(nameof(ScanRunStatus.Failed), "socket failure",
        "The last scheduled scan failed: socket failure. Retrying around 09:00.")]
    [InlineData(nameof(ScanRunStatus.SaveFailed), null,
        "The last scheduled scan could not be saved: Saving failed. Retrying around 09:00.")]
    public void WaitingStatusReportsTheLastOutcomeAndNextAttempt(string? last, string? message, string expected)
    {
        var outcome = last is null ? null : new ScanRunOutcome(Enum.Parse<ScanRunStatus>(last)) { Message = message };

        Assert.Equal(expected, Status(Enabled, new PeriodicScanStatus(PeriodicScanState.Waiting, Next, outcome)));
    }

    [Theory]
    [InlineData(nameof(NetworkActivityKind.LanScan), "another LAN scan")]
    [InlineData(nameof(NetworkActivityKind.InternetSpeedTest), "a Cloudflare speed test")]
    [InlineData(nameof(NetworkActivityKind.NetworkTroubleshooting), "network troubleshooting")]
    [InlineData(nameof(NetworkActivityKind.DeviceServiceScan), "a device service scan")]
    [InlineData(null, "another network measurement")]
    public void BusyStatusNamesTheBlockingActivity(string? activity, string name)
    {
        var busy = new ScanRunOutcome(ScanRunStatus.Busy)
        {
            BlockingActivity = activity is null ? null : Enum.Parse<NetworkActivityKind>(activity)
        };

        Assert.Equal(
            $"Skipped because {name} was in progress. Retrying around 09:00.",
            Status(Enabled, new PeriodicScanStatus(PeriodicScanState.Waiting, Next, busy, 1)));
    }

    [Fact]
    public void StatusUsesLocalTimeAddsTheDayWhenNeededAndAppendsNotes()
    {
        var zone = TimeZoneInfo.CreateCustomTimeZone("Review+2", TimeSpan.FromHours(2), "Review+2", "Review+2");
        var lateNow = new DateTimeOffset(2026, 11, 6, 21, 30, 0, TimeSpan.Zero);
        var waiting = new PeriodicScanStatus(PeriodicScanState.Waiting, lateNow.AddHours(1));

        Assert.Equal(
            "First scheduled scan around Sat 00:30. " + PeriodicScanPresentation.SaveFailedMessage,
            PeriodicScanPresentation.Status(
                Enabled, waiting, false, lateNow, zone, CultureInfo.InvariantCulture,
                PeriodicScanPresentation.SaveFailedMessage, null));
        Assert.Equal(
            "Off. Scans run only when you select Scan LAN. " + PeriodicScanPresentation.LoadFailedMessage,
            PeriodicScanPresentation.Status(
                PeriodicScanSettings.Default, waiting, false, lateNow, zone, CultureInfo.InvariantCulture,
                PeriodicScanPresentation.LoadFailedMessage));
    }

    [Fact]
    public void HeaderSummaryAppearsOnlyWhenEnabled()
    {
        var waiting = new PeriodicScanStatus(PeriodicScanState.Waiting, Next);
        var unavailable = waiting with { LastOutcome = new ScanRunOutcome(ScanRunStatus.Unavailable), ConsecutiveUnsuccessfulAttempts = 1 };
        var failed = waiting with { LastOutcome = new ScanRunOutcome(ScanRunStatus.Failed), ConsecutiveUnsuccessfulAttempts = 2 };

        Assert.Null(PeriodicScanPresentation.HeaderSummary(PeriodicScanSettings.Default, waiting, false));
        Assert.Equal("Scheduled every 1 hour", PeriodicScanPresentation.HeaderSummary(Enabled, waiting, false));
        Assert.Equal("Scheduled every 4 hours", PeriodicScanPresentation.HeaderSummary(new(true, 240), waiting, false));
        Assert.Equal("Scheduled scans paused", PeriodicScanPresentation.HeaderSummary(Enabled, waiting, true));
        Assert.Equal("Scheduled scans paused", PeriodicScanPresentation.HeaderSummary(Enabled, unavailable, false));
        Assert.Equal("Scheduled scans retrying", PeriodicScanPresentation.HeaderSummary(Enabled, failed, false));
    }

    [Fact]
    public void EvidenceNoteDoesNotClaimContinuousAvailability()
    {
        Assert.Contains("samples", PeriodicScanPresentation.EvidenceNote);
        Assert.Contains("not proof", PeriodicScanPresentation.EvidenceNote);
        Assert.Contains("does not track a continuous availability timeline", PeriodicScanPresentation.EvidenceNote);
    }

    [Fact]
    public void DeferredDiscoveriesAreMergedOnceInFirstSeenOrder()
    {
        var virtualId = Guid.Parse("8ac4dc6a-48f1-4ad6-a2f3-1f5b58ab4f35");
        IReadOnlyList<DeviceDiscovery> pending = [new("001122334455"), new("001122334466", virtualId)];

        var merged = PeriodicScanPresentation.MergeDiscoveries(
            pending,
            [new("001122334477", virtualId), new("001122334455"), new("001122334488")]);

        Assert.Equal(new[] { "001122334455", "001122334466", "001122334488" }, merged.Select(item => item.Mac));
    }

    private static string Status(PeriodicScanSettings settings, PeriodicScanStatus status, bool suspended = false) =>
        PeriodicScanPresentation.Status(settings, status, suspended, Now, TimeZoneInfo.Utc, CultureInfo.InvariantCulture);
}
