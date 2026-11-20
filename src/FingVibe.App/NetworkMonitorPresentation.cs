using System.Globalization;
using FingVibe.Core.Models;

namespace FingVibe.App;

internal static class NetworkMonitorPresentation
{
    public const string Disclosure =
        "Monitoring is opt-in and runs only while FingVibe is open. Every 60 seconds it sends five one-second-spaced " +
        "ICMP probes to the gateway, 1.1.1.1 and 8.8.8.8, then resolves example.com through Windows (including its cache) " +
        "and the Cloudflare and Google public DNS resolvers. User-started network work takes priority.";

    public const string LoadFailedMessage =
        "Saved network-monitoring settings could not be loaded, so monitoring is off. Changes apply until " +
        "FingVibe closes and will not overwrite the file.";

    public const string SaveFailedMessage =
        "Network-monitoring changes apply now but could not be saved for the next launch.";

    public const string SleepMonitoringMessage =
        "Windows sleep notifications are unavailable, so background network monitoring cannot pause for sleep.";

    public static string Status(
        NetworkMonitorSettings settings,
        NetworkMonitorStatus status,
        bool suspended,
        DateTimeOffset now,
        TimeZoneInfo timeZone,
        CultureInfo culture,
        params string?[] notes)
    {
        var text = !settings.IsEnabled
            ? "Off. No background network checks are scheduled."
            : suspended
                ? "Paused while Windows sleeps. The next check runs after a full 60-second wait when Windows resumes."
                : status.State switch
                {
                    NetworkMonitorSchedulerState.Running => "Collecting raw ping and DNS observations.",
                    NetworkMonitorSchedulerState.Waiting => WaitingText(status, now, timeZone, culture),
                    _ => "Starts after FingVibe finishes loading."
                };
        return string.Join(" ", new[] { text }.Concat(notes).Where(value => !string.IsNullOrWhiteSpace(value)));
    }

    public static NetworkMonitorSnapshot Snapshot(
        NetworkMonitorSettings settings,
        NetworkMonitorStatus status,
        bool suspended,
        DateTimeOffset now,
        string detail)
    {
        var state = !settings.IsEnabled
            ? NetworkMonitorState.Off
            : suspended
                ? NetworkMonitorState.Paused
                : status.State switch
                {
                    NetworkMonitorSchedulerState.Running => NetworkMonitorState.Checking,
                    _ => NetworkMonitorState.Waiting
                };
        return new(state, now, status.NextCheckAt, status.LastObservation, detail);
    }

    private static string WaitingText(
        NetworkMonitorStatus status,
        DateTimeOffset now,
        TimeZoneInfo timeZone,
        CultureInfo culture)
    {
        var next = status.NextCheckAt is { } due ? FormatTime(due, now, timeZone, culture) : "soon";
        var last = status.LastOutcome;
        return last?.Status switch
        {
            null => $"First raw network check around {next}.",
            NetworkMonitorRunStatus.Completed => last.Observation?.PingSamples
                .ConcatObservationErrors(last.Observation?.DnsObservations)
                is { Count: > 0 } errors
                    ? $"Last raw check completed with {errors.Count} probe error{(errors.Count == 1 ? "" : "s")}: " +
                      $"{Sentence(errors[0], "Probe failed.")} Next around {next}."
                    : $"Last raw ping and DNS check completed. Next around {next}.",
            NetworkMonitorRunStatus.Cancelled =>
                $"Last check was cancelled; no failure was inferred. Next around {next}.",
            NetworkMonitorRunStatus.Skipped =>
                $"Skipped because {ActivityName(last.BlockingActivity)} was active. Next around {next}.",
            _ => $"The last raw network check failed to complete: {Sentence(last.Message, "Unexpected probe failure.")} Next around {next}."
        };
    }

    private static string ActivityName(NetworkActivityKind? activity) => activity switch
    {
        NetworkActivityKind.LanScan => "a LAN scan",
        NetworkActivityKind.InternetSpeedTest => "a Cloudflare speed test",
        NetworkActivityKind.NetworkTroubleshooting => "network diagnostics",
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

    private static IReadOnlyList<string> ConcatObservationErrors(
        this IReadOnlyList<NetworkMonitorPingSample>? pings,
        IReadOnlyList<NetworkMonitorDnsObservation>? dns) =>
        (pings ?? []).Select(item => item.Observation)
            .Concat((dns ?? []).Select(item => item.Observation))
            .Where(item => item.State == DiagnosticState.Error)
            .Select(item => item.Detail)
            .ToArray();
}
