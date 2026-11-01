using System.Net;
using System.Net.NetworkInformation;
using System.Text.Json.Serialization;

namespace FingVibe.Core.Models;

public enum InventoryDeviceStatus
{
    Online,
    Offline,
    FingOnly,
    Unknown
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
    bool Present,
    IReadOnlyList<UdpServiceObservation>? UdpObservations = null)
{
    public ScanResult ToScanResult(string mac) => new(
        IPAddress.Parse(Address), Present ? HostStatus.Alive : HostStatus.Unreachable,
        Latency, ProbeDuration, Hostname, PhysicalAddress.Parse(mac), Vendor, Ports, Classification, UdpObservations);
}

public sealed record InventoryDevice(
    string Mac,
    ImportedDeviceMetadata Imported,
    IReadOnlyList<DeviceObservation> Observations)
{
    [JsonIgnore]
    public DeviceObservation? LatestObservation => Observations.OrderByDescending(item =>
            item.LastChecked == CurrentCompletedAt && item.NetworkId == CurrentNetworkId && item.Subnet == CurrentSubnet)
        .ThenByDescending(item => item.LastChecked)
        .ThenByDescending(item => item.Present).ThenByDescending(item => item.LastSeen)
        .ThenBy(item => item.Address, StringComparer.Ordinal).FirstOrDefault();
    [JsonIgnore]
    public DateTimeOffset? CurrentCompletedAt { get; init; }
    [JsonIgnore]
    public string? CurrentNetworkId { get; init; }
    [JsonIgnore]
    public string? CurrentSubnet { get; init; }
    [JsonIgnore]
    public InventoryDeviceStatus Status => Observations.Count == 0
        ? InventoryDeviceStatus.FingOnly
        : LatestObservation!.LastChecked != CurrentCompletedAt
            || LatestObservation.NetworkId != CurrentNetworkId || LatestObservation.Subnet != CurrentSubnet ? InventoryDeviceStatus.Unknown
        : LatestObservation.Present ? InventoryDeviceStatus.Online : InventoryDeviceStatus.Offline;
}

public sealed record DeviceInventoryData(
    Guid Revision,
    IReadOnlyDictionary<string, InventoryDevice> Devices,
    IReadOnlyDictionary<string, string> Names,
    IReadOnlyDictionary<string, DeviceClassificationOverride> Classifications,
    PeopleRoomsData PeopleRooms)
{
    public IReadOnlyList<PrivateVirtualDevice> VirtualDevices { get; init; } = [];

    public static DeviceInventoryData Empty { get; } = new(Guid.Empty,
        new Dictionary<string, InventoryDevice>(), new Dictionary<string, string>(),
        new Dictionary<string, DeviceClassificationOverride>(), new PeopleRoomsData());

    public DeviceInventoryData UpdateProbeResults(ScanResult result)
    {
        var mac = result.MacAddress?.ToString()
            ?? throw new ArgumentException("A MAC identity is required.", nameof(result));
        if (!Devices.TryGetValue(mac, out var device)
            || !device.Observations.Any(item => item.Present && item.LastChecked == device.CurrentCompletedAt
                && item.NetworkId == device.CurrentNetworkId && item.Subnet == device.CurrentSubnet
                && item.Address == result.AddressText))
            throw new InvalidOperationException("The selected address has no current inventory response.");
        DeviceObservation Update(DeviceObservation item) => item with
        {
            Ports = result.OpenPortItems, UdpObservations = result.UdpObservationItems
        };
        var devices = Devices.ToDictionary(pair => pair.Key, pair => pair.Value);
        devices[mac] = device with
        {
            Observations = device.Observations.Select(item =>
                item.Present && item.LastChecked == device.CurrentCompletedAt
                    && item.NetworkId == device.CurrentNetworkId && item.Subnet == device.CurrentSubnet && item.Address == result.AddressText
                    ? Update(item) : item).ToArray()
        };
        return this with
        {
            Devices = devices,
            VirtualDevices = VirtualDevices.Select(slot => slot with
            {
                History = slot.History.Select(item => item.Mac == mac && item.Observation.Address == result.AddressText
                    && item.Observation.Present && item.Observation.LastChecked == slot.CurrentCompletedAt
                        ? item with { Observation = Update(item.Observation) } : item).ToArray()
            }).ToArray()
        };
    }

    public DeviceInventoryData ObserveCompletedScan(
        string? networkId, ScanSnapshot snapshot, bool historical = false)
    {
        var devices = Devices.ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.OrdinalIgnoreCase);
        var responses = snapshot.Results.Where(result => result.Status == HostStatus.Alive
            && result.MacAddress?.GetAddressBytes().Length == 6).ToArray();
        var seen = responses.Select(result => (result.MacAddress!.ToString(), result.AddressText)).ToHashSet();
        foreach (var result in responses)
        {
            var mac = result.MacAddress!.ToString();
            var device = devices.GetValueOrDefault(mac) ?? new InventoryDevice(mac, new(), []);
            var observations = device.Observations.ToList();
            var previous = observations.FirstOrDefault(item => item.NetworkId == networkId
                && item.Subnet == snapshot.Subnet && item.Address == result.AddressText);
            if (previous is not null) observations.Remove(previous);
            observations.Add(new DeviceObservation(networkId, snapshot.Subnet, result.AddressText,
                result.DeviceName, result.VendorName, result.DetectedClassification, result.OpenPortItems,
                result.RoundtripTimeMilliseconds, result.ProbeDuration,
                previous?.FirstSeen ?? snapshot.CompletedAt, snapshot.CompletedAt, snapshot.CompletedAt, true,
                result.UdpObservations));
            devices[mac] = device with { Observations = observations };
        }

        // A CIDR alone cannot identify a network, including when migrating an old snapshot.
        if (!historical && networkId is not null)
        {
            foreach (var (mac, device) in devices.ToArray())
            {
                devices[mac] = device with
                {
                    Observations = device.Observations.Select(item =>
                        item.NetworkId == networkId && item.Subnet == snapshot.Subnet
                            && !seen.Contains((mac, item.Address))
                            ? item with { Present = false, LastChecked = snapshot.CompletedAt }
                            : item).ToArray()
                };
            }
        }
        foreach (var (mac, device) in devices.ToArray())
            devices[mac] = device with
            {
                CurrentCompletedAt = historical ? null : snapshot.CompletedAt,
                CurrentNetworkId = historical ? null : networkId,
                CurrentSubnet = historical ? null : snapshot.Subnet
            };
        var observed = this with { Devices = devices };
        return observed with
        {
            VirtualDevices = PrivateVirtualDeviceAllocator.Observe(observed, networkId, snapshot, historical)
        };
    }
}
