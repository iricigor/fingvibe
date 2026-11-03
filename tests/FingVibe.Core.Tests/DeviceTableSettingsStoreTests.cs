using System.Text.Json;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class DeviceTableSettingsStoreTests : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"FingVibe-table-{Guid.NewGuid():N}");
    private string FilePath => Path.Combine(_directory, "device-table.json");

    [Fact]
    public void MissingFile_UsesDefaults()
    {
        Assert.Null(new DeviceTableSettingsStore(FilePath).Load());
    }

    [Fact]
    public void RoundTrip_PreservesAllPreferencesAndReplacesAtomically()
    {
        var store = new DeviceTableSettingsStore(FilePath);
        var settings = new DeviceTableSettings(new() { ["Name"] = new(230, true), ["Mac"] = new(160, false) },
            false, false, false, true);
        store.Save(settings);
        store.Save(settings);
        var loaded = Assert.IsType<DeviceTableSettings>(store.Load());
        Assert.Equal(settings.Columns, loaded.Columns);
        Assert.False(loaded.CombineNameType);
        Assert.False(loaded.CombineAddresses);
        Assert.False(loaded.CombineStatusResponse);
        Assert.True(loaded.CombinePersonRoom);
        Assert.Single(Directory.GetFiles(_directory));
    }

    [Theory]
    [InlineData("null")]
    [InlineData("{}")]
    [InlineData("{\"columns\":{\"Name\":{\"width\":-20,\"isVisible\":true}}}")]
    [InlineData("{\"columns\":{\"Name\":null}}")]
    [InlineData("{\"columns\":{\"Name\":{\"width\":10000}}}")]
    public void InvalidSettings_ReportFailureWithoutOverwriting(string json)
    {
        Directory.CreateDirectory(_directory);
        File.WriteAllText(FilePath, json);
        Assert.Throws<JsonException>(() => new DeviceTableSettingsStore(FilePath).Load());
        Assert.Equal(json, File.ReadAllText(FilePath));
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, true);
    }
}
