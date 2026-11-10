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
    public IReadOnlySet<DeviceUsageCategory> UsageCategories { get; init; } = new HashSet<DeviceUsageCategory>();
    public bool AnyKnownStatus { get; init; }
    public bool AnyKnownType { get; init; }
    public bool AnyKnownOperatingSystem { get; init; }
    public bool AnyKnownVendor { get; init; }
    public bool AnyAssignedPerson { get; init; }
    public bool AnyAssignedRoom { get; init; }
    public bool AnyClassifiedUsage { get; init; }

    public int ActiveSecondaryCategoryCount =>
        (AnyKnownType || Types.Count > 0 ? 1 : 0) + (AnyKnownOperatingSystem || OperatingSystems.Count > 0 ? 1 : 0)
        + (AnyKnownVendor || Vendors.Count > 0 ? 1 : 0) + (AnyAssignedPerson || People.Count > 0 ? 1 : 0)
        + (AnyAssignedRoom || Rooms.Count > 0 ? 1 : 0) + (OpenPortsOnly ? 1 : 0)
        + (AnyClassifiedUsage || UsageCategories.Count > 0 ? 1 : 0);

    public bool HasRestrictions => AliveOnly || OpenPortsOnly || !string.IsNullOrEmpty(SearchText)
        || Status is not null || PersonId is not null || RoomId is not null
        || UnassignedPersonOnly || UnassignedRoomOnly || AnyKnownStatus || Statuses.Count > 0
        || ActiveSecondaryCategoryCount > 0;

    public bool Matches(ScanResultRow row) =>
        (!AliveOnly || row.IsOnline)
        && (!OpenPortsOnly || row.OpenPortItems.Count > 0)
        && (Status is null || row.Status == Status)
        && (PersonId is null || row.PersonId == PersonId)
        && (RoomId is null || row.RoomId == RoomId)
        && (!UnassignedPersonOnly || row.PersonId is null)
        && (!UnassignedRoomOnly || row.RoomId is null)
        && (AnyKnownStatus ? row.Status != InventoryDeviceStatus.Unknown : Statuses.Count == 0 || Statuses.Contains(row.Status))
        && (AnyKnownType ? row.Type != DeviceType.Unknown : Types.Count == 0 || Types.Contains(row.Type))
        && (AnyKnownOperatingSystem ? row.OperatingSystem != DeviceOperatingSystem.Unknown
            : OperatingSystems.Count == 0 || OperatingSystems.Contains(row.OperatingSystem))
        && (AnyKnownVendor ? DeviceVendorPresentation.IsKnown(row.VendorText)
            : Vendors.Count == 0 || Vendors.Contains(DeviceVendorPresentation.FilterValue(row.VendorText)))
        && (AnyAssignedPerson ? row.PersonId is not null : People.Count == 0 || People.Contains(row.PersonId))
        && (AnyAssignedRoom ? row.RoomId is not null : Rooms.Count == 0 || Rooms.Contains(row.RoomId))
        && (AnyClassifiedUsage ? row.EffectiveUsageCategory is not (null or DeviceUsageCategory.Unclassified)
            : UsageCategories.Count == 0 || row.EffectiveUsageCategory is { } category && UsageCategories.Contains(category))
        && row.MatchesFilter(SearchText);
}
