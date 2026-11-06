using System.Net;
using System.Net.NetworkInformation;
using System.Text.Json.Nodes;
using FingVibe.Core.Import;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class DeviceDiscoveryTests : IDisposable
{
    private const string Network = "network-a";
    private const string Subnet = "192.0.2.0/24";
    private const string Known = "001122334455";
    private const string New = "001122334466";
    private const string Private = "D0C907000001";
    private const string Rotated = "D0C907000002";
    private static readonly DateTimeOffset Start = new(2026, 11, 1, 12, 0, 0, TimeSpan.Zero);
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"fingvibe-discovery-{Guid.NewGuid():N}");
    private string PathName => Path.Combine(_directory, "inventory.json");

    private static ScanResult Result(string mac, string address = "192.0.2.1") =>
        new(IPAddress.Parse(address), HostStatus.Alive, 1, TimeSpan.FromMilliseconds(1),
            null, PhysicalAddress.Parse(mac), mac.StartsWith("D0C907") ? "Private" : "Example");
    private static ScanSnapshot Scan(int minute, params ScanResult[] results) => new(Subnet, Start.AddMinutes(minute), results);
    private static DeviceInventoryData Baseline() =>
        DeviceInventoryData.Empty.ObserveCompletedScan(Network, Scan(0, Result(Known)));
    private static IReadOnlyList<DeviceDiscovery> Discover(
        DeviceInventoryData before, ScanSnapshot scan, string? network = Network) =>
        DeviceDiscovery.FindNewDevices(before, before.ObserveCompletedScan(network, scan), network, scan);

    [Fact]
    public void FirstScanIsQuietAndLaterScanHasExactlyOneEntryPerNewLogicalDevice()
    {
        Assert.Empty(Discover(DeviceInventoryData.Empty, Scan(0, Result(Known), Result(Private))));
        var before = Baseline();
        var scan = Scan(1, Result(Known), Result(New), Result(New, "192.0.2.2"),
            Result(Private, "192.0.2.3"), Result(Private, "192.0.2.4"));
        var after = before.ObserveCompletedScan(Network, scan);
        var discoveries = DeviceDiscovery.FindNewDevices(before, after, Network, scan);
        Assert.Equal([New, Private], discoveries.Select(item => item.Mac));
        Assert.Null(discoveries[0].VirtualDeviceId);
        Assert.Equal(Assert.Single(after.VirtualDevices).Id, discoveries[1].VirtualDeviceId);
    }

    [Fact]
    public void RepeatReturnAndNewMacInExistingVirtualIdentityDoNotAlert()
    {
        var before = Baseline().ObserveCompletedScan(Network, Scan(1, Result(Private)));
        Assert.Empty(Discover(before, Scan(2, Result(Known), Result(Private))));
        before = before.ObserveCompletedScan(Network, Scan(2));
        Assert.Empty(Discover(before, Scan(3, Result(Known), Result(Rotated))));
        var addedSlot = Discover(before, Scan(4, Result(Private), Result(Rotated)));
        Assert.Equal(Rotated, Assert.Single(addedSlot).Mac);
    }

    [Fact]
    public void ImportedOnlyQualifiesButImportAndUnreachableOrUnkeyedResultsAreNotDiscoveries()
    {
        var before = Baseline() with
        {
            Devices = Baseline().Devices.Append(new KeyValuePair<string, InventoryDevice>(
                New, new(New, new(Name: "Imported", Address: "192.0.2.9"), []))).ToDictionary()
        };
        Assert.Empty(Discover(before, Scan(1)));
        Assert.Empty(Discover(before, Scan(1, Result(New) with { Status = HostStatus.Unreachable },
            Result(New) with { MacAddress = null })));
        Assert.Equal(New, Assert.Single(Discover(before, Scan(1, Result(New)))).Mac);
    }

    [Fact]
    public void NetworkAndSubnetBaselinesAndNewnessAreIndependent()
    {
        var before = Baseline();
        Assert.Empty(Discover(before, Scan(1, Result(Known), Result(New)), "network-b"));
        before = before.ObserveCompletedScan("network-b", Scan(1, Result(New)));
        Assert.Equal(Known, Assert.Single(Discover(before, Scan(2, Result(Known)), "network-b")).Mac);
        Assert.Equal(New, Assert.Single(Discover(before, Scan(3, Result(New)))).Mac);
        var otherSubnet = Scan(4, Result(New)) with { Subnet = "198.51.100.0/24" };
        Assert.Empty(Discover(before, otherSubnet));
        Assert.Empty(Discover(before, Scan(5, Result(New)), null));
    }

    [Fact]
    public void UnknownNetworkAndHistoricalRestorationCannotEstablishBaseline()
    {
        var unknown = DeviceInventoryData.Empty.ObserveCompletedScan(null, Scan(0, Result(Known)));
        Assert.Empty(unknown.DiscoveryBaselines);
        Assert.Empty(Discover(unknown, Scan(1, Result(New))));
        var restored = DeviceInventoryData.Empty.ObserveCompletedScan(null, Scan(0, Result(Known)), historical: true);
        Assert.Empty(restored.DiscoveryBaselines);
        Assert.Empty(Discover(restored, Scan(1, Result(New))));
        var before = Baseline();
        var historical = before.ObserveCompletedScan(null, Scan(1, Result(New)), historical: true);
        Assert.Equal(New, Assert.Single(Discover(historical, Scan(2, Result(New)))).Mac);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    public async Task LegacyInventoryBaselineSurvivesActivationAndUpgrade(int version)
    {
        var store = new DeviceInventoryStore(PathName);
        await store.SaveAsync(Baseline().ObserveCompletedScan(Network, Scan(1, Result(Private))), Guid.Empty);
        var json = JsonNode.Parse(await File.ReadAllTextAsync(PathName))!;
        json["version"] = version;
        json["data"]!.AsObject().Remove("discoveryBaselines");
        foreach (var device in json["data"]!["devices"]!.AsObject())
            device.Value!.AsObject().Remove("scanHistory");
        if (version == 1) json["data"]!.AsObject().Remove("virtualDevices");
        await File.WriteAllTextAsync(PathName, json.ToJsonString());
        var loaded = (await store.LoadAsync())!;
        Assert.Empty(loaded.DiscoveryBaselines);
        Assert.Empty(Discover(loaded, Scan(2, Result(Known), Result(Private))));
        Assert.Equal(New, Assert.Single(Discover(loaded, Scan(2, Result(New)))).Mac);
    }

    [Fact]
    public async Task EmptyBaselineAndDuplicateSuppressionSurviveRestart()
    {
        var store = new DeviceInventoryStore(PathName);
        var emptyScan = Scan(0);
        var baseline = DeviceInventoryData.Empty.ObserveCompletedScan(Network, emptyScan);
        await store.SaveAsync(baseline, Guid.Empty);
        var loaded = (await store.LoadAsync())!;
        Assert.Single(loaded.DiscoveryBaselines);
        var scan = Scan(1, Result(New), Result(Private));
        Assert.Equal(2, Discover(loaded, scan).Count);
        var observed = loaded.ObserveCompletedScan(Network, scan);
        await store.SaveAsync(observed, loaded.Revision);
        loaded = (await store.LoadAsync())!;
        Assert.Empty(Discover(loaded, Scan(2, Result(New), Result(Rotated))));
        Assert.Single(loaded.DiscoveryBaselines);
    }

    [Fact]
    public async Task FailedPersistenceRetainsDurableComparisonUntilSuccessfulRetry()
    {
        var store = new DeviceInventoryStore(PathName);
        var persisted = await store.SaveAsync(Baseline(), Guid.Empty);
        var firstScan = Scan(1, Result(New), Result(Private));
        var unsaved = persisted.ObserveCompletedScan(Network, firstScan);
        using (var locked = new FileStream(PathName + ".lock", FileMode.Open, FileAccess.ReadWrite, FileShare.None))
            await Assert.ThrowsAsync<IOException>(() => store.SaveAsync(unsaved, persisted.Revision));
        Assert.Equal(persisted.Revision, (await store.LoadAsync())!.Revision);
        var retryScan = Scan(2, Result(New), Result(Rotated));
        var retry = unsaved.ObserveCompletedScan(Network, retryScan);
        var discoveries = DeviceDiscovery.FindNewDevices(persisted, retry, Network, retryScan);
        Assert.Equal([New, Rotated], discoveries.Select(item => item.Mac));
        await store.SaveAsync(retry, persisted.Revision);
        Assert.Empty(Discover((await store.LoadAsync())!, Scan(3, Result(New), Result(Rotated))));
    }

    [Fact]
    public async Task FailedInitialSaveDoesNotEstablishBaselineAndImportPreservesEmptyBaseline()
    {
        var store = new DeviceInventoryStore(PathName);
        Directory.CreateDirectory(_directory);
        var unsaved = DeviceInventoryData.Empty.ObserveCompletedScan(Network, Scan(0, Result(Known)));
        using (var locked = new FileStream(PathName + ".lock", FileMode.Create, FileAccess.ReadWrite, FileShare.None))
            await Assert.ThrowsAsync<IOException>(() => store.SaveAsync(unsaved, Guid.Empty));
        Assert.Null(await store.LoadAsync());
        var retryScan = Scan(1, Result(New));
        Assert.Empty(DeviceDiscovery.FindNewDevices(DeviceInventoryData.Empty,
            unsaved.ObserveCompletedScan(Network, retryScan), Network, retryScan));

        var baseline = DeviceInventoryData.Empty.ObserveCompletedScan(Network, Scan(2));
        var imported = FingImportAnalyzer.Analyze(
            new FingExport([new FingDeviceRecord(2, New, new(Name: "Imported"), null, null)], [], 1), baseline).Updated;
        var saved = await store.SaveAsync(imported, Guid.Empty);
        Assert.Single(saved.DiscoveryBaselines);
        Assert.Equal(New, Assert.Single(Discover((await store.LoadAsync())!, Scan(3, Result(New)))).Mac);
    }

    [Theory]
    [InlineData("missing")]
    [InlineData("null-entry")]
    [InlineData("network")]
    [InlineData("subnet")]
    [InlineData("duplicate")]
    public async Task InvalidBaselineFailsClosed(string corruption)
    {
        var store = new DeviceInventoryStore(PathName);
        var saved = await store.SaveAsync(Baseline(), Guid.Empty);
        var json = JsonNode.Parse(await File.ReadAllTextAsync(PathName))!;
        var baselines = json["data"]!["discoveryBaselines"]!.AsArray();
        switch (corruption)
        {
            case "missing": json["data"]!.AsObject().Remove("discoveryBaselines"); break;
            case "null-entry": baselines[0] = null; break;
            case "network": baselines[0]!["networkId"] = " "; break;
            case "subnet": baselines[0]!["subnet"] = "bad"; break;
            case "duplicate": baselines.Add(baselines[0]!.DeepClone()); break;
        }
        var corrupt = json.ToJsonString();
        await File.WriteAllTextAsync(PathName, corrupt);
        await Assert.ThrowsAsync<InvalidDataException>(() => store.LoadAsync());
        await Assert.ThrowsAsync<InvalidDataException>(() => store.SaveAsync(saved, saved.Revision));
        Assert.Equal(corrupt, await File.ReadAllTextAsync(PathName));
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }
}
