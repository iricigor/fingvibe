using System.Text.RegularExpressions;
using System.Net;
using System.Runtime.InteropServices;
using FingVibe.Core.Models;

namespace FingVibe.Core.Networking;

public sealed record SsdpDeviceInfo(
    string? FriendlyName,
    string? DeviceType,
    string? Manufacturer,
    string? ModelName,
    string? Server);

public sealed record MdnsDeviceInfo(
    IReadOnlyList<string> Services, string? Model = null, bool HasConflictingModels = false,
    string? HostName = null);

public sealed record ServiceBanner(string Source, string Value);

public static class DeviceClassifier
{
    public static DeviceClassification Classify(SsdpDeviceInfo? ssdp, MdnsDeviceInfo? mdns)
        => ClassifyAdvertisements(ssdp is null ? [] : [ssdp], mdns);

    public static DeviceClassification ClassifyAdvertisements(
        IEnumerable<SsdpDeviceInfo> advertisements, MdnsDeviceInfo? mdns,
        string? discoveredName = null, string? vendorName = null,
        IReadOnlyList<OpenPort>? openPorts = null, IReadOnlyList<ServiceBanner>? banners = null,
        int? responseTtl = null)
    {
        var devices = advertisements.ToArray();
        var operatingSystems = new Dictionary<DeviceOperatingSystem, string>();
        var inferredOperatingSystems = new HashSet<DeviceOperatingSystem>();
        var types = new Dictionary<DeviceType, string>();
        var serviceTypes = new Dictionary<DeviceType, string>();
        foreach (var ssdp in devices)
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

        foreach (var banner in banners ?? [])
        {
            foreach (var (pattern, os) in new[]
            {
                (@"\b(?:Windows|Microsoft-IIS|Microsoft-HTTPAPI|OpenSSH_for_Windows)(?=$|[^A-Za-z])", DeviceOperatingSystem.Windows),
                (@"\b(?:Linux|Ubuntu|Debian|Raspbian|OpenWrt)\b", DeviceOperatingSystem.Linux),
                (@"\bAndroid\b", DeviceOperatingSystem.Android)
            })
            {
                if (Regex.IsMatch(banner.Value, pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant))
                {
                    operatingSystems.TryAdd(os, $"{banner.Source}: {banner.Value}.");
                }
            }
        }

        foreach (var service in mdns?.Services ?? [])
        {
            var type = service.ToLowerInvariant() switch
            {
                "_ipp._tcp.local" or "_ipps._tcp.local" or "_printer._tcp.local" => DeviceType.Printer,
                "_googlecast._tcp.local" => DeviceType.MediaDevice,
                "_hap._tcp.local" => DeviceType.SmartDevice,
                "_androidtvremote._tcp.local" or "_androidtvremote2._tcp.local" => DeviceType.MediaDevice,
                "_adisk._tcp.local" => DeviceType.Storage,
                _ => DeviceType.Unknown
            };
            if (type != DeviceType.Unknown)
            {
                serviceTypes.TryAdd(type, $"DNS-SD service: {service} (likely).");
            }

            if (service.Equals("_androidtvremote._tcp.local", StringComparison.OrdinalIgnoreCase)
                || service.Equals("_androidtvremote2._tcp.local", StringComparison.OrdinalIgnoreCase)
                || service.Equals("_adb-tls-connect._tcp.local", StringComparison.OrdinalIgnoreCase))
            {
                operatingSystems.TryAdd(DeviceOperatingSystem.Android, $"DNS-SD service: {service}.");
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
                    if (operatingSystems.TryAdd(os, $"DNS-SD advertised model: {model} (likely)."))
                    {
                        inferredOperatingSystems.Add(os);
                    }
                }
            }
        }

        var usingServiceTypes = types.Count == 0;
        if (usingServiceTypes)
        {
            types = serviceTypes;
        }

        var result = new DeviceClassification(
            operatingSystems.Count == 1 ? operatingSystems.Keys.Single() : DeviceOperatingSystem.Unknown,
            types.Count == 1 ? types.Keys.Single() : DeviceType.Unknown,
            Evidence(operatingSystems, "OS", mdns is { HasConflictingModels: true }
                ? "Conflicting DNS-SD models; no reliable OS evidence advertised."
                : DeviceClassification.Unknown.OperatingSystemEvidence),
            Evidence(types, "device-type", mdns is { HasConflictingModels: true }
                ? "Conflicting DNS-SD models; no reliable device-type evidence advertised."
                : DeviceClassification.Unknown.TypeEvidence),
            OperatingSystemIsInferred: operatingSystems.Count == 1
                && inferredOperatingSystems.Contains(operatingSystems.Keys.Single()),
            TypeIsInferred: types.Count == 1 && usingServiceTypes);

        return ApplyFallbacks(result, devices, mdns, discoveredName, vendorName, openPorts ?? [],
            operatingSystems.Count == 0 && mdns?.HasConflictingModels != true,
            types.Count == 0 && mdns?.HasConflictingModels != true, responseTtl);
    }

    private static DeviceClassification ApplyFallbacks(
        DeviceClassification result, IReadOnlyList<SsdpDeviceInfo> devices, MdnsDeviceInfo? mdns,
        string? discoveredName, string? vendorName, IReadOnlyList<OpenPort> ports,
        bool inferOperatingSystem, bool inferDeviceType, int? responseTtl)
    {
        var identities = devices.Select(device => $"{device.ModelName} {device.FriendlyName}")
            .Append(mdns is { HasConflictingModels: false } ? mdns.Model ?? string.Empty : string.Empty)
            .Append(discoveredName ?? string.Empty).ToArray();
        var vendor = vendorName ?? string.Empty;
        bool Product(string pattern) => identities.Any(identity =>
            Regex.IsMatch(identity, pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant));
        bool Vendor(string name) => vendor.Contains(name, StringComparison.OrdinalIgnoreCase)
            || devices.Any(device => device.Manufacturer?.Contains(name, StringComparison.OrdinalIgnoreCase) == true);
        bool HasPort(int port) => ports.Any(value => value.Protocol == EndpointProtocol.Tcp && value.Port == port);
        var canUseWindowsHint = false;

        if (inferOperatingSystem)
        {
            var osHints = new HashSet<DeviceOperatingSystem>();
            if (Product(@"\bAndroid(?:[-_ .\d]|$)"))
            {
                osHints.Add(DeviceOperatingSystem.Android);
            }
            if (Product(@"\b(?:iPhone|iPad)(?:[-_ .\d,]|$)"))
            {
                osHints.Add(DeviceOperatingSystem.IOS);
            }
            if (Product(@"\b(?:MacBook(?:Air|Pro)?|iMac|Macmini|MacPro|MacStudio)(?:[-_ .\d,]|$)"))
            {
                osHints.Add(DeviceOperatingSystem.MacOS);
            }
            if (osHints.Count == 1)
            {
                var os = osHints.Single();
                result = result with
                {
                    OperatingSystem = os,
                    OperatingSystemEvidence = $"Likely {os.Label()} from discovered product/host identity: {string.Join("; ", identities.Where(text => !string.IsNullOrWhiteSpace(text)))}.",
                    OperatingSystemIsInferred = true
                };
            }
            else if (osHints.Count > 1)
            {
                result = result with { OperatingSystemEvidence = "Conflicting OS hints in discovered product/host identities." };
            }
            canUseWindowsHint = osHints.Count == 0;
        }

        DeviceClassification Complete(DeviceClassification candidate)
        {
            if (canUseWindowsHint && responseTtl is 127 or 128 && HasPort(445)
                && (candidate.Type == DeviceType.Computer
                    || candidate.Type == DeviceType.Unknown && inferDeviceType))
            {
                candidate = candidate with
                {
                    OperatingSystem = DeviceOperatingSystem.Windows,
                    OperatingSystemEvidence = $"Likely Windows: ICMP response TTL {responseTtl} together with SMB on TCP 445. This combination is a heuristic, not OS proof.",
                    OperatingSystemIsInferred = true
                };
            }
            if (inferDeviceType && candidate.Type == DeviceType.Unknown
                && candidate.OperatingSystem == DeviceOperatingSystem.Windows && HasPort(445))
            {
                candidate = candidate with
                {
                    Type = DeviceType.Computer,
                    TypeEvidence = "Likely computer: Windows identification together with SMB on TCP 445.",
                    TypeIsInferred = true
                };
            }
            return candidate;
        }

        if (!inferDeviceType)
        {
            return Complete(result);
        }

        var hints = new Dictionary<DeviceType, string>();
        if (((Vendor("Western Digital") || Vendor("WesternDigital"))
            && Product(@"\bWDMyCloud\b|\bMy[ -]?Cloud\b|\bMy[ -]?Book[ -]?Live\b"))
            || (Vendor("Synology") || Vendor("QNAP")) && HasPort(445))
        {
            hints.TryAdd(DeviceType.Storage, "NAS product identity and storage vendor.");
        }
        if (Vendor("Philips Lighting") || Vendor("Signify") || Vendor("Tuya")
            || Vendor("Shelly") || Vendor("LIFX") || Vendor("Nanoleaf")
            || Product(@"\b(?:Philips Hue|Hue Bridge|Tapo|Kasa|Shelly)\b"))
        {
            hints.TryAdd(DeviceType.SmartDevice, "Smart-home manufacturer/product identity.");
        }
        if (Product(@"\b(?:Fire[ -]?TV|Chromecast|Apple[ -]?TV|BRAVIA|Roku|Sonos)\b") || Vendor("Sonos"))
        {
            hints.TryAdd(DeviceType.MediaDevice, "Media-device manufacturer/product identity.");
        }
        if (Product(@"\b(?:PlayStation|Xbox)\b"))
        {
            hints.TryAdd(DeviceType.GameConsole, "Game-console product identity.");
        }
        if (Product(@"\biPhone(?:[-_ .\d,]|$)"))
        {
            hints.TryAdd(DeviceType.Phone, "iPhone product identity.");
        }
        if (Product(@"\biPad(?:[-_ .\d,]|$)"))
        {
            hints.TryAdd(DeviceType.Tablet, "iPad product identity.");
        }
        if (Product(@"\b(?:MacBook(?:Air|Pro)?|iMac|Macmini|MacPro|MacStudio)(?:[-_ .\d,]|$)"))
        {
            hints.TryAdd(DeviceType.Computer, "Mac computer product identity.");
        }
        if (HasPort(9100) && (Vendor("Xerox") || Vendor("Brother") || Vendor("Epson")
            || Vendor("Canon") || Vendor("Hewlett") || Product(@"\b(?:LaserJet|OfficeJet|Phaser|PIXMA)\b")))
        {
            hints.TryAdd(DeviceType.Printer, "Printer manufacturer/product identity plus TCP 9100.");
        }

        if (hints.Count > 1)
        {
            return result with { TypeEvidence = $"Conflicting device-type hints: {string.Join(" ", hints.Values)}" };
        }
        return Complete(hints.Count == 1
            ? result with
            {
                Type = hints.Keys.Single(),
                TypeEvidence = $"Likely {hints.Keys.Single().Label()}: {hints.Values.Single()} Vendor: {vendor}. Discovered identity: {string.Join("; ", identities.Where(text => !string.IsNullOrWhiteSpace(text)))}.",
                TypeIsInferred = true
            }
            : result);
    }

    public static DeviceClassification ApplyNetworkContext(
        DeviceClassification result, IPAddress address, LanNetwork network)
    {
        if (address.Equals(network.LocalAddress))
        {
            var os = RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? DeviceOperatingSystem.Windows
                : RuntimeInformation.IsOSPlatform(OSPlatform.OSX) ? DeviceOperatingSystem.MacOS
                : RuntimeInformation.IsOSPlatform(OSPlatform.Linux) ? DeviceOperatingSystem.Linux
                : DeviceOperatingSystem.Other;
            return result with
            {
                OperatingSystem = os,
                Type = DeviceType.Computer,
                OperatingSystemEvidence = $"This computer's OS: {RuntimeInformation.OSDescription}.",
                TypeEvidence = "This computer is running the desktop scanner.",
                OperatingSystemIsInferred = false,
                TypeIsInferred = false
            };
        }

        return address.Equals(network.GatewayAddress)
            ? result with
            {
                Type = DeviceType.Router,
                TypeEvidence = "Configured IPv4 gateway for the selected network interface.",
                TypeIsInferred = false
            }
            : result;
    }

    private static string Evidence<T>(Dictionary<T, string> candidates, string kind, string unknown)
        where T : notnull => candidates.Count switch
        {
            0 => unknown,
            1 => candidates.Values.Single(),
            _ => $"Conflicting {kind} evidence: {string.Join(" ", candidates.Values)}"
        };
}
