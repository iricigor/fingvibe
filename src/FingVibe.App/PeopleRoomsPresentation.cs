using System.Globalization;
using FingVibe.Core.Models;

namespace FingVibe.App;

internal static class PeopleRoomsPresentation
{
    internal static bool MatchesSearch(string shortName, string name, string search) =>
        shortName.Contains(search.Trim(), StringComparison.OrdinalIgnoreCase)
        || name.Contains(search.Trim(), StringComparison.OrdinalIgnoreCase);

    internal static string SuggestShortName(string name) =>
        string.Concat(name.Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Select(word => StringInfo.GetNextTextElement(word))
            .Take(2)
            .Select(initial => initial.ToUpperInvariant()));

    internal static string? ValidatePerson(
        PeopleRoomsData data, ManagedPerson? existing, string name, string shortName) =>
        ValidateName(name, shortName)
        ?? (data.People.Any(person => person.Id != existing?.Id
            && string.Equals(person.ShortName.Trim(), shortName.Trim(), StringComparison.OrdinalIgnoreCase))
            ? "That short name is already used by another person." : null);

    internal static string? ValidateRoom(
        PeopleRoomsData data, ManagedRoom? existing, string name, string shortName) =>
        ValidateName(name, shortName)
        ?? (data.Rooms.Any(room => room.Id != existing?.Id
            && string.Equals(room.ShortName.Trim(), shortName.Trim(), StringComparison.OrdinalIgnoreCase))
            ? "That short name is already used by another room." : null);

    private static string? ValidateName(string name, string shortName) =>
        string.IsNullOrWhiteSpace(name) ? "A full name is required."
            : PeopleRoomsData.ValidateShortName(shortName);

    internal static IReadOnlyList<AssignedDeviceListRow> AssignedTo(
        PeopleRoomsData data, IReadOnlyList<AssignedDeviceListRow> devices, Guid? personId, Guid? roomId) =>
        devices.Where(row =>
        {
            var assignment = Assignment(data, row);
            return assignment is not null
                && (personId is null || assignment.PersonId == personId)
                && (roomId is null || assignment.RoomId == roomId);
        }).ToArray();

    internal static string DeviceCount(int count) => $"{count} {(count == 1 ? "device" : "devices")}";

    internal static string ResponseCount(IReadOnlyList<AssignedDeviceListRow> devices, bool hasCurrentScan) =>
        hasCurrentScan
            ? $"{devices.Count(row => row.ScanResult?.IsOnline == true)} online"
            : "No local scan evidence";

    internal static string DetailResponses(IReadOnlyList<AssignedDeviceListRow> devices, bool hasCurrentScan) =>
        hasCurrentScan
            ? $"{devices.Count(row => row.ScanResult?.IsOnline == true)} devices Online in their latest applicable scan evidence."
            : "No local scan evidence.";

    internal static IReadOnlyList<ManagedPersonListRow> PeopleRows(
        PeopleRoomsData data, IReadOnlyList<AssignedDeviceListRow> devices, bool hasCurrentScan)
    {
        var counts = ProjectCounts(data, devices, person: true);
        return data.People.Select(person =>
        {
            var summary = counts.GetValueOrDefault(person.Id);
            return new ManagedPersonListRow(person, DeviceCount(summary.Devices),
                hasCurrentScan ? $"{summary.Online} online" : "No local scan evidence");
        }).ToArray();
    }

    internal static IReadOnlyList<ManagedRoomListRow> RoomRows(
        PeopleRoomsData data, IReadOnlyList<AssignedDeviceListRow> devices, bool hasCurrentScan)
    {
        var counts = ProjectCounts(data, devices, person: false);
        return data.Rooms.Select(room =>
        {
            var summary = counts.GetValueOrDefault(room.Id);
            return new ManagedRoomListRow(room, DeviceCount(summary.Devices),
                hasCurrentScan ? $"{summary.Online} online" : "No local scan evidence");
        }).ToArray();
    }

    private static Dictionary<Guid, (int Devices, int Online)> ProjectCounts(
        PeopleRoomsData data, IReadOnlyList<AssignedDeviceListRow> devices, bool person)
    {
        var counts = new Dictionary<Guid, (int Devices, int Online)>();
        foreach (var device in devices)
        {
            var assignment = Assignment(data, device);
            var id = person ? assignment?.PersonId : assignment?.RoomId;
            if (id is not { } assigned) continue;
            var summary = counts.GetValueOrDefault(assigned);
            counts[assigned] = (
                summary.Devices + 1,
                summary.Online + (device.ScanResult?.IsOnline == true ? 1 : 0));
        }
        return counts;
    }

    private static DeviceAssignment? Assignment(PeopleRoomsData data, AssignedDeviceListRow row) =>
        row.ScanResult?.VirtualDevice is { } virtualDevice ? virtualDevice.Assignment
            : row.ScanResult?.LinkedDevice is { } linked ? linked.Assignment
            : data.Assignments.GetValueOrDefault(row.IdentityKey);
}
