using System.Net;
using System.Net.NetworkInformation;
using System.Text.Json.Serialization;

namespace FingVibe.Core.Models;

public sealed record VirtualDeviceConnection(string Mac, DeviceObservation Observation, bool Inferred);

public sealed record PrivateVirtualDevice(
    Guid Id,
    string NetworkId,
    string Subnet,
    string Prefix,
    int Number,
    string LastActiveMac,
    DateTimeOffset LastChecked,
    bool Present,
    IReadOnlyList<VirtualDeviceConnection> History,
    string? Name = null,
    DeviceClassificationOverride? Classification = null,
    DeviceAssignment? Assignment = null)
{
    [JsonIgnore]
    public string AutomaticName => $"Private {string.Join("-", Enumerable.Range(0, 3).Select(i => Prefix.Substring(i * 2, 2)))}"
        + (Number == 1 ? string.Empty : $" -{Number}");
    [JsonIgnore]
    public DateTimeOffset? CurrentCompletedAt { get; init; }
    [JsonIgnore]
    public InventoryDeviceStatus Status => LastChecked != CurrentCompletedAt ? InventoryDeviceStatus.Unknown
        : Present ? InventoryDeviceStatus.Online : InventoryDeviceStatus.Offline;
    [JsonIgnore]
    public VirtualDeviceConnection LatestConnection => History
        .Where(item => item.Mac == LastActiveMac)
        .OrderByDescending(item => item.Observation.LastSeen)
        .ThenBy(item => item.Observation.Address, StringComparer.Ordinal).First();
}

public static class PrivateVirtualDeviceAllocator
{
    public static bool IsEligible(DeviceInventoryData data, InventoryDevice device)
    {
        var observation = device.LatestObservation;
        var mac = PhysicalAddress.Parse(device.Mac).GetAddressBytes();
        if (mac.Length != 6 || (mac[0] & 3) != 0 || observation?.Vendor != "Private"
            || Meaningful(data.Names.GetValueOrDefault(device.Mac))
            || Meaningful(device.Imported.Name) || Meaningful(device.Imported.Hostname)
            || Meaningful(observation.Hostname) || Meaningful(device.Imported.Family)
            || Meaningful(device.Imported.Model) || Meaningful(device.Imported.Type)
            || Meaningful(device.Imported.OperatingSystem)
            || Meaningful(device.Imported.Brand) && device.Imported.Brand != "Private"
            || observation.Classification.Type != DeviceType.Unknown
            || observation.Classification.OperatingSystem != DeviceOperatingSystem.Unknown)
            return false;
        var correction = data.Classifications.GetValueOrDefault(device.Mac);
        return correction?.Type is null or DeviceType.Unknown
            && correction?.OperatingSystem is null or DeviceOperatingSystem.Unknown;
    }

    private static bool Meaningful(string? value) => !string.IsNullOrWhiteSpace(value)
        && value.Trim() != "-" && !value.Trim().Equals("Unknown", StringComparison.OrdinalIgnoreCase)
        && !IPAddress.TryParse(value.Trim(), out _);

    public static IReadOnlyList<PrivateVirtualDevice> Observe(
        DeviceInventoryData data, string? networkId, ScanSnapshot snapshot, bool historical)
    {
        var slots = data.VirtualDevices.Select(slot => slot with
        {
            CurrentCompletedAt = !historical && slot.NetworkId == networkId && slot.Subnet == snapshot.Subnet
                ? snapshot.CompletedAt : null
        }).ToList();
        if (historical || networkId is null) return slots;

        var responding = snapshot.Results.Where(result => result.Status == HostStatus.Alive
                && result.MacAddress?.GetAddressBytes().Length == 6)
            .Select(result => result.MacAddress!.ToString()).Distinct()
            .Where(mac => IsEligible(data, data.Devices[mac]))
            .OrderBy(mac => mac, StringComparer.Ordinal).ToArray();
        var allocated = new HashSet<Guid>();
        var assignments = new Dictionary<string, Guid>();

        // Reserve known identities first; otherwise a new MAC could steal a returning member's slot.
        foreach (var mac in responding.OrderByDescending(mac => slots.Any(slot =>
                     slot.NetworkId == networkId && slot.Subnet == snapshot.Subnet && slot.LastActiveMac == mac))
                     .ThenBy(mac => mac, StringComparer.Ordinal))
        {
            var known = slots.Where(slot => slot.NetworkId == networkId && slot.Subnet == snapshot.Subnet
                    && slot.Prefix == mac[..6] && !allocated.Contains(slot.Id)
                    && slot.History.Any(item => item.Mac == mac))
                .OrderByDescending(slot => slot.History.Where(item => item.Mac == mac).Max(item => item.Observation.LastSeen))
                .ThenByDescending(slot => slot.LastActiveMac == mac).ThenBy(slot => slot.Number).FirstOrDefault();
            if (known is null) continue;
            assignments.Add(mac, known.Id);
            allocated.Add(known.Id);
        }
        foreach (var mac in responding.Where(mac => !assignments.ContainsKey(mac)))
        {
            var candidates = slots.Where(slot => slot.NetworkId == networkId
                && slot.Subnet == snapshot.Subnet && slot.Prefix == mac[..6]).ToArray();
            var slot = candidates.Where(slot => !allocated.Contains(slot.Id)).OrderBy(slot => slot.Number).FirstOrDefault();
            if (slot is null)
            {
                slot = new(Guid.NewGuid(), networkId, snapshot.Subnet, mac[..6],
                    candidates.Select(item => item.Number).DefaultIfEmpty(0).Max() + 1,
                    mac, snapshot.CompletedAt, true, []);
                slots.Add(slot);
            }
            assignments.Add(mac, slot.Id);
            allocated.Add(slot.Id);
        }

        foreach (var device in data.Devices.Values.Where(device => IsEligible(data, device)
                     && !assignments.ContainsKey(device.Mac)).OrderBy(device => device.Mac, StringComparer.Ordinal))
        {
            var observations = device.Observations.Where(item => item.NetworkId == networkId
                && item.Subnet == snapshot.Subnet).ToArray();
            if (observations.Length == 0 || slots.Any(slot => slot.NetworkId == networkId
                    && slot.Subnet == snapshot.Subnet && slot.History.Any(item => item.Mac == device.Mac)))
                continue;
            var index = slots.FindIndex(slot => slot.NetworkId == networkId && slot.Subnet == snapshot.Subnet
                && slot.Prefix == device.Mac[..6] && slot.Number == 1);
            var history = observations.Select(item => new VirtualDeviceConnection(device.Mac, item, true)).ToArray();
            if (index < 0)
                slots.Add(new(Guid.NewGuid(), networkId, snapshot.Subnet, device.Mac[..6], 1,
                    device.Mac, snapshot.CompletedAt, false, history));
            else
                slots[index] = slots[index] with { History = slots[index].History.Concat(history).ToArray() };
        }

        for (var i = 0; i < slots.Count; i++)
        {
            var slot = slots[i];
            if (slot.NetworkId != networkId || slot.Subnet != snapshot.Subnet) continue;
            var currentMac = assignments.FirstOrDefault(pair => pair.Value == slot.Id).Key;
            var history = slot.History.Select(item => item with
            {
                Observation = item.Observation with { Present = false, LastChecked = snapshot.CompletedAt }
            }).ToList();
            if (currentMac is not null)
            {
                var inferred = !slot.History.Any(item => item.Mac == currentMac);
                foreach (var observation in data.Devices[currentMac].Observations.Where(item =>
                             item.NetworkId == networkId && item.Subnet == snapshot.Subnet
                             && item.Present && item.LastChecked == snapshot.CompletedAt))
                {
                    var previous = history.FirstOrDefault(item => item.Mac == currentMac
                        && item.Observation.Address == observation.Address);
                    if (previous is not null) history.Remove(previous);
                    history.Add(new(currentMac, observation with
                    {
                        FirstSeen = previous?.Observation.FirstSeen ?? snapshot.CompletedAt
                    }, previous?.Inferred ?? inferred));
                }
            }
            slots[i] = slot with
            {
                LastActiveMac = currentMac ?? slot.LastActiveMac,
                LastChecked = snapshot.CompletedAt,
                Present = currentMac is not null,
                History = history,
                CurrentCompletedAt = snapshot.CompletedAt
            };
        }
        return slots;
    }
}
