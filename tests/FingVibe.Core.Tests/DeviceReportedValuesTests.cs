using System.Net;
using System.Net.NetworkInformation;
using System.Xml.Linq;
using FingVibe.App;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using FingVibe.Core.Storage;
using Microsoft.Data.Sqlite;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class DeviceReportedValuesTests : IDisposable
{
    private static readonly DateTimeOffset Start = new(2026, 11, 1, 12, 0, 0, TimeSpan.Zero);
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"reported-values-{Guid.NewGuid():N}");
    private string Database => Path.Combine(_directory, "device-inventory.sqlite");
    private const string Mac = "001122334455";

    private static ScanResult Result(string address = "192.0.2.1", string mac = Mac,
        params ReportedDeviceValue[] values) =>
        new(IPAddress.Parse(address), HostStatus.Alive, 1, TimeSpan.FromMilliseconds(1),
            mac.StartsWith("D0C907") ? null : "unchanged display name",
            PhysicalAddress.Parse(mac), mac.StartsWith("D0C907") ? "Private" : "Example")
        { ReportedValues = values };

    private static ScanSnapshot Snapshot(int minute, params ScanResult[] results) =>
        new("192.0.2.0/24", Start.AddMinutes(minute), results) { ScanId = Guid.NewGuid() };

    [Theory]
    [InlineData(" UUID:SYNTHETIC-ID ", "synthetic-id")]
    [InlineData("synthetic-id", "synthetic-id")]
    [InlineData("uuid: ", null)]
    [InlineData(" ", null)]
    public void SsdpNormalizesOnlyRootUuid(string input, string? expected)
    {
        var document = new XDocument(new XElement("root", new XElement("device",
            new XElement("UDN", input),
            new XElement("deviceList", new XElement("device", new XElement("UDN", "uuid:not-the-root"))))));
        Assert.Equal(expected, SsdpDiscoveryService.ParseDeviceDescription(document, null)!.DeviceUuid);
    }

    [Fact]
    public void BoundsRejectMalformedValuesAndPreserveDistinctCaseInsensitiveEvidence()
    {
        var values = Enumerable.Range(0, 7).Select(i => new ReportedDeviceValue(ReportedDeviceValueKind.GoogleCastId, $"id-{i}"))
            .Concat([new(ReportedDeviceValueKind.GoogleCastId, "ID-0"),
                new(ReportedDeviceValueKind.MdnsName, " \t "),
                new(ReportedDeviceValueKind.MdnsName, "bad\nname"),
                new(ReportedDeviceValueKind.MdnsName, new string('x', 129)),
                new(ReportedDeviceValueKind.MdnsName, "bad\uFFFDname"),
                new(ReportedDeviceValueKind.MdnsName, "bad\uD800name"),
                new((ReportedDeviceValueKind)99, "unknown")]);
        var result = DeviceReportedValues.Collect(values);
        Assert.Equal(new[] { "id-0", "id-1", "id-2", "id-3" }, result.Select(item => item.Value));
        Assert.Equal(new string('x', 128), DeviceReportedValues.Normalize(ReportedDeviceValueKind.PrinterUuid, new string('x', 128)));
        Assert.Null(DeviceReportedValues.Normalize(ReportedDeviceValueKind.UpnpUuid, new string('x', 129)));
        Assert.Equal("Synthetic \U0001F5A8", DeviceReportedValues.Normalize(ReportedDeviceValueKind.SsdpName, "Synthetic \U0001F5A8"));
    }

    [Fact]
    public void MissedKindsRetainTimesAndReceivedKindsReplaceOnlyTheMatchingObservation()
    {
        var first = Result(values: [new(ReportedDeviceValueKind.SsdpName, "first name"),
            new(ReportedDeviceValueKind.GoogleCastId, "old-a"), new(ReportedDeviceValueKind.GoogleCastId, "old-b")]);
        var data = DeviceInventoryData.Empty.ObserveCompletedScan("network", Snapshot(0, first,
            Result("192.0.2.2", values: [new(ReportedDeviceValueKind.PrinterUuid, "other-address")])));
        data = data.ObserveCompletedScan("network", Snapshot(1,
            Result(values: [new(ReportedDeviceValueKind.GoogleCastId, "new-id")])));
        var current = data.Devices[Mac].Observations.Single(item => item.Address == "192.0.2.1");
        Assert.Contains(new(ReportedDeviceValueKind.SsdpName, "first name", Start), current.ReportedValues);
        Assert.Contains(new(ReportedDeviceValueKind.GoogleCastId, "new-id", Start.AddMinutes(1)), current.ReportedValues);
        Assert.Equal(2, current.ReportedValues.Count);
        Assert.Equal("unchanged display name", current.Hostname);
        Assert.Empty(current.ToScanResult(Mac).ReportedValues);
        data = data.ObserveCompletedScan("network", Snapshot(2, Result()));
        Assert.Equal(current.ReportedValues, data.Devices[Mac].Observations.Single(item => item.Address == "192.0.2.1").ReportedValues);
        data = data.ObserveCompletedScan("other-network", Snapshot(3, Result()));
        Assert.Empty(data.Devices[Mac].Observations.Single(item => item.NetworkId == "other-network").ReportedValues);
        Assert.Equal("other-address", Assert.Single(data.Devices[Mac].Observations
            .Single(item => item.Address == "192.0.2.2").ReportedValues).Value);
    }

    [Fact]
    public void PendingCheckpointsCannotStampEvidenceBeforeCompletedScan()
    {
        var data = DeviceInventoryData.Empty.ObserveCompletedScan("network",
            Snapshot(0, Result(values: [new(ReportedDeviceValueKind.MdnsName, "old.local")])));
        var pending = Snapshot(1, Result(values: [new(ReportedDeviceValueKind.MdnsName, "new.local")]))
            with { State = ScanCheckpointState.Pending };
        data = data.ObserveCompletedScan("network", pending);
        Assert.Equal("old.local", Assert.Single(data.Devices[Mac].LatestObservation!.ReportedValues).Value);
        var completed = pending with { State = ScanCheckpointState.Complete, CompletedAt = Start.AddMinutes(2) };
        data = data.ObserveCompletedScan("network", completed);
        Assert.Equal(new(ReportedDeviceValueKind.MdnsName, "new.local", Start.AddMinutes(2)),
            Assert.Single(data.Devices[Mac].LatestObservation!.ReportedValues));
    }

    [Fact]
    public async Task SQLiteAndSnapshotsRoundTripEvidenceIncludingVirtualConnections()
    {
        var first = Result(mac: "D0C907000001", values: [new(ReportedDeviceValueKind.UpnpUuid, "synthetic-one")]);
        var snapshot = Snapshot(0, first);
        var cache = new ScanSnapshotStore(Path.Combine(_directory, "snapshot.json"));
        await cache.SaveAsync(snapshot);
        Assert.Equal(first.ReportedValues, Assert.Single((await cache.LoadAsync())!.Results).ReportedValues);
        var data = DeviceInventoryData.Empty.ObserveCompletedScan("network", snapshot);
        data = data.ObserveCompletedScan("network", Snapshot(1,
            Result("192.0.2.2", "D0C907000002", new ReportedDeviceValue(ReportedDeviceValueKind.HomeKitId, "synthetic-two"))));
        var saved = await new DeviceInventoryStore(Database).SaveAsync(data, Guid.Empty);
        var loaded = (await new DeviceInventoryStore(Database).LoadAsync())!;
        Assert.Equal(saved.Revision, loaded.Revision);
        var history = Assert.Single(loaded.VirtualDevices).History;
        Assert.Equal(new(ReportedDeviceValueKind.UpnpUuid, "synthetic-one", Start),
            Assert.Single(history.Single(item => item.Mac == "D0C907000001").Observation.ReportedValues));
        Assert.Equal(new(ReportedDeviceValueKind.HomeKitId, "synthetic-two", Start.AddMinutes(1)),
            Assert.Single(history.Single(item => item.Mac == "D0C907000002").Observation.ReportedValues));
    }

    [Fact]
    public async Task OlderInventoryWithoutEvidenceLoadsAndInvalidSavedValuesAreRejected()
    {
        var store = new DeviceInventoryStore(Database);
        var data = DeviceInventoryData.Empty.ObserveCompletedScan("network", Snapshot(0, Result()));
        var saved = await store.SaveAsync(data, Guid.Empty);
        using (var connection = new SqliteConnection($"Data Source={Database};Pooling=False"))
        {
            connection.Open();
            using var command = connection.CreateCommand();
            command.CommandText = "UPDATE devices SET data=json_remove(data,'$.observations[0].reportedValues')";
            command.ExecuteNonQuery();
        }
        saved = (await new DeviceInventoryStore(Database).LoadAsync())!;
        Assert.Empty(saved.Devices[Mac].LatestObservation!.ReportedValues);
        IReadOnlyList<ObservedDeviceValue>[] invalid =
        [
            [new(ReportedDeviceValueKind.UpnpUuid, "uuid:NOT-NORMALIZED", Start)],
            [new(ReportedDeviceValueKind.MdnsName, new string('x', 129), Start)],
            [new(ReportedDeviceValueKind.MdnsName, "future", Start.AddSeconds(1))],
            [new((ReportedDeviceValueKind)99, "unknown", Start)],
            [new(ReportedDeviceValueKind.MdnsName, "same", Start), new(ReportedDeviceValueKind.MdnsName, "SAME", Start)],
            Enumerable.Range(0, 5).Select(i => new ObservedDeviceValue(ReportedDeviceValueKind.PrinterUuid, $"id-{i}", Start)).ToArray()
        ];
        foreach (var values in invalid)
        {
            var changed = saved with { Devices = new Dictionary<string, InventoryDevice>
            {
                [Mac] = saved.Devices[Mac] with
                { Observations = [saved.Devices[Mac].LatestObservation! with { ReportedValues = values }] }
            }};
            await Assert.ThrowsAsync<InvalidDataException>(() => store.SaveAsync(changed, saved.Revision));
        }
    }

    [Fact]
    public void DetailsFollowSelectedAddressAndNeverCombineDifferentNetworkEvidence()
    {
        var data = DeviceInventoryData.Empty.ObserveCompletedScan("network", Snapshot(0,
            Result(values: [new(ReportedDeviceValueKind.UpnpUuid, "first-address")]),
            Result("192.0.2.2", values: [new(ReportedDeviceValueKind.HomeKitId, "second-address")])));
        var row = new ScanResultRow(data.Devices[Mac], 24, historical: false);
        row.SelectAddress("192.0.2.2");
        var text = DeviceDetailsPresentation.ReportedValues(row);
        Assert.Contains("192.0.2.2", text);
        Assert.Contains("HomeKit ID: second-address", text);
        Assert.Contains("Last received:", text);
        Assert.DoesNotContain("first-address", text);
        row.SelectAddress("192.0.2.1");
        Assert.Contains("UPnP device UUID: first-address", DeviceDetailsPresentation.ReportedValues(row));
        Assert.DoesNotContain("second-address", DeviceDetailsPresentation.ReportedValues(row));
        data = data.ObserveCompletedScan("other-network", Snapshot(1, Result()));
        var otherNetwork = new ScanResultRow(data.Devices[Mac], 24, historical: false);
        Assert.Empty(otherNetwork.ReportedValues);
        var empty = new ScanResultRow(Result(), 24);
        Assert.Equal("No reported names or device IDs saved for 192.0.2.1.", DeviceDetailsPresentation.ReportedValues(empty));
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, true);
    }
}
