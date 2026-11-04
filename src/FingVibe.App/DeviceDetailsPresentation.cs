using System.Net;
using FingVibe.Core.Models;

namespace FingVibe.App;

internal sealed record DeviceDetailField(string Label, string Value);

internal sealed record DeviceEndpointPresentation(
    OpenPort Endpoint, string Value, Uri? BrowserUri, string BrowserLabel)
{
    public string AccessibleLabel => Endpoint.AccessibleLabel;
    public bool HasBrowserAction => BrowserUri is not null;
}

internal static class DeviceDetailsPresentation
{
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
        }.Where(field => CanCopy(field.Value)).ToArray();
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
