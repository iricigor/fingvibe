namespace FingVibe.Core.Models;

/// <summary>A MAC address the user linked into one device, with the date it was linked.</summary>
public sealed record LinkedDeviceMember(string Mac, DateTimeOffset LinkedAt);

/// <summary>The shared name and identification confirmed when the device was linked; Reset restores them.</summary>
public sealed record LinkedDeviceConfirmation(string Name, DeviceClassificationOverride Identification);

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
        && (Assignment?.RoomId is not { } room || data.PeopleRooms.Rooms.Any(item => item.Id == room));

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
