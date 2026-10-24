namespace FingVibe.App;

public sealed record DeviceResultFilter(
    bool AliveOnly,
    bool OpenPortsOnly,
    string SearchText,
    Guid? PersonId = null,
    Guid? RoomId = null,
    bool UnassignedPersonOnly = false,
    bool UnassignedRoomOnly = false)
{
    public bool Matches(ScanResultRow row) =>
        (!AliveOnly || row.IsOnline)
        && (!OpenPortsOnly || row.Result.OpenPortItems.Count > 0)
        && (PersonId is null || row.PersonId == PersonId)
        && (RoomId is null || row.RoomId == RoomId)
        && (!UnassignedPersonOnly || row.PersonId is null)
        && (!UnassignedRoomOnly || row.RoomId is null)
        && row.MatchesFilter(SearchText);
}
