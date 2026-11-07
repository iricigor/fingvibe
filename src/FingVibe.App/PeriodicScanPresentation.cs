using System.Globalization;
using FingVibe.Core.Models;

namespace FingVibe.App;

// Pure text for the Settings card and shared header, kept separate from WinUI so it can be tested.
internal static class PeriodicScanPresentation
{
    public const string EvidenceNote =
        "Each scheduled scan samples which devices answer at that moment. Missed responses between scans " +
        "are not proof that a device was offline, and FingVibe does not track a continuous availability timeline.";

    public const string LoadFailedMessage =
        "Saved scheduled-scan settings could not be loaded, so scheduled scans are off. " +
        "Changes apply until FingVibe closes and will not overwrite the file.";

    public const string SaveFailedMessage = "Scheduled-scan changes apply now but could not be saved for the next launch.";

    public const string SleepMonitoringMessage =
        "Windows sleep notifications are unavailable, so scheduled scans cannot pause for sleep. " +
        "A delayed scan still runs only once.";

    public static string IntervalLabel(int minutes) => minutes switch
    {
        60 => "1 hour",
        _ when minutes % 60 == 0 => $"{minutes / 60} hours",
        1 => "1 minute",
        _ => $"{minutes} minutes"
    };

    public static string Status(
        PeriodicScanSettings settings,
        PeriodicScanStatus status,
        bool suspended,
        DateTimeOffset now,
        TimeZoneInfo timeZone,
        CultureInfo culture,
        params string?[] notes)
    {
        var text = !settings.IsEnabled
            ? "Off. Scans run only when you select Scan LAN."
            : suspended
                ? "Paused while Windows sleeps. The next scan runs one full interval after Windows resumes."
                : status.State switch
                {
                    PeriodicScanState.Running => "Scheduled scan in progress.",
                    PeriodicScanState.Waiting => WaitingText(status, now, timeZone, culture),
                    _ => "Starts once FingVibe finishes loading."
                };
        return string.Join(" ", new[] { text }.Concat(notes).Where(value => !string.IsNullOrWhiteSpace(value)));
    }

    public static string? HeaderSummary(PeriodicScanSettings settings, PeriodicScanStatus status, bool suspended)
    {
        if (!settings.IsEnabled)
        {
            return null;
        }

        if (suspended || status is { State: PeriodicScanState.Waiting, LastOutcome.Status: ScanRunStatus.Unavailable })
        {
            return "Scheduled scans paused";
        }

        return status.ConsecutiveUnsuccessfulAttempts > 0
            ? "Scheduled scans retrying"
            : $"Scheduled every {IntervalLabel(settings.IntervalMinutes)}";
    }

    // Discoveries waiting for the window to be restored are listed once, in the order they were first found.
    public static IReadOnlyList<DeviceDiscovery> MergeDiscoveries(
        IReadOnlyList<DeviceDiscovery> pending,
        IReadOnlyList<DeviceDiscovery> added) =>
        pending.Concat(added).DistinctBy(discovery => discovery.IdentityKey).ToArray();

    private static string WaitingText(PeriodicScanStatus status, DateTimeOffset now, TimeZoneInfo timeZone, CultureInfo culture)
    {
        var next = status.NextAttemptAt is { } due ? FormatTime(due, now, timeZone, culture) : "soon";
        var last = status.LastOutcome;
        return last?.Status switch
        {
            null => $"First scheduled scan around {next}.",
            ScanRunStatus.Completed => $"Last scheduled scan completed. Next around {next}.",
            ScanRunStatus.Cancelled => $"Last scheduled scan was cancelled; committed checkpoints are retained as incomplete. Next around {next}.",
            ScanRunStatus.Busy =>
                $"Skipped because {ActivityName(last.BlockingActivity)} was in progress. Retrying around {next}.",
            ScanRunStatus.Unavailable => $"Paused: {Sentence(last.Message, "The selected LAN is unavailable.")} Checking again around {next}.",
            ScanRunStatus.SaveFailed =>
                $"The last scheduled scan could not be saved: {Sentence(last.Message, "Saving failed.")} Retrying around {next}.",
            _ => $"The last scheduled scan failed: {Sentence(last.Message, "The scan stopped unexpectedly.")} Retrying around {next}."
        };
    }

    private static string ActivityName(NetworkActivityKind? activity) => activity switch
    {
        NetworkActivityKind.LanScan => "another LAN scan",
        NetworkActivityKind.InternetSpeedTest => "a Cloudflare speed test",
        NetworkActivityKind.NetworkTroubleshooting => "network troubleshooting",
        NetworkActivityKind.DeviceServiceScan => "a device service scan",
        _ => "another network measurement"
    };

    private static string Sentence(string? message, string fallback)
    {
        var text = string.IsNullOrWhiteSpace(message) ? fallback : message.Trim();
        return text.EndsWith('.') ? text : text + ".";
    }

    private static string FormatTime(DateTimeOffset due, DateTimeOffset now, TimeZoneInfo timeZone, CultureInfo culture)
    {
        var local = TimeZoneInfo.ConvertTime(due, timeZone);
        var today = TimeZoneInfo.ConvertTime(now, timeZone).Date;
        var time = local.ToString("t", culture);
        return local.Date == today ? time : $"{local.ToString("ddd", culture)} {time}";
    }
}
