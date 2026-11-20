using System.Globalization;
using FingVibe.Core.Networking;

namespace FingVibe.App;

internal sealed record NetworkIncidentRow(
    Guid Id,
    NetworkIncidentState State,
    string Status,
    string Symptoms,
    string Times,
    string Recovery,
    string Network,
    string? Gaps)
{
    public string AccessibleName => string.Join(" ", new[] { $"{Status} incident.", Symptoms, Times, Recovery, Network, Gaps }
        .Where(part => !string.IsNullOrWhiteSpace(part)));
}

/// <summary>
/// Presents saved incident history. Every line is historical (first observed, confirmed, recovery observed) and never a
/// current health verdict; the time until recovery was observed is not presented as an exact outage duration.
/// </summary>
internal static class NetworkIncidentPresentation
{
    public const string EmptyText =
        "No confirmed incidents are saved. Background monitoring records an incident after two suspicious checks in a row.";
    public const string HistoryNote =
        "Saved history only: viewing it sends no probes. Current health is shown above.";

    public static IReadOnlyList<NetworkIncidentRow> Rows(
        IReadOnlyList<NetworkIncident> incidents, DateTimeOffset now, TimeZoneInfo timeZone, CultureInfo culture) =>
        incidents.Select(incident => Row(incident, now, timeZone, culture)).ToList();

    /// <summary>Network summary line: the ongoing (or recovery-unknown) incident first, otherwise the most recent one.</summary>
    public static string Summary(
        IReadOnlyList<NetworkIncident> incidents, DateTimeOffset now, TimeZoneInfo timeZone, CultureInfo culture)
    {
        var incident = incidents.FirstOrDefault(item => item.IsActive) ?? incidents.FirstOrDefault();
        if (incident is null) return "Incident history: no confirmed incidents saved.";
        var row = Row(incident, now, timeZone, culture);
        return incident.State switch
        {
            NetworkIncidentState.Ongoing =>
                $"Incident history: ongoing incident since {Time(incident.FirstObservedAt)}. {row.Symptoms} {row.Recovery}",
            NetworkIncidentState.RecoveryUnknown =>
                $"Incident history: incident first observed {Time(incident.FirstObservedAt)}. {row.Symptoms} {row.Recovery}",
            _ => $"Incident history: most recent incident first observed {Time(incident.FirstObservedAt)}. {row.Symptoms} {row.Recovery}"
        };

        string Time(DateTimeOffset value) => NetworkMonitorViewPresentation.FormatTime(value, now, timeZone, culture);
    }

    private static NetworkIncidentRow Row(NetworkIncident incident, DateTimeOffset now, TimeZoneInfo timeZone, CultureInfo culture)
    {
        var status = incident.State switch
        {
            NetworkIncidentState.Ongoing => "Ongoing",
            NetworkIncidentState.Recovered => "Recovered",
            _ => "Recovery unknown"
        };
        var symptoms = string.Join(" ", incident.Symptoms.Select(symptom => Sentence(symptom.Description)));
        var times = $"First observed {Time(incident.FirstObservedAt)}; confirmed {Time(incident.ConfirmedAt)}.";
        var progress = $"{incident.RecoveryChecks} of {NetworkHealthEvaluator.RecoveryCheckCount} consecutive healthy checks";
        var openGap = incident.Gaps.LastOrDefault(gap => gap.EndedAt is null);
        var recovery = incident.State switch
        {
            NetworkIncidentState.Ongoing =>
                $"Not recovered when last checked {Time(incident.LastObservedAt)}. Recovery: {progress}.",
            NetworkIncidentState.RecoveryUnknown =>
                $"Recovery unknown: not observed since {Time(openGap?.StartedAt ?? incident.LastObservedAt)}" +
                $"{(openGap is null ? "" : $" because {Reason(openGap.Reason)}")}. Recovery so far: {progress}; " +
                "counting resumes when monitoring checks this network again.",
            _ when incident.RecoveryTimeUncertain =>
                $"Recovery observed {Time(incident.RecoveredAt!.Value)} after an observation gap, so the exact recovery time is unknown.",
            _ => $"Recovery observed {Time(incident.RecoveredAt!.Value)}, " +
                $"{Duration(incident.RecoveredAt!.Value - incident.FirstObservedAt)} after it was first observed " +
                "(time until recovery was observed, not an exact outage duration)."
        };
        var gaps = incident.Gaps.Count == 0 ? null
            : $"Observation gaps: {string.Join("; ", incident.Gaps.Select(gap =>
                $"{GapLabel(gap.Reason)} from {Time(gap.StartedAt)} " +
                (gap.EndedAt is { } ended ? $"to {Time(ended)}" : "until now")))}.";
        return new(incident.Id, incident.State, status, symptoms, times, recovery,
            $"Network: {incident.NetworkLabel}.", gaps);

        string Time(DateTimeOffset value) => NetworkMonitorViewPresentation.FormatTime(value, now, timeZone, culture);
    }

    private static string Reason(NetworkObservationGapReason reason) => reason switch
    {
        NetworkObservationGapReason.AppClosed => "FingVibe was closed",
        NetworkObservationGapReason.Sleep => "the PC was asleep",
        NetworkObservationGapReason.MonitoringOff => "monitoring was turned off",
        _ => "another network was selected"
    };

    internal static string Duration(TimeSpan value)
    {
        if (value < TimeSpan.FromMinutes(1)) return "under a minute";
        if (value < TimeSpan.FromHours(1)) return $"{(int)value.TotalMinutes} min";
        if (value < TimeSpan.FromDays(1)) return value.Minutes == 0 ? $"{(int)value.TotalHours} h" : $"{(int)value.TotalHours} h {value.Minutes} min";
        return value.Hours == 0 ? $"{(int)value.TotalDays} d" : $"{(int)value.TotalDays} d {value.Hours} h";
    }

    private static string GapLabel(NetworkObservationGapReason reason) => reason switch
    {
        NetworkObservationGapReason.AppClosed => "App closed",
        NetworkObservationGapReason.Sleep => "Sleep",
        NetworkObservationGapReason.MonitoringOff => "Monitoring off",
        _ => "Other network selected"
    };

    private static string Sentence(string text) => text.EndsWith('.') ? text : text + ".";
}
