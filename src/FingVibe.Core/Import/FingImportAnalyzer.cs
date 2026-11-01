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
    public IReadOnlyList<FingImportDiagnostic> Diagnostics { get; init; } = [];
    public IReadOnlyList<FingAnalysisGroup> Groups { get; init; } = [];
    public IReadOnlyList<FingDeviceChanges> Devices { get; init; } = [];
    public int AppliedFields => Changes.Count(change => change.Apply);
    public int SkippedFields => Changes.Count(change => !change.Apply);
    public bool CanImport => Added > 0 || AppliedFields > 0;
}

public sealed record FingAnalysisGroup(string Category, string Summary, IReadOnlyList<string> Details, bool HasWarnings);
public sealed record FingDeviceChanges(string Mac, string Name, bool IsNew, IReadOnlyList<FingImportChange> Changes)
{
    public bool CanImport => IsNew || Changes.Any(change => change.Apply);
    public string Summary => $"{Changes.Count(change => change.Apply && !change.Conflict)} additions · "
        + $"{Changes.Count(change => change.Conflict && change.SkipReason is null)} conflicts · "
        + $"{Changes.Count(change => change.SkipReason is not null)} skipped";
}

public static class FingImportAnalyzer
{
    public static FingImportAnalysis Analyze(FingExport export, DeviceInventoryData current, IReadOnlySet<string>? replacements = null,
        IReadOnlySet<string>? selectedMacs = null)
    {
        var devices = current.Devices.ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.OrdinalIgnoreCase);
        var names = current.Names.ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.OrdinalIgnoreCase);
        var classifications = current.Classifications.ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.OrdinalIgnoreCase);
        var peopleRooms = current.PeopleRooms;
        var changes = new List<FingImportChange>();
        var warnings = export.Warnings.ToList();
        var diagnostics = export.Diagnostics.Count > 0 ? export.Diagnostics.ToList()
            : export.Warnings.Select(warning => new FingImportDiagnostic("Other warnings", warning)).ToList();
        void Warn(string category, string message, int row)
        {
            diagnostics.Add(new(category, message, row));
            warnings.Add($"Row {row}: {message}");
        }
        var deviceChanges = new List<FingDeviceChanges>();
        var matched = 0;
        var added = 0;
        foreach (var record in export.Devices)
        {
            if (selectedMacs is not null && !selectedMacs.Contains(record.Mac)) continue;
            var firstChange = changes.Count;
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
                if (skipReason is not null) Warn(field is "Person" ? "People" : field is "Room" ? "Rooms" : "Skipped records / fields", skipReason, record.Row);
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
                Warn("Classification", $"Type '{incoming.Type}' has no reliable category mapping; original Fing type is retained.", record.Row);
            if (incoming.OperatingSystem is not null && FingClassificationMapper.OperatingSystem(incoming.OperatingSystem) is null)
                Warn("Classification", $"OS '{incoming.OperatingSystem}' has no reliable mapping; original Fing OS is retained.", record.Row);
            if (Consider("Type", metadata.Type, incoming.Type)) metadata = metadata with { Type = incoming.Type };
            if (Consider("OS", metadata.OperatingSystem, incoming.OperatingSystem))
                metadata = metadata with { OperatingSystem = incoming.OperatingSystem };
            var versionSkip = incoming.OperatingSystem is not null
                && !string.Equals(metadata.OperatingSystem, incoming.OperatingSystem, StringComparison.Ordinal)
                    ? "The incoming OS was not selected, so its OS version is skipped." : null;
            if (Consider("OS version", metadata.OperatingSystemVersion, incoming.OperatingSystemVersion, versionSkip))
                metadata = metadata with { OperatingSystemVersion = incoming.OperatingSystemVersion };
            if (incoming.Type is not null && userClassification?.Type is { } selectedType
                && FingClassificationMapper.Type(incoming.Type) is { } mappedType && selectedType != mappedType
                && Consider("Device type correction", selectedType.Label(), mappedType.Label(),
                    metadata.Type != incoming.Type ? "The incoming type was not selected; its classification replacement is skipped." : null))
                userClassification = userClassification with { Type = null };
            if (incoming.OperatingSystem is not null && userClassification?.OperatingSystem is { } selectedOs
                && FingClassificationMapper.OperatingSystem(incoming.OperatingSystem) is { } mappedOs && selectedOs != mappedOs
                && Consider("OS correction", selectedOs.Label(), mappedOs.Label(),
                    metadata.OperatingSystem != incoming.OperatingSystem ? "The incoming OS was not selected; its classification replacement is skipped." : null))
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
            deviceChanges.Add(new(record.Mac, displayName, existing is null, changes.Skip(firstChange).ToArray()));
        }
        return new(current.Revision, current with
        {
            Devices = devices,
            Names = names,
            Classifications = classifications,
            PeopleRooms = peopleRooms
        }, changes, warnings, export.DeviceRows, matched, added)
        {
            Diagnostics = diagnostics,
            Devices = deviceChanges,
            Groups = BuildGroups(export, current, diagnostics)
        };
    }

    private static IReadOnlyList<FingAnalysisGroup> BuildGroups(FingExport export, DeviceInventoryData current,
        IReadOnlyList<FingImportDiagnostic> diagnostics)
    {
        var groups = new List<FingAnalysisGroup>();
        void Assignments(string category, IEnumerable<string?> references, IEnumerable<string> existing)
        {
            var names = references.Where(name => !string.IsNullOrWhiteSpace(name)).Select(name => name!.Trim())
                .GroupBy(name => name, StringComparer.OrdinalIgnoreCase).ToArray();
            var saved = existing.ToArray();
            var details = names.Select(group =>
            {
                var matches = saved.Count(name => EqualName(name, group.Key));
                return $"{group.Key}: {(matches == 1 ? "matched" : matches == 0 ? "missing" : "ambiguous")} · {group.Count()} devices";
            }).ToArray();
            var missing = names.Count(group => saved.Count(name => EqualName(name, group.Key)) != 1);
            var summary = names.Length == 0 ? $"No {category.ToLowerInvariant()} referenced in this export."
                : missing == 0 ? $"All {names.Length} referenced {category.ToLowerInvariant()} match; no extra {category.ToLowerInvariant()} need adding."
                : $"{names.Length - missing} matched · {missing} missing or ambiguous; assignments to these entries will be skipped.";
            groups.Add(new(category, summary, details, missing > 0));
        }
        Assignments("People", export.Devices.Select(device => device.Owner), current.PeopleRooms.People.Select(person => person.Name));
        Assignments("Rooms", export.Devices.Select(device => device.Location), current.PeopleRooms.Rooms.Select(room => room.Name));
        foreach (var category in diagnostics.Where(item => item.Category is not ("People" or "Rooms")).GroupBy(item => item.Category))
        {
            var details = category.GroupBy(item => item.Message).Select(items =>
                $"{items.Key} ({items.Count()} occurrences)"
                + (items.Any(item => item.Row is not null) ? $" Rows: {string.Join(", ", items.Where(item => item.Row is not null).Select(item => item.Row))}" : "")).ToArray();
            groups.Add(new(category.Key, $"{category.Count()} warnings", details, true));
        }
        return groups;
    }

    private static bool EqualName(string existing, string incoming) =>
        string.Equals(existing.Trim(), incoming.Trim(), StringComparison.OrdinalIgnoreCase);
}
