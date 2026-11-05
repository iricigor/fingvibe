using System.Text.Json;
using FingVibe.Core.Models;

namespace FingVibe.Core.Storage;

public sealed class NavigationPaneSettingsStore
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true
    };

    private readonly string _filePath;

    public NavigationPaneSettingsStore(string filePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        _filePath = filePath;
    }

    public NavigationPaneSettings Load()
    {
        try
        {
            var settings = JsonSerializer.Deserialize<StoredNavigationPaneSettings>(File.ReadAllText(_filePath), JsonOptions);
            return settings is null
                ? new NavigationPaneSettings()
                : new NavigationPaneSettings(
                    settings.ExpandedWidth is { } width && double.IsFinite(width)
                        ? Math.Clamp(width, NavigationPaneSettings.MinimumExpandedWidth,
                            NavigationPaneSettings.MaximumExpandedWidth)
                        : NavigationPaneSettings.DefaultExpandedWidth,
                    settings.IsCollapsed);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            return new NavigationPaneSettings();
        }
    }

    private sealed record StoredNavigationPaneSettings(double? ExpandedWidth = null, bool IsCollapsed = false);

    public void Save(NavigationPaneSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        if (!double.IsFinite(settings.ExpandedWidth) ||
            settings.ExpandedWidth < NavigationPaneSettings.MinimumExpandedWidth ||
            settings.ExpandedWidth > NavigationPaneSettings.MaximumExpandedWidth)
        {
            throw new ArgumentException("The navigation pane width is invalid.", nameof(settings));
        }

        var directory = Path.GetDirectoryName(_filePath)
            ?? throw new ArgumentException("The settings path must include a directory.", nameof(_filePath));
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
