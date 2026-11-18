using System.Net.NetworkInformation;
using System.Text.Json.Serialization;
using FingVibe.Core.Import;

namespace FingVibe.Core.Models;

/// <summary>Evidence that two MAC records may be the same physical device, strongest first.</summary>
public enum DeviceMatchReason
{
    LocalAdapters,
    SameDeviceId,
    SameName
}

/// <summary>An unordered MAC pair the user kept separate; it is never suggested again.</summary>
public sealed record DeclinedDeviceMatch(string FirstMac, string SecondMac)
{
    public static DeclinedDeviceMatch Create(string mac, string otherMac)
    {
        var first = PeopleRoomsData.NormalizeMacAddress(mac);
        var second = PeopleRoomsData.NormalizeMacAddress(otherMac);
        if (first == second) throw new ArgumentException("A device cannot be declined as its own match.", nameof(otherMac));
        return string.CompareOrdinal(first, second) < 0 ? new(first, second) : new(second, first);
    }

    [JsonIgnore]
    public string Key => $"{FirstMac}|{SecondMac}";

    public bool IsValid() =>
        FirstMac is not null && SecondMac is not null
        && IsNormalized(FirstMac) && IsNormalized(SecondMac) && string.CompareOrdinal(FirstMac, SecondMac) < 0;

    private static bool IsNormalized(string mac)
    {
        try { return PeopleRoomsData.NormalizeMacAddress(mac) == mac; }
        catch (FormatException) { return false; }
    }
}

public sealed record DeviceMatchSuggestion(string Mac, string OtherMac, DeviceMatchReason Reason, string Evidence)
{
    /// <summary>Short reason for tooltips, for example "Same discovered name".</summary>
    public string ShortReason => Reason switch
    {
        DeviceMatchReason.LocalAdapters => "Both are this PC's network adapters",
        DeviceMatchReason.SameDeviceId => $"Same device ID ({Evidence})",
        _ => "Same discovered name"
    };

    /// <summary>Completes "Suggested because …".</summary>
    public string Explanation => Reason switch
    {
        DeviceMatchReason.LocalAdapters => "both MAC addresses belong to this PC's Ethernet or Wi-Fi adapters",
        DeviceMatchReason.SameDeviceId => $"both records reported the same {Evidence}",
        _ => "the discovered names match"
    };
}

public static class DeviceMatchSuggestions
{
    /// <summary>Factory and placeholder names that identify a product rather than one device.</summary>
    public static IReadOnlyList<string> CommonDefaultNames { get; } =
        ["iPhone", "iPad", "Android", "Galaxy", "localhost", "raspberrypi", "Chromecast", "ESP", "espressif", "Unknown"];

    private static readonly HashSet<string> Defaults =
        CommonDefaultNames.Select(name => name.ToLowerInvariant()).ToHashSet(StringComparer.Ordinal);

    private static readonly HashSet<ReportedDeviceValueKind> HostNameKinds =
        [ReportedDeviceValueKind.MdnsName, ReportedDeviceValueKind.NetBiosName, ReportedDeviceValueKind.ReverseDnsName];

    private static readonly HashSet<ReportedDeviceValueKind> NameKinds =
        [ReportedDeviceValueKind.SsdpName, .. HostNameKinds];

    private static readonly HashSet<ReportedDeviceValueKind> DeviceIdKinds =
    [
        ReportedDeviceValueKind.UpnpUuid, ReportedDeviceValueKind.GoogleCastId, ReportedDeviceValueKind.HomeKitId,
        ReportedDeviceValueKind.AirPlayDeviceId, ReportedDeviceValueKind.PrinterUuid
    ];

    public static IReadOnlyDictionary<string, IReadOnlyList<DeviceMatchSuggestion>> Find(
        DeviceInventoryData data, IReadOnlySet<string> localAdapterMacs)
    {
        ArgumentNullException.ThrowIfNull(data);
        ArgumentNullException.ThrowIfNull(localAdapterMacs);
        var grouped = data.VirtualDevices.SelectMany(slot => slot.History.Select(item => item.Mac))
            .ToHashSet(StringComparer.Ordinal);
        var declined = data.DeclinedMatches.Select(item => item.Key).ToHashSet(StringComparer.Ordinal);
        // Group records by normalized evidence keys instead of comparing every pair.
        var groups = new Dictionary<(string Network, DeviceMatchReason Reason, string Kind, string Value), HashSet<string>>();
        void Add(string network, DeviceMatchReason reason, string kind, string value, string mac)
        {
            var key = (network, reason, kind, value);
            if (!groups.TryGetValue(key, out var macs)) groups[key] = macs = new(StringComparer.Ordinal);
            macs.Add(mac);
        }

        foreach (var device in data.Devices.Values)
        {
            if (device.Observations.Count == 0 || grouped.Contains(device.Mac)) continue;
            var networks = device.Observations.Select(item => item.NetworkId).OfType<string>()
                .Distinct(StringComparer.Ordinal).ToArray();
            if (networks.Length == 0) continue;
            if (localAdapterMacs.Contains(device.Mac))
                foreach (var network in networks) Add(network, DeviceMatchReason.LocalAdapters, string.Empty, string.Empty, device.Mac);
            foreach (var observation in device.Observations)
            {
                if (observation.NetworkId is not { } network) continue;
                foreach (var value in observation.ReportedValues.Where(item => DeviceIdKinds.Contains(item.Kind)))
                    Add(network, DeviceMatchReason.SameDeviceId, value.Kind.ToString(), value.Value.ToLowerInvariant(), device.Mac);
            }
            foreach (var (network, name) in CurrentNames(data, device, networks))
                Add(network, DeviceMatchReason.SameName, string.Empty, name, device.Mac);
        }

        var pairs = new Dictionary<(string, string), (DeviceMatchReason Reason, string Evidence)>();
        foreach (var ((_, reason, kind, _), macs) in groups)
        {
            if (macs.Count < 2) continue;
            var ordered = macs.Order(StringComparer.Ordinal).ToArray();
            for (var i = 0; i < ordered.Length; i++)
                for (var j = i + 1; j < ordered.Length; j++)
                {
                    var pair = (ordered[i], ordered[j]);
                    if (pairs.TryGetValue(pair, out var existing) && existing.Reason <= reason) continue;
                    if (declined.Contains($"{ordered[i]}|{ordered[j]}")) continue;
                    if (reason == DeviceMatchReason.SameName
                        && TypesConflict(KnownType(data, data.Devices[ordered[i]]), KnownType(data, data.Devices[ordered[j]])))
                        continue;
                    pairs[pair] = (reason, reason == DeviceMatchReason.SameDeviceId
                        ? Enum.Parse<ReportedDeviceValueKind>(kind).Label() : string.Empty);
                }
        }

        var result = new Dictionary<string, List<DeviceMatchSuggestion>>(StringComparer.Ordinal);
        foreach (var ((first, second), (reason, evidence)) in pairs)
        {
            Collect(result, first).Add(new(first, second, reason, evidence));
            Collect(result, second).Add(new(second, first, reason, evidence));
        }
        return result.ToDictionary(pair => pair.Key, pair => (IReadOnlyList<DeviceMatchSuggestion>)pair.Value
            .OrderBy(item => item.Reason)
            .ThenByDescending(item => data.Devices[item.OtherMac].LatestObservation?.LastSeen)
            .ThenBy(item => item.OtherMac, StringComparer.Ordinal).ToArray(), StringComparer.Ordinal);
    }

    /// <summary>The comparable form of a name, or null when it cannot be evidence for this record.</summary>
    public static string? NameKey(string? name, bool isHostName, InventoryDevice device)
    {
        var trimmed = name?.Trim();
        if (string.IsNullOrEmpty(trimmed)) return null;
        var lower = trimmed.ToLowerInvariant();
        foreach (var address in device.Observations.Select(item => item.Address).Distinct(StringComparer.Ordinal))
            if (lower.Contains(address, StringComparison.Ordinal) || lower.Contains(address.Replace('.', '-'), StringComparison.Ordinal))
                return null;
        var hex = new string(lower.Where(character => character is not (':' or '-' or '.' or '_' or ' ')).ToArray());
        var mac = device.Mac.ToLowerInvariant();
        if (hex.Contains(mac, StringComparison.Ordinal) || hex.Contains(mac[6..], StringComparison.Ordinal)) return null;
        var key = (isHostName ? lower.Split('.')[0] : lower).Trim();
        return key.Length == 0 || Defaults.Contains(key) ? null : key;
    }

    private static IEnumerable<(string Network, string Name)> CurrentNames(
        DeviceInventoryData data, InventoryDevice device, IReadOnlyList<string> networks)
    {
        var everywhere = new List<string?>
        {
            NameKey(data.Names.GetValueOrDefault(device.Mac), false, device),
            NameKey(device.Imported.Name, false, device),
            NameKey(device.Imported.Hostname, IsHostName(device.Imported.Hostname), device)
        };
        foreach (var name in everywhere.OfType<string>().Distinct(StringComparer.Ordinal))
            foreach (var network in networks) yield return (network, name);

        var reported = device.Observations.SelectMany(observation => observation.ReportedValues
                .Where(item => NameKinds.Contains(item.Kind)).Select(item => (observation, item)))
            .ToArray();
        if (reported.Length == 0)
        {
            // Records saved before reported values existed use their latest observation's hostname.
            if (device.LatestObservation is { NetworkId: { } network, Hostname: var hostname }
                && NameKey(hostname, IsHostName(hostname), device) is { } name)
                yield return (network, name);
            yield break;
        }
        // Reported names count only when received in the most recent scan that reported a name.
        var latest = reported.Max(item => item.item.LastReceivedAt);
        foreach (var (observation, item) in reported.Where(item => item.item.LastReceivedAt == latest))
            if (observation.NetworkId is { } network
                && NameKey(item.Value, HostNameKinds.Contains(item.Kind), device) is { } name)
                yield return (network, name);
    }

    private static bool IsHostName(string? name) => name is not null && !name.Trim().Contains(' ');

    /// <summary>The device type when it is clearly known: chosen by the user or Fing, or detected without "(likely)".</summary>
    public static DeviceType? KnownType(DeviceInventoryData data, InventoryDevice device)
    {
        var type = data.Classifications.GetValueOrDefault(device.Mac)?.Type
            ?? FingClassificationMapper.Type(device.Imported.Type);
        if (type is null && device.LatestObservation?.Classification is { TypeIsInferred: false } detected)
            type = detected.Type;
        return type is null or DeviceType.Unknown ? null : type;
    }

    public static bool TypesConflict(DeviceType? first, DeviceType? second) =>
        first is { } a && second is { } b && a != b
        && a is not (DeviceType.Computer or DeviceType.SmartDevice)
        && b is not (DeviceType.Computer or DeviceType.SmartDevice);

    /// <summary>MAC addresses of this PC's Ethernet and Wi-Fi adapters, read locally without network traffic.</summary>
    public static IReadOnlySet<string> ReadLocalAdapterMacs()
    {
        var result = new HashSet<string>(StringComparer.Ordinal);
        try
        {
            foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (adapter.NetworkInterfaceType is not (NetworkInterfaceType.Ethernet or NetworkInterfaceType.GigabitEthernet
                        or NetworkInterfaceType.FastEthernetT or NetworkInterfaceType.FastEthernetFx
                        or NetworkInterfaceType.Ethernet3Megabit or NetworkInterfaceType.Wireless80211))
                    continue;
                var bytes = adapter.GetPhysicalAddress().GetAddressBytes();
                if (bytes.Length == 6 && bytes.Any(value => value != 0))
                    result.Add(new PhysicalAddress(bytes).ToString());
            }
        }
        catch (NetworkInformationException) { }
        return result;
    }

    private static List<DeviceMatchSuggestion> Collect(Dictionary<string, List<DeviceMatchSuggestion>> result, string mac)
    {
        if (!result.TryGetValue(mac, out var list)) result[mac] = list = [];
        return list;
    }
}
