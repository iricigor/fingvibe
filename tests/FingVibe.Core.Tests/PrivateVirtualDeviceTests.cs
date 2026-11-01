using System.Net;
using System.Net.NetworkInformation;
using System.Text.Json.Nodes;
using FingVibe.App;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class PrivateVirtualDeviceTests
{
    private const string First = "D0C907000001";
    private const string Second = "D0C907000002";
    private const string Third = "D0C907000003";
    private static readonly DateTimeOffset Start = new(2026, 11, 1, 12, 0, 0, TimeSpan.Zero);

    private static ScanResult Result(string mac, string ip = "192.0.2.1") =>
        new(IPAddress.Parse(ip), HostStatus.Alive, 1, TimeSpan.FromMilliseconds(1),
            null, PhysicalAddress.Parse(mac), "Private");

    private static DeviceInventoryData Scan(DeviceInventoryData data, int minute, params ScanResult[] results) =>
        data.ObserveCompletedScan("synthetic-network", new("192.0.2.0/24", Start.AddMinutes(minute), results));

    [Fact]
    public void RotatingMacReusesOnePersistentVirtualDeviceWithoutMergingRawInventory()
    {
        var first = Scan(DeviceInventoryData.Empty, 0, Result(First));
        var slot = Assert.Single(first.VirtualDevices);
        Assert.Equal("Private D0-C9-07", slot.AutomaticName);
        var second = Scan(first, 1, Result(Second, "192.0.2.2"));
        var reused = Assert.Single(second.VirtualDevices);
        Assert.Equal(slot.Id, reused.Id);
        Assert.Equal(Second, reused.LastActiveMac);
        Assert.Equal(2, reused.History.Count);
        Assert.Equal(2, second.Devices.Count);
        Assert.Equal(InventoryDeviceStatus.Offline, second.Devices[First].Status);
        Assert.Equal(InventoryDeviceStatus.Online, reused.Status);
        var row = new ScanResultRow(reused, second, 24);
        Assert.Equal("192.0.2.2", row.AddressText);
        Assert.True(row.CanProbe);
        Assert.Contains("D0-C9-07-00-00-01", row.ConnectionHistoryText);
        Assert.Contains("Inferred association", row.ConnectionHistoryText);
    }

    [Fact]
    public void ReturningMembersAreReservedBeforeNewMacsTakeLowestAvailableNumber()
    {
        var data = Scan(DeviceInventoryData.Empty, 0, Result(First), Result(Second, "192.0.2.2"));
        Assert.Equal([1, 2], data.VirtualDevices.Select(slot => slot.Number));
        data = Scan(data, 1, Result(Second, "192.0.2.2"), Result(Third, "192.0.2.3"));
        Assert.Equal(Third, data.VirtualDevices.Single(slot => slot.Number == 1).LastActiveMac);
        Assert.Equal(Second, data.VirtualDevices.Single(slot => slot.Number == 2).LastActiveMac);
        data = Scan(data, 2, Result(Third));
        Assert.Equal(InventoryDeviceStatus.Online, data.VirtualDevices.Single(slot => slot.Number == 1).Status);
        var offline = data.VirtualDevices.Single(slot => slot.Number == 2);
        Assert.Equal("Private D0-C9-07 -2", offline.AutomaticName);
        Assert.Equal(InventoryDeviceStatus.Offline, offline.Status);
        Assert.Single(offline.History);
        data = Scan(data, 3, Result("D0C907000004"));
        Assert.Equal("D0C907000004", data.VirtualDevices.Single(slot => slot.Number == 1).LastActiveMac);
        Assert.Equal(2, data.VirtualDevices.Count);
    }

    [Fact]
    public void AnyNumberOfRespondingMacsCreatesDistinctPersistentSlots()
    {
        var results = Enumerable.Range(1, 12).Select(i => Result($"D0C907{i:X6}", $"192.0.2.{i}")).ToArray();
        var data = Scan(DeviceInventoryData.Empty, 0, results.Reverse().ToArray());
        Assert.Equal(12, data.VirtualDevices.Count);
        Assert.Equal(Enumerable.Range(1, 12), data.VirtualDevices.Select(slot => slot.Number));
        Assert.All(data.VirtualDevices, slot => Assert.Single(slot.History));
        data = Scan(data, 1, Result(First));
        Assert.Single(data.VirtualDevices, slot => slot.Status == InventoryDeviceStatus.Online);
        Assert.Equal(11, data.VirtualDevices.Count(slot => slot.Status == InventoryDeviceStatus.Offline));
    }

    [Fact]
    public void SimultaneouslyReturningMacsFromOneSlotGetSeparateHistories()
    {
        var data = Scan(Scan(DeviceInventoryData.Empty, 0, Result(First)), 1, Result(Second));
        data = Scan(data, 2, Result(First), Result(Second, "192.0.2.2"));
        Assert.Equal(2, data.VirtualDevices.Count);
        Assert.Equal(Second, data.VirtualDevices.Single(slot => slot.Number == 1).LastActiveMac);
        Assert.Equal(First, data.VirtualDevices.Single(slot => slot.Number == 2).LastActiveMac);
        Assert.Equal(Start.AddMinutes(2), Assert.Single(data.VirtualDevices.Single(slot => slot.Number == 2).History).Observation.FirstSeen);
        data = Scan(data, 3, Result(First));
        Assert.Equal(First, data.VirtualDevices.Single(slot => slot.Number == 2).LastActiveMac);
        Assert.Equal(InventoryDeviceStatus.Online, data.VirtualDevices.Single(slot => slot.Number == 2).Status);
    }

    [Fact]
    public void SameMacMultipleAddressesStayOneIdentityAndCanSelectCurrentProbeAddress()
    {
        var data = Scan(DeviceInventoryData.Empty, 0, Result(First), Result(First, "192.0.2.2"));
        Assert.Single(data.Devices);
        var slot = Assert.Single(data.VirtualDevices);
        Assert.Equal(2, slot.History.Count);
        var row = new ScanResultRow(slot, data, 24);
        Assert.Equal(2, row.CurrentConnections.Count);
        row.SelectAddress("192.0.2.2");
        Assert.Equal("192.0.2.2", row.Result!.AddressText);
        Assert.Throws<ArgumentException>(() => row.SelectAddress("192.0.2.99"));
        data = Scan(data, 1, Result(First, "192.0.2.3"));
        Assert.Single(data.Devices);
        Assert.Equal(3, data.Devices[First].Observations.Count);
        Assert.Single(new ScanResultRow(Assert.Single(data.VirtualDevices), data, 24).CurrentConnections);
        Assert.Equal("192.0.2.3", data.Devices[First].LatestObservation!.Address);
    }

    [Fact]
    public void ProjectionCountsVirtualIdentitiesAndSearchesHistoricalMembersWithoutDuplicateRows()
    {
        var data = Scan(Scan(DeviceInventoryData.Empty, 0, Result(First)), 1, Result(Second));
        data = Scan(data, 2, Result(Second), Result(Third, "192.0.2.3"),
            Result("001122000001", "192.0.2.4") with { DeviceName = "Recognized", VendorName = "Known" });
        var rows = ScanResultRow.CreateInventoryRows(data).ToArray();
        Assert.Equal(3, rows.Length);
        Assert.Equal(2, rows.Count(row => row.VirtualDevice is not null));
        Assert.Equal(3, rows.Count(row => row.IsOnline));
        Assert.Single(rows, row => row.NameText == "Recognized");
        var historyMatch = Assert.Single(rows, row => row.MatchesFilter("D0-C9-07-00-00-01"));
        Assert.Equal(1, historyMatch.VirtualDevice!.Number);
        data = Scan(data, 3, Result(Second));
        rows = ScanResultRow.CreateInventoryRows(data).ToArray();
        Assert.Equal(3, rows.Length);
        Assert.Single(rows, row => row.IsOnline);
        Assert.Equal(2, rows.Count(row => row.IsOffline));
        Assert.All(rows, row => Assert.DoesNotContain("Online · historical", row.StatusContext));
        var restored = data with
        {
            Devices = data.Devices.ToDictionary(pair => pair.Key, pair => pair.Value with { CurrentCompletedAt = null }),
            VirtualDevices = data.VirtualDevices.Select(slot => slot with { CurrentCompletedAt = null }).ToArray()
        };
        rows = ScanResultRow.CreateInventoryRows(restored).ToArray();
        Assert.All(rows, row => Assert.Equal("Unknown", row.StatusLabel));
        Assert.DoesNotContain(rows, row => row.IsOnline || row.IsOffline || row.CanProbe);
    }

    [Fact]
    public void ProbeResultsStayWithSelectedAddressAndPersistToItsVirtualHistory()
    {
        var data = Scan(DeviceInventoryData.Empty, 0, Result(First),
            Result(First, "192.0.2.2") with { OpenPorts = [new(443, "HTTPS")] });
        var row = Assert.Single(ScanResultRow.CreateInventoryRows(data));
        Assert.Single(row.OpenPortItems);
        Assert.Empty(row.Result!.OpenPortItems);
        Assert.True(new DeviceResultFilter(false, true, "").Matches(row));
        row.SelectAddress("192.0.2.2");
        row.UpdateOpenPorts([new(443, "HTTPS"), new(1883, "MQTT")]);
        var updated = data.UpdateProbeResults(row.Result!);
        Assert.Empty(updated.Devices[First].Observations.Single(item => item.Address == "192.0.2.1").Ports);
        Assert.Equal(2, updated.Devices[First].Observations.Single(item => item.Address == "192.0.2.2").Ports.Count);
        Assert.Equal(2, Assert.Single(updated.VirtualDevices).History.Single(item => item.Observation.Address == "192.0.2.2").Observation.Ports.Count);
        row.SelectAddress("192.0.2.1");
        Assert.Empty(row.Result!.OpenPortItems);
        row.SelectAddress("192.0.2.2");
        Assert.Equal(2, row.Result!.OpenPortItems.Count);
        Assert.Equal("2", row.AddressHost);
        Assert.Throws<InvalidOperationException>(() =>
            Scan(updated, 1).UpdateProbeResults(Result(First, "192.0.2.2")));
    }

    [Fact]
    public void IdenticalScanTimestampsDoNotMakeOtherNetworkObservationsCurrent()
    {
        var data = Scan(DeviceInventoryData.Empty, 0, Result(First));
        data = data.ObserveCompletedScan("different-network", new("192.0.2.0/24", Start, []));
        Assert.Equal(InventoryDeviceStatus.Unknown, data.Devices[First].Status);
        Assert.Equal(InventoryDeviceStatus.Unknown, Assert.Single(data.VirtualDevices).Status);
        data = data.ObserveCompletedScan("different-network", new("192.0.2.0/24", Start, [Result(First)]));
        Assert.Equal(InventoryDeviceStatus.Online, data.Devices[First].Status);
        Assert.Equal("different-network", data.Devices[First].LatestObservation!.NetworkId);
    }

    [Fact]
    public void PreviouslyUnassociatedScopedHistoryJoinsLowestSlotAfterSuccessfulScan()
    {
        var legacy = Scan(Scan(DeviceInventoryData.Empty, 0, Result(First)), 1, Result(Second)) with { VirtualDevices = [] };
        var observed = Scan(legacy, 2, Result(Third));
        var slot = Assert.Single(observed.VirtualDevices);
        Assert.Equal(3, slot.History.Count);
        Assert.Equal(Start, slot.History.Single(item => item.Mac == First).Observation.FirstSeen);
        Assert.Single(ScanResultRow.CreateInventoryRows(observed));
        Assert.Equal(3, observed.Devices.Count);
        var absent = Scan(legacy, 2);
        Assert.Equal(InventoryDeviceStatus.Offline, Assert.Single(absent.VirtualDevices).Status);
        Assert.Equal(2, absent.VirtualDevices[0].History.Count);
        var restoredOnly = legacy.ObserveCompletedScan(null, new("192.0.2.0/24", Start.AddMinutes(2), []), historical: true);
        Assert.Empty(restoredOnly.VirtualDevices);
    }

    [Fact]
    public void VirtualNameClassificationAndAssignmentUpdatesDoNotAffectMacEligibility()
    {
        var data = Scan(DeviceInventoryData.Empty, 0, Result(First));
        var slot = Assert.Single(data.VirtualDevices);
        var row = new ScanResultRow(slot, data, 24);
        var updated = slot with { Name = "Synthetic device", Classification = new(Type: DeviceType.SmartDevice) };
        row.UpdateVirtualDevice(updated);
        Assert.Equal(slot.Id.ToString("D"), row.IdentityKey);
        Assert.Equal("Synthetic device", row.NameText);
        Assert.Equal(DeviceType.SmartDevice, row.Type);
        Assert.Equal(slot.AutomaticName, row.AutomaticName);
        Assert.True(PrivateVirtualDeviceAllocator.IsEligible(data, data.Devices[First]));
        Assert.Throws<ArgumentException>(() => row.UpdateVirtualDevice(updated with { Id = Guid.NewGuid() }));
        Assert.Equal(row.MacAddressText, new AssignedDeviceListRow(row.IdentityKey, row).MacAddressText);
    }

    [Theory]
    [InlineData("name")]
    [InlineData("hostname")]
    [InlineData("type")]
    [InlineData("os")]
    [InlineData("family")]
    [InlineData("model")]
    [InlineData("brand")]
    [InlineData("saved-name")]
    [InlineData("saved-type")]
    public void MeaningfulMacSpecificMetadataExcludesRecords(string field)
    {
        var imported = field switch
        {
            "name" => new ImportedDeviceMetadata(Name: "Known"),
            "hostname" => new(Hostname: "known.local"),
            "type" => new(Type: "Unmapped but meaningful"),
            "os" => new(OperatingSystem: "Linux"),
            "family" => new(Family: "Known"),
            "model" => new(Model: "Known"),
            "brand" => new(Brand: "Known"),
            _ => new()
        };
        var data = DeviceInventoryData.Empty with
        {
            Devices = new Dictionary<string, InventoryDevice> { [First] = new(First, imported, []) },
            Names = field == "saved-name" ? new Dictionary<string, string> { [First] = "Known" } : new Dictionary<string, string>(),
            Classifications = field == "saved-type"
                ? new Dictionary<string, DeviceClassificationOverride> { [First] = new(Type: DeviceType.Printer) }
                : new Dictionary<string, DeviceClassificationOverride>()
        };
        data = Scan(data, 0, Result(First));
        Assert.Empty(data.VirtualDevices);
        Assert.Single(data.Devices);
    }

    [Fact]
    public void IpNamesAreNotIdentificationAndPrivateRegistrationIsNotRandomization()
    {
        var data = DeviceInventoryData.Empty with { Names = new Dictionary<string, string> { [First] = "192.0.2.1" } };
        data = Scan(data, 0, Result(First) with { DeviceName = "192.0.2.1" },
            Result("D2C907000001"), Result("001122000001") with { VendorName = "Known" },
            Result("D0C908000001", "192.0.2.2"));
        Assert.Equal(2, data.VirtualDevices.Count);
        Assert.Equal(2, data.VirtualDevices.Select(slot => slot.Prefix).Distinct().Count());
    }

    [Fact]
    public void OtherNetworksSubnetsUnscopedAndHistoricalScansDoNotEstablishAbsence()
    {
        var data = Scan(DeviceInventoryData.Empty, 0, Result(First));
        foreach (var (network, subnet, historical) in new (string?, string, bool)[]
                 { ("other-network", "192.0.2.0/24", false), ("synthetic-network", "198.51.100.0/24", false),
                   (null, "192.0.2.0/24", false), ("synthetic-network", "192.0.2.0/24", true) })
        {
            var next = data.ObserveCompletedScan(network, new(subnet, Start.AddMinutes(1), []), historical);
            Assert.Equal(InventoryDeviceStatus.Unknown, Assert.Single(next.VirtualDevices).Status);
            Assert.Equal(InventoryDeviceStatus.Unknown, next.Devices[First].Status);
            Assert.True(Assert.Single(next.VirtualDevices).Present);
            Assert.True(next.Devices[First].LatestObservation!.Present);
        }
        var unscoped = DeviceInventoryData.Empty.ObserveCompletedScan(null, new("192.0.2.0/24", Start, [Result(First)]));
        Assert.Empty(unscoped.VirtualDevices);
        Assert.Equal(InventoryDeviceStatus.Online, unscoped.Devices[First].Status);
        // Failed/cancelled attempts do not call ObserveCompletedScan; retained evidence is unchanged.
        Assert.Equal(InventoryDeviceStatus.Online, data.Devices[First].Status);
    }

    [Fact]
    public async Task PersistenceRestoresUnknownStatusAndVirtualEditsFollowRotatingMac()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"fingvibe-virtual-{Guid.NewGuid():N}");
        var path = Path.Combine(directory, "inventory.json");
        try
        {
            var person = new ManagedPerson(Guid.NewGuid(), "Synthetic person", "S");
            var room = new ManagedRoom(Guid.NewGuid(), "Synthetic room", "S");
            var data = Scan(DeviceInventoryData.Empty, 0, Result(First)) with
            {
                PeopleRooms = new PeopleRoomsData([person], [room]).AssignRoom(First, room.Id)
            };
            var slot = Assert.Single(data.VirtualDevices) with
            {
                Name = "Virtual name",
                Classification = new(Type: DeviceType.SmartDevice),
                Assignment = new(PersonId: person.Id)
            };
            data = data with { VirtualDevices = [slot] };
            var store = new DeviceInventoryStore(path);
            var saved = await store.SaveAsync(data, Guid.Empty);
            var restored = (await store.LoadAsync())!;
            Assert.Equal(InventoryDeviceStatus.Unknown, restored.Devices[First].Status);
            Assert.Equal(InventoryDeviceStatus.Unknown, Assert.Single(restored.VirtualDevices).Status);
            Assert.DoesNotContain("currentCompletedAt", await File.ReadAllTextAsync(path));
            var historical = new ScanResultRow(Assert.Single(restored.VirtualDevices), restored, 24);
            Assert.Equal("Unknown", historical.StatusLabel);
            Assert.False(historical.CanProbe);
            Assert.True(new DeviceResultFilter(false, false, "", Status: InventoryDeviceStatus.Unknown).Matches(historical));
            Assert.False(new DeviceResultFilter(false, false, "", Status: InventoryDeviceStatus.Online).Matches(historical));
            restored = Scan(restored, 1, Result(Second));
            var rotated = Assert.Single(restored.VirtualDevices);
            Assert.Equal(slot.Id, rotated.Id);
            Assert.Equal("Virtual name", rotated.Name);
            Assert.Equal(slot.Classification, rotated.Classification);
            Assert.Equal(person.Id, rotated.Assignment!.PersonId);
            Assert.Equal(room.Id, restored.PeopleRooms.Assignments[First].RoomId);
            Assert.False(restored.Names.ContainsKey(Second));
            Assert.False(restored.Classifications.ContainsKey(Second));
            Assert.Equal(DeviceType.SmartDevice, new ScanResultRow(rotated, restored, 24).Type);
            await store.SaveAsync(restored, saved.Revision);
        }
        finally
        {
            if (File.Exists(path)) File.Delete(path);
            if (File.Exists(path + ".lock")) File.Delete(path + ".lock");
            if (Directory.Exists(directory)) Directory.Delete(directory);
        }
    }

    [Fact]
    public async Task LegacyInventoryWithoutVirtualDevicesStillLoadsAndInvalidHistoryIsRejected()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"fingvibe-virtual-legacy-{Guid.NewGuid():N}");
        var path = Path.Combine(directory, "inventory.json");
        try
        {
            var store = new DeviceInventoryStore(path);
            await store.SaveAsync(Scan(DeviceInventoryData.Empty, 0, Result(First)), Guid.Empty);
            var json = JsonNode.Parse(await File.ReadAllTextAsync(path))!;
            var original = json.ToJsonString();
            json["data"]!.AsObject().Remove("virtualDevices");
            json["version"] = 1;
            await File.WriteAllTextAsync(path, json.ToJsonString());
            Assert.Empty((await store.LoadAsync())!.VirtualDevices);
            json = JsonNode.Parse(original)!;
            json["data"]!["virtualDevices"]![0]!["history"]![0]!["mac"] = Second;
            await File.WriteAllTextAsync(path, json.ToJsonString());
            await Assert.ThrowsAsync<InvalidDataException>(() => store.LoadAsync());
        }
        finally
        {
            if (File.Exists(path)) File.Delete(path);
            if (File.Exists(path + ".lock")) File.Delete(path + ".lock");
            if (Directory.Exists(directory)) Directory.Delete(directory);
        }
    }
}
