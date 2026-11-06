using System.Text.Json;
using FingVibe.Core.Models;

namespace FingVibe.Core.Storage;

public sealed class PeriodicScanSettingsStore
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web) { WriteIndented = true };

    private readonly string _filePath;

    public PeriodicScanSettingsStore(string filePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        _filePath = filePath;
    }

    // Returns null when nothing was saved; unreadable content throws so callers can avoid overwriting it.
    public PeriodicScanSettings? Load()
    {
        string json;
        try
        {
            json = File.ReadAllText(_filePath);
        }
        catch (Exception exception) when (exception is FileNotFoundException or DirectoryNotFoundException)
        {
            return null;
        }

        var settings = JsonSerializer.Deserialize<PeriodicScanSettings>(json, JsonOptions)
            ?? throw new JsonException("Scheduled-scan settings are empty.");
        return settings.Normalize();
    }

    public void Save(PeriodicScanSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        if (!PeriodicScanSettings.IsSupportedInterval(settings.IntervalMinutes))
        {
            throw new ArgumentException("The scheduled-scan interval is not supported.", nameof(settings));
        }

        var directory = Path.GetDirectoryName(_filePath)
            ?? throw new ArgumentException("The settings path must include a directory.", nameof(settings));
        Directory.CreateDirectory(directory);
        var temporaryPath = Path.Combine(directory, $".{Path.GetFileName(_filePath)}.{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllText(temporaryPath, JsonSerializer.Serialize(settings, JsonOptions));
            File.Move(temporaryPath, _filePath, true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }
}
