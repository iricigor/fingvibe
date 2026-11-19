namespace FingVibe.Core.Models;

/// <summary>A MAC address the user linked into one device, with the date it was linked.</summary>
public sealed record LinkedDeviceMember(string Mac, DateTimeOffset LinkedAt);

/// <summary>The shared name and identification confirmed when the device was linked; Reset restores them.</summary>
public sealed record LinkedDeviceConfirmation(string Name, DeviceClassificationOverride Identification);

/// <summary>The member MAC shown for a linked device on one identified network; kept across scans and restarts.</summary>
public sealed record LinkedDeviceRepresentative(string NetworkId, string Subnet, string Mac);

/// <summary>
/// Several MAC records the user confirmed as one device. Shared values replace each member's own values while
/// linked; the members keep their saved values, observations and history unchanged so Unlink can restore them.
/// </summary>
public sealed record LinkedDevice(
    Guid Id,
    IReadOnlyList<LinkedDeviceMember> Members,
    string Name,
    DeviceClassificationOverride Identification,
    LinkedDeviceConfirmation Confirmed,
    DeviceAssignment? Assignment = null,
    DeviceUsageCategory? UsageCategoryOverride = null)
{
    public IReadOnlyList<LinkedDeviceRepresentative> Representatives { get; init; } = [];

    public bool HasMember(string mac) => Members.Any(member => member.Mac == mac);

    internal bool IsValid(DeviceInventoryData data) =>
        Id != Guid.Empty && Members is { Count: >= 2 } && Members.All(member => member is not null
            && member.LinkedAt != default && member.Mac is not null && IsNormalized(member.Mac)
            && data.Devices.ContainsKey(member.Mac))
        && Members.Select(member => member.Mac).Distinct(StringComparer.Ordinal).Count() == Members.Count
        && !string.IsNullOrWhiteSpace(Name) && Identification is { } identification && identification.HasValidValues()
        && Confirmed is { Identification: { } confirmed } && !string.IsNullOrWhiteSpace(Confirmed.Name)
        && confirmed.HasValidValues()
        && (UsageCategoryOverride is not { } usage || Enum.IsDefined(usage))
        && (Assignment?.PersonId is not { } person || data.PeopleRooms.People.Any(item => item.Id == person))
        && (Assignment?.RoomId is not { } room || data.PeopleRooms.Rooms.Any(item => item.Id == room))
        && Representatives is not null && Representatives.All(item => item is not null
            && !string.IsNullOrWhiteSpace(item.NetworkId) && !string.IsNullOrWhiteSpace(item.Subnet)
            && item.Mac is not null && HasMember(item.Mac))
        && Representatives.Select(item => (item.NetworkId, item.Subnet)).Distinct().Count() == Representatives.Count;

    private static bool IsNormalized(string mac)
    {
        try { return PeopleRoomsData.NormalizeMacAddress(mac) == mac; }
        catch (FormatException) { return false; }
    }
}

/// <summary>The shared values the user confirmed for a new link.</summary>
public sealed record LinkedDeviceChoices(
    string Name,
    DeviceClassificationOverride Identification,
    DeviceAssignment? Assignment,
    DeviceUsageCategory? UsageCategoryOverride);

public static class LinkedDeviceRepresentatives
{
    /// <summary>
    /// The member shown for a network/subnet: the saved representative while it responded in the current scan,
    /// otherwise a responding member (lowest MAC), otherwise the most recently seen member there (ties by MAC).
    /// Without a current scan the saved representative stays. Members never seen there are not candidates.
    /// </summary>
    public static string? Select(LinkedDevice linked, DeviceInventoryData data, string? networkId, string subnet,
        DateTimeOffset? currentScan)
    {
        var candidates = linked.Members
            .Select(member => (member.Mac, Observations: data.Devices.TryGetValue(member.Mac, out var device)
                ? device.Observations.Where(item => item.NetworkId == networkId && item.Subnet == subnet).ToArray() : []))
            .Where(item => item.Observations.Length > 0)
            .OrderBy(item => item.Mac, StringComparer.Ordinal).ToArray();
        if (candidates.Length == 0) return null;
        var saved = networkId is null ? null : linked.Representatives
            .FirstOrDefault(item => item.NetworkId == networkId && item.Subnet == subnet)?.Mac;
        if (currentScan is { } scan)
        {
            var online = candidates.Where(item => item.Observations.Any(observation =>
                observation.Present && observation.LastChecked == scan)).Select(item => item.Mac).ToArray();
            if (saved is not null && online.Contains(saved)) return saved;
            if (online.Length > 0) return online[0];
        }
        else if (saved is not null && candidates.Any(item => item.Mac == saved)) return saved;
        return candidates.OrderByDescending(item => item.Observations.Max(observation => observation.LastSeen))
            .ThenBy(item => item.Mac, StringComparer.Ordinal).First().Mac;
    }

    /// <summary>Saves each linked device's representative for a completed scan's network.</summary>
    internal static IReadOnlyList<LinkedDevice> Observe(DeviceInventoryData data, string networkId, string subnet,
        DateTimeOffset completedAt) =>
        data.LinkedDevices.Select(linked =>
        {
            if (Select(linked, data, networkId, subnet, completedAt) is not { } mac) return linked;
            var entry = new LinkedDeviceRepresentative(networkId, subnet, mac);
            var index = linked.Representatives.ToList().FindIndex(item => item.NetworkId == networkId && item.Subnet == subnet);
            if (index >= 0 && linked.Representatives[index] == entry) return linked;
            return linked with
            {
                Representatives = index < 0 ? [.. linked.Representatives, entry]
                    : linked.Representatives.Select((item, position) => position == index ? entry : item).ToArray()
            };
        }).ToArray();
}
