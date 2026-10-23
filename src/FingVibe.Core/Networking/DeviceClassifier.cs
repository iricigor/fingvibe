using System.Text.RegularExpressions;
using FingVibe.Core.Models;

namespace FingVibe.Core.Networking;

public sealed record SsdpDeviceInfo(
    string? FriendlyName,
    string? DeviceType,
    string? Manufacturer,
    string? ModelName,
    string? Server);

public sealed record MdnsDeviceInfo(
    IReadOnlyList<string> Services, string? Model = null, bool HasConflictingModels = false);

public static class DeviceClassifier
{
    public static DeviceClassification Classify(SsdpDeviceInfo? ssdp, MdnsDeviceInfo? mdns)
        => ClassifyAdvertisements(ssdp is null ? [] : [ssdp], mdns);

    public static DeviceClassification ClassifyAdvertisements(
        IEnumerable<SsdpDeviceInfo> advertisements, MdnsDeviceInfo? mdns)
    {
        var operatingSystems = new Dictionary<DeviceOperatingSystem, string>();
        var types = new Dictionary<DeviceType, string>();
        var serviceTypes = new Dictionary<DeviceType, string>();
        foreach (var ssdp in advertisements)
        {
            var advertisedOs = new Dictionary<DeviceOperatingSystem, string>();
            foreach (var (pattern, os) in new[]
            {
                (@"\bWindows\b", DeviceOperatingSystem.Windows),
                (@"\bAndroid\b", DeviceOperatingSystem.Android),
                (@"\bLinux\b", DeviceOperatingSystem.Linux),
                (@"\b(?:macOS|Mac OS X)\b", DeviceOperatingSystem.MacOS),
                (@"\b(?:iOS|iPadOS)\b", DeviceOperatingSystem.IOS)
            })
            {
                if (Regex.IsMatch(ssdp.Server ?? string.Empty, pattern,
                    RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
                {
                    advertisedOs.TryAdd(os, $"SSDP SERVER advertises {os.Label()}.");
                }
            }

            // Android is Linux-based; an explicit Android token in the same advertisement is more specific.
            if (advertisedOs.ContainsKey(DeviceOperatingSystem.Android))
            {
                advertisedOs.Remove(DeviceOperatingSystem.Linux);
            }
            foreach (var (os, evidence) in advertisedOs)
            {
                operatingSystems.TryAdd(os, evidence);
            }

            var upnpType = ssdp.DeviceType?.Split(':').ElementAtOrDefault(3);
            var advertisedType = upnpType?.ToLowerInvariant() switch
            {
                "internetgatewaydevice" or "wandevice" or "wlanaccesspointdevice" => DeviceType.Router,
                "printer" or "printerbasic" => DeviceType.Printer,
                "mediarenderer" => DeviceType.MediaDevice,
                "binarylight" or "dimmablelight" or "hvac_system" => DeviceType.SmartDevice,
                _ => DeviceType.Unknown
            };
            if (advertisedType != DeviceType.Unknown)
            {
                types.TryAdd(advertisedType, $"UPnP device type: {upnpType}.");
            }
        }

        foreach (var service in mdns?.Services ?? [])
        {
            var type = service.ToLowerInvariant() switch
            {
                "_ipp._tcp.local" or "_ipps._tcp.local" or "_printer._tcp.local" => DeviceType.Printer,
                "_googlecast._tcp.local" => DeviceType.MediaDevice,
                "_hap._tcp.local" => DeviceType.SmartDevice,
                _ => DeviceType.Unknown
            };
            if (type != DeviceType.Unknown)
            {
                serviceTypes.TryAdd(type, $"DNS-SD service: {service} (likely).");
            }
        }

        var model = mdns is { HasConflictingModels: false } ? mdns.Model : null;
        if (!string.IsNullOrWhiteSpace(model))
        {
            var modelType = model.ToLowerInvariant() switch
            {
                var text when text.StartsWith("iphone") => DeviceType.Phone,
                var text when text.StartsWith("ipad") => DeviceType.Tablet,
                var text when text.StartsWith("macbook") || text.StartsWith("imac")
                    || text.StartsWith("macmini") || text.StartsWith("macpro")
                    || text.StartsWith("macstudio") => DeviceType.Computer,
                var text when text.StartsWith("appletv") => DeviceType.MediaDevice,
                _ => DeviceType.Unknown
            };
            if (modelType != DeviceType.Unknown)
            {
                types.TryAdd(modelType, $"DNS-SD advertised model: {model}.");
                var os = modelType switch
                {
                    DeviceType.Phone or DeviceType.Tablet => DeviceOperatingSystem.IOS,
                    DeviceType.Computer => DeviceOperatingSystem.MacOS,
                    _ => DeviceOperatingSystem.Unknown
                };
                if (os != DeviceOperatingSystem.Unknown)
                {
                    operatingSystems.TryAdd(os, $"DNS-SD advertised model: {model} (likely).");
                }
            }
        }

        if (types.Count == 0)
        {
            types = serviceTypes;
        }

        return new DeviceClassification(
            operatingSystems.Count == 1 ? operatingSystems.Keys.Single() : DeviceOperatingSystem.Unknown,
            types.Count == 1 ? types.Keys.Single() : DeviceType.Unknown,
            Evidence(operatingSystems, "OS", mdns is { HasConflictingModels: true }
                ? "Conflicting DNS-SD models; no reliable OS evidence advertised."
                : DeviceClassification.Unknown.OperatingSystemEvidence),
            Evidence(types, "device-type", mdns is { HasConflictingModels: true }
                ? "Conflicting DNS-SD models; no reliable device-type evidence advertised."
                : DeviceClassification.Unknown.TypeEvidence));
    }

    private static string Evidence<T>(Dictionary<T, string> candidates, string kind, string unknown)
        where T : notnull => candidates.Count switch
        {
            0 => unknown,
            1 => candidates.Values.Single(),
            _ => $"Conflicting {kind} evidence: {string.Join(" ", candidates.Values)}"
        };
}
