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
            if (document is null || document.Version is not (1 or 2) || document.Data is not { } saved
                || saved.Revision == Guid.Empty || saved.Devices is null || saved.Names is null || saved.Classifications is null
                || saved.PeopleRooms?.People is null || saved.PeopleRooms.Rooms is null || saved.PeopleRooms.Assignments is null
                || document.Version == 2 && saved.VirtualDevices is null)
                throw new InvalidDataException("The device inventory has an unsupported or invalid format.");
            var data = new DeviceInventoryData(saved.Revision, saved.Devices, saved.Names, saved.Classifications,
                new PeopleRoomsData(saved.PeopleRooms.People, saved.PeopleRooms.Rooms, saved.PeopleRooms.Assignments))
            {
                VirtualDevices = saved.VirtualDevices ?? []
            };
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
                var document = new Document(2, new SavedData(updated.Revision, updated.Devices, updated.Names,
                    updated.Classifications, new SavedPeopleRooms(updated.PeopleRooms.People, updated.PeopleRooms.Rooms,
                        updated.PeopleRooms.Assignments), updated.VirtualDevices));
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
            var identities = new HashSet<(string?, string, string)>();
            foreach (var observation in device.Observations)
            {
                ValidateObservation(observation);
                if (!identities.Add((observation.NetworkId, observation.Subnet, observation.Address)))
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
        if (data.VirtualDevices is null)
            throw new InvalidDataException("Virtual devices are missing.");
        var ids = new HashSet<Guid>();
        var numbers = new HashSet<(string, string, string, int)>();
        var activeMacs = new HashSet<(string, string, string)>();
        foreach (var slot in data.VirtualDevices)
        {
            if (slot is null || slot.Id == Guid.Empty || !ids.Add(slot.Id)
                || string.IsNullOrWhiteSpace(slot.NetworkId) || !ValidSubnet(slot.Subnet)
                || slot.Prefix is null || slot.Prefix.Length != 6 || !slot.Prefix.All(Uri.IsHexDigit)
                || slot.Prefix != slot.Prefix.ToUpperInvariant() || slot.Number < 1
                || (Convert.ToByte(slot.Prefix[..2], 16) & 3) != 0
                || !numbers.Add((slot.NetworkId, slot.Subnet, slot.Prefix, slot.Number))
                || slot.LastChecked == default || slot.History is null || slot.History.Count == 0
                || slot.Name is not null && string.IsNullOrWhiteSpace(slot.Name)
                || slot.Classification is { } classification
                    && (classification.Type is { } type && !Enum.IsDefined(type)
                        || classification.OperatingSystem is { } os && !Enum.IsDefined(os)
                        || classification.Icon is { } icon && !Enum.IsDefined(icon))
                || slot.Assignment?.PersonId is { } person && data.PeopleRooms.People.All(item => item.Id != person)
                || slot.Assignment?.RoomId is { } room && data.PeopleRooms.Rooms.All(item => item.Id != room))
                throw new InvalidDataException("The inventory contains invalid virtual devices.");
            var connections = new HashSet<(string, string)>();
            foreach (var connection in slot.History)
            {
                if (connection is null || connection.Observation is not { } observation
                    || !data.Devices.ContainsKey(connection.Mac) || !connection.Mac.StartsWith(slot.Prefix, StringComparison.Ordinal)
                    || observation.NetworkId != slot.NetworkId || observation.Subnet != slot.Subnet
                    || !connections.Add((connection.Mac, observation.Address)) || observation.LastChecked > slot.LastChecked)
                    throw new InvalidDataException("A virtual-device connection is invalid.");
                ValidateObservation(observation);
            }
            if (!slot.History.Any(item => item.Mac == slot.LastActiveMac))
                throw new InvalidDataException("A virtual device has no last-active connection.");
            var current = slot.History.Where(item => item.Observation.Present
                && item.Observation.LastChecked == slot.LastChecked).ToArray();
            if (slot.Present && (current.Length == 0 || current.Any(item => item.Mac != slot.LastActiveMac))
                || !slot.Present && current.Length != 0)
                throw new InvalidDataException("A virtual device must have at most one responding MAC.");
            if (slot.Present && !activeMacs.Add((slot.NetworkId, slot.Subnet, slot.LastActiveMac)))
                throw new InvalidDataException("A responding MAC cannot occupy multiple virtual devices.");
        }
    }

    private static void ValidateObservation(DeviceObservation observation)
    {
        if (observation is null || !IsIpv4(observation.Address) || observation.FirstSeen == default
            || observation.LastSeen < observation.FirstSeen || observation.LastChecked < observation.LastSeen
            || observation.Classification is null || observation.Ports is null
            || !Enum.IsDefined(observation.Classification.Type) || !Enum.IsDefined(observation.Classification.OperatingSystem)
            || string.IsNullOrWhiteSpace(observation.Classification.TypeEvidence)
            || string.IsNullOrWhiteSpace(observation.Classification.OperatingSystemEvidence)
            || observation.NetworkId is not null && string.IsNullOrWhiteSpace(observation.NetworkId)
            || observation.Ports.Any(port => port is null || port.Port is < 1 or > 65535 || !Enum.IsDefined(port.Protocol))
            || (observation.UdpObservations?.Any(item => item is null || item.Port is not (53 or 123)
                || !Enum.IsDefined(item.State) || string.IsNullOrWhiteSpace(item.ServiceName)
                || string.IsNullOrWhiteSpace(item.Detail)) ?? false)
            || !ValidSubnet(observation.Subnet))
            throw new InvalidDataException("The device inventory contains invalid local observations.");
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
        SavedPeopleRooms? PeopleRooms, IReadOnlyList<PrivateVirtualDevice>? VirtualDevices = null);
    private sealed record SavedPeopleRooms(IReadOnlyList<ManagedPerson>? People, IReadOnlyList<ManagedRoom>? Rooms,
        IReadOnlyDictionary<string, DeviceAssignment>? Assignments);
}
