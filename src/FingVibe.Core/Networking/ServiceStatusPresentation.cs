using System.Globalization;

namespace FingVibe.Core.Networking;

public enum ServiceStatusFilter
{
    All,
    Consumer,
    Infrastructure
}

public enum ServiceStatusTone
{
    Neutral,
    Good,
    Attention
}

public sealed record ServiceStatusRow(
    ServiceStatusEntry Entry,
    ProviderReportState State,
    string Headline,
    string Detail,
    ServiceStatusTone Tone,
    string SourceLine,
    string TimestampLine,
    Uri Link,
    string LinkLabel)
{
    public string CategoryText => ServiceStatusPresentation.CategoryText(Entry.Category);

    public string AccessibleName =>
        $"{Entry.Provider} {Entry.Service}, {CategoryText}: {Headline}. {Detail}. {SourceLine}, {TimestampLine}.";
}

public static class ServiceStatusPresentation
{
    public static string CategoryText(ServiceStatusCategory category) =>
        category == ServiceStatusCategory.Consumer ? "Consumer" : "Infrastructure";

    public static string FilterText(ServiceStatusFilter filter) => filter switch
    {
        ServiceStatusFilter.Consumer => "Consumer",
        ServiceStatusFilter.Infrastructure => "Infrastructure",
        _ => $"All {ServiceStatusCatalog.Entries.Count}"
    };

    public static IReadOnlyList<ServiceStatusRow> Rows(ServiceStatusSnapshot? snapshot, DateTimeOffset now)
    {
        var reports = snapshot?.Reports.GroupBy(report => report.EntryId, StringComparer.Ordinal)
            .ToDictionary(group => group.Key, group => group.Last(), StringComparer.Ordinal) ?? [];
        return [.. ServiceStatusCatalog.Entries.Select(entry => Row(entry, reports.GetValueOrDefault(entry.Id), now))];
    }

    public static IReadOnlyList<ServiceStatusRow> Filter(IEnumerable<ServiceStatusRow> rows, ServiceStatusFilter filter) =>
        [.. rows.Where(row => filter == ServiceStatusFilter.All ||
            (filter == ServiceStatusFilter.Consumer) == (row.Entry.Category == ServiceStatusCategory.Consumer))];

    public static ServiceStatusRow Row(ServiceStatusEntry entry, ProviderReport? report, DateTimeOffset now)
    {
        // Entries without an approved feed are never monitored, whatever a source returns for them.
        var state = entry.SourceKind switch
        {
            ServiceStatusSourceKind.NoApprovedSource => ProviderReportState.SourcePending,
            ServiceStatusSourceKind.OfficialPageOnly => ProviderReportState.OfficialPageOnly,
            _ => report?.State is { } reported and not ProviderReportState.SourcePending and not ProviderReportState.OfficialPageOnly
                ? reported : ProviderReportState.NotConnected
        };
        if (state == ProviderReportState.NotConnected) report = null;
        var link = state == ProviderReportState.Incident && report?.IncidentLink is { } incident ? incident : entry.Link;
        var linkLabel = state == ProviderReportState.Incident && report?.IncidentLink is not null ? "View incident" : entry.LinkLabel;
        var (headline, detail, tone) = state switch
        {
            ProviderReportState.NoIncidents => ("No incidents reported", report?.Scope ?? "In published feed", ServiceStatusTone.Good),
            ProviderReportState.Incident => (string.IsNullOrWhiteSpace(report?.IncidentTitle) ? "Incident reported" : report.IncidentTitle,
                report?.Scope ?? "Published scope unavailable", ServiceStatusTone.Attention),
            ProviderReportState.SourcePending => ("Source pending", "Not monitored", ServiceStatusTone.Neutral),
            ProviderReportState.OfficialPageOnly => ("Official page only", "Not monitored", ServiceStatusTone.Neutral),
            ProviderReportState.Unavailable => ("Feed unavailable", "Status unknown - try refresh", ServiceStatusTone.Attention),
            ProviderReportState.Stale => ("Report outdated",
                report?.RetrievedAt is { } retrieved ? $"Retained from {Time(retrieved, now)} - not current" : "Retained report - not current",
                ServiceStatusTone.Attention),
            ProviderReportState.Malformed => ("Feed unreadable", "Status unknown - unexpected data", ServiceStatusTone.Attention),
            _ => ("Feed not connected", "Not monitored - open the status page", ServiceStatusTone.Neutral)
        };
        var timestamp = state switch
        {
            ProviderReportState.NoIncidents or ProviderReportState.Incident => report?.ProviderUpdated is { } updated
                ? $"Provider updated {Time(updated, now)}" : "No provider timestamp",
            ProviderReportState.Stale or ProviderReportState.Unavailable => report?.FailedAt is { } failed
                ? $"Refresh failed at {Time(failed, now)}" : "Refresh failed",
            ProviderReportState.Malformed => report?.FailedAt is { } checkedAt
                ? $"Unreadable at {Time(checkedAt, now)}" : "Unreadable response",
            _ => "No feed timestamp"
        };
        return new(entry, state, headline, detail, tone, entry.SourceName, timestamp, link, linkLabel);
    }

    public static string Summary(IReadOnlyCollection<ServiceStatusRow> rows)
    {
        var issues = rows.Count(row => row.State == ProviderReportState.Incident);
        var problems = rows.Count(row => row.State is ProviderReportState.Unavailable or ProviderReportState.Stale or ProviderReportState.Malformed);
        var unmonitored = rows.Count(row => row.State is ProviderReportState.NotConnected or ProviderReportState.SourcePending
            or ProviderReportState.OfficialPageOnly);
        return $"{issues} reported {Plural(issues, "issue")} | {problems} {Plural(problems, "feed")} without current data | " +
            $"{unmonitored} {Plural(unmonitored, "entry", "entries")} not monitored";
    }

    public static string RetrievalText(ServiceStatusSnapshot? snapshot, DateTimeOffset now) =>
        snapshot?.RetrievedAt is { } retrieved
            ? $"Feed refresh: {(retrieved.Date == now.Date ? "today, " : "")}{Time(retrieved, now)}"
            : "Provider feeds not retrieved";

    /// <summary>After a failed whole refresh, retained reports remain visible but can no longer look current.</summary>
    public static ServiceStatusSnapshot MarkStale(ServiceStatusSnapshot snapshot, DateTimeOffset failedAt) => snapshot with
    {
        Reports = [.. snapshot.Reports.Select(report => report.State is ProviderReportState.NoIncidents or ProviderReportState.Incident
            ? report with { State = ProviderReportState.Stale, RetrievedAt = report.RetrievedAt ?? snapshot.RetrievedAt, FailedAt = failedAt }
            : report)]
    };

    private static string Time(DateTimeOffset value, DateTimeOffset now) =>
        value.Date == now.Date
            ? value.ToString("HH:mm", CultureInfo.InvariantCulture)
            : value.ToString("d MMM, HH:mm", CultureInfo.InvariantCulture);

    private static string Plural(int count, string singular, string? plural = null) =>
        count == 1 ? singular : plural ?? singular + "s";
}

/// <summary>Service status page state: loads reports from one source and keeps request failures explicit.</summary>
public sealed class ServiceStatusPageModel(IServiceStatusSource source, TimeProvider time)
{
    public ServiceStatusSnapshot? Snapshot { get; private set; }
    public string? RequestError { get; private set; }
    public ServiceStatusFilter Filter { get; set; }

    public IReadOnlyList<ServiceStatusRow> AllRows => ServiceStatusPresentation.Rows(Snapshot, time.GetLocalNow());
    public IReadOnlyList<ServiceStatusRow> VisibleRows => ServiceStatusPresentation.Filter(AllRows, Filter);
    public string Summary => ServiceStatusPresentation.Summary(AllRows);
    public string RetrievalText => ServiceStatusPresentation.RetrievalText(Snapshot, time.GetLocalNow());

    public async Task LoadAsync(bool refresh, CancellationToken cancellationToken)
    {
        try
        {
            Snapshot = await source.GetReportsAsync(refresh, cancellationToken);
            RequestError = null;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception)
        {
            var now = time.GetLocalNow();
            if (Snapshot is { } retained) Snapshot = ServiceStatusPresentation.MarkStale(retained, now);
            RequestError = $"Provider reports could not be retrieved: {exception.Message} Earlier reports, if any, are marked outdated.";
        }
    }
}
