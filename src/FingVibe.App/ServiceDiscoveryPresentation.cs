using System.Globalization;
using FingVibe.Core.Models;

namespace FingVibe.App;

internal static class ServiceDiscoveryPresentation
{
    private const int TooltipServices = 6;

    internal static string Tooltip(IReadOnlyList<ServiceAdvertisement> advertisements, TimeZoneInfo? timeZone = null)
    {
        if (advertisements.Count == 0) return string.Empty;
        var lines = advertisements.Take(TooltipServices).Select(item => $"• {item.Summary} - {item.ProtocolText}");
        var more = advertisements.Count > TooltipServices ? $"\n• and {advertisements.Count - TooltipServices} more" : string.Empty;
        return $"Advertised in the latest scan, observed {ObservedText(advertisements, timeZone)}:\n"
            + string.Join("\n", lines) + more + "\nOpen Service discovery in Device Details.";
    }

    internal static string Heading(IReadOnlyList<ServiceAdvertisement> advertisements) =>
        $"Service discovery ({advertisements.Count})";

    internal static string ObservedText(IReadOnlyList<ServiceAdvertisement> advertisements, TimeZoneInfo? timeZone = null) =>
        advertisements.Count == 0 ? "-" : Time(advertisements.Max(item => item.ObservedAt), timeZone);

    internal static string Time(DateTimeOffset time, TimeZoneInfo? timeZone = null) =>
        TimeZoneInfo.ConvertTime(time, timeZone ?? TimeZoneInfo.Local).ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture);

    // Metadata stays labeled as advertised; it never replaces saved/manual names, hostnames or models.
    internal static IReadOnlyList<(string Label, string Value)> Fields(ServiceAdvertisement item, TimeZoneInfo? timeZone = null)
    {
        var fields = new List<(string, string)>
        {
            ("Service", item.ServiceType),
            ("Protocol", item.ProtocolText),
            ("Advertised endpoint", item.EndpointText)
        };
        if (item.Role is { } role) fields.Add(("Inferred role", role));
        if (item.InstanceName is { } instance) fields.Add(("Advertised instance", instance));
        if (item.AdvertisedName is { } name) fields.Add(("Advertised name", name));
        if (item.Manufacturer is { } manufacturer) fields.Add(("Advertised manufacturer", manufacturer));
        if (item.Model is { } model) fields.Add(("Advertised model", model));
        fields.Add(("TCP verification", item.VerificationText));
        fields.Add(("Observed", Time(item.ObservedAt, timeZone)));
        return fields;
    }
}
