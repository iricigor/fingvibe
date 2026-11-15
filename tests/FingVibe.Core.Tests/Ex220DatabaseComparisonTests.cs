using Ex220Inspector;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class Ex220DatabaseComparisonTests
{
    private const string Mac = "AABBCCDDEEFF";
    private static readonly DateTimeOffset Now = new(2026, 11, 15, 10, 0, 0, TimeSpan.Zero);
    private static readonly DatabaseNetwork Network = new("network-a", "192.168.0.0/24");

    [Fact]
    public async Task CustomNamesAndLatestNetworkIpAreComparedWithoutChangingDatabase()
    {
        using var fixture = new Fixture();
        await fixture.SaveAsync();
        var before = await File.ReadAllBytesAsync(fixture.Path);
        var comparer = new FingVibeDatabaseComparison(fixture.Path);
        var networks = await comparer.NetworksAsync(CancellationToken.None);
        Assert.Equal(2, networks.Count);
        var matches = await comparer.CompareAsync([Client(" desk ", "192.168.0.3")], Network, CancellationToken.None);
        var match = Assert.Single(matches).Value;
        Assert.Equal("Same in DB", match.Status);
        Assert.Equal("Desk", match.Name);
        Assert.Equal("192.168.0.3", match.Ip);
        Assert.Equal(before, await File.ReadAllBytesAsync(fixture.Path));
    }

    [Fact]
    public async Task NameAndIpDifferencesAreIndependentAndMissingMacIsNotInDb()
    {
        using var fixture = new Fixture();
        await fixture.SaveAsync();
        var comparer = new FingVibeDatabaseComparison(fixture.Path);
        foreach (var (name, ip, details) in new[]
        {
            ("Other", "192.168.0.3", "Name differs"),
            ("Desk", "192.168.0.4", "IP differs"),
            ("Other", "192.168.0.4", "Name differs; IP differs")
        })
        {
            var match = Assert.Single(await comparer.CompareAsync([Client(name, ip)], Network, CancellationToken.None)).Value;
            Assert.Equal("Different in DB", match.Status);
            Assert.Equal(details, match.Details);
        }
        var absent = Client("New", "192.168.0.8") with { Mac = "00:11:22:33:44:55" };
        Assert.Equal("Not in DB", Assert.Single(await comparer.CompareAsync([absent], Network, CancellationToken.None)).Value.Status);
    }

    [Fact]
    public async Task WrongNetworkAndMissingRouterNameCannotBeCompared()
    {
        using var fixture = new Fixture();
        await fixture.SaveAsync();
        var comparer = new FingVibeDatabaseComparison(fixture.Path);
        var wrong = await comparer.CompareAsync([Client("Desk", "192.168.0.3")],
            new("unknown-network", Network.Subnet), CancellationToken.None);
        Assert.Equal("Cannot compare", Assert.Single(wrong).Value.Status);
        var unnamed = await comparer.CompareAsync([Client("", "192.168.0.3")], Network, CancellationToken.None);
        Assert.Equal("Cannot compare", Assert.Single(unnamed).Value.Status);
    }

    [Fact]
    public async Task MissingDatabaseIsAnErrorAndIsNotCreated()
    {
        using var fixture = new Fixture();
        await Assert.ThrowsAsync<FileNotFoundException>(() =>
            new FingVibeDatabaseComparison(fixture.Path).NetworksAsync(CancellationToken.None));
        Assert.False(File.Exists(fixture.Path));
    }

    [Fact]
    public async Task ActiveVirtualDeviceUsesItsDisplayedCustomName()
    {
        using var fixture = new Fixture();
        const string mac = "001122334455";
        var observation = new DeviceObservation(Network.NetworkId, Network.Subnet, "192.168.0.5", null,
            "Private", DeviceClassification.Unknown, [], null, TimeSpan.Zero, Now, Now, Now, true);
        var device = new InventoryDevice(mac, new(), [observation]);
        var slot = new PrivateVirtualDevice(Guid.NewGuid(), Network.NetworkId, Network.Subnet,
            "001122", 1, mac, Now, true, [new(mac, observation, false)], Name: "Kid tablet");
        var data = DeviceInventoryData.Empty with
        {
            Devices = new Dictionary<string, InventoryDevice> { [mac] = device },
            VirtualDevices = [slot]
        };
        await new DeviceInventoryStore(fixture.Path).SaveAsync(data, Guid.Empty);
        var client = Client("Kid tablet", "192.168.0.5") with { Mac = "00:11:22:33:44:55" };
        var match = Assert.Single(await new FingVibeDatabaseComparison(fixture.Path)
            .CompareAsync([client], Network, CancellationToken.None)).Value;
        Assert.Equal("Same in DB", match.Status);
        Assert.Equal("Kid tablet", match.Name);
    }

    private static ClientDisplay Client(string name, string ip) =>
        new(name, "AA:BB:CC:DD:EE:FF", ip, "Wired", "Client List", "");

    private sealed class Fixture : IDisposable
    {
        private readonly string _directory = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "Ex220DbTest-" + Guid.NewGuid().ToString("N"));
        public string Path => System.IO.Path.Combine(_directory, "inventory.sqlite");

        public async Task SaveAsync()
        {
            DeviceObservation Observation(string network, string ip, DateTimeOffset time) =>
                new(network, Network.Subnet, ip, "Discovered", "Example vendor", DeviceClassification.Unknown,
                    [], null, TimeSpan.Zero, time, time, time, true);
            var device = new InventoryDevice(Mac, new ImportedDeviceMetadata(Name: "Imported", Address: "192.168.0.99"),
                [Observation(Network.NetworkId, "192.168.0.2", Now),
                 Observation(Network.NetworkId, "192.168.0.3", Now.AddMinutes(1)),
                 Observation("network-b", "192.168.0.8", Now.AddMinutes(2))]);
            var data = DeviceInventoryData.Empty with
            {
                Devices = new Dictionary<string, InventoryDevice> { [Mac] = device },
                Names = new Dictionary<string, string> { [Mac] = "Desk" }
            };
            await new DeviceInventoryStore(Path).SaveAsync(data, Guid.Empty);
        }

        public void Dispose()
        {
            if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
        }
    }
}
