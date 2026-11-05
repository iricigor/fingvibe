using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class NavigationPaneSettingsStoreTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
    private string FilePath => Path.Combine(_directory, "navigation.json");

    [Fact]
    public void Load_MissingFile_ReturnsDefaultsWithoutSaving()
    {
        Assert.Equal(new NavigationPaneSettings(216, false), new NavigationPaneSettingsStore(FilePath).Load());
        Assert.False(File.Exists(FilePath));
    }

    [Theory]
    [InlineData(160, false)]
    [InlineData(216, true)]
    [InlineData(287.5, false)]
    [InlineData(320, true)]
    public void SaveAndLoad_PreservesWidthAndCollapsedState(double width, bool isCollapsed)
    {
        var settings = new NavigationPaneSettings(width, isCollapsed);
        new NavigationPaneSettingsStore(FilePath).Save(settings);

        Assert.Equal(settings, new NavigationPaneSettingsStore(FilePath).Load());
        Assert.Single(Directory.GetFiles(_directory));
    }

    [Theory]
    [InlineData("{\"expandedWidth\":100,\"isCollapsed\":true}", 160, true)]
    [InlineData("{\"expandedWidth\":500}", 320, false)]
    [InlineData("{\"isCollapsed\":true}", 216, true)]
    [InlineData("{\"expandedWidth\":null,\"isCollapsed\":false}", 216, false)]
    [InlineData("{}", 216, false)]
    public void Load_MissingOrOutOfRangeWidth_ClampsOrUsesDefault(string json, double width, bool isCollapsed)
    {
        Directory.CreateDirectory(_directory);
        File.WriteAllText(FilePath, json);

        Assert.Equal(new NavigationPaneSettings(width, isCollapsed), new NavigationPaneSettingsStore(FilePath).Load());
        Assert.Equal(json, File.ReadAllText(FilePath));
    }

    [Theory]
    [InlineData("{")]
    [InlineData("null")]
    [InlineData("{\"expandedWidth\":\"NaN\"}")]
    [InlineData("{\"expandedWidth\":\"wide\",\"isCollapsed\":true}")]
    [InlineData("{\"expandedWidth\":240,\"isCollapsed\":\"yes\"}")]
    public void Load_InvalidDocument_ReturnsDefaults(string json)
    {
        Directory.CreateDirectory(_directory);
        File.WriteAllText(FilePath, json);

        Assert.Equal(new NavigationPaneSettings(), new NavigationPaneSettingsStore(FilePath).Load());
        Assert.Equal(json, File.ReadAllText(FilePath));
    }

    [Theory]
    [InlineData(159.999)]
    [InlineData(320.001)]
    [InlineData(double.NaN)]
    [InlineData(double.PositiveInfinity)]
    public void Save_InvalidWidth_DoesNotOverwritePreviousSettings(double width)
    {
        var store = new NavigationPaneSettingsStore(FilePath);
        var settings = new NavigationPaneSettings(280, true);
        store.Save(settings);

        Assert.Throws<ArgumentException>(() => store.Save(new NavigationPaneSettings(width, false)));
        Assert.Equal(settings, store.Load());
        Assert.Single(Directory.GetFiles(_directory));
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory))
        {
            Directory.Delete(_directory, recursive: true);
        }
    }
}
