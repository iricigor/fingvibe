using System.Globalization;
using FingVibe.Core.Models;

namespace FingVibe.App;

internal enum NetworkMonitorIndicatorKind
{
    Off,
    Paused,
    NoResult,
    Checking,
    Observed,
    Stale
}

internal sealed record NetworkMonitorRawRow(string Label, string Result);

internal sealed record NetworkMonitorView(
    NetworkMonitorIndicatorKind Kind,
    string Title,
    string Detail,
    string LastCheck,
    IReadOnlyList<NetworkMonitorRawRow> Rows)
{
    public string IndicatorName => $"Network monitoring: {Title}. {LastCheck} Opens Network health.";
}

/// <summary>Projects the monitor snapshot for the header dot, Network health and the Network summary without a verdict.</summary>
internal static class NetworkMonitorViewPresentation
{
    public const string OffDetail =
        "Background health checks are not running, so there is no current health result. This is not a healthy state.";
    public const string RawNote = "Raw observations only; FingVibe does not judge network health from them.";

    // Two missed one-minute cycles plus probe time mean the retained result no longer reflects the current network.
    public static readonly TimeSpan StaleAfter = TimeSpan.FromMinutes(2.5);

    public static NetworkMonitorView Create(
        NetworkMonitorSnapshot snapshot, DateTimeOffset now, TimeZoneInfo timeZone, CultureInfo culture)
    {
        var observation = snapshot.LastObservation;
        var stale = observation is not null && now - observation.CompletedAt > StaleAfter;
        var kind = snapshot.State switch
        {
            NetworkMonitorState.Off => NetworkMonitorIndicatorKind.Off,
            NetworkMonitorState.Paused => NetworkMonitorIndicatorKind.Paused,
            NetworkMonitorState.Checking => NetworkMonitorIndicatorKind.Checking,
            _ when observation is null => NetworkMonitorIndicatorKind.NoResult,
            _ when stale => NetworkMonitorIndicatorKind.Stale,
            _ => NetworkMonitorIndicatorKind.Observed
        };
        var title = kind switch
        {
            NetworkMonitorIndicatorKind.Off => "Monitoring off",
            NetworkMonitorIndicatorKind.Paused => "Monitoring paused",
            NetworkMonitorIndicatorKind.Checking => "Monitoring on - checking now",
            NetworkMonitorIndicatorKind.NoResult => "Monitoring on - no result yet",
            NetworkMonitorIndicatorKind.Stale => "Monitoring on - last result not current",
            _ => "Monitoring on - raw observations"
        };
        var detail = kind == NetworkMonitorIndicatorKind.Off
            ? JoinSentences(OffDetail, ExtraNotes(snapshot.Detail))
            : JoinSentences(snapshot.Detail, RawNote);
        return new(kind, title, detail, LastCheck(observation, snapshot.State, stale, now, timeZone, culture), Rows(observation));
    }

    public static IReadOnlyList<NetworkMonitorRawRow> Rows(NetworkMonitorObservation? observation)
    {
        if (observation is null) return [];
        var rows = new List<NetworkMonitorRawRow>();
        foreach (var target in observation.PingSamples.GroupBy(sample => sample.Target).OrderBy(group => group.Key))
        {
            var samples = target.ToList();
            var address = samples[0].Observation.Target;
            var responded = samples.Where(sample => sample.Observation.State == DiagnosticState.Responded).ToList();
            var latencies = responded.Select(sample => sample.Observation.RoundtripMilliseconds).OfType<long>().ToList();
            var errors = samples.Count(sample => sample.Observation.State == DiagnosticState.Error);
            var result = $"{responded.Count}/{samples.Count} ping responses";
            if (latencies.Count > 0)
                result += latencies.Min() == latencies.Max() ? $", {latencies.Min()} ms" : $", {latencies.Min()}-{latencies.Max()} ms";
            if (errors > 0) result += $"; {errors} probe error{(errors == 1 ? "" : "s")}";
            rows.Add(new($"{TargetName(target.Key)} {address}", result));
        }
        foreach (var dns in observation.DnsObservations.OrderBy(item => item.Source))
        {
            var item = dns.Observation;
            var result = item.State switch
            {
                DiagnosticState.Responded => item.RoundtripMilliseconds is { } ms ? $"Resolved, {ms} ms" : "Resolved",
                DiagnosticState.Unanswered => "No answer",
                DiagnosticState.Cancelled => "Cancelled",
                DiagnosticState.Unavailable => "Unavailable",
                DiagnosticState.Error => $"Error: {Trim(item.Detail)}",
                _ => item.State.ToString()
            };
            rows.Add(new(DnsName(dns.Source), result));
        }
        return rows;
    }

    private static string LastCheck(NetworkMonitorObservation? observation, NetworkMonitorState state, bool stale,
        DateTimeOffset now, TimeZoneInfo timeZone, CultureInfo culture)
    {
        if (observation is null) return "No raw check has completed yet.";
        var text = $"Last raw check: {FormatTime(observation.CompletedAt, now, timeZone, culture)}";
        if (observation.Cancelled) text += " (stopped before every probe finished)";
        text += state switch
        {
            NetworkMonitorState.Off => ". Not current: monitoring is off.",
            NetworkMonitorState.Paused => ". Not current: monitoring is paused.",
            _ when stale => ". Not current: no newer result has been delivered.",
            _ => "."
        };
        return text;
    }

    private static string? ExtraNotes(string? detail)
    {
        const string off = "Off. No background network checks are scheduled.";
        if (string.IsNullOrWhiteSpace(detail)) return null;
        var notes = detail.StartsWith(off, StringComparison.Ordinal) ? detail[off.Length..].Trim() : detail.Trim();
        return notes.Length == 0 ? null : notes;
    }

    private static string JoinSentences(params string?[] parts) =>
        string.Join(" ", parts.Where(part => !string.IsNullOrWhiteSpace(part)).Select(part => part!.Trim()));

    private static string Trim(string detail) => string.IsNullOrWhiteSpace(detail) ? "probe failed" : detail.Trim().TrimEnd('.');

    private static string TargetName(NetworkMonitorTarget target) => target switch
    {
        NetworkMonitorTarget.Gateway => "Gateway",
        NetworkMonitorTarget.Cloudflare => "Cloudflare",
        _ => "Google"
    };

    private static string DnsName(NetworkMonitorDnsSource source) => source switch
    {
        NetworkMonitorDnsSource.WindowsConfiguredOrCached => "Windows DNS (may use cache)",
        NetworkMonitorDnsSource.Cloudflare => "Cloudflare DNS",
        _ => "Google DNS"
    };

    private static string FormatTime(DateTimeOffset value, DateTimeOffset now, TimeZoneInfo timeZone, CultureInfo culture)
    {
        var local = TimeZoneInfo.ConvertTime(value, timeZone);
        var today = TimeZoneInfo.ConvertTime(now, timeZone).Date;
        var time = local.ToString("T", culture);
        return local.Date == today ? $"today {time}" : $"{local.ToString("d MMM", culture)} {time}";
    }
}
