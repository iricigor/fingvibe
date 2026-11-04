using FingVibe.Core.Models;

namespace FingVibe.App;

public sealed record DeviceResultFilter(
    bool AliveOnly,
    bool OpenPortsOnly,
    string SearchText,
    Guid? PersonId = null,
    Guid? RoomId = null,
    bool UnassignedPersonOnly = false,
    bool UnassignedRoomOnly = false,
    FingVibe.Core.Models.InventoryDeviceStatus? Status = null)
{
    public IReadOnlySet<InventoryDeviceStatus> Statuses { get; init; } = new HashSet<InventoryDeviceStatus>();
    public IReadOnlySet<DeviceType> Types { get; init; } = new HashSet<DeviceType>();
    public IReadOnlySet<DeviceOperatingSystem> OperatingSystems { get; init; } = new HashSet<DeviceOperatingSystem>();
    public IReadOnlySet<string> Vendors { get; init; } = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    public IReadOnlySet<Guid?> People { get; init; } = new HashSet<Guid?>();
    public IReadOnlySet<Guid?> Rooms { get; init; } = new HashSet<Guid?>();

    public int ActiveSecondaryCategoryCount =>
        (Types.Count > 0 ? 1 : 0) + (OperatingSystems.Count > 0 ? 1 : 0)
        + (Vendors.Count > 0 ? 1 : 0) + (People.Count > 0 ? 1 : 0)
        + (Rooms.Count > 0 ? 1 : 0) + (OpenPortsOnly ? 1 : 0);

    public bool HasRestrictions => AliveOnly || OpenPortsOnly || !string.IsNullOrEmpty(SearchText)
        || Status is not null || PersonId is not null || RoomId is not null
        || UnassignedPersonOnly || UnassignedRoomOnly || Statuses.Count > 0
        || ActiveSecondaryCategoryCount > 0;

    public bool Matches(ScanResultRow row) =>
        (!AliveOnly || row.IsOnline)
        && (!OpenPortsOnly || row.OpenPortItems.Count > 0)
        && (Status is null || row.Status == Status)
        && (PersonId is null || row.PersonId == PersonId)
        && (RoomId is null || row.RoomId == RoomId)
        && (!UnassignedPersonOnly || row.PersonId is null)
        && (!UnassignedRoomOnly || row.RoomId is null)
        && (Statuses.Count == 0 || Statuses.Contains(row.Status))
        && (Types.Count == 0 || Types.Contains(row.Type))
        && (OperatingSystems.Count == 0 || OperatingSystems.Contains(row.OperatingSystem))
        && (Vendors.Count == 0 || Vendors.Contains(row.VendorText))
        && (People.Count == 0 || People.Contains(row.PersonId))
        && (Rooms.Count == 0 || Rooms.Contains(row.RoomId))
        && row.MatchesFilter(SearchText);
}
