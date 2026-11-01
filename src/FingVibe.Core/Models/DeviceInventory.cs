using System.Net;
using System.Net.NetworkInformation;
using System.Text.Json.Serialization;

namespace FingVibe.Core.Models;

public enum InventoryDeviceStatus
{
    Online,
    Offline,
    FingOnly
}

public sealed record ImportedDeviceMetadata(
    string? Name = null,
    string? Hostname = null,
    string? Type = null,
    string? Brand = null,
    string? Family = null,
    string? Model = null,
    string? OperatingSystem = null,
    string? OperatingSystemVersion = null,
    string? Address = null);

public sealed record DeviceObservation(
    string? NetworkId,
    string Subnet,
    string Address,
    string? Hostname,
    string Vendor,
    DeviceClassification Classification,
    IReadOnlyList<OpenPort> Ports,
    long? Latency,
    TimeSpan ProbeDuration,
    DateTimeOffset FirstSeen,
    DateTimeOffset LastSeen,
    DateTimeOffset LastChecked,
    bool Present)
{
    public ScanResult ToScanResult(string mac) => new(
        IPAddress.Parse(Address), Present ? HostStatus.Alive : HostStatus.Unreachable,
        Latency, ProbeDuration, Hostname, PhysicalAddress.Parse(mac), Vendor, Ports, Classification);
}

public sealed record InventoryDevice(
    string Mac,
    ImportedDeviceMetadata Imported,
    IReadOnlyList<DeviceObservation> Observations)
{
    [JsonIgnore]
    public DeviceObservation? LatestObservation => Observations.OrderByDescending(item => item.LastChecked).FirstOrDefault();
    [JsonIgnore]
    public InventoryDeviceStatus Status => Observations.Count == 0
        ? InventoryDeviceStatus.FingOnly
        : LatestObservation!.Present ? InventoryDeviceStatus.Online : InventoryDeviceStatus.Offline;
}

public sealed record DeviceInventoryData(
    Guid Revision,
    IReadOnlyDictionary<string, InventoryDevice> Devices,
    IReadOnlyDictionary<string, string> Names,
    IReadOnlyDictionary<string, DeviceClassificationOverride> Classifications,
    PeopleRoomsData PeopleRooms)
{
    public static DeviceInventoryData Empty { get; } = new(Guid.Empty,
        new Dictionary<string, InventoryDevice>(), new Dictionary<string, string>(),
        new Dictionary<string, DeviceClassificationOverride>(), new PeopleRoomsData());

    public DeviceInventoryData ObserveCompletedScan(
        string? networkId, ScanSnapshot snapshot, bool historical = false)
    {
        var devices = Devices.ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.OrdinalIgnoreCase);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var result in snapshot.Results.Where(result => result.Status == HostStatus.Alive
                     && result.MacAddress?.GetAddressBytes().Length == 6))
        {
            var mac = result.MacAddress!.ToString();
            seen.Add(mac);
            var device = devices.GetValueOrDefault(mac) ?? new InventoryDevice(mac, new(), []);
            var observations = device.Observations.ToList();
            var previous = observations.FirstOrDefault(item => item.NetworkId == networkId && item.Subnet == snapshot.Subnet);
            if (previous is not null) observations.Remove(previous);
            observations.Add(new DeviceObservation(networkId, snapshot.Subnet, result.AddressText,
                result.DeviceName, result.VendorName, result.DetectedClassification, result.OpenPortItems,
                result.RoundtripTimeMilliseconds, result.ProbeDuration,
                previous?.FirstSeen ?? snapshot.CompletedAt, snapshot.CompletedAt, snapshot.CompletedAt, true));
            devices[mac] = device with { Observations = observations };
        }

        // A CIDR alone cannot identify a network, including when migrating an old snapshot.
        if (!historical && networkId is not null)
        {
            foreach (var (mac, device) in devices.ToArray())
            {
                if (seen.Contains(mac)) continue;
                devices[mac] = device with
                {
                    Observations = device.Observations.Select(item =>
                        item.NetworkId == networkId && item.Subnet == snapshot.Subnet
                            ? item with { Present = false, LastChecked = snapshot.CompletedAt }
                            : item).ToArray()
                };
            }
        }
        return this with { Devices = devices };
    }
}
