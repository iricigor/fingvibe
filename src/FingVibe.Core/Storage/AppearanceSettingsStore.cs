using System.Text.Json;
using System.Text.Json.Serialization;
using FingVibe.Core.Models;

namespace FingVibe.Core.Storage;

public sealed class AppearanceSettingsStore
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() }
    };

    private readonly string _filePath;

    public AppearanceSettingsStore(string filePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        _filePath = filePath;
    }

    public AppearanceSettings Load(ThemeVariant defaultTheme = ThemeVariant.StandardLight)
    {
        if (!Enum.IsDefined(defaultTheme))
        {
            throw new ArgumentOutOfRangeException(nameof(defaultTheme));
        }

        try
        {
            var settings = JsonSerializer.Deserialize<StoredAppearanceSettings>(File.ReadAllText(_filePath), JsonOptions);
            return settings is null
                ? new AppearanceSettings(Theme: defaultTheme)
                : new AppearanceSettings(
                    Enum.IsDefined(settings.Backdrop) ? settings.Backdrop : WindowBackdrop.Solid,
                    settings.Theme is { } theme && Enum.IsDefined(theme) ? theme : defaultTheme);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            return new AppearanceSettings(Theme: defaultTheme);
        }
    }

    private sealed record StoredAppearanceSettings(
        WindowBackdrop Backdrop = WindowBackdrop.Solid,
        ThemeVariant? Theme = null);

    public void Save(AppearanceSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        if (!Enum.IsDefined(settings.Backdrop) || !Enum.IsDefined(settings.Theme))
        {
            throw new ArgumentException("The appearance settings are invalid.", nameof(settings));
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
