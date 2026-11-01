using System.Net;
using System.Text.Json;
using FingVibe.Core.Models;

namespace FingVibe.Core.Storage;

public sealed class DeviceInventoryStore
{
    private static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web) { WriteIndented = true };
    private readonly string _path;

    public DeviceInventoryStore(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        _path = path;
    }

    public async Task<DeviceInventoryData?> LoadAsync(CancellationToken cancellationToken = default)
    {
        try
        {
            await using var stream = File.OpenRead(_path);
            var document = await JsonSerializer.DeserializeAsync<Document>(stream, Options, cancellationToken);
            if (document is null || document.Version != 1 || document.Data is not { } saved
                || saved.Revision == Guid.Empty || saved.Devices is null || saved.Names is null || saved.Classifications is null
                || saved.PeopleRooms?.People is null || saved.PeopleRooms.Rooms is null || saved.PeopleRooms.Assignments is null)
                throw new InvalidDataException("The device inventory has an unsupported or invalid format.");
            var data = new DeviceInventoryData(saved.Revision, saved.Devices, saved.Names, saved.Classifications,
                new PeopleRoomsData(saved.PeopleRooms.People, saved.PeopleRooms.Rooms, saved.PeopleRooms.Assignments));
            Validate(data);
            return data;
        }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
        catch (Exception exception) when (exception is JsonException or ArgumentException or FormatException)
        {
            throw new InvalidDataException("The device inventory contains invalid saved data.", exception);
        }
    }

    public async Task<DeviceInventoryData> SaveAsync(
        DeviceInventoryData data, Guid expectedRevision, CancellationToken cancellationToken = default)
    {
        Validate(data);
        var directory = Path.GetDirectoryName(_path)
            ?? throw new ArgumentException("The inventory path must include a directory.");
        Directory.CreateDirectory(directory);
        await using var fileLock = new FileStream(_path + ".lock", FileMode.OpenOrCreate,
            FileAccess.ReadWrite, FileShare.None);
        var saved = await LoadAsync(cancellationToken);
        if ((saved?.Revision ?? Guid.Empty) != expectedRevision)
            throw new InvalidOperationException("Saved device data changed in another app instance. Restart and analyze again before saving.");
        var updated = data with { Revision = Guid.NewGuid() };
        var temporary = Path.Combine(directory, $".{Path.GetFileName(_path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            await using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                var document = new Document(1, new SavedData(updated.Revision, updated.Devices, updated.Names,
                    updated.Classifications, new SavedPeopleRooms(updated.PeopleRooms.People, updated.PeopleRooms.Rooms,
                        updated.PeopleRooms.Assignments)));
                await JsonSerializer.SerializeAsync(stream, document, Options, cancellationToken);
                await stream.FlushAsync(cancellationToken);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, _path, true);
            return updated;
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    private static void Validate(DeviceInventoryData data)
    {
        if (data.Devices is null || data.Names is null || data.Classifications is null || data.PeopleRooms is null)
            throw new InvalidDataException("The device inventory is incomplete.");
        _ = new PeopleRoomsData(data.PeopleRooms.People, data.PeopleRooms.Rooms, data.PeopleRooms.Assignments);
        foreach (var (key, device) in data.Devices)
        {
            if (device is null || key != PeopleRoomsData.NormalizeMacAddress(key) || device.Mac != key
                || device.Imported is null || device.Observations is null)
                throw new InvalidDataException("The device inventory contains an invalid MAC or device.");
            if (device.Imported.Address is { } importedAddress && !IsIpv4(importedAddress))
                throw new InvalidDataException("An imported address is invalid.");
            if (new[] { device.Imported.Name, device.Imported.Hostname, device.Imported.Type, device.Imported.Brand,
                    device.Imported.Family, device.Imported.Model, device.Imported.OperatingSystem, device.Imported.OperatingSystemVersion }
                .Any(value => value is not null && string.IsNullOrWhiteSpace(value)))
                throw new InvalidDataException("Imported metadata must use null, not blank values, for missing fields.");
            var identities = new HashSet<(string?, string)>();
            foreach (var observation in device.Observations)
            {
                if (observation is null || !IsIpv4(observation.Address) || observation.FirstSeen == default
                    || observation.LastSeen < observation.FirstSeen || observation.LastChecked < observation.LastSeen
                    || observation.Classification is null || observation.Ports is null
                    || !Enum.IsDefined(observation.Classification.Type) || !Enum.IsDefined(observation.Classification.OperatingSystem)
                    || string.IsNullOrWhiteSpace(observation.Classification.TypeEvidence)
                    || string.IsNullOrWhiteSpace(observation.Classification.OperatingSystemEvidence)
                    || observation.NetworkId is not null && string.IsNullOrWhiteSpace(observation.NetworkId)
                    || observation.Ports.Any(port => port is null || port.Port is < 1 or > 65535)
                    || !identities.Add((observation.NetworkId, observation.Subnet))
                    || !ValidSubnet(observation.Subnet))
                    throw new InvalidDataException("The device inventory contains invalid local observations.");
            }
        }
        foreach (var (key, name) in data.Names)
            if (key != PeopleRoomsData.NormalizeMacAddress(key) || string.IsNullOrWhiteSpace(name))
                throw new InvalidDataException("A saved name is invalid.");
        foreach (var (key, classification) in data.Classifications)
            if (key != PeopleRoomsData.NormalizeMacAddress(key) || classification is null
                || classification.OperatingSystem is { } os && !Enum.IsDefined(os)
                || classification.Type is { } type && !Enum.IsDefined(type)
                || classification.Icon is { } icon && !Enum.IsDefined(icon))
                throw new InvalidDataException("A saved classification is invalid.");
    }

    private static bool IsIpv4(string value) => IPAddress.TryParse(value, out var address)
        && address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork;

    private static bool ValidSubnet(string? value)
    {
        if (value is null) return false;
        var parts = value.Split('/');
        return parts.Length == 2 && IsIpv4(parts[0]) && int.TryParse(parts[1], out var prefix) && prefix is >= 0 and <= 32;
    }

    private sealed record Document(int Version, SavedData? Data);
    private sealed record SavedData(Guid Revision, IReadOnlyDictionary<string, InventoryDevice>? Devices,
        IReadOnlyDictionary<string, string>? Names, IReadOnlyDictionary<string, DeviceClassificationOverride>? Classifications,
        SavedPeopleRooms? PeopleRooms);
    private sealed record SavedPeopleRooms(IReadOnlyList<ManagedPerson>? People, IReadOnlyList<ManagedRoom>? Rooms,
        IReadOnlyDictionary<string, DeviceAssignment>? Assignments);
}
