namespace FingVibe.Core.Models;

public sealed record DeviceDiscovery(string Mac, Guid? VirtualDeviceId = null)
{
    public string IdentityKey => VirtualDeviceId?.ToString("D") ?? Mac;

    public static IReadOnlyList<DeviceDiscovery> FindNewDevices(
        DeviceInventoryData persisted, DeviceInventoryData observed, string? networkId, ScanSnapshot scan)
    {
        if (networkId is null) return [];

        bool InScope(DeviceObservation observation) =>
            observation.NetworkId == networkId && observation.Subnet == scan.Subnet;
        bool Seen(InventoryDevice device) => device.Observations.Any(InScope)
            || (device.ScanHistory is IDeviceHistoryQuery query ? query.HasPresence(networkId, scan.Subnet)
                : device.ScanHistory.Any(item => item.NetworkId == networkId && item.Subnet == scan.Subnet && item.Present));
        bool InScopeSlot(PrivateVirtualDevice slot) => slot.NetworkId == networkId && slot.Subnet == scan.Subnet;

        // Legacy local aggregates establish a baseline too; imported metadata never does.
        var knownMacs = persisted.Devices.Values.Where(Seen).Select(device => device.Mac).ToHashSet();
        var knownSlots = persisted.VirtualDevices.Where(InScopeSlot).ToArray();
        if (!persisted.DiscoveryBaselines.Contains(new(networkId, scan.Subnet))
            && knownMacs.Count == 0 && knownSlots.Length == 0)
            return [];

        var responding = scan.Results.Where(result => result.Status == HostStatus.Alive
                && result.MacAddress?.GetAddressBytes().Length == 6)
            .Select(result => result.MacAddress!.ToString()).ToHashSet();
        var currentSlots = observed.VirtualDevices.Where(slot => InScopeSlot(slot)
            && slot.Present && slot.LastChecked == scan.CompletedAt && responding.Contains(slot.LastActiveMac)).ToArray();
        var representedMacs = currentSlots.Select(slot => slot.LastActiveMac).ToHashSet();
        var discoveries = new List<DeviceDiscovery>();
        foreach (var slot in currentSlots)
        {
            if (!knownSlots.Any(known => known.Id == slot.Id)
                && !knownMacs.Contains(slot.LastActiveMac)
                && !knownSlots.Any(known => known.History.Any(item => item.Mac == slot.LastActiveMac)))
                discoveries.Add(new(slot.LastActiveMac, slot.Id));
        }
        foreach (var mac in responding.Where(mac => !representedMacs.Contains(mac)))
        {
            if (!knownMacs.Contains(mac)
                && !knownSlots.Any(slot => slot.History.Any(item => item.Mac == mac)))
                discoveries.Add(new(mac));
        }
        return discoveries.OrderBy(item => item.Mac, StringComparer.Ordinal).ToArray();
    }
}
