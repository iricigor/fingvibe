using System.Net;
using System.Net.NetworkInformation;
using System.Text.Json.Nodes;
using FingVibe.App;
using FingVibe.Core.Import;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class DeviceScanHistoryTests : IDisposable
{
    private const string Normal = "001122334455";
    private const string Private = "D0C907000001";
    private const string Rotated = "D0C907000002";
    private const string Network = "synthetic-network";
    private const string Subnet = "192.0.2.0/24";
    private static readonly DateTimeOffset Start = new(2026, 11, 1, 12, 0, 0, TimeSpan.Zero);
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"fingvibe-history-{Guid.NewGuid():N}");
    private string PathName => Path.Combine(_directory, "inventory.json");

    private static ScanResult Result(string mac, string address = "192.0.2.1") =>
        new(IPAddress.Parse(address), HostStatus.Alive, 1, TimeSpan.FromMilliseconds(1),
            null, PhysicalAddress.Parse(mac), mac.StartsWith("D0C907") ? "Private" : "Example");

    private static DeviceInventoryData Scan(DeviceInventoryData data, int minute, params ScanResult[] results) =>
        data.ObserveCompletedScan(Network, new(Subnet, Start.AddMinutes(minute), results));

    [Fact]
    public void RepeatedPresenceAbsenceAndReturnKeepEveryScanForBothIdentities()
    {
        var data = Scan(DeviceInventoryData.Empty, 0, Result(Normal), Result(Private, "192.0.2.2"));
        var id = Assert.Single(data.VirtualDevices).Id;
        data = Scan(data, 1, Result(Normal), Result(Private, "192.0.2.2"));
        data = Scan(data, 2);
        data = Scan(data, 3, Result(Normal), Result(Rotated, "192.0.2.3"));
        Assert.Equal(id, Assert.Single(data.VirtualDevices).Id);
        Assert.Equal(Rotated, data.VirtualDevices[0].LastActiveMac);
        foreach (var history in new[] { data.Devices[Normal].ScanHistory, data.VirtualDevices[0].ScanHistory })
        {
            Assert.Equal([true, true, false, true], history.Select(item => item.Present));
            Assert.Equal(Enumerable.Range(0, 4).Select(minute => Start.AddMinutes(minute)), history.Select(item => item.CompletedAt));
            Assert.All(history, item => { Assert.Equal(Network, item.NetworkId); Assert.Equal(Subnet, item.Subnet); });
        }
        var rows = ScanResultRow.CreateInventoryRows(data).ToArray();
        Assert.Equal(2, rows.Length);
        foreach (var row in rows)
        {
            var history = DeviceDetailsPresentation.ScanHistory(row.GetHistorySummary(Network, Subnet), TimeZoneInfo.Utc);
            Assert.Equal(["12:03:00", "12:02:00", "12:01:00", "12:00:00"], history.Select(item => item.Time));
            Assert.All(history, item => Assert.Equal("2026-11-01", item.Date));
            Assert.Equal(["Present", "Absent", "Present", "Present"],
                history.Select(item => item.State));
            Assert.Equal([false, true, false, true], history.Select(item => item.IsAlternateRow));
        }
    }

    [Fact]
    public void MultipleAddressesAndAssociatedMacsDoNotDuplicateDeviceLevelEntries()
    {
        var data = Scan(DeviceInventoryData.Empty, 0, Result(Normal), Result(Normal, "192.0.2.2"),
            Result(Private, "192.0.2.3"), Result(Private, "192.0.2.4"));
        Assert.Single(data.Devices[Normal].ScanHistory);
        Assert.Single(Assert.Single(data.VirtualDevices).ScanHistory);
        data = Scan(data, 1, Result(Normal, "192.0.2.5"), Result(Rotated, "192.0.2.6"));
        Assert.All(data.Devices[Normal].ScanHistory, item => Assert.True(item.Present));
        Assert.Equal(2, data.VirtualDevices[0].ScanHistory.Count);
        data = Scan(data, 2, Result(Private), Result(Rotated, "192.0.2.2"));
        Assert.Equal(2, data.VirtualDevices.Count);
        Assert.Equal(3, data.VirtualDevices.Single(slot => slot.Number == 1).ScanHistory.Count);
        Assert.Single(data.VirtualDevices.Single(slot => slot.Number == 2).ScanHistory);
    }

    [Theory]
    [InlineData("other-network", Subnet, false)]
    [InlineData(Network, "198.51.100.0/24", false)]
    [InlineData(null, Subnet, false)]
    [InlineData(Network, Subnet, true)]
    public void UnrelatedUnscopedAndRestoredScansNeverAppendAbsence(string? network, string subnet, bool historical)
    {
        var data = Scan(DeviceInventoryData.Empty, 0, Result(Normal), Result(Private, "192.0.2.2"));
        var next = data.ObserveCompletedScan(network, new(subnet, Start.AddMinutes(1), []), historical);
        Assert.Equal(data.Devices[Normal].ScanHistory, next.Devices[Normal].ScanHistory);
        Assert.Equal(data.VirtualDevices[0].ScanHistory, next.VirtualDevices[0].ScanHistory);
    }

    [Fact]
    public void UnscopedPresenceIsRecordedButCannotEstablishSubsequentAbsence()
    {
        var data = DeviceInventoryData.Empty.ObserveCompletedScan(null, new(Subnet, Start, [Result(Normal)]));
        var item = Assert.Single(data.Devices[Normal].ScanHistory);
        Assert.Null(item.NetworkId);
        Assert.True(item.Present);
        data = Scan(data, 1);
        Assert.Single(data.Devices[Normal].ScanHistory);
        Assert.Empty(DeviceDetailsPresentation.ScanHistory(new ScanResultRow(data.Devices[Normal], 24).GetHistorySummary(null, Subnet)));
        data = Scan(data, 2, Result(Normal));
        data = Scan(data, 3);
        Assert.Equal([true, true, false], data.Devices[Normal].ScanHistory.Select(item => item.Present));
    }

    [Fact]
    public void OtherNetworkPresenceKeepsDistinctContextAndLeavesOriginalVirtualHistoryAlone()
    {
        var data = Scan(DeviceInventoryData.Empty, 0, Result(Normal), Result(Private, "192.0.2.2"));
        var original = Assert.Single(data.VirtualDevices);
        data = data.ObserveCompletedScan("other-network", new(Subnet, Start.AddMinutes(1),
            [Result(Normal), Result(Private, "192.0.2.2")]));
        Assert.Equal([Network, "other-network"], data.Devices[Normal].ScanHistory.Select(item => item.NetworkId));
        Assert.Equal(2, data.VirtualDevices.Count);
        Assert.Single(data.VirtualDevices.Single(slot => slot.Id == original.Id).ScanHistory);
    }

    [Fact]
    public void ImportedOnlyLegacyAndUnusedAddressesDoNotInventHistory()
    {
        var imported = new InventoryDevice(Normal, new(Name: "Imported", Address: "192.0.2.4"), []);
        var data = DeviceInventoryData.Empty with { Devices = new Dictionary<string, InventoryDevice> { [Normal] = imported } };
        data = Scan(data, 0, Result("001122334466") with { Status = HostStatus.Unreachable });
        Assert.Single(data.Devices);
        Assert.Empty(data.Devices[Normal].ScanHistory);
        Assert.Contains("Imported Fing", DeviceDetailsPresentation.EmptyScanHistory(new(imported, 24), Network, Subnet));
        var historical = data.ObserveCompletedScan(null, new(Subnet, Start, [Result(Normal)]), historical: true);
        Assert.Empty(historical.Devices[Normal].ScanHistory);
        Assert.Contains("Earlier saved aggregates", DeviceDetailsPresentation.EmptyScanHistory(new(historical.Devices[Normal], 24), Network, Subnet));
        Assert.Contains("MAC-based", DeviceDetailsPresentation.EmptyScanHistory(new(Result(Normal) with { MacAddress = null }, 24), Network, Subnet));
    }

    [Fact]
    public void ImportAndAdditionalProbeUpdatesPreserveScanHistory()
    {
        var data = Scan(DeviceInventoryData.Empty, 0, Result(Normal), Result(Private, "192.0.2.2"));
        var updated = data.UpdateProbeResults(Result(Private, "192.0.2.2") with { OpenPorts = [new(443, "HTTPS")] });
        Assert.Equal(data.VirtualDevices[0].ScanHistory, updated.VirtualDevices[0].ScanHistory);
        Assert.Equal(data.Devices[Private].ScanHistory, updated.Devices[Private].ScanHistory);
        var export = new FingExport([new FingDeviceRecord(2, Normal, new(Name: "Imported name"), null, null)], [], 1);
        updated = FingImportAnalyzer.Analyze(export, updated).Updated;
        Assert.Equal(data.Devices[Normal].ScanHistory, updated.Devices[Normal].ScanHistory);
    }

    [Fact]
    public async Task RestartAndRepeatedRestorationPreserveHistoryWithoutFreshEvidence()
    {
        var data = Scan(Scan(DeviceInventoryData.Empty, 0, Result(Normal), Result(Private)), 1, Result(Normal), Result(Rotated));
        var store = new DeviceInventoryStore(PathName);
        await store.SaveAsync(data, Guid.Empty);
        var restored = (await store.LoadAsync())!;
        Assert.Equal(data.Devices[Normal].ScanHistory, restored.Devices[Normal].ScanHistory);
        Assert.Equal(data.VirtualDevices[0].ScanHistory, restored.VirtualDevices[0].ScanHistory);
        Assert.Equal(InventoryDeviceStatus.Unknown, restored.VirtualDevices[0].Status);
        for (var i = 0; i < 2; i++)
            restored = restored.ObserveCompletedScan(null, new(Subnet, Start.AddMinutes(1), [Result(Normal)]), historical: true);
        Assert.Equal(data.Devices[Normal].ScanHistory, restored.Devices[Normal].ScanHistory);
        Assert.Equal(data.VirtualDevices[0].ScanHistory, restored.VirtualDevices[0].ScanHistory);
        Assert.False(new ScanResultRow(restored.Devices[Normal], 24).IsOnline);
    }

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    public async Task OlderInventoryFormatsLoadWithoutFabricatedScanEntries(int version)
    {
        var store = new DeviceInventoryStore(PathName);
        await InventoryJsonFixture.WriteAsync(PathName, Scan(DeviceInventoryData.Empty, 0, Result(Normal), Result(Private)));
        var json = JsonNode.Parse(await File.ReadAllTextAsync(PathName))!;
        json["version"] = version;
        foreach (var device in json["data"]!["devices"]!.AsObject())
            device.Value!.AsObject().Remove("scanHistory");
        foreach (var slot in json["data"]!["virtualDevices"]!.AsArray())
            slot!.AsObject().Remove("scanHistory");
        if (version == 1) json["data"]!.AsObject().Remove("virtualDevices");
        await File.WriteAllTextAsync(PathName, json.ToJsonString());
        var loaded = (await store.LoadAsync())!;
        Assert.All(loaded.Devices.Values, device => Assert.Empty(device.ScanHistory));
        Assert.All(loaded.VirtualDevices, slot => Assert.Empty(slot.ScanHistory));
        var observed = Scan(loaded, 1);
        Assert.Single(observed.Devices[Normal].ScanHistory);
        Assert.Single(Assert.Single(observed.VirtualDevices).ScanHistory);
        await store.SaveAsync(observed, loaded.Revision);
        Assert.Equal(version, JsonNode.Parse(await File.ReadAllTextAsync(PathName))!["version"]!.GetValue<int>());
        Assert.Single((await new DeviceInventoryStore(PathName).LoadAsync())!.Devices[Normal].ScanHistory);
    }

    [Fact]
    public async Task RetentionHasNoAgeOrCountTruncation()
    {
        var data = DeviceInventoryData.Empty;
        for (var i = 0; i < 1100; i++)
            data = Scan(data, i * 1440, Result(Normal), Result(Private));
        var store = new DeviceInventoryStore(PathName);
        await store.SaveAsync(data, Guid.Empty);
        var loaded = (await store.LoadAsync())!;
        Assert.Equal(1100, loaded.Devices[Normal].ScanHistory.Count);
        Assert.Equal(1100, loaded.VirtualDevices[0].ScanHistory.Count);
        Assert.Equal(Start, loaded.Devices[Normal].ScanHistory[0].CompletedAt);
    }

    [Theory]
    [InlineData("null-list")]
    [InlineData("null-entry")]
    [InlineData("time")]
    [InlineData("network")]
    [InlineData("subnet")]
    [InlineData("unscoped-absence")]
    [InlineData("virtual-scope")]
    public async Task InvalidHistoryFailsClosedAndIsNotOverwritten(string corruption)
    {
        var store = new DeviceInventoryStore(PathName);
        var saved = await InventoryJsonFixture.WriteAsync(PathName, Scan(DeviceInventoryData.Empty, 0, Result(Normal), Result(Private)));
        var json = JsonNode.Parse(await File.ReadAllTextAsync(PathName))!;
        var device = json["data"]!["devices"]![Normal]!;
        var entry = device["scanHistory"]![0]!;
        switch (corruption)
        {
            case "null-list": device["scanHistory"] = null; break;
            case "null-entry": device["scanHistory"]![0] = null; break;
            case "time": entry["completedAt"] = default(DateTimeOffset).ToString("O"); break;
            case "network": entry["networkId"] = " "; break;
            case "subnet": entry["subnet"] = "bad"; break;
            case "unscoped-absence": entry["networkId"] = null; entry["present"] = false; break;
            case "virtual-scope": json["data"]!["virtualDevices"]![0]!["scanHistory"]![0]!["networkId"] = "other"; break;
        }
        var corrupt = json.ToJsonString();
        await File.WriteAllTextAsync(PathName, corrupt);
        await Assert.ThrowsAsync<InvalidDataException>(() => store.LoadAsync());
        await Assert.ThrowsAsync<InvalidDataException>(() => store.SaveAsync(saved, saved.Revision));
        Assert.Equal(corrupt, await File.ReadAllTextAsync(PathName));
    }

    [Fact]
    public async Task FailedSaveDoesNotClaimNewHistoryWasPersisted()
    {
        var store = new DeviceInventoryStore(PathName);
        var saved = await store.SaveAsync(Scan(DeviceInventoryData.Empty, 0, Result(Normal)), Guid.Empty);
        using (var locked = new FileStream(PathName + ".lock", FileMode.Open, FileAccess.ReadWrite, FileShare.None))
            await Assert.ThrowsAsync<IOException>(() => store.SaveAsync(Scan(saved, 1, Result(Normal)), saved.Revision));
        var loaded = (await store.LoadAsync())!;
        Assert.Single(loaded.Devices[Normal].ScanHistory);
        Assert.Equal(saved.Revision, loaded.Revision);
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }
}
