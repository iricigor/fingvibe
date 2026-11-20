using System.Text.Json;
using FingVibe.Core.Models;

namespace FingVibe.Core.Storage;

public sealed class NetworkMonitorSettingsStore(string filePath)
{
    private static readonly JsonSerializerOptions JsonOptions =
        new(JsonSerializerDefaults.Web) { WriteIndented = true };

    private readonly string _filePath = !string.IsNullOrWhiteSpace(filePath)
        ? filePath
        : throw new ArgumentException("A settings path is required.", nameof(filePath));

    // Returns null when nothing was saved; unreadable content throws so callers can avoid overwriting it.
    public NetworkMonitorSettings? Load()
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

        return JsonSerializer.Deserialize<NetworkMonitorSettings>(json, JsonOptions)
            ?? throw new JsonException("Network-monitor settings are empty.");
    }

    public void Save(NetworkMonitorSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
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
