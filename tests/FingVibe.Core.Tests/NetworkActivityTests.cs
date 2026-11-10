using System.Net;
using System.Net.NetworkInformation;
using FingVibe.App;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class NetworkActivityTests
{
    private static readonly DateTimeOffset Now = DateTimeOffset.Parse("2026-11-07T18:00:00Z");
    private static readonly LogicalDeviceId[] Ids = Enumerable.Range(1, 14)
        .Select(index => LogicalDeviceId.Mac($"001122{index:X6}")).ToArray();

    private static AnalyticsScanEvidence Scan(string time, params AnalyticsResponse[] responses)
    {
        var instant = DateTimeOffset.Parse(time);
        return new(Guid.NewGuid(), instant, instant, ScanCheckpointState.Complete, 0, responses);
    }

    private static AnalyticsEvidence Evidence(IReadOnlyList<AnalyticsScanEvidence> scans, int count = 3,
        DateTimeOffset? now = null, TimeZoneInfo? zone = null)
    {
        var time = now ?? Now;
        zone ??= TimeZoneInfo.Utc;
        var last = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(time, zone).DateTime);
        return new(Guid.NewGuid(), "network-a", "192.0.2.0/24", time, zone.Id, last.AddDays(-29), last,
            time.AddDays(-30), Ids.Take(count).Select(id => new AnalyticsDevice(id, time.AddDays(-50), false)).ToArray(),
            scans.Select(scan => scan with { LocalCompletedAt = TimeZoneInfo.ConvertTime(scan.CompletedAt, zone) }).ToArray(), null);
    }

    private static IReadOnlyList<ActivityCountDay> Count(AnalyticsEvidence evidence, int hours = 1,
        IReadOnlyList<ActivityContributor>? contributors = null, ActivityCountFilter? filter = null) =>
        NetworkActivity.Count(DeviceActivity.Group(evidence, hours),
            contributors ?? evidence.Devices.Select(device => new ActivityContributor(device.Identity, null,
                DeviceType.Unknown, DeviceUsageCategory.Unclassified)).ToArray(), filter ?? new());

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    [InlineData(4)]
    public void UnionNotSumOrPeakAndRepeatedScansDoNotInflate(int hours)
    {
        var first = Scan("2026-11-06T12:00:00Z", AnalyticsResponse.Responded, AnalyticsResponse.Responded, AnalyticsResponse.DidNotRespond);
        var second = Scan("2026-11-06T12:30:00Z", AnalyticsResponse.DidNotRespond, AnalyticsResponse.Responded, AnalyticsResponse.Responded);
        var day = Assert.Single(Count(Evidence([first, first, second]), hours), day => day.Count > 0);
        Assert.Equal(3, day.Count);
        Assert.Equal(2, day.CompletedScans);
        Assert.Equal(AnalyticsCoverage.Exact, day.Coverage);
        Assert.Equal(12, day.StartHour);
    }

    [Theory]
    [InlineData(12, 12)]
    [InlineData(0, 8)]
    public void ExactWeekdayMeansIncludeZeroAndExcludeUnknown(int middle, int mean)
    {
        var scans = new[] { (14, 10), (21, middle), (28, 14) }.Select(item =>
            Scan($"2026-10-{item.Item1}T12:00:00Z", Enumerable.Range(0, 14)
                .Select(index => index < item.Item2 ? AnalyticsResponse.Responded : AnalyticsResponse.DidNotRespond).ToArray())).ToArray();
        var days = Count(Evidence(scans, 14));
        var weekday = NetworkActivity.ByWeekday(days).Single(day => day.Day == DayOfWeek.Wednesday && day.StartHour == 12);
        Assert.Equal((mean, 3, 4, 1, 0), (weekday.Mean, weekday.ExactDates, weekday.ApplicableDates, weekday.UnknownDates, weekday.PartialDates));
        Assert.Equal(mean * 3, weekday.Numerator);
        Assert.Null(NetworkActivity.ByWeekday(days).Single(day => day.Day == DayOfWeek.Wednesday && day.StartHour == 13).Mean);
    }

    [Fact]
    public void MissingFirstSightingLegacyAndUnidentifiedEvidenceRemainLowerBounds()
    {
        var evidence = Evidence([
            Scan("2026-10-14T12:00:00Z", AnalyticsResponse.Responded, AnalyticsResponse.Responded, AnalyticsResponse.Unknown),
            Scan("2026-10-21T12:00:00Z", AnalyticsResponse.Responded, AnalyticsResponse.Responded, AnalyticsResponse.Responded),
            Scan("2026-10-28T12:00:00Z", AnalyticsResponse.DidNotRespond, AnalyticsResponse.DidNotRespond, AnalyticsResponse.DidNotRespond) with { UnidentifiedResponses = 1 },
            Scan("2026-11-04T12:00:00Z", AnalyticsResponse.Responded, AnalyticsResponse.Unknown, AnalyticsResponse.Unknown) with { ScanId = null, State = null }
        ]);
        var days = Count(evidence);
        Assert.Equal((2, AnalyticsCoverage.Partial), (days.Single(day => day.Date.Day == 14 && day.StartHour == 12).Count,
            days.Single(day => day.Date.Day == 14 && day.StartHour == 12).Coverage));
        var weekday = NetworkActivity.ByWeekday(days).Single(day => day.Day == DayOfWeek.Wednesday && day.StartHour == 12);
        Assert.Equal((3m, 1, 3), (weekday.Mean, weekday.ExactDates, weekday.PartialDates));
        var imported = evidence with { Devices = evidence.Devices.Select(device => device with { FirstReliableSighting = null }).ToArray() };
        Assert.All(Count(imported).Where(day => day.CompletedScans > 0), day =>
        {
            Assert.Equal(0, day.Count);
            Assert.Equal(AnalyticsCoverage.Partial, day.Coverage);
        });
    }

    [Fact]
    public void FiltersAreConjunctiveAndRecomputeExactCoverageForSelectedContributors()
    {
        var room = Guid.NewGuid();
        var contributors = new[]
        {
            new ActivityContributor(Ids[0], room, DeviceType.Computer, DeviceUsageCategory.Permanent),
            new ActivityContributor(Ids[1], room, DeviceType.Phone, DeviceUsageCategory.Personal),
            new ActivityContributor(Ids[2], null, DeviceType.Unknown, DeviceUsageCategory.Unclassified)
        };
        var evidence = Evidence([Scan("2026-11-06T12:00:00Z", AnalyticsResponse.Responded, AnalyticsResponse.Responded, AnalyticsResponse.Unknown)]);
        ActivityCountDay Selected(ActivityCountFilter filter) => Assert.Single(Count(evidence, contributors: contributors, filter: filter),
            day => day.CompletedScans > 0);
        Assert.Equal(AnalyticsCoverage.Partial, Selected(new()).Coverage);
        Assert.Equal((1, AnalyticsCoverage.Exact), (Selected(new(room, Type: DeviceType.Computer,
            Category: DeviceUsageCategory.Permanent)).Count, Selected(new(room)).Coverage));
        Assert.Equal((0, AnalyticsCoverage.Partial), (Selected(new(UnassignedRoomOnly: true)).Count,
            Selected(new(Type: DeviceType.Unknown, Category: DeviceUsageCategory.Unclassified)).Coverage));
        Assert.Equal((0, AnalyticsCoverage.Exact), (Selected(new(room, Category: DeviceUsageCategory.Guest)).Count,
            Selected(new(room, Category: DeviceUsageCategory.Guest)).Coverage));
        contributors[0] = contributors[0] with { RoomId = null, Category = DeviceUsageCategory.Guest };
        Assert.Equal(0, Selected(new(room, Type: DeviceType.Computer)).Count);
        Assert.Equal(1, Selected(new(UnassignedRoomOnly: true, Category: DeviceUsageCategory.Guest)).Count);
    }

    [Fact]
    public void EmptyCompletedScanIsKnownZeroButNoScansIsUnknown()
    {
        var days = Count(Evidence([Scan("2026-11-06T12:00:00Z")], 0));
        var zero = Assert.Single(days, day => day.Coverage == AnalyticsCoverage.Exact);
        Assert.Equal(0, zero.Count);
        Assert.Equal(AnalyticsCoverage.Unknown, days[0].Coverage);
        Assert.Equal(0m, NetworkActivity.ByWeekday(days).Single(day => day.Day == DayOfWeek.Friday && day.StartHour == 12).Mean);
    }

    [Fact]
    public void DstSkippedAndRepeatedHoursAndFutureEvidenceUseSharedBuckets()
    {
        var zone = TimeZoneInfo.FindSystemTimeZoneById("Europe/Berlin");
        var spring = Count(Evidence([], 0, DateTimeOffset.Parse("2026-03-29T12:00:00Z"), zone));
        Assert.False(spring.Single(day => day.Date.Day == 29 && day.StartHour == 2).IsApplicable);
        var weekday = NetworkActivity.ByWeekday(spring).Single(day => day.Day == DayOfWeek.Sunday && day.StartHour == 2);
        Assert.Equal((5, 4), (weekday.IncludedDates, weekday.ApplicableDates));
        var autumn = Count(Evidence([
            Scan("2026-10-25T02:30:00+02:00", AnalyticsResponse.Responded),
            Scan("2026-10-25T02:30:00+01:00", AnalyticsResponse.Responded),
            Scan("2026-10-25T13:00:00Z", AnalyticsResponse.Responded)
        ], 1, DateTimeOffset.Parse("2026-10-25T12:00:00Z"), zone));
        var repeated = Assert.Single(autumn, day => day.Count > 0);
        Assert.Equal((1, 2, 2), (repeated.Count, repeated.CompletedScans, repeated.StartHour));
        Assert.True(repeated.IsPartialDate);
    }

    [Fact]
    public void PresentationExposesExactFractionsLowerBoundsAndHonestZeroScale()
    {
        var data = DeviceInventoryData.Empty with { Revision = Guid.NewGuid() };
        var empty = Evidence([], 0) with { Revision = data.Revision };
        var unknown = NetworkActivityPresentation.Create(empty, data, 1, true, new());
        Assert.Contains("unavailable", unknown.Legend);
        Assert.All(unknown.Cells, cell => Assert.True(cell.Hatched));
        var zero = NetworkActivityPresentation.Create(empty with { Scans = [Scan("2026-11-06T12:00:00Z")] }, data, 1, false, new());
        Assert.Contains("0 only", zero.Legend);
        Assert.Contains(zero.Cells, cell => cell.Value == "0" && !cell.Hatched);
        var partial = NetworkActivityPresentation.Create(empty with
        {
            Scans = [Scan("2026-11-06T12:00:00Z") with { UnidentifiedResponses = 1 }]
        }, data, 1, false, new());
        Assert.Contains(partial.Cells, cell => cell.Value == "0+" && cell.Hatched && cell.Details.Contains("At least 0"));
        Assert.Contains("lower bound 0+ only", partial.Legend);
        Assert.DoesNotContain("0 only", partial.Legend);
    }

    [Fact]
    public void FractionalMeanKeepsExactNumeratorAndCurrentSevenDateClassification()
    {
        var evidence = Evidence([
            Scan("2026-10-14T12:00:00Z", AnalyticsResponse.Responded, AnalyticsResponse.DidNotRespond),
            Scan("2026-10-21T12:00:00Z", AnalyticsResponse.Responded, AnalyticsResponse.Responded),
            Scan("2026-11-06T09:00:00Z", AnalyticsResponse.DidNotRespond, AnalyticsResponse.Responded)
        ], 2);
        var data = DeviceInventoryData.Empty with
        {
            Revision = evidence.Revision,
            Devices = Ids.Take(2).ToDictionary(id => id.Id,
                id => new InventoryDevice(id.Id, new ImportedDeviceMetadata(), []))
        };
        var display = NetworkActivityPresentation.Create(evidence, data, 1, true, new());
        var wednesday = display.Cells.Single(cell => cell.RowLabel == "Wed" && cell.StartHour == 12);
        Assert.Equal("1.5", wednesday.Value);
        Assert.Contains("exact sum 3 / 2 exact dates", wednesday.Details);
        Assert.Contains("Exact daily counts: 1, 2", wednesday.Details);
        Assert.Contains("2 / 4 applicable dates observed", wednesday.Details);
        Assert.True(wednesday.Hatched);
        var contributors = NetworkActivityPresentation.Contributors(data, evidence);
        Assert.Equal(DeviceUsageCategory.Guest, contributors[0].Category);
        Assert.Equal(DeviceUsageCategory.Permanent, contributors[1].Category);
        Assert.Equal(0m, NetworkActivityPresentation.Create(evidence, data, 1, false,
            new(Category: DeviceUsageCategory.Guest)).Cells.Single(cell =>
                cell.RowLabel == "Fri 6 Nov" && cell.StartHour == 9).Fraction);
    }

    [Fact]
    public async Task CurrentMetadataOverridesVirtualAliasesAndNetworkIsolationUseProductionQuery()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"fingvibe-network-count-{Guid.NewGuid():N}");
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
                Snapshot(Now.AddDays(-1), "network-a", Response(mac, "192.0.2.1"), Response(mac, "192.0.2.3"), Response(privateMac, "192.0.2.2")),
                Snapshot(Now.AddMinutes(-1), "network-b", Response("001122000099", "192.0.2.99"))
            }) data = await store.SaveAsync(data.ObserveCompletedScan(scan.NetworkId, scan), data.Revision);
            var room = new ManagedRoom(Guid.NewGuid(), "Office", "OFF");
            data = await store.SaveAsync(data with
            {
                PeopleRooms = new PeopleRoomsData(rooms: [room], assignments: new Dictionary<string, DeviceAssignment>
                    { [mac] = new(RoomId: room.Id) }),
                Classifications = new Dictionary<string, DeviceClassificationOverride> { [mac] = new(Type: DeviceType.Computer) }
            }, data.Revision);
            data = await store.SaveAsync(data.SetUsageCategoryOverride(LogicalDeviceId.Mac(mac), DeviceUsageCategory.Guest), data.Revision);
            var evidence = await store.QueryAnalyticsAsync(new("network-a", "192.0.2.0/24", Now, 30, TimeZoneInfo.Utc, data.Revision));
            Assert.Equal(2, evidence.Devices.Count);
            Assert.Contains(evidence.Devices, device => device.Identity.Kind == "virtual");
            Assert.DoesNotContain(evidence.Devices, device => device.Identity == LogicalDeviceId.Mac(privateMac));
            var all = NetworkActivityPresentation.Create(evidence, data, 1, false, new());
            Assert.Equal(2, all.Contributors);
            Assert.Contains(all.Cells, cell => cell.Value == "2" && !cell.Hatched);
            var filtered = NetworkActivityPresentation.Create(evidence, data, 1, false,
                new(room.Id, Type: DeviceType.Computer, Category: DeviceUsageCategory.Guest));
            Assert.Equal(1, filtered.Contributors);
            Assert.Contains(filtered.Cells, cell => cell.Value == "1" && cell.Fraction == 1m);
            Assert.Contains("to 1", filtered.Legend);
            Assert.Throws<InvalidOperationException>(() => NetworkActivityPresentation.Create(evidence,
                data with { Revision = Guid.NewGuid() }, 1, false, new()));
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true); }
    }

    [Fact]
    public void CancellationAndContributorMisalignmentFailExplicitly()
    {
        var evidence = Evidence([]);
        var buckets = DeviceActivity.Group(evidence, 1);
        var contributors = evidence.Devices.Select(device => new ActivityContributor(device.Identity, null,
            DeviceType.Unknown, DeviceUsageCategory.Unclassified)).ToArray();
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        Assert.Throws<OperationCanceledException>(() => NetworkActivity.Count(buckets, contributors, new(), cancellation.Token));
        Assert.Throws<OperationCanceledException>(() => NetworkActivity.ByWeekday(Count(evidence), cancellation.Token));
        Assert.Throws<ArgumentException>(() => NetworkActivity.Count(buckets, contributors.Reverse().ToArray(), new()));
    }
}
