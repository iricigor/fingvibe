namespace FingVibe.Core.Models;

public sealed record LogicalDeviceId(string Kind, string Id)
{
    public static LogicalDeviceId Mac(string mac) => new("mac", PeopleRoomsData.NormalizeMacAddress(mac));
    public static LogicalDeviceId Virtual(Guid id) => new("virtual", id.ToString("D"));
}

public sealed record AnalyticsEvidenceRequest(
    string NetworkId, string Subnet, DateTimeOffset QueryTime, int CalendarDays,
    TimeZoneInfo TimeZone, Guid ExpectedRevision, IReadOnlyList<LogicalDeviceId>? Devices = null);

public enum AnalyticsResponse : byte
{
    Unknown,
    Responded,
    DidNotRespond
}

public enum AnalyticsCoverage { Unknown, Partial, Exact }

public sealed record AnalyticsDevice(
    LogicalDeviceId Identity, DateTimeOffset? FirstReliableSighting, bool AmbiguousMapping);

public sealed record AnalyticsScanEvidence(
    Guid? ScanId, DateTimeOffset CompletedAt, DateTimeOffset LocalCompletedAt,
    ScanCheckpointState? State, int UnidentifiedResponses, IReadOnlyList<AnalyticsResponse> Responses)
{
    public bool HasCompletedLedger => ScanId is not null && State == ScanCheckpointState.Complete;
    public AnalyticsCoverage Coverage => State is ScanCheckpointState.Pending or ScanCheckpointState.Incomplete
        ? AnalyticsCoverage.Unknown
        : HasCompletedLedger && UnidentifiedResponses == 0 && Responses.All(value => value != AnalyticsResponse.Unknown)
            ? AnalyticsCoverage.Exact
            : HasCompletedLedger || Responses.Any(value => value != AnalyticsResponse.Unknown)
                ? AnalyticsCoverage.Partial : AnalyticsCoverage.Unknown;
}

// Responses are aligned with Devices by index; a null ScanId is explicit legacy evidence,
// never a reconstructed completed scan. LatestScan can precede the selected calendar window.
public sealed record AnalyticsEvidence(
    Guid Revision, string NetworkId, string Subnet, DateTimeOffset QueryTime,
    string TimeZoneId, DateOnly FirstDate, DateOnly LastDate, DateTimeOffset WindowStart,
    IReadOnlyList<AnalyticsDevice> Devices, IReadOnlyList<AnalyticsScanEvidence> Scans,
    AnalyticsScanEvidence? LatestScan);

internal sealed record ScanEvidenceWrite(
    Guid ScanId, string? NetworkId, string Subnet, DateTimeOffset CompletedAt,
    ScanCheckpointState State, int UnidentifiedResponses)
{
    internal static ScanEvidenceWrite From(ScanSnapshot scan) => new(
        scan.ScanId, scan.NetworkId, scan.Subnet, scan.CompletedAt, scan.State,
        scan.Results.Where(result => result.Status == HostStatus.Alive
                && result.MacAddress?.GetAddressBytes().Length != 6)
            .Select(result => result.AddressText).Distinct().Count());
}
