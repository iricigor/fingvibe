namespace FingVibe.Core.Networking;

public enum ProviderReportState
{
    /// <summary>An official feed exists, but no report was supplied for it.</summary>
    NotConnected,
    NoIncidents,
    Incident,
    SourcePending,
    OfficialPageOnly,
    /// <summary>Retrieval failed and no usable report is retained.</summary>
    Unavailable,
    /// <summary>A retained report is no longer current because a later retrieval failed.</summary>
    Stale,
    /// <summary>The feed responded with data that could not be read.</summary>
    Malformed
}

/// <summary>
/// One provider-published report for a catalog entry. <paramref name="ProviderUpdated"/> is the provider's own
/// timestamp; <paramref name="RetrievedAt"/> and <paramref name="FailedAt"/> are local request times.
/// </summary>
public sealed record ProviderReport(
    string EntryId,
    ProviderReportState State,
    string? Scope = null,
    DateTimeOffset? ProviderUpdated = null,
    DateTimeOffset? RetrievedAt = null,
    DateTimeOffset? FailedAt = null,
    string? IncidentTitle = null,
    Uri? IncidentLink = null);

/// <param name="RetrievedAt">Local time of the latest completed retrieval, or null when nothing was retrieved.</param>
public sealed record ServiceStatusSnapshot(IReadOnlyList<ProviderReport> Reports, DateTimeOffset? RetrievedAt);

/// <summary>
/// Supplies provider reports for the Service status page. Implementations own parsing, scoped mapping,
/// retrieval and cache policy; <paramref name="refresh"/> is true only for an explicit Refresh reports request.
/// Whole-request failures throw; per-entry failures are reported as Unavailable, Stale or Malformed.
/// </summary>
public interface IServiceStatusSource
{
    Task<ServiceStatusSnapshot> GetReportsAsync(bool refresh, CancellationToken cancellationToken);
}

/// <summary>An explicitly unconnected source for offline use: it sends no requests and reports nothing.</summary>
public sealed class UnconnectedServiceStatusSource : IServiceStatusSource
{
    public Task<ServiceStatusSnapshot> GetReportsAsync(bool refresh, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(new ServiceStatusSnapshot([], null));
    }
}

/// <summary>Synthetic, controlled reports covering every presentation state for UI review. Never live data.</summary>
public sealed class ControlledServiceStatusSource(TimeProvider time) : IServiceStatusSource
{
    public Task<ServiceStatusSnapshot> GetReportsAsync(bool refresh, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.FromResult(Create(time.GetLocalNow()));
    }

    public static ServiceStatusSnapshot Create(DateTimeOffset now) => new(
    [
        new("microsoft-azure", ProviderReportState.NoIncidents, "In published feed", now.AddMinutes(-1), now),
        new("google-gmail", ProviderReportState.NoIncidents, "In published feed", now.AddMinutes(-1), now),
        new("google-cloud", ProviderReportState.Incident, "Example: europe-west1", now.AddMinutes(-4), now,
            IncidentTitle: "Degraded service", IncidentLink: new("https://status.cloud.google.com/")),
        new("amazon-aws", ProviderReportState.NoIncidents, "Published service/region scope", now.AddMinutes(-1), now),
        new("cloudflare-dns", ProviderReportState.Malformed, FailedAt: now),
        new("cloudflare-network", ProviderReportState.Stale, "In published feed", now.AddMinutes(-40), now.AddMinutes(-35), now),
        new("github-website", ProviderReportState.NoIncidents, "In published feed", now.AddMinutes(-1), now),
        new("github-actions", ProviderReportState.Unavailable, FailedAt: now)
    ], now);
}
