using System.Net;
using System.Globalization;
using FingVibe.Core.Models;

namespace FingVibe.App;

internal sealed record DeviceDetailField(string Label, string Value);

public sealed record DeviceScanHistoryRow(string ScanTime, string State, string NetworkContext)
{
    public string AccessibleLabel => $"{ScanTime}; {State}; {NetworkContext}";
}

internal sealed record DeviceEndpointPresentation(
    OpenPort Endpoint, string Value, Uri? BrowserUri, string BrowserLabel)
{
    public string AccessibleLabel => Endpoint.AccessibleLabel;
    public bool HasBrowserAction => BrowserUri is not null;
}

internal static class DeviceDetailsPresentation
{
    internal static string HistoryTimestamp(DateTimeOffset? timestamp, bool aggregate = false) =>
        timestamp is { } time
            ? time.UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss 'UTC'", CultureInfo.InvariantCulture)
                + (aggregate ? " (historical aggregate; individual scan unavailable)" : string.Empty)
            : "Unavailable - no matching local presence evidence.";

    internal static string ObservedSince(DeviceHistorySummary summary) =>
        summary.Latest is { } latest && summary.Since is { } since
            ? $"Observed {(latest.Present ? "online" : "offline")} since: {HistoryTimestamp(since)}"
            : "Observed state / since: Unavailable - no matching individual scan observations.";

    internal static IReadOnlyList<DeviceScanHistoryRow> ScanHistory(DeviceHistorySummary summary) =>
        summary.History.Select(item => new DeviceScanHistoryRow(
            HistoryTimestamp(item.CompletedAt),
            item.Present ? "Observed present" : "Observed absent",
            $"Network {item.NetworkId ?? "identity unavailable"} | {item.Subnet}")).ToArray();

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
