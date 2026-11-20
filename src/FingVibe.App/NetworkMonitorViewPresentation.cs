using System.Globalization;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;

namespace FingVibe.App;

internal enum NetworkMonitorIndicatorKind
{
    Off,
    Paused,
    NoResult,
    Checking,
    Observed,
    Stale,
    Learning,
    Healthy,
    Verifying,
    Problem,
    Uncertain
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

/// <summary>Projects the monitor snapshot and its health verdict for the header dot, Network health and the Network summary.</summary>
internal static class NetworkMonitorViewPresentation
{
    public const string OffDetail =
        "Background health checks are not running, so there is no current health result. This is not a healthy state.";
    public const string RawNote = "Raw observations show what the latest check measured; ICMP and DNS replies can be blocked even when services work.";

    // Approved staleness: after three minutes without a completed check, old health is not shown as current.
    public static readonly TimeSpan StaleAfter = TimeSpan.FromMinutes(3);

    public static NetworkMonitorView Create(
        NetworkMonitorSnapshot snapshot, DateTimeOffset now, TimeZoneInfo timeZone, CultureInfo culture)
    {
        var observation = snapshot.LastObservation;
        // A restarted monitor (context change, wake, re-enable) has no observation yet, so no earlier verdict is shown.
        var health = observation is null ? null : snapshot.Health;
        var latest = new[] { observation?.CompletedAt, health?.ObservedAt }.Max();
        var stale = latest is { } completed && now - completed > StaleAfter;
        // Off and Paused take precedence; a running check keeps showing the current verdict while the dot pulses.
        var kind = snapshot.State switch
        {
            NetworkMonitorState.Off => NetworkMonitorIndicatorKind.Off,
            NetworkMonitorState.Paused => NetworkMonitorIndicatorKind.Paused,
            _ when stale => NetworkMonitorIndicatorKind.Stale,
            _ when health is not null => health.Verdict switch
            {
                NetworkHealthVerdict.Learning => NetworkMonitorIndicatorKind.Learning,
                NetworkHealthVerdict.Healthy => NetworkMonitorIndicatorKind.Healthy,
                NetworkHealthVerdict.Verifying => NetworkMonitorIndicatorKind.Verifying,
                NetworkHealthVerdict.Problem => NetworkMonitorIndicatorKind.Problem,
                _ => NetworkMonitorIndicatorKind.Uncertain
            },
            NetworkMonitorState.Checking => NetworkMonitorIndicatorKind.Checking,
            _ when observation is null => NetworkMonitorIndicatorKind.NoResult,
            _ => NetworkMonitorIndicatorKind.Observed
        };
        var title = kind switch
        {
            NetworkMonitorIndicatorKind.Off => "Monitoring off",
            NetworkMonitorIndicatorKind.Paused => "Monitoring paused",
            NetworkMonitorIndicatorKind.Checking => "Monitoring on - checking now",
            NetworkMonitorIndicatorKind.NoResult => "Monitoring on - no result yet",
            NetworkMonitorIndicatorKind.Stale => "Monitoring on - last result not current",
            NetworkMonitorIndicatorKind.Learning => "Learning - no problems found",
            NetworkMonitorIndicatorKind.Healthy => "Healthy",
            NetworkMonitorIndicatorKind.Verifying => "Possible problem - verifying",
            NetworkMonitorIndicatorKind.Problem => "Problem confirmed",
            NetworkMonitorIndicatorKind.Uncertain => "Uncertain - multiple network routes",
            _ => "Monitoring on - raw observations"
        };
        var detail = kind switch
        {
            NetworkMonitorIndicatorKind.Off => JoinSentences(OffDetail, ExtraNotes(snapshot.Detail)),
            NetworkMonitorIndicatorKind.Stale => JoinSentences(
                "No check has completed for over three minutes, so the last result is not shown as current health.", snapshot.Detail),
            _ when health is not null && kind >= NetworkMonitorIndicatorKind.Learning =>
                JoinSentences([VerdictText(health), .. health.Notes, snapshot.Detail]),
            _ => JoinSentences(snapshot.Detail, RawNote)
        };
        return new(kind, title, detail, LastCheck(observation, snapshot.State, stale, now, timeZone, culture), Rows(observation));
    }

    private static string VerdictText(NetworkHealthAssessment health)
    {
        var symptoms = string.Join(" ", health.Symptoms.Select(symptom => Sentence(symptom.Description)));
        return health.Verdict switch
        {
            NetworkHealthVerdict.Learning =>
                $"No problems found. Learning normal latency: {health.BaselineChecks} of {NetworkHealthEvaluator.BaselineSize} " +
                $"healthy checks; until then the fixed limits ({NetworkHealthEvaluator.GatewayThresholdMilliseconds:0} ms gateway, " +
                $"{NetworkHealthEvaluator.ExternalThresholdMilliseconds:0} ms internet) apply.",
            NetworkHealthVerdict.Healthy => "No problems found against the learned normal latency and the fixed limits.",
            NetworkHealthVerdict.Verifying =>
                $"{symptoms} Checking again every 30 seconds; a second suspicious check in a row confirms a problem.",
            NetworkHealthVerdict.Problem =>
                $"{symptoms} Recovery: {health.RecoveryChecks} of {NetworkHealthEvaluator.RecoveryCheckCount} consecutive " +
                "healthy checks. Checking every 30 seconds.",
            _ => "FingVibe does not judge the selected LAN while Windows may route the checks elsewhere."
        };
    }

    private static string Sentence(string text) => text.EndsWith('.') ? text : text + ".";
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

    internal static string FormatTime(DateTimeOffset value, DateTimeOffset now, TimeZoneInfo timeZone, CultureInfo culture)
    {
        var local = TimeZoneInfo.ConvertTime(value, timeZone);
        var today = TimeZoneInfo.ConvertTime(now, timeZone).Date;
        var time = local.ToString("T", culture);
        return local.Date == today ? $"today {time}" : $"{local.ToString("d MMM", culture)} {time}";
    }
}
