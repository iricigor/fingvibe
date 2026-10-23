using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class DeviceClassificationOverrideStoreTests
{
    [Fact]
    public async Task SaveAndLoad_PreservesIndependentChoicesAndNormalizesMac()
    {
        var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        var path = Path.Combine(directory, "overrides.json");
        var store = new DeviceClassificationOverrideStore(path);
        var choices = new DeviceClassificationOverride(DeviceOperatingSystem.Android,
            DeviceType.Phone, DeviceType.GameConsole);
        try
        {
            Assert.Empty(await store.LoadAsync());
            await store.SaveAsync(new Dictionary<string, DeviceClassificationOverride>
            {
                ["aa:bb:cc:dd:ee:ff"] = choices,
                ["00-11-22-33-44-55"] = new(DeviceOperatingSystem.Unknown)
            });
            var loaded = await new DeviceClassificationOverrideStore(path).LoadAsync();
            Assert.Equal(choices, loaded["AABBCCDDEEFF"]);
            Assert.Equal(DeviceOperatingSystem.Unknown, loaded["001122334455"].OperatingSystem);
            Assert.Null(loaded["001122334455"].Icon);

            await store.SaveAsync(new Dictionary<string, DeviceClassificationOverride>());
            Assert.Empty(await store.LoadAsync());
            Assert.Single(Directory.GetFiles(directory));
        }
        finally
        {
            if (Directory.Exists(directory))
            {
                Directory.Delete(directory, recursive: true);
            }
        }
    }

    [Theory]
    [InlineData("{")]
    [InlineData("null")]
    [InlineData("""{"AABBCCDDEEFF":null}""")]
    [InlineData("""{"AABBCCDDEEFF":{}}""")]
    [InlineData("""{"not-a-mac":{"type":"Phone"}}""")]
    [InlineData("""{"AABBCCDDEEFF":{"type":999}}""")]
    [InlineData("""{"AABBCCDDEEFF":{"operatingSystem":"NotAnOs"}}""")]
    [InlineData("""{"aa:bb:cc:dd:ee:ff":{"type":"Phone"},"AABBCCDDEEFF":{"type":"Tablet"}}""")]
    public async Task Load_RejectsInvalidOverrides(string json)
    {
        var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "overrides.json");
        try
        {
            await File.WriteAllTextAsync(path, json);
            await Assert.ThrowsAsync<InvalidDataException>(() =>
                new DeviceClassificationOverrideStore(path).LoadAsync());
            Assert.Equal(json, await File.ReadAllTextAsync(path));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public async Task FailedSave_DoesNotReplaceSavedChoices()
    {
        var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        var store = new DeviceClassificationOverrideStore(Path.Combine(directory, "overrides.json"));
        try
        {
            var original = new DeviceClassificationOverride(Type: DeviceType.Printer);
            await store.SaveAsync(new Dictionary<string, DeviceClassificationOverride> { ["001122334455"] = original });
            await Assert.ThrowsAsync<ArgumentException>(() => store.SaveAsync(
                new Dictionary<string, DeviceClassificationOverride> { ["001122334455"] = new(Type: (DeviceType)999) }));
            Assert.Equal(original, Assert.Single(await store.LoadAsync()).Value);

            using var cancellation = new CancellationTokenSource();
            cancellation.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => store.SaveAsync(
                new Dictionary<string, DeviceClassificationOverride>(), cancellation.Token));
            Assert.Equal(original, Assert.Single(await store.LoadAsync()).Value);
            Assert.Single(Directory.GetFiles(directory));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }
}
