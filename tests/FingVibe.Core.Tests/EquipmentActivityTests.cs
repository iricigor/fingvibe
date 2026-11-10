using System.Net;
using System.Net.NetworkInformation;
using FingVibe.App;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class EquipmentActivityTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.Parse("2026-11-07T18:00:00Z");
    private static readonly LogicalDeviceId[] Ids = [LogicalDeviceId.Mac("001122000001"), LogicalDeviceId.Mac("001122000002")];
    private static readonly ManagedPerson Person = new(Guid.NewGuid(), "Equipment person", "EP");

    private static AnalyticsScanEvidence Scan(string time, params AnalyticsResponse[] responses)
    {
        var instant = DateTimeOffset.Parse(time);
        return new(Guid.NewGuid(), instant, instant, ScanCheckpointState.Complete, 0, responses);
    }

    private static AnalyticsEvidence Evidence(params AnalyticsScanEvidence[] scans) =>
        new(Guid.NewGuid(), "network-a", "192.0.2.0/24", Now, TimeZoneInfo.Utc.Id, new(2026, 10, 9), new(2026, 11, 7),
            Now.AddDays(-30), Ids.Select(id => new AnalyticsDevice(id, Now.AddDays(-50), false)).ToArray(),
            scans, scans.OrderBy(scan => scan.CompletedAt).LastOrDefault());

    private static DeviceInventoryData Data(AnalyticsEvidence evidence) => DeviceInventoryData.Empty with
    {
        Revision = evidence.Revision,
        Devices = Ids.ToDictionary(id => id.Id, id => new InventoryDevice(id.Id, new ImportedDeviceMetadata(), [])),
        Names = new Dictionary<string, string> { [Ids[0].Id] = "Laptop", [Ids[1].Id] = "Phone" },
        PeopleRooms = new PeopleRoomsData([Person], assignments: Ids.ToDictionary(id => id.Id, _ => new DeviceAssignment(PersonId: Person.Id)))
    };

    [Theory]
    [InlineData(false, "1.5", 2)]
    [InlineData(true, "1", 3)]
    public void EquipmentMeansUseExactDailyCountsAndNameContributors(bool includeZero, string mean, int dates)
    {
        var scans = new List<AnalyticsScanEvidence>
        {
            Scan("2026-10-14T12:00:00Z", AnalyticsResponse.Responded, AnalyticsResponse.DidNotRespond),
            Scan("2026-10-21T12:00:00Z", AnalyticsResponse.Responded, AnalyticsResponse.Responded)
        };
        if (includeZero) scans.Add(Scan("2026-10-28T12:00:00Z", AnalyticsResponse.DidNotRespond, AnalyticsResponse.DidNotRespond));
        var evidence = Evidence(scans.ToArray());
        var display = EquipmentActivityPresentation.Create(evidence, Data(evidence), 1, true);
        var wednesday = display.Grid.Cells.Single(cell => cell.RowLabel == "Wed" && cell.StartHour == 12);
        Assert.Equal(mean, wednesday.Value);
        Assert.Contains($"exact sum 3 / {dates} exact dates", wednesday.Details);
        Assert.Contains($"{dates} / 4 applicable dates observed", wednesday.Details);
        Assert.Contains("Laptop, Phone", wednesday.Details);
        Assert.True(wednesday.Hatched);
        Assert.Contains(display.Grid.Cells, cell => cell.Value == "" && cell.Hatched && cell.Details.Contains("Unavailable"));
    }

    [Fact]
    public void RepeatedResponsesCountDistinctEquipmentAndMissingEvidenceIsALowerBound()
    {
        var scan = Scan("2026-11-06T12:00:00Z", AnalyticsResponse.Responded, AnalyticsResponse.Responded);
        var evidence = Evidence(scan, scan, scan with { ScanId = Guid.NewGuid(), CompletedAt = scan.CompletedAt.AddMinutes(10) });
        var display = EquipmentActivityPresentation.Create(evidence, Data(evidence), 1, false);
        var cell = display.Grid.Cells.Single(cell => cell.Value == "2");
        Assert.Contains("2 distinct devices", cell.Details);
        Assert.Contains("Responded: Laptop, Phone", cell.Details);
        Assert.DoesNotContain("hours of", cell.Details);
        var partial = evidence with { Scans = [scan with { Responses = [AnalyticsResponse.Responded, AnalyticsResponse.Unknown] }] };
        display = EquipmentActivityPresentation.Create(partial, Data(partial), 1, false);
        cell = display.Grid.Cells.Single(cell => cell.Value == "1+");
        Assert.True(cell.Hatched);
        Assert.Contains("Unknown/ineligible: Phone", cell.Details);
        Assert.DoesNotContain(EquipmentActivityPresentation.Create(partial, Data(partial), 1, true).Grid.Cells,
            item => item.Value.Length > 0);
    }

    [Theory]
    [InlineData(ScanCheckpointState.Complete, AnalyticsResponse.Responded, AnalyticsResponse.DidNotRespond, EquipmentScanState.Online)]
    [InlineData(ScanCheckpointState.Complete, AnalyticsResponse.DidNotRespond, AnalyticsResponse.DidNotRespond, EquipmentScanState.NoResponse)]
    [InlineData(ScanCheckpointState.Complete, AnalyticsResponse.Responded, AnalyticsResponse.Unknown, EquipmentScanState.Unknown)]
    [InlineData(ScanCheckpointState.Incomplete, AnalyticsResponse.Responded, AnalyticsResponse.Responded, EquipmentScanState.Unknown)]
    [InlineData(ScanCheckpointState.Pending, AnalyticsResponse.Responded, AnalyticsResponse.Responded, EquipmentScanState.Unknown)]
    public void LatestIndicatorRequiresCompleteEligibleEvidence(ScanCheckpointState state,
        AnalyticsResponse first, AnalyticsResponse second, EquipmentScanState expected)
    {
        var evidence = Evidence(Scan("2026-11-07T17:00:00Z", first, second) with { State = state });
        var status = EquipmentActivity.Latest(evidence);
        Assert.Equal(expected, status.State);
        Assert.Contains("network-a", EquipmentActivityPresentation.Context(status, "network-a", Now));
        Assert.Contains("of 2", EquipmentActivityPresentation.Context(status, "network-a", Now));
        Assert.Equal(EquipmentScanState.Unknown, EquipmentActivity.Latest(evidence with
        {
            Devices = evidence.Devices.Select(device => device with { FirstReliableSighting = null }).ToArray()
        }).State);
        Assert.Equal(EquipmentScanState.Unknown, EquipmentActivity.Latest(evidence with
        {
            Devices = evidence.Devices.Select(device => device with { AmbiguousMapping = true }).ToArray()
        }).State);
        Assert.Equal(EquipmentScanState.Unknown, EquipmentActivity.Latest(evidence with
        {
            LatestScan = evidence.LatestScan! with { UnidentifiedResponses = 1 }
        }).State);
    }

    [Fact]
    public void AgeThresholdIsStrictAndDoesNotChangeEvidenceState()
    {
        var evidence = Evidence(Scan("2026-11-07T16:00:00Z", AnalyticsResponse.Responded, AnalyticsResponse.Responded));
        var status = EquipmentActivity.Latest(evidence);
        Assert.Equal(EquipmentScanState.Online, status.State);
        Assert.DoesNotContain("Older scan", EquipmentActivityPresentation.Context(status, "network-a", Now));
        Assert.Contains("Older scan", EquipmentActivityPresentation.Context(status, "network-a", Now.AddTicks(1)));
        Assert.Equal("Equipment online", EquipmentActivityPresentation.StateText(status));
        Assert.Equal(EquipmentScanState.Unknown, EquipmentActivity.Latest(evidence with { LatestScan = null }).State);
        var empty = evidence with { Devices = [], Scans = [], LatestScan = null };
        var display = EquipmentActivityPresentation.Create(empty, Data(empty), 1, true);
        Assert.Equal(EquipmentScanState.NoEquipment, display.Latest.State);
        Assert.Empty(display.Grid.Cells);
        Assert.Equal("No equipment assigned.", display.Contributors);
    }

    [Fact]
    public void RetainedAssignmentWithoutInventoryAndPreSightingLatestScanStayUnknown()
    {
        var evidence = Evidence(Scan("2026-11-07T16:00:00Z", AnalyticsResponse.Responded, AnalyticsResponse.Responded));
        var missing = LogicalDeviceId.Mac("001122000099");
        var data = Data(evidence);
        data = data with
        {
            PeopleRooms = new PeopleRoomsData([Person], assignments: new Dictionary<string, DeviceAssignment>(
                data.PeopleRooms.Assignments) { [missing.Id] = new(PersonId: Person.Id) })
        };
        var selection = EquipmentActivity.Select(data, Person.Id, evidence.NetworkId, evidence.Subnet);
        Assert.Equal(missing, Assert.Single(selection.UnavailableDevices));
        var display = EquipmentActivityPresentation.Create(EquipmentActivity.IncludeUnavailable(evidence, selection), data, 1, false);
        Assert.Equal(EquipmentScanState.Unknown, display.Latest.State);
        Assert.Equal(3, display.Latest.Total);
        Assert.Contains(display.Grid.Cells, cell => cell.Value == "2+" && cell.Hatched);
        Assert.Equal(EquipmentScanState.Unknown, EquipmentActivity.Latest(evidence with
        {
            Devices = evidence.Devices.Select(device => device with { FirstReliableSighting = Now }).ToArray()
        }).State);
    }

    [Fact]
    public async Task CurrentAssignmentsVirtualDeduplicationNetworkIsolationAndDeletionUseSavedEvidence()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"fingvibe-equipment-{Guid.NewGuid():N}");
        try
        {
            var store = new DeviceInventoryStore(Path.Combine(directory, "inventory.sqlite"));
            const string mac = "001122000001", privateMac = "D0C907000001";
            ScanResult Response(string id, string address) => new(IPAddress.Parse(address), HostStatus.Alive, 1, TimeSpan.Zero,
                MacAddress: PhysicalAddress.Parse(id), VendorName: id == privateMac ? "Private" : "Example");
            ScanSnapshot Snapshot(DateTimeOffset time, string network, params ScanResult[] rows) =>
                new("192.0.2.0/24", time, rows) { NetworkId = network, ScanId = Guid.NewGuid() };
            var data = DeviceInventoryData.Empty;
            foreach (var scan in new[]
            {
                Snapshot(Now.AddDays(-40), "network-a", Response(mac, "192.0.2.1"), Response(privateMac, "192.0.2.2")),
                Snapshot(Now.AddHours(-2), "network-a", Response(mac, "192.0.2.1"), Response(mac, "192.0.2.3"), Response(privateMac, "192.0.2.2")),
                Snapshot(Now.AddMinutes(-1), "network-b", Response("001122000099", "192.0.2.99"))
            }) data = await store.SaveAsync(data.ObserveCompletedScan(scan.NetworkId, scan), data.Revision);
            data = await store.SaveAsync(data with
            {
                PeopleRooms = new PeopleRoomsData([Person], assignments: new Dictionary<string, DeviceAssignment>
                {
                    [mac] = new(PersonId: Person.Id), [privateMac] = new(PersonId: Person.Id)
                }),
                VirtualDevices = data.VirtualDevices.Select(slot => slot with { Assignment = new(PersonId: Person.Id) }).ToArray()
            }, data.Revision);
            async Task<EquipmentActivityDisplay> Load(int days = 30) => await EquipmentActivityPresentation.LoadAsync(store, data,
                Person.Id, new("network-a", "192.0.2.0/24", Now, days, TimeZoneInfo.Utc, data.Revision), 1, false);
            var display = await Load();
            Assert.Equal(2, display.Latest.Total);
            Assert.Equal(2, display.Latest.Responded);
            Assert.Equal(Now.AddHours(-2), display.Latest.CompletedAt);
            Assert.Contains(display.Grid.Cells, cell => cell.Value == "2" && !cell.Hatched);
            Assert.Contains(display.Grid.Buckets.Devices, device => device.Identity.Kind == "virtual");
            Assert.DoesNotContain(display.Grid.Buckets.Devices, device => device.Identity == LogicalDeviceId.Mac(privateMac));

            var other = new ManagedPerson(Guid.NewGuid(), "Other", "OT");
            data = await store.SaveAsync(data with
            {
                PeopleRooms = new PeopleRoomsData([Person, other], assignments:
                    new Dictionary<string, DeviceAssignment> { [mac] = new(PersonId: other.Id) })
            }, data.Revision);
            Assert.Equal(1, (await Load()).Latest.Total);
            // A virtual device assigned on another network must remain unknown, not disappear.
            var foreign = data.VirtualDevices.Single() with { Id = Guid.NewGuid(), NetworkId = "network-b" };
            data = data with { VirtualDevices = [.. data.VirtualDevices, foreign] };
            var selection = EquipmentActivity.Select(data, Person.Id, "network-a", "192.0.2.0/24");
            Assert.Equal(LogicalDeviceId.Virtual(foreign.Id), Assert.Single(selection.UnavailableDevices));
            var evidence = await store.QueryAnalyticsAsync(new("network-a", "192.0.2.0/24", Now, 30, TimeZoneInfo.Utc,
                data.Revision, selection.QueryDevices));
            Assert.Equal(EquipmentScanState.Unknown, EquipmentActivity.Latest(EquipmentActivity.IncludeUnavailable(evidence, selection)).State);
            data = data with { PeopleRooms = new PeopleRoomsData([other]) };
            Assert.Empty(EquipmentActivity.Select(data, Person.Id, "network-a", "192.0.2.0/24").QueryDevices);
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true); }
    }

    [Fact]
    public void AssignmentRevisionAndCancellationPreventPublishingObsoleteResults()
    {
        var evidence = Evidence();
        Assert.Throws<InvalidOperationException>(() => EquipmentActivityPresentation.Create(evidence,
            Data(evidence) with { Revision = Guid.NewGuid() }, 1, false));
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        Assert.Throws<OperationCanceledException>(() =>
            EquipmentActivityPresentation.Create(evidence, Data(evidence), 1, true, cancellation.Token));
        using var session = new AsyncSurfaceSession();
        var old = session.Start("Person one / network one / old assignments")!;
        var current = session.Start("Person two / network two / new assignments")!;
        Assert.True(old.CancellationToken.IsCancellationRequested);
        Assert.False(session.Complete(old, AsyncSurfaceState.Ready, () => throw new Exception("Stale render")));
        Assert.True(session.Complete(current, AsyncSurfaceState.Ready, () => { }));
        var navigation = session.Start("Navigating away")!;
        session.Cancel();
        Assert.True(navigation.CancellationToken.IsCancellationRequested);
        Assert.False(session.Complete(navigation, AsyncSurfaceState.Error, () => throw new Exception("Stale error")));
    }
}
