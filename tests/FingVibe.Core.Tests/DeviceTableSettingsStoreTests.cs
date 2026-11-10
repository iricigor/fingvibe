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
        Assert.Null(loaded.StatusFilters);
        Assert.False(loaded.StatusAnyKnown);
        Assert.Single(Directory.GetFiles(_directory));
    }

    [Theory]
    [InlineData(new[] { InventoryDeviceStatus.Online })]
    [InlineData(new[] { InventoryDeviceStatus.Online, InventoryDeviceStatus.Offline })]
    [InlineData(new[] { InventoryDeviceStatus.Unknown, InventoryDeviceStatus.FingOnly })]
    [InlineData(new InventoryDeviceStatus[0])]
    public void StatusSelectionsSurviveReplacementAndFreshStoreInstances(InventoryDeviceStatus[] statuses)
    {
        var store = new DeviceTableSettingsStore(FilePath);
        store.Save(new(new() { ["Name"] = new(230, true) }) { StatusFilters = [InventoryDeviceStatus.Online] });
        store.Save(new(new() { ["Name"] = new(230, true) }) { StatusFilters = statuses });
        var restored = new DeviceTableSettingsStore(FilePath).Load()!;
        Assert.Equal(statuses, restored.StatusFilters);
        Assert.Equal(230, restored.Columns["Name"].Width);
        Assert.Single(Directory.GetFiles(_directory));
    }

    [Theory]
    [InlineData("{\"columns\":{},\"statusFilters\":[99]}")]
    [InlineData("{\"columns\":{},\"statusFilters\":[0,0]}")]
    [InlineData("{\"columns\":{},\"statusFilters\":\"Online\"}")]
    [InlineData("{\"columns\":{},\"statusFilters\":[1],\"statusAnyKnown\":true}")]
    public void InvalidStatusSelectionsAreReportedAndTheOriginalFileIsPreserved(string json)
    {
        Directory.CreateDirectory(_directory);
        File.WriteAllText(FilePath, json);
        Assert.Throws<JsonException>(() => new DeviceTableSettingsStore(FilePath).Load());
        Assert.Equal(json, File.ReadAllText(FilePath));
    }

    [Fact]
    public void InvalidStatusSelectionsCannotReplaceSavedPreferences()
    {
        var store = new DeviceTableSettingsStore(FilePath);
        var valid = new DeviceTableSettings(new()) { StatusFilters = [InventoryDeviceStatus.Online] };
        store.Save(valid);
        Assert.Throws<ArgumentException>(() => store.Save(valid with { StatusFilters = [(InventoryDeviceStatus)99] }));
        Assert.Throws<ArgumentException>(() => store.Save(valid with { StatusAnyKnown = true }));
        Assert.Equal(valid.StatusFilters, store.Load()!.StatusFilters);
    }

    [Fact]
    public void AnyStatusSurvivesRestartAsAModeAndCanBeReplacedByUnrestrictedOrSpecificValues()
    {
        var store = new DeviceTableSettingsStore(FilePath);
        var settings = new DeviceTableSettings(new()) { StatusAnyKnown = true, StatusFilters = [] };
        store.Save(settings);
        var restored = new DeviceTableSettingsStore(FilePath).Load()!;
        Assert.True(restored.StatusAnyKnown);
        Assert.Empty(restored.StatusFilters!);

        var selection = new DeviceFilterSelection<InventoryDeviceStatus>(InventoryDeviceStatus.Unknown);
        selection.SetChoices(Enum.GetValues<InventoryDeviceStatus>().Select(value => (value, value.ToString())));
        selection.SetAnyKnown(restored.StatusAnyKnown);
        Assert.True(selection.AnyKnown);
        Assert.Empty(selection.Selected);
        store.Save(settings with { StatusAnyKnown = false });
        Assert.False(store.Load()!.StatusAnyKnown);
        store.Save(settings with { StatusAnyKnown = false, StatusFilters = [InventoryDeviceStatus.Online] });
        Assert.Equal([InventoryDeviceStatus.Online], store.Load()!.StatusFilters);
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
        Assert.False(loaded.StatusAnyKnown);
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
