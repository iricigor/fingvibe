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

    [Theory]
    [InlineData(ThemeVariant.StandardLight)]
    [InlineData(ThemeVariant.StandardDark)]
    public void Load_MissingFile_UsesSystemThemeWithoutSaving(ThemeVariant systemTheme)
    {
        Assert.Equal(new AppearanceSettings(Theme: systemTheme),
            new AppearanceSettingsStore(FilePath).Load(systemTheme));
        Assert.False(File.Exists(FilePath));
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
                Assert.Equal(settings, new AppearanceSettingsStore(FilePath).Load(ThemeVariant.StandardLight));
                Assert.Equal(settings, new AppearanceSettingsStore(FilePath).Load(ThemeVariant.StandardDark));
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
        Assert.Equal(new AppearanceSettings(Theme: ThemeVariant.StandardDark),
            new AppearanceSettingsStore(FilePath).Load(ThemeVariant.StandardDark));
        Assert.Equal(json, File.ReadAllText(FilePath));
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("{\"backdrop\":\"Mica\"}")]
    [InlineData("{\"backdrop\":\"Mica\",\"theme\":null}")]
    [InlineData("{\"backdrop\":\"Mica\",\"theme\":99}")]
    public void Load_MissingOrInvalidTheme_UsesSystemThemeAndPreservesBackdrop(string json)
    {
        Directory.CreateDirectory(_directory);
        File.WriteAllText(FilePath, json);
        var backdrop = json == "{}" ? WindowBackdrop.Solid : WindowBackdrop.Mica;

        foreach (var systemTheme in new[] { ThemeVariant.StandardLight, ThemeVariant.StandardDark })
        {
            Assert.Equal(new AppearanceSettings(backdrop, systemTheme),
                new AppearanceSettingsStore(FilePath).Load(systemTheme));
        }

        Assert.Equal(json, File.ReadAllText(FilePath));
    }

    [Fact]
    public void Load_InvalidDefaultTheme_Throws()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() =>
            new AppearanceSettingsStore(FilePath).Load((ThemeVariant)99));
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
