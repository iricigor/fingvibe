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
    public bool Matches(ScanResultRow row) =>
        (!AliveOnly || row.IsOnline)
        && (!OpenPortsOnly || row.OpenPortItems.Count > 0)
        && (Status is null || row.Status == Status)
        && (PersonId is null || row.PersonId == PersonId)
        && (RoomId is null || row.RoomId == RoomId)
        && (!UnassignedPersonOnly || row.PersonId is null)
        && (!UnassignedRoomOnly || row.RoomId is null)
        && row.MatchesFilter(SearchText);
}
