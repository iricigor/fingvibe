using System.Text.Json;
using FingVibe.App;
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
            false, false, false, true, false, true, true);
        store.Save(settings);
        store.Save(settings);
        var loaded = Assert.IsType<DeviceTableSettings>(store.Load());
        Assert.Equal(settings.Columns, loaded.Columns);
        Assert.False(loaded.CombineNameType);
        Assert.False(loaded.CombineAddresses);
        Assert.False(loaded.CombineStatusResponse);
        Assert.True(loaded.CombinePersonRoom);
        Assert.False(loaded.EnlargedCellPreviews);
        Assert.True(loaded.CombineVendorOs);
        Assert.True(loaded.CompactRows);
        Assert.Single(Directory.GetFiles(_directory));
    }

    [Theory]
    [InlineData("{\"columns\":{}}")]
    [InlineData("{\"columns\":{},\"combinePersonRoom\":true}")]
    public void ExistingSettings_DefaultToEnabledPreviews(string json)
    {
        Directory.CreateDirectory(_directory);
        File.WriteAllText(FilePath, json);
        var loaded = new DeviceTableSettingsStore(FilePath).Load()!;
        Assert.True(loaded.EnlargedCellPreviews);
        Assert.False(loaded.CombineVendorOs);
        Assert.True(loaded.CompactRows);
    }

    [Fact]
    public void LegacyDensity_RoundTripPersistsMigrationAndSubsequentStandardChoice()
    {
        Directory.CreateDirectory(_directory);
        File.WriteAllText(FilePath, """{"columns":{},"compactRows":false,"combineVendorOs":true}""");
        var store = new DeviceTableSettingsStore(FilePath);
        var legacy = store.Load()!;
        Assert.Equal(0, legacy.DensityVersion);
        var layout = new DeviceColumnLayout();
        layout.Restore(legacy);
        Assert.True(layout.CompactRows);
        store.Save(layout.Capture());
        Assert.Equal(1, store.Load()!.DensityVersion);
        layout.CompactRows = false;
        store.Save(layout.Capture());
        var restored = new DeviceColumnLayout();
        restored.Restore(store.Load()!);
        Assert.False(restored.CompactRows);
        Assert.True(restored.CombineVendorOs);
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
