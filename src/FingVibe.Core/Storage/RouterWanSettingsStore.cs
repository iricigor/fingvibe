using System.Net;
using System.Text.Json;

namespace FingVibe.Core.Storage;

public static class RouterWanAddress
{
    public static IPAddress? Parse(string value)
    {
        value = value.Trim();
        if (value.Length == 0) return null;
        var parts = value.Split('.');
        if (parts.Length != 4 || parts.Any(part => part.Length is < 1 or > 3
            || part.Any(character => character is < '0' or > '9')
            || part.Length > 1 && part[0] == '0'
            || !byte.TryParse(part, out _))
            || !IPAddress.TryParse(value, out var address))
            throw new ArgumentException("Enter an IPv4 address as four decimal octets (for example, 203.0.113.10), or leave it blank.");
        var bytes = address.GetAddressBytes();
        if (bytes[0] is 0 or 127 or >= 224 || address.Equals(IPAddress.Broadcast))
            throw new ArgumentException("Enter a unicast router WAN IPv4 address, not a loopback, multicast, or unspecified address.");
        return address;
    }
}

public sealed class RouterWanSettingsStore(string filePath)
{
    public string Load(Guid networkId)
    {
        if (networkId == Guid.Empty) throw new ArgumentException("A reliable Windows network identity is required.", nameof(networkId));
        var settings = Read();
        return settings.TryGetValue(networkId, out var value) ? value : string.Empty;
    }

    public void Save(Guid networkId, string value)
    {
        if (networkId == Guid.Empty) throw new ArgumentException("A reliable Windows network identity is required.", nameof(networkId));
        var address = RouterWanAddress.Parse(value);
        var settings = Read();
        if (address is null) settings.Remove(networkId);
        else settings[networkId] = address.ToString();
        var directory = Path.GetDirectoryName(filePath)
            ?? throw new ArgumentException("The settings path must include a directory.", nameof(filePath));
        Directory.CreateDirectory(directory);
        var temporaryPath = Path.Combine(directory, $".{Path.GetFileName(filePath)}.{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllText(temporaryPath, JsonSerializer.Serialize(settings, new JsonSerializerOptions { WriteIndented = true }));
            File.Move(temporaryPath, filePath, true);
        }
        finally
        {
            if (File.Exists(temporaryPath)) File.Delete(temporaryPath);
        }
    }

    private Dictionary<Guid, string> Read()
    {
        string json;
        try { json = File.ReadAllText(filePath); }
        catch (FileNotFoundException) { return []; }
        catch (DirectoryNotFoundException) { return []; }
        var settings = JsonSerializer.Deserialize<Dictionary<Guid, string>>(json)
            ?? throw new InvalidDataException("The WAN settings file is empty or invalid.");
        foreach (var (id, value) in settings)
        {
            if (id == Guid.Empty || value is null) throw new InvalidDataException("Invalid saved network identity or WAN address.");
            try
            {
                if (RouterWanAddress.Parse(value) is null) throw new InvalidDataException("A saved WAN address is blank.");
            }
            catch (ArgumentException exception)
            {
                throw new InvalidDataException("A saved WAN address is invalid.", exception);
            }
        }
        return settings;
    }
}
