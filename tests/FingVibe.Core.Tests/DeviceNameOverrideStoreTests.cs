using FingVibe.Core.Storage;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class DeviceNameOverrideStoreTests
{
    [Fact]
    public async Task SaveAndLoadAsync_NormalizesMacAddressAndPreservesCustomName()
    {
        var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        var store = new DeviceNameOverrideStore(Path.Combine(directory, "device-names.json"));

        try
        {
            await store.SaveAsync(new Dictionary<string, string>
            {
                ["aa:bb:cc:dd:ee:ff"] = "  Living room TV  "
            });

            var names = await store.LoadAsync();

            Assert.Equal("Living room TV", Assert.Single(names).Value);
            Assert.Equal("Living room TV", names["AABBCCDDEEFF"]);
        }
        finally
        {
            if (Directory.Exists(directory))
            {
                Directory.Delete(directory, recursive: true);
            }
        }
    }

    [Fact]
    public async Task LoadAsync_ReturnsEmptyMapWhenFileDoesNotExist()
    {
        var store = new DeviceNameOverrideStore(
            Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"), "device-names.json"));

        Assert.Empty(await store.LoadAsync());
    }

    [Fact]
    public async Task SaveAsync_RejectsMacAddressThatCannotIdentifyADevice()
    {
        var store = new DeviceNameOverrideStore(
            Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"), "device-names.json"));

        await Assert.ThrowsAsync<FormatException>(() => store.SaveAsync(
            new Dictionary<string, string> { ["not-a-mac"] = "Device" }));
    }
}
