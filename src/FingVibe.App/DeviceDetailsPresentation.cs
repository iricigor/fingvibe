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
