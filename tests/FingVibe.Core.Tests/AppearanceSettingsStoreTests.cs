using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class AppearanceSettingsStoreTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
    private string FilePath => Path.Combine(_directory, "appearance.json");

    [Fact]
    public void Load_MissingFile_ReturnsDefaults()
    {
        Assert.Equal(new AppearanceSettings(), new AppearanceSettingsStore(FilePath).Load());
    }

    [Fact]
    public void SaveAndLoad_PreservesEveryBackdropAndTheme()
    {
        foreach (var backdrop in Enum.GetValues<WindowBackdrop>())
        {
            foreach (var theme in Enum.GetValues<ThemeVariant>())
            {
                var settings = new AppearanceSettings(backdrop, theme);
                new AppearanceSettingsStore(FilePath).Save(settings);

                Assert.Equal(settings, new AppearanceSettingsStore(FilePath).Load());
                Assert.Single(Directory.GetFiles(_directory));
            }
        }
    }

    [Theory]
    [InlineData("{")]
    [InlineData("null")]
    [InlineData("{\"backdrop\":\"FutureMaterial\",\"theme\":\"FutureTheme\"}")]
    public void Load_InvalidDocument_ReturnsDefaults(string json)
    {
        Directory.CreateDirectory(_directory);
        File.WriteAllText(FilePath, json);

        Assert.Equal(new AppearanceSettings(), new AppearanceSettingsStore(FilePath).Load());
    }

    [Fact]
    public void Load_UnknownNumericValue_DefaultsOnlyInvalidPreference()
    {
        Directory.CreateDirectory(_directory);
        File.WriteAllText(FilePath, "{\"backdrop\":99,\"theme\":\"OledDark\"}");

        Assert.Equal(new AppearanceSettings(WindowBackdrop.Solid, ThemeVariant.OledDark),
            new AppearanceSettingsStore(FilePath).Load());
    }

    [Fact]
    public void Save_InvalidPreference_DoesNotOverwritePreviousSettings()
    {
        var store = new AppearanceSettingsStore(FilePath);
        var settings = new AppearanceSettings(WindowBackdrop.Acrylic, ThemeVariant.WarmLight);
        store.Save(settings);

        Assert.Throws<ArgumentException>(() => store.Save(settings with { Theme = (ThemeVariant)99 }));
        Assert.Equal(settings, store.Load());
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory))
        {
            Directory.Delete(_directory, recursive: true);
        }
    }
}
