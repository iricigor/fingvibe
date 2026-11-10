using System.Text.Json;
using FingVibe.Core.Models;

namespace FingVibe.Core.Storage;

public sealed class DeviceTableSettingsStore(string filePath)
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web) { WriteIndented = true };

    public DeviceTableSettings? Load()
    {
        string json;
        try
        {
            json = File.ReadAllText(filePath);
        }
        catch (Exception exception) when (exception is FileNotFoundException or DirectoryNotFoundException)
        {
            return null;
        }
        var settings = JsonSerializer.Deserialize<DeviceTableSettings>(json, JsonOptions)
            ?? throw new JsonException("Device table settings are empty.");
        if (settings.Columns is null || settings.Columns.Any(entry =>
                entry.Value is null || !double.IsFinite(entry.Value.Width) || entry.Value.Width < 56
                || entry.Value.Width > 4096))
        {
            throw new JsonException("Device table column widths are invalid.");
        }
        if (!ValidStatuses(settings.StatusFilters, settings.StatusAnyKnown))
            throw new JsonException("Device table Status filter selections are invalid.");
        return settings;
    }

    public void Save(DeviceTableSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        if (settings.Columns is null || settings.Columns.Any(entry =>
                entry.Value is null || !double.IsFinite(entry.Value.Width) || entry.Value.Width < 56
                || entry.Value.Width > 4096))
            throw new ArgumentException("Device table column widths are invalid.", nameof(settings));
        if (!ValidStatuses(settings.StatusFilters, settings.StatusAnyKnown))
            throw new ArgumentException("Device table Status filter selections are invalid.", nameof(settings));
        var directory = Path.GetDirectoryName(filePath)
            ?? throw new ArgumentException("The settings path must include a directory.", nameof(filePath));
        Directory.CreateDirectory(directory);
        var temporaryPath = Path.Combine(directory, $".{Path.GetFileName(filePath)}.{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllText(temporaryPath, JsonSerializer.Serialize(settings, JsonOptions));
            File.Move(temporaryPath, filePath, true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }

        }
    }

    private static bool ValidStatuses(InventoryDeviceStatus[]? statuses, bool anyKnown) =>
        (!anyKnown || statuses is null or { Length: 0 })
        && (statuses is null || statuses.All(status => Enum.IsDefined(status))
            && statuses.Distinct().Count() == statuses.Length);
}
