using System.Net;
using System.Globalization;
using FingVibe.Core.Models;

namespace FingVibe.App;

internal sealed record DeviceDetailField(string Label, string Value);

public sealed record DeviceScanHistoryRow(DateTimeOffset CompletedAt, bool Present, bool IsAlternateRow,
    TimeZoneInfo TimeZone)
{
    private DateTimeOffset LocalTime => TimeZoneInfo.ConvertTime(CompletedAt, TimeZone);
    public string Date => LocalTime.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
    public string Time => LocalTime.ToString("HH:mm:ss", CultureInfo.InvariantCulture);
    public string FullTimestamp => LocalTime.ToString("yyyy-MM-dd HH:mm:ss zzz", CultureInfo.InvariantCulture);
    public string State => Present ? "Present" : "Absent";
    public bool Absent => !Present;
    public string AccessibleLabel => $"{FullTimestamp}; Observed {State.ToLowerInvariant()}";
}

public enum DeviceLastSeenKind
{
    Timestamp,
    SeenThisScan,
    Unavailable,
    NeverLocally
}

public sealed record DeviceLastSeen(DeviceLastSeenKind Kind, DateTimeOffset? Timestamp, string Text, string Description)
{
    public static DeviceLastSeen NotCalculated { get; } = Unavailable("last seen has not been calculated.");
    public bool IsMuted => Kind != DeviceLastSeenKind.Timestamp;

    // Shown instead of an age when a clock change makes the saved timestamp later than now.
    internal string LocalTime { get; init; } = string.Empty;

    // Refreshing changes only the displayed age; kind, timestamp, and the exact description never change.
    public DeviceLastSeen At(DateTimeOffset now) =>
        Kind == DeviceLastSeenKind.Timestamp && Timestamp is { } time
            ? this with { Text = DeviceDetailsPresentation.LastSeenAge(time, now) ?? LocalTime }
            : this;

    internal static DeviceLastSeen Unavailable(string reason) =>
        new(DeviceLastSeenKind.Unavailable, null, "Unavailable", $"Last seen: Unavailable - {reason}");
}

internal sealed record DeviceEndpointPresentation(
    OpenPort Endpoint, string Value, Uri? BrowserUri, string BrowserLabel)
{
    public string AccessibleLabel => Endpoint.AccessibleLabel;
    public bool HasBrowserAction => BrowserUri is not null;
}

internal static class DeviceDetailsPresentation
{
    internal static string HistoryTimestamp(DateTimeOffset? timestamp, bool aggregate = false,
        TimeZoneInfo? timeZone = null) =>
        timestamp is { } time
            ? TimeZoneInfo.ConvertTime(time, timeZone ?? TimeZoneInfo.Local)
                .ToString("yyyy-MM-dd HH:mm:ss '(local)'", CultureInfo.InvariantCulture)
                + (aggregate ? " (historical aggregate; individual scan unavailable)" : string.Empty)
            : "Unavailable - no matching local presence evidence.";

    internal static string HistoryTimestampTooltip(DateTimeOffset? timestamp) =>
        timestamp is { } time
            ? TimeZoneInfo.ConvertTime(time, TimeZoneInfo.Local)
                .ToString("yyyy-MM-dd HH:mm:ss zzz", CultureInfo.InvariantCulture)
            : string.Empty;

    internal static string HistoryAge(DateTimeOffset? timestamp, DateTimeOffset now)
    {
        if (timestamp is not { } time) return string.Empty;
        var elapsed = now - time;
        var days = Math.Abs(elapsed.TotalDays);
        var (value, unit) = days >= 365 ? (days / 365, "year")
            : days >= 30 ? (days / 30, "month")
            : days >= 1 ? (days, "day")
            : Math.Abs(elapsed.TotalHours) >= 1 ? (Math.Abs(elapsed.TotalHours), "hour")
            : (Math.Abs(elapsed.TotalMinutes), "minute");
        var rounded = Math.Round(value, MidpointRounding.AwayFromZero);
        var age = $"{rounded.ToString("0", CultureInfo.InvariantCulture)} {unit}{(rounded == 1 ? "" : "s")}";
        return elapsed < TimeSpan.Zero ? $"in {age}" : $"{age} ago";
    }

    // Whole elapsed units (30-day months, 365-day years) change exactly at boundaries and never show 60 min. or 24 h.
    // A future timestamp returns null so callers show its local time rather than a negative or fabricated age.
    internal static string? LastSeenAge(DateTimeOffset timestamp, DateTimeOffset now)
    {
        var elapsed = now - timestamp;
        if (elapsed < TimeSpan.Zero) return null;
        if (elapsed < TimeSpan.FromMinutes(1)) return "< 1 min. ago";
        if (elapsed < TimeSpan.FromHours(1)) return $"{(int)elapsed.TotalMinutes} min. ago";
        if (elapsed < TimeSpan.FromDays(1)) return $"{(int)elapsed.TotalHours} h ago";
        var days = (int)elapsed.TotalDays;
        return days < 30 ? Ago(days, "day") : days < 365 ? Ago(days / 30, "month") : Ago(days / 365, "year");

        static string Ago(int value, string unit) =>
            $"{value.ToString(CultureInfo.InvariantCulture)} {unit}{(value == 1 ? "" : "s")} ago";
    }

    internal static string ObservedSince(DeviceHistorySummary summary, TimeZoneInfo? timeZone = null) =>
        summary.Latest is { } latest && summary.Since is { } since
            ? $"Observed {(latest.Present ? "online" : "offline")} since: {HistoryTimestamp(since, timeZone: timeZone)}"
            : "Observed state / since: Unavailable - no matching individual scan observations.";

    internal static IReadOnlyList<DeviceScanHistoryRow> ScanHistory(DeviceHistorySummary summary,
        TimeZoneInfo? timeZone = null) =>
        summary.History.Select((item, index) => new DeviceScanHistoryRow(
            item.CompletedAt, item.Present, index % 2 == 1, timeZone ?? TimeZoneInfo.Local)).ToArray();

    internal static string EmptyScanHistory(ScanResultRow row, string? networkId, string? subnet) =>
        string.IsNullOrWhiteSpace(networkId) || string.IsNullOrWhiteSpace(subnet)
        ? "Current network identity or subnet unavailable. History and summaries cannot use another network's evidence."
        : row.IsFingOnly
        ? "No local scan history. Imported Fing data is not a local scan observation."
        : row.MacAddress is null
            ? "Scan history requires a MAC-based device identity."
            : "No recorded scan history for the current network/subnet. Earlier saved aggregates are not individual scan observations.";

    internal static bool CanCopy(string? value) =>
        !string.IsNullOrWhiteSpace(value) && value is not ("-" or "Unknown" or "Unknown (likely)");

    internal static DeviceLastSeen LastSeen(ScanResultRow row, string? networkId, string? subnet,
        DateTimeOffset? displayedScanCompletedAt, TimeZoneInfo? timeZone = null, DateTimeOffset? now = null)
    {
        var zone = timeZone ?? TimeZoneInfo.Local;
        string Exact(DateTimeOffset time) =>
            TimeZoneInfo.ConvertTime(time, zone).ToString("yyyy-MM-dd HH:mm:ss zzz", CultureInfo.InvariantCulture);

        if (row.IsFingOnly)
            return new(DeviceLastSeenKind.NeverLocally, null, "Never",
                "Last seen: Never - not observed by a local scan. Imported Fing data is not a local scan observation"
                + " and does not mean the device was never present on any network.");
        if (row.IsCurrentScanResponse && (row.CurrentScanCompletedAt ?? displayedScanCompletedAt) is { } scan)
            return new(DeviceLastSeenKind.SeenThisScan, scan, "Online",
                $"Last seen: Online - responded in the displayed scan ({Exact(scan)})");
        if (row.MacAddress is null)
            return DeviceLastSeen.Unavailable("scan history requires a MAC-based device identity.");
        if (string.IsNullOrWhiteSpace(networkId) || string.IsNullOrWhiteSpace(subnet))
            return DeviceLastSeen.Unavailable(
                "current network identity or subnet unavailable. Another network's evidence is not used.");

        DeviceHistorySummary summary;
        try { summary = row.GetHistorySummary(networkId, subnet); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
            or InvalidDataException or InvalidOperationException)
        {
            return DeviceLastSeen.Unavailable($"saved history could not be loaded: {exception.Message}");
        }
        if (summary.LastSeen is not { } lastSeen)
            return DeviceLastSeen.Unavailable("no matching local presence evidence for the current network/subnet.");
        var local = TimeZoneInfo.ConvertTime(lastSeen, zone).ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture);
        return new DeviceLastSeen(DeviceLastSeenKind.Timestamp, lastSeen, local,
            $"Last seen: {Exact(lastSeen)}"
            + (summary.LastSeenIsAggregate ? " (historical aggregate; individual scan unavailable)" : string.Empty))
        {
            LocalTime = local
        }.At(now ?? DateTimeOffset.UtcNow);
    }

    internal static IReadOnlyList<DeviceDetailField> ImportedFields(ImportedDeviceMetadata? metadata)
    {
        if (metadata is null) return [];
        return new[]
        {
            new DeviceDetailField("Name", metadata.Name ?? ""),
            new DeviceDetailField("Hostname", metadata.Hostname ?? ""),
            new DeviceDetailField("Device type", metadata.Type ?? ""),
            new DeviceDetailField("Brand", metadata.Brand ?? ""),
            new DeviceDetailField("Family", metadata.Family ?? ""),
            new DeviceDetailField("Model", metadata.Model ?? ""),
            new DeviceDetailField("Operating system", metadata.OperatingSystem ?? ""),
            new DeviceDetailField("OS version", metadata.OperatingSystemVersion ?? ""),
            new DeviceDetailField("Historical imported IP (not a current observation)", metadata.Address ?? "")
        }.Where(field => !string.IsNullOrWhiteSpace(field.Value) && field.Value.Trim() != "-").ToArray();
    }

    internal static DeviceEndpointPresentation Endpoint(ScanResultRow row, OpenPort port)
    {
        var scheme = port.Protocol == EndpointProtocol.Tcp ? port.Port switch
        {
            80 or 8080 => "http",
            443 or 8443 => "https",
            _ => null
        } : null;
        var address = row.Result?.Address;
        var uri = scheme is not null && row.CanProbe && address is not null
            && row.Result!.OpenPortItems.Any(item => item.Identity == port.Identity)
            ? new UriBuilder(scheme, address.ToString(), port.Port).Uri : null;
        var host = IPAddress.TryParse(row.AddressText, out var parsed)
            && parsed.AddressFamily == System.Net.Sockets.AddressFamily.InterNetworkV6
                ? $"[{parsed}]" : row.AddressText;
        var label = port.Port is 8080 or 8443
            ? $"Try {scheme?.ToUpperInvariant()}" : $"Open {scheme?.ToUpperInvariant()}";
        return new(port, $"{host}:{port.Port}", uri, uri is null ? string.Empty : label);
    }
}
