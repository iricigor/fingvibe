using System.Net.NetworkInformation;
using System.Globalization;

namespace FingVibe.Core.Models;

public sealed record ManagedPerson(Guid Id, string Name, string ShortName, string? Notes = null);

public sealed record ManagedRoom(Guid Id, string Name, string ShortName, string? Notes = null);

public sealed record DeviceAssignment(Guid? PersonId = null, Guid? RoomId = null);

public sealed class PeopleRoomsData
{
    public PeopleRoomsData(
        IReadOnlyList<ManagedPerson>? people = null,
        IReadOnlyList<ManagedRoom>? rooms = null,
        IReadOnlyDictionary<string, DeviceAssignment>? assignments = null)
    {
        People = people?.Select(person => person is null
            ? throw new ArgumentException("People cannot contain null entries.", nameof(people))
            : person with
            {
                Name = person.Name?.Trim() ?? string.Empty,
                ShortName = person.ShortName?.Trim() ?? string.Empty,
                Notes = string.IsNullOrWhiteSpace(person.Notes) ? null : person.Notes.Trim()
            }).ToArray() ?? [];
        Rooms = rooms?.Select(room => room is null
            ? throw new ArgumentException("Rooms cannot contain null entries.", nameof(rooms))
            : room with
            {
                Name = room.Name?.Trim() ?? string.Empty,
                ShortName = room.ShortName?.Trim() ?? string.Empty,
                Notes = string.IsNullOrWhiteSpace(room.Notes) ? null : room.Notes.Trim()
            }).ToArray() ?? [];
        Assignments = NormalizeAssignments(assignments ?? new Dictionary<string, DeviceAssignment>());
        Validate();
    }

    public IReadOnlyList<ManagedPerson> People { get; }
    public IReadOnlyList<ManagedRoom> Rooms { get; }
    public IReadOnlyDictionary<string, DeviceAssignment> Assignments { get; }

    public PeopleRoomsData AssignPerson(string macAddress, Guid? personId)
    {
        if (personId is not null && People.All(person => person.Id != personId))
        {
            throw new ArgumentException("The person does not exist.", nameof(personId));
        }

        return UpdateAssignment(macAddress, assignment => assignment with { PersonId = personId });
    }

    public PeopleRoomsData AssignRoom(string macAddress, Guid? roomId)
    {
        if (roomId is not null && Rooms.All(room => room.Id != roomId))
        {
            throw new ArgumentException("The room does not exist.", nameof(roomId));
        }

        return UpdateAssignment(macAddress, assignment => assignment with { RoomId = roomId });
    }

    public PeopleRoomsData DeletePerson(Guid personId)
    {
        var people = People.Where(person => person.Id != personId).ToArray();
        var assignments = Assignments
            .Select(pair => new KeyValuePair<string, DeviceAssignment>(
                pair.Key, pair.Value with { PersonId = pair.Value.PersonId == personId ? null : pair.Value.PersonId }))
            .Where(pair => pair.Value.PersonId is not null || pair.Value.RoomId is not null)
            .ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.OrdinalIgnoreCase);
        return new PeopleRoomsData(people, Rooms, assignments);
    }

    public PeopleRoomsData DeleteRoom(Guid roomId)
    {
        var rooms = Rooms.Where(room => room.Id != roomId).ToArray();
        var assignments = Assignments
            .Select(pair => new KeyValuePair<string, DeviceAssignment>(
                pair.Key, pair.Value with { RoomId = pair.Value.RoomId == roomId ? null : pair.Value.RoomId }))
            .Where(pair => pair.Value.PersonId is not null || pair.Value.RoomId is not null)
            .ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.OrdinalIgnoreCase);
        return new PeopleRoomsData(People, rooms, assignments);
    }

    public static string? ValidateShortName(string? value)
    {
        var shortName = value?.Trim() ?? string.Empty;
        var length = StringInfo.ParseCombiningCharacters(shortName).Length;
        return length switch
        {
            0 => "A short name is required.",
            > 3 => "Short names must contain 1 to 3 characters.",
            _ => null
        };
    }

    public static string NormalizeMacAddress(string macAddress)
    {
        if (string.IsNullOrWhiteSpace(macAddress))
        {
            throw new FormatException("A MAC address is required.");
        }

        var address = PhysicalAddress.Parse(macAddress);
        if (address.GetAddressBytes().Length != 6)
        {
            throw new FormatException("A six-byte MAC address is required.");
        }

        return address.ToString();
    }

    private PeopleRoomsData UpdateAssignment(
        string macAddress,
        Func<DeviceAssignment, DeviceAssignment> update)
    {
        var key = NormalizeMacAddress(macAddress);
        var assignments = Assignments.ToDictionary(
            pair => pair.Key, pair => pair.Value, StringComparer.OrdinalIgnoreCase);
        var assignment = update(assignments.GetValueOrDefault(key) ?? new DeviceAssignment());
        if (assignment.PersonId is null && assignment.RoomId is null)
        {
            assignments.Remove(key);
        }
        else
        {
            assignments[key] = assignment;
        }

        return new PeopleRoomsData(People, Rooms, assignments);
    }

    private void Validate()
    {
        ValidateEntries(People.Select(person => (person.Id, person.Name, person.ShortName)), "person");
        ValidateEntries(Rooms.Select(room => (room.Id, room.Name, room.ShortName)), "room");

        var peopleIds = People.Select(person => person.Id).ToHashSet();
        var roomIds = Rooms.Select(room => room.Id).ToHashSet();
        foreach (var assignment in Assignments.Values)
        {
            if (assignment.PersonId is { } personId && !peopleIds.Contains(personId)
                || assignment.RoomId is { } roomId && !roomIds.Contains(roomId))
            {
                throw new ArgumentException("Assignments must reference existing people and rooms.");
            }
        }
    }

    private static void ValidateEntries(
        IEnumerable<(Guid Id, string Name, string ShortName)> entries,
        string category)
    {
        var ids = new HashSet<Guid>();
        var shortNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (id, name, shortName) in entries)
        {
            if (id == Guid.Empty || !ids.Add(id) || string.IsNullOrWhiteSpace(name))
            {
                throw new ArgumentException($"Each {category} must have a unique id and a full name.");
            }

            var trimmedShortName = shortName?.Trim() ?? string.Empty;
            var validationMessage = ValidateShortName(trimmedShortName);
            if (validationMessage is not null || !shortNames.Add(trimmedShortName))
            {
                throw new ArgumentException(validationMessage
                    ?? $"Short names must be unique within {category}, ignoring case.");
            }
        }
    }

    private static IReadOnlyDictionary<string, DeviceAssignment> NormalizeAssignments(
        IReadOnlyDictionary<string, DeviceAssignment> assignments)
    {
        var normalized = new Dictionary<string, DeviceAssignment>(StringComparer.OrdinalIgnoreCase);
        foreach (var (macAddress, assignment) in assignments)
        {
            var key = NormalizeMacAddress(macAddress);
            if (assignment is null)
            {
                throw new ArgumentException("Device assignments cannot be null.", nameof(assignments));
            }

            if (assignment.PersonId is not null || assignment.RoomId is not null)
            {
                if (!normalized.TryAdd(key, assignment))
                {
                    throw new ArgumentException("A device can only have one assignment record.", nameof(assignments));
                }
            }
        }

        return normalized;
    }
}
