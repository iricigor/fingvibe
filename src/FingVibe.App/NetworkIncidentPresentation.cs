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
    string? Gaps,
    string Evidence = NetworkIncidentPresentation.NoEvidenceStatus)
{
    public string AccessibleName => string.Join(" ", new[] { $"{Status} incident.", Symptoms, Times, Recovery, Network, Gaps, Evidence }
        .Where(part => !string.IsNullOrWhiteSpace(part)));
}

internal sealed record NetworkEvidenceRow(string Label, string Result);

/// <summary>Saved deeper diagnostic evidence for one incident, labelled with its network and observation time.</summary>
internal sealed record NetworkEvidenceView(
    string Context,
    string Outcome,
    string? Summary,
    IReadOnlyList<NetworkEvidenceRow> Checks,
    string? Trace,
    IReadOnlyList<NetworkEvidenceRow> Hops)
{
    public string Signature => string.Join("\n", new[] { Context, Outcome, Summary ?? "", Trace ?? "" }
        .Concat(Checks.Concat(Hops).Select(row => $"{row.Label}\t{row.Result}")));
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
    public const string NoEvidenceStatus = "Deeper diagnostics: none saved.";
    public const string SelectText =
        "Select an incident to view its saved deeper diagnostic evidence. Viewing evidence sends no probes.";

    public static IReadOnlyList<NetworkIncidentRow> Rows(
        IReadOnlyList<NetworkIncident> incidents, DateTimeOffset now, TimeZoneInfo timeZone, CultureInfo culture) =>
        Rows(incidents, new Dictionary<Guid, NetworkIncidentEvidence>(), now, timeZone, culture);

    public static IReadOnlyList<NetworkIncidentRow> Rows(IReadOnlyList<NetworkIncident> incidents,
        IReadOnlyDictionary<Guid, NetworkIncidentEvidence> evidence, DateTimeOffset now, TimeZoneInfo timeZone,
        CultureInfo culture) =>
        incidents.Select(incident => Row(incident, now, timeZone, culture) with
        {
            Evidence = EvidenceStatus(evidence.GetValueOrDefault(incident.Id))
        }).ToList();

    public static string EvidenceStatus(NetworkIncidentEvidence? evidence) => evidence?.Outcome switch
    {
        null => NoEvidenceStatus,
        NetworkEvidenceOutcome.Running => "Deeper diagnostics: running.",
        NetworkEvidenceOutcome.Complete => "Deeper diagnostics: complete.",
        NetworkEvidenceOutcome.Partial => "Deeper diagnostics: partial.",
        NetworkEvidenceOutcome.NotRun => "Deeper diagnostics: not run.",
        _ => "Deeper diagnostics: failed."
    };

    public static NetworkEvidenceView Evidence(NetworkIncident incident, NetworkIncidentEvidence? evidence,
        DateTimeOffset now, TimeZoneInfo timeZone, CultureInfo culture)
    {
        string Time(DateTimeOffset value) => NetworkMonitorViewPresentation.FormatTime(value, now, timeZone, culture);
        if (evidence is null)
            return new($"Incident first observed {Time(incident.FirstObservedAt)} on {incident.NetworkLabel}.",
                "No deeper diagnostic evidence is saved for this incident. Deeper diagnostics run once, automatically, " +
                "when an incident is confirmed; incidents recorded before that feature have none.",
                null, [], null, []);

        var context = $"Saved evidence from {incident.NetworkLabel}, collected {Time(evidence.StartedAt)}" +
            (evidence.Outcome == NetworkEvidenceOutcome.Complete && evidence.CompletedAt is { } done
                ? $" to {Time(done)}" : "") +
            ". This is history, not current status; viewing it sends no probes.";
        var outcome = evidence.Outcome switch
        {
            NetworkEvidenceOutcome.Running => "Running: deeper diagnostics started for this incident and have not finished.",
            NetworkEvidenceOutcome.Complete => "Complete: every check finished within the 45-second limit.",
            NetworkEvidenceOutcome.Partial => $"Partial: {evidence.Detail}",
            _ => evidence.Detail
        };
        var summary = string.IsNullOrWhiteSpace(evidence.SummaryStatus) ? null
            : $"{evidence.SummaryStatus}: {evidence.SummaryExplanation}";
        var checks = evidence.Observations.OrderBy(item => item.Checkpoint)
            .Select(item => new NetworkEvidenceRow(CheckpointLabel(item.Checkpoint),
                FingVibe.Core.Formatting.NetworkDiagnosticFormatter.Describe(item))).ToList();
        string? trace = evidence.Outcome is NetworkEvidenceOutcome.NotRun ? null
            : evidence.Hops.Count == 0 ? "Traceroute toward 1.1.1.1: no hops were observed."
            : evidence.TraceComplete ? $"Traceroute toward 1.1.1.1: destination reached at hop {evidence.Hops[^1].Number}. Unanswered earlier hops do not prove a broken link."
            : $"Traceroute toward 1.1.1.1: incomplete after {evidence.Hops.Count} hop{(evidence.Hops.Count == 1 ? "" : "s")}. Filtering or routing may explain unanswered hops.";
        var hops = evidence.Hops.Select(hop => new NetworkEvidenceRow($"Hop {hop.Number}",
            $"{hop.Observation.State}: {hop.Observation.RespondingAddress?.ToString() ?? "no responder"}" +
            (hop.Observation.RoundtripMilliseconds is { } ms ? $", {ms} ms" : ""))).ToList();
        return new(context, outcome, summary, checks, trace, hops);
    }

    internal static string CheckpointLabel(FingVibe.Core.Models.DiagnosticCheckpoint checkpoint) => checkpoint switch
    {
        FingVibe.Core.Models.DiagnosticCheckpoint.Loopback => "Loopback",
        FingVibe.Core.Models.DiagnosticCheckpoint.LocalAddress => "This PC LAN IPv4",
        FingVibe.Core.Models.DiagnosticCheckpoint.Gateway => "Default gateway LAN IPv4",
        FingVibe.Core.Models.DiagnosticCheckpoint.LanPeer => "Selected LAN peer",
        FingVibe.Core.Models.DiagnosticCheckpoint.RouterWan => "Optional router WAN IPv4",
        FingVibe.Core.Models.DiagnosticCheckpoint.Hop2 => "Observed hop 2",
        FingVibe.Core.Models.DiagnosticCheckpoint.CloudflarePing => "Cloudflare IP ping",
        FingVibe.Core.Models.DiagnosticCheckpoint.GooglePing => "Google IP ping",
        FingVibe.Core.Models.DiagnosticCheckpoint.ConfiguredDns => "Windows configured DNS",
        FingVibe.Core.Models.DiagnosticCheckpoint.CloudflareDns => "Direct Cloudflare DNS",
        _ => "Direct Google DNS"
    };

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
