using System.Text.Json;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class NetworkMonitorSettingsStoreTests : IDisposable
{
    private readonly string _directory =
        Path.Combine(Path.GetTempPath(), $"FingVibe-network-monitor-{Guid.NewGuid():N}");

    private string FilePath => Path.Combine(_directory, "network-monitor.json");

    [Fact]
    public void MissingSettingsAreOffAndDoNotCreateAFile()
    {
        var store = new NetworkMonitorSettingsStore(FilePath);

        Assert.Null(store.Load());
        Assert.False(NetworkMonitorSettings.Default.IsEnabled);
        Assert.False(File.Exists(FilePath));
    }

    [Fact]
    public void RoundTripIsAtomicAndPreservesOnlyTheToggle()
    {
        var store = new NetworkMonitorSettingsStore(FilePath);

        store.Save(new(true));
        store.Save(new(false));

        Assert.Equal(new NetworkMonitorSettings(false), store.Load());
        Assert.Single(Directory.GetFiles(_directory));
    }

    [Theory]
    [InlineData("{} ", false)]
    [InlineData("{\"isEnabled\":true}", true)]
    [InlineData("{\"isEnabled\":false}", false)]
    public void SavedToggleLoads(string json, bool enabled)
    {
        Directory.CreateDirectory(_directory);
        File.WriteAllText(FilePath, json);

        Assert.Equal(enabled, new NetworkMonitorSettingsStore(FilePath).Load()!.IsEnabled);
    }

    [Theory]
    [InlineData("null")]
    [InlineData("not json")]
    [InlineData("{\"isEnabled\":\"yes\"}")]
    public void InvalidContentFailsWithoutOverwrite(string json)
    {
        Directory.CreateDirectory(_directory);
        File.WriteAllText(FilePath, json);

        Assert.Throws<JsonException>(() => new NetworkMonitorSettingsStore(FilePath).Load());
        Assert.Equal(json, File.ReadAllText(FilePath));
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory))
        {
            Directory.Delete(_directory, true);
        }
    }
}
