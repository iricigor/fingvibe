using FingVibe.Core.Models;

namespace FingVibe.Core.Import;

public static class FingClassificationMapper
{
    public static DeviceType? Type(string? value) => value?.Trim().ToLowerInvariant() switch
    {
        "computer" or "desktop" or "laptop" or "server" => DeviceType.Computer,
        "mobile" or "phone" or "smartphone" => DeviceType.Phone,
        "tablet" => DeviceType.Tablet,
        "router" or "wi-fi" or "access point" => DeviceType.Router,
        "printer" => DeviceType.Printer,
        "tv" or "smart tv" or "speaker/amp" or "media player" or "voice assistant" => DeviceType.MediaDevice,
        "nas" or "storage" => DeviceType.Storage,
        "game console" => DeviceType.GameConsole,
        "smart cleaner" or "smart device" or "smart appliance" => DeviceType.SmartDevice,
        _ => null
    };

    public static DeviceOperatingSystem? OperatingSystem(string? value) => value?.Trim().ToLowerInvariant() switch
    {
        "windows" => DeviceOperatingSystem.Windows,
        "android" => DeviceOperatingSystem.Android,
        "linux" => DeviceOperatingSystem.Linux,
        "macos" or "mac os" or "os x" => DeviceOperatingSystem.MacOS,
        "ios" or "ipados" or "ios/ipados" => DeviceOperatingSystem.IOS,
        _ => null
    };
}

public sealed record FingImportChange(string Mac, string DeviceName, string Field,
    string? Current, string Incoming, bool Conflict, bool Apply, string? SkipReason = null)
{
    public string Key => $"{Mac}:{Field}";
    public string Action => SkipReason is not null ? Field is "Person" or "Room" ? "Skip assignment" : "Skip field"
        : Apply ? Conflict ? "Replace" : "Add" : "Keep existing";
    public bool CanChoose => Conflict && SkipReason is null;
    public int ChoiceIndex => Conflict && Apply ? 1 : 0;
    public string BeforeAfter => $"{Current ?? "Not saved"} \u2192 {Incoming}";
}

public sealed record FingImportAnalysis(
    Guid Revision, DeviceInventoryData Updated, IReadOnlyList<FingImportChange> Changes,
    IReadOnlyList<string> Warnings, int DeviceRows, int Matched, int Added)
{
    public int AppliedFields => Changes.Count(change => change.Apply);
    public int SkippedFields => Changes.Count(change => !change.Apply);
    public bool CanImport => Added > 0 || AppliedFields > 0;
}

public static class FingImportAnalyzer
{
    public static FingImportAnalysis Analyze(FingExport export, DeviceInventoryData current, IReadOnlySet<string>? replacements = null)
    {
        var devices = current.Devices.ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.OrdinalIgnoreCase);
        var names = current.Names.ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.OrdinalIgnoreCase);
        var classifications = current.Classifications.ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.OrdinalIgnoreCase);
        var peopleRooms = current.PeopleRooms;
        var changes = new List<FingImportChange>();
        var warnings = export.Warnings.ToList();
        var matched = 0;
        var added = 0;
        foreach (var record in export.Devices)
        {
            var existing = devices.GetValueOrDefault(record.Mac);
            if (existing is null) added++; else matched++;
            var device = existing ?? new InventoryDevice(record.Mac, new(), []);
            var metadata = device.Imported;
            var incoming = record.Metadata;
            var userClassification = classifications.GetValueOrDefault(record.Mac);
            var displayName = names.GetValueOrDefault(record.Mac) ?? metadata.Name
                ?? device.LatestObservation?.Hostname ?? metadata.Hostname ?? incoming.Name ?? incoming.Hostname ?? record.Mac;

            bool Consider(string field, string? before, string? after, string? skipReason = null)
            {
                if (string.IsNullOrWhiteSpace(after)
                    || skipReason is null && string.Equals(before, after, StringComparison.Ordinal)) return false;
                var conflict = !string.IsNullOrWhiteSpace(before);
                var apply = skipReason is null && (!conflict || replacements?.Contains($"{record.Mac}:{field}") == true);
                changes.Add(new(record.Mac, displayName, field, before, after, conflict, apply, skipReason));
                if (skipReason is not null) warnings.Add($"Row {record.Row}: {skipReason}");
                return apply;
            }

            if (Consider("Name", names.GetValueOrDefault(record.Mac) ?? metadata.Name, incoming.Name))
            {
                metadata = metadata with { Name = incoming.Name };
                names.Remove(record.Mac);
            }
            if (Consider("Hostname", metadata.Hostname, incoming.Hostname)) metadata = metadata with { Hostname = incoming.Hostname };
            if (Consider("Brand", metadata.Brand, incoming.Brand)) metadata = metadata with { Brand = incoming.Brand };
            if (Consider("Family", metadata.Family, incoming.Family)) metadata = metadata with { Family = incoming.Family };
            if (Consider("Model", metadata.Model, incoming.Model)) metadata = metadata with { Model = incoming.Model };
            if (Consider("Imported IP", metadata.Address, incoming.Address)) metadata = metadata with { Address = incoming.Address };
            if (incoming.Type is not null && FingClassificationMapper.Type(incoming.Type) is null)
                warnings.Add($"Row {record.Row}: type '{incoming.Type}' has no reliable category mapping; review the original Fing type in the preview.");
            if (incoming.OperatingSystem is not null && FingClassificationMapper.OperatingSystem(incoming.OperatingSystem) is null)
                warnings.Add($"Row {record.Row}: OS '{incoming.OperatingSystem}' has no reliable mapping; review the original Fing OS in the preview.");
            if (Consider("Type", metadata.Type, incoming.Type)) metadata = metadata with { Type = incoming.Type };
            if (Consider("OS", metadata.OperatingSystem, incoming.OperatingSystem))
                metadata = metadata with { OperatingSystem = incoming.OperatingSystem };
            var versionSkip = incoming.OperatingSystem is not null
                && !string.Equals(metadata.OperatingSystem, incoming.OperatingSystem, StringComparison.Ordinal)
                    ? "The incoming OS was not selected, so its OS version is skipped." : null;
            if (Consider("OS version", metadata.OperatingSystemVersion, incoming.OperatingSystemVersion, versionSkip))
                metadata = metadata with { OperatingSystemVersion = incoming.OperatingSystemVersion };
            if (incoming.Type is not null && userClassification?.Type is { } selectedType
                && FingClassificationMapper.Type(metadata.Type) is { } mappedType
                && Consider("Device type correction", selectedType.Label(), mappedType.Label()))
                userClassification = userClassification with { Type = null };
            if (incoming.OperatingSystem is not null && userClassification?.OperatingSystem is { } selectedOs
                && FingClassificationMapper.OperatingSystem(metadata.OperatingSystem) is { } mappedOs
                && Consider("OS correction", selectedOs.Label(), mappedOs.Label()))
                userClassification = userClassification with { OperatingSystem = null };
            if (userClassification is not null)
            {
                if (userClassification.IsEmpty) classifications.Remove(record.Mac);
                else classifications[record.Mac] = userClassification;
            }

            var assignment = peopleRooms.Assignments.GetValueOrDefault(record.Mac) ?? new DeviceAssignment();
            if (record.Owner is { } owner)
            {
                var matches = peopleRooms.People.Where(person => EqualName(person.Name, owner)).ToArray();
                var before = peopleRooms.People.FirstOrDefault(person => person.Id == assignment.PersonId)?.Name;
                var reason = matches.Length == 1 ? null : $"Owner '{owner}' is missing or ambiguous; person assignment skipped.";
                if ((reason is not null || matches[0].Id != assignment.PersonId) && Consider("Person", before, owner, reason))
                    peopleRooms = peopleRooms.AssignPerson(record.Mac, matches[0].Id);
            }
            if (record.Location is { } location)
            {
                var matches = peopleRooms.Rooms.Where(room => EqualName(room.Name, location)).ToArray();
                var before = peopleRooms.Rooms.FirstOrDefault(room => room.Id == assignment.RoomId)?.Name;
                var reason = matches.Length == 1 ? null : $"Location '{location}' is missing or ambiguous; room assignment skipped.";
                if ((reason is not null || matches[0].Id != assignment.RoomId) && Consider("Room", before, location, reason))
                    peopleRooms = peopleRooms.AssignRoom(record.Mac, matches[0].Id);
            }
            devices[record.Mac] = device with { Imported = metadata };
        }
        return new(current.Revision, current with
        {
            Devices = devices,
            Names = names,
            Classifications = classifications,
            PeopleRooms = peopleRooms
        }, changes, warnings, export.DeviceRows, matched, added);
    }

    private static bool EqualName(string existing, string incoming) =>
        string.Equals(existing.Trim(), incoming.Trim(), StringComparison.OrdinalIgnoreCase);
}
