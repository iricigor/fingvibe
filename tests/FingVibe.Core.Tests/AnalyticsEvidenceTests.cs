using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Microsoft.Data.Sqlite;
using Xunit;

namespace FingVibe.Core.Tests;

[Collection("History workload")]
public sealed class AnalyticsEvidenceTests : IDisposable
{
    private const string Network = "network-a";
    private const string Subnet = "192.0.2.0/24";
    private const string A = "001122330001";
    private const string B = "001122330002";
    private const string C = "001122330003";
    private static readonly DateTimeOffset Day = DateTimeOffset.Parse("2026-11-07T00:00:00Z");
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"fingvibe-analytics-{Guid.NewGuid():N}");
    private string Database => Path.Combine(_directory, "inventory.sqlite");

    private static ScanResult Response(string mac, int host = 1, string vendor = "Example") =>
        new(IPAddress.Parse($"192.0.2.{host}"), HostStatus.Alive, 1, TimeSpan.FromMilliseconds(1),
            MacAddress: PhysicalAddress.Parse(mac), VendorName: vendor);

    private static ScanSnapshot Scan(DateTimeOffset time, params ScanResult[] results) =>
        new(Subnet, time, results) { ScanId = Guid.NewGuid(), NetworkId = Network };

    private static async Task<DeviceInventoryData> Save(DeviceInventoryStore store, DeviceInventoryData data, ScanSnapshot scan) =>
        await store.SaveAsync(data.ObserveCompletedScan(scan.NetworkId, scan), data.Revision);

    private static AnalyticsEvidenceRequest Request(DeviceInventoryData data, int days = 30,
        IReadOnlyList<LogicalDeviceId>? devices = null) =>
        new(Network, Subnet, Day.AddHours(12), days, TimeZoneInfo.Utc, data.Revision, devices);

    [Fact]
    public async Task ShapeRetainsEmptyScansAndAlignedIdentitiesAcrossCheckpointsSavesAndRestart()
    {
        var store = new DeviceInventoryStore(Database);
        var data = await Save(store, DeviceInventoryData.Empty, Scan(Day.AddDays(-40), Response(A)));
        var s1 = Scan(Day.AddHours(9), Response(A), Response(B, 2), Response(A, 3));
        data = await Save(store, data, s1 with { State = ScanCheckpointState.Pending });
        data = await Save(store, data, s1);
        data = await Save(store, data, s1);
        var s2 = Scan(Day.AddHours(9.5), Response(B, 2), Response(C, 3));
        data = await Save(store, data, s2);
        var s3 = Scan(Day.AddHours(10));
        data = await Save(store, data, s3);
        data = await store.SaveAsync(data with { Names = new Dictionary<string, string> { [A] = "Renamed" } }, data.Revision);
        var restarted = new DeviceInventoryStore(Database);
        var loaded = (await restarted.LoadMetadataAsync())!;
        var evidence = await restarted.QueryAnalyticsAsync(Request(loaded));
        Assert.Equal(new[] { A, B, C }, evidence.Devices.Select(device => device.Identity.Id));
        Assert.Equal(Day.AddDays(-40), evidence.Devices[0].FirstReliableSighting);
        Assert.Equal(Day.AddHours(9), evidence.Devices[1].FirstReliableSighting);
        Assert.Equal(Day.AddHours(9.5), evidence.Devices[2].FirstReliableSighting);
        Assert.Equal(new[] { s1.ScanId, s2.ScanId, s3.ScanId }, evidence.Scans.Select(scan => scan.ScanId!.Value));
        Assert.Equal(new[] { AnalyticsResponse.Responded, AnalyticsResponse.Responded, AnalyticsResponse.Unknown },
            evidence.Scans[0].Responses);
        Assert.Equal(new[] { AnalyticsResponse.DidNotRespond, AnalyticsResponse.Responded, AnalyticsResponse.Responded },
            evidence.Scans[1].Responses);
        Assert.All(evidence.Scans[2].Responses, response => Assert.Equal(AnalyticsResponse.DidNotRespond, response));
        Assert.Equal(AnalyticsCoverage.Exact, evidence.Scans[2].Coverage);
        Assert.Equal(AnalyticsCoverage.Partial, evidence.Scans[0].Coverage);
        Assert.Equal(3, evidence.Scans.Where(scan => scan.LocalCompletedAt.Hour == 9)
            .SelectMany(scan => scan.Responses.Select((response, index) => (response, index)))
            .Where(item => item.response == AnalyticsResponse.Responded).Select(item => item.index).Distinct().Count());
        Assert.DoesNotContain(evidence.Scans, scan => scan.LocalCompletedAt.Hour == 11);
        Assert.Equal(s3.ScanId, evidence.LatestScan!.ScanId);
        Assert.Equal(4L, Scalar("SELECT COUNT(*) FROM scan_evidence"));
        Assert.Equal(4, loaded.Devices[A].ScanHistory.Count);
        Assert.Equal(s3.ScanId, DeviceHistoryQuery.ReadPage(loaded.Devices[A].ScanHistory, Network, Subnet).Items[0].ScanId);
        Assert.Equal(loaded.Revision, evidence.Revision);
    }

    [Fact]
    public async Task EmptyInventoryIsKnownZeroButNoScanIsUnknownAndSelectionCanBeEmpty()
    {
        var store = new DeviceInventoryStore(Database);
        var data = await store.SaveAsync(DeviceInventoryData.Empty, Guid.Empty);
        var before = await store.QueryAnalyticsAsync(Request(data));
        Assert.Empty(before.Scans);
        Assert.Null(before.LatestScan);
        data = await Save(store, data, Scan(Day.AddHours(10)));
        var after = await store.QueryAnalyticsAsync(Request(data, devices: []));
        Assert.Empty(after.Devices);
        Assert.Equal(AnalyticsCoverage.Exact, Assert.Single(after.Scans).Coverage);
    }

    [Fact]
    public async Task LatestScanIsNetworkScopedEvenWhenIncompleteOrOutsideTheWindow()
    {
        var store = new DeviceInventoryStore(Database);
        var old = Scan(Day.AddDays(-40), Response(A));
        var data = await Save(store, DeviceInventoryData.Empty, old);
        data = await Save(store, data, Scan(Day.AddHours(9), Response(B)) with { NetworkId = "network-b" });
        var evidence = await store.QueryAnalyticsAsync(Request(data));
        Assert.Empty(evidence.Scans);
        Assert.Equal(old.ScanId, evidence.LatestScan!.ScanId);
        Assert.Equal(AnalyticsResponse.Responded, Assert.Single(evidence.LatestScan.Responses));
        var pending = Scan(Day.AddHours(10), Response(C)) with { State = ScanCheckpointState.Pending };
        data = await Save(store, data, pending);
        data = await store.SaveAsync(data with { LatestScan = pending with { State = ScanCheckpointState.Incomplete } }, data.Revision);
        data = await Save(store, data, Scan(Day.AddHours(11), Response(B)) with { NetworkId = "network-b" });
        evidence = await store.QueryAnalyticsAsync(Request(data));
        Assert.Equal(pending.ScanId, evidence.LatestScan!.ScanId);
        Assert.Equal(ScanCheckpointState.Incomplete, evidence.LatestScan.State);
        Assert.Equal(AnalyticsCoverage.Unknown, evidence.LatestScan.Coverage);
        Assert.All(evidence.LatestScan.Responses, response => Assert.Equal(AnalyticsResponse.Unknown, response));
        Assert.Null(evidence.Devices.Single(device => device.Identity.Id == C).FirstReliableSighting);
        Assert.DoesNotContain(evidence.Devices, device => device.Identity.Id == B);
        data = await Save(store, data, Scan(Day.AddHours(11.5)));
        evidence = await store.QueryAnalyticsAsync(Request(data));
        Assert.Equal(AnalyticsResponse.Unknown, evidence.LatestScan!.Responses[
            evidence.Devices.ToList().FindIndex(device => device.Identity.Id == C)]);
    }

    [Fact]
    public async Task LatestScanOutsideWindowDoesNotMixOtherScansAtTheSameInstant()
    {
        var store = new DeviceInventoryStore(Database);
        var time = Day.AddDays(-40);
        var data = await Save(store, DeviceInventoryData.Empty, Scan(time, Response(A)));
        var latest = Scan(time);
        data = await Save(store, data, latest);
        var evidence = await store.QueryAnalyticsAsync(Request(data));
        Assert.Empty(evidence.Scans);
        Assert.Equal(latest.ScanId, evidence.LatestScan!.ScanId);
        Assert.Equal(AnalyticsResponse.DidNotRespond, Assert.Single(evidence.LatestScan.Responses));
    }

    [Fact]
    public async Task LegacyUpgradeDoesNotBackfillScansAndAggregateOrImportedTimesCannotEstablishAbsence()
    {
        var store = new DeviceInventoryStore(Database);
        var legacy = DeviceInventoryData.Empty.ObserveCompletedScan(Network,
            Scan(Day.AddDays(-40), Response(A)) with { ScanId = Guid.Empty });
        legacy = legacy.ObserveCompletedScan(Network, Scan(Day.AddHours(9), Response(A)) with { ScanId = Guid.Empty });
        legacy = legacy.ObserveCompletedScan(Network, Scan(Day.AddHours(10)) with { ScanId = Guid.Empty });
        var devices = legacy.Devices.ToDictionary(pair => pair.Key, pair => pair.Value);
        devices[B] = new(B, new(Name: "Imported"), []);
        var aggregate = legacy.Devices[A].Observations[0] with { Address = "192.0.2.3" };
        devices[C] = new(C, new(), [aggregate])
        {
            ScanHistory = [new(Day.AddHours(9), Network, Subnet, false)]
        };
        var data = await store.SaveAsync(legacy with { Devices = devices }, Guid.Empty);
        Sql("""
            DROP TABLE scan_evidence;
            DROP INDEX history_scan_identity;
            ALTER TABLE scan_history DROP COLUMN scan_id;
            ALTER TABLE scan_history DROP COLUMN virtual_id;
            UPDATE inventory SET version=2;
            """);
        data = (await new DeviceInventoryStore(Database).LoadMetadataAsync())!;
        Assert.Equal(0L, Scalar("SELECT COUNT(*) FROM scan_evidence"));
        var evidence = await store.QueryAnalyticsAsync(Request(data));
        Assert.Equal(2, evidence.Scans.Count);
        Assert.All(evidence.Scans, scan =>
        {
            Assert.Null(scan.ScanId);
            Assert.False(scan.HasCompletedLedger);
            Assert.Equal(AnalyticsCoverage.Partial, scan.Coverage);
            Assert.Equal(AnalyticsResponse.Unknown, scan.Responses[1]);
            Assert.Equal(AnalyticsResponse.Unknown, scan.Responses[2]);
        });
        Assert.Equal(Day.AddDays(-40), evidence.Devices[0].FirstReliableSighting);
        Assert.Null(evidence.Devices[1].FirstReliableSighting);
        Assert.Null(evidence.Devices[2].FirstReliableSighting);
        Assert.Equal(AnalyticsResponse.DidNotRespond, evidence.Scans[1].Responses[0]);
    }

    [Fact]
    public async Task ActualVirtualRowsDeduplicateMacAliasesWithoutMappingOlderRawHistory()
    {
        var store = new DeviceInventoryStore(Database);
        var data = await Save(store, DeviceInventoryData.Empty, Scan(Day.AddDays(-40), Response(A, vendor: "Private")));
        var slot = Assert.Single(data.VirtualDevices);
        data = await Save(store, data, Scan(Day.AddHours(9), Response(B, vendor: "Private")));
        data = await Save(store, data, Scan(Day.AddHours(10)));
        var evidence = await store.QueryAnalyticsAsync(Request(data,
            devices: [LogicalDeviceId.Mac(A), LogicalDeviceId.Mac(B), LogicalDeviceId.Virtual(slot.Id)]));
        Assert.Equal(LogicalDeviceId.Virtual(slot.Id), Assert.Single(evidence.Devices).Identity);
        Assert.Equal(Day.AddDays(-40), evidence.Devices[0].FirstReliableSighting);
        Assert.Equal(AnalyticsResponse.Responded, evidence.Scans[0].Responses[0]);
        Assert.Equal(AnalyticsResponse.DidNotRespond, evidence.Scans[1].Responses[0]);
        Sql("DELETE FROM scan_history WHERE kind='virtual'; DELETE FROM history_counts WHERE kind='virtual';");
        evidence = await store.QueryAnalyticsAsync(Request(data));
        Assert.Null(Assert.Single(evidence.Devices).FirstReliableSighting);
        Assert.All(evidence.Scans, scan =>
        {
            Assert.Equal(AnalyticsResponse.Unknown, Assert.Single(scan.Responses));
            Assert.Equal(AnalyticsCoverage.Partial, scan.Coverage);
        });
    }

    [Fact]
    public async Task AmbiguousRawMacAssociationDoesNotChooseAnArbitraryHistoricalVirtualSlot()
    {
        var store = new DeviceInventoryStore(Database);
        var data = await Save(store, DeviceInventoryData.Empty,
            Scan(Day.AddHours(9), Response(A, vendor: "Private"), Response(B, 2, "Private")));
        data = await Save(store, data, Scan(Day.AddHours(9.5), Response(C, vendor: "Private")));
        data = await Save(store, data,
            Scan(Day.AddHours(10), Response(C, vendor: "Private"), Response(A, 2, "Private")));
        Assert.Equal(2, data.VirtualDevices.Count(slot => slot.History.Any(item => item.Mac == A)));
        var evidence = await store.QueryAnalyticsAsync(Request(data, devices: [LogicalDeviceId.Mac(A)]));
        Assert.True(Assert.Single(evidence.Devices).AmbiguousMapping);
        Assert.Null(evidence.Devices[0].FirstReliableSighting);
        Assert.All(evidence.Scans, scan => Assert.Equal(AnalyticsResponse.Unknown, Assert.Single(scan.Responses)));
        var direct = await store.QueryAnalyticsAsync(Request(data));
        Assert.Equal(2, direct.Devices.Count);
        Assert.All(direct.Devices, device => Assert.Equal("virtual", device.Identity.Kind));
        Assert.Equal(2, direct.LatestScan!.Responses.Count(response => response == AnalyticsResponse.Responded));
    }

    [Fact]
    public async Task NamedMacReturningFromVirtualGroupingDoesNotDuplicateItsEarlierResponses()
    {
        var store = new DeviceInventoryStore(Database);
        var data = await Save(store, DeviceInventoryData.Empty, Scan(Day.AddHours(9), Response(A, vendor: "Private")));
        var slot = Assert.Single(data.VirtualDevices);
        data = await store.SaveAsync(data with { Names = new Dictionary<string, string> { [A] = "Named device" } }, data.Revision);
        data = await Save(store, data, Scan(Day.AddHours(10), Response(A, vendor: "Private")));
        var evidence = await store.QueryAnalyticsAsync(Request(data));
        Assert.Equal(2, evidence.Devices.Count);
        Assert.Equal(LogicalDeviceId.Mac(A), evidence.Devices[0].Identity);
        Assert.Equal(LogicalDeviceId.Virtual(slot.Id), evidence.Devices[1].Identity);
        Assert.Equal(Day.AddHours(10), evidence.Devices[0].FirstReliableSighting);
        Assert.Equal(new[] { AnalyticsResponse.Unknown, AnalyticsResponse.Responded }, evidence.Scans[0].Responses);
        Assert.Equal(new[] { AnalyticsResponse.Responded, AnalyticsResponse.DidNotRespond }, evidence.Scans[1].Responses);
    }

    [Fact]
    public async Task DistinctLogicalScansAtOneInstantRemainDistinctAndUnidentifiedResponsesArePartial()
    {
        var store = new DeviceInventoryStore(Database);
        var first = Scan(Day.AddHours(10), Response(A));
        var second = Scan(first.CompletedAt);
        var data = DeviceInventoryData.Empty.ObserveCompletedScan(Network, first).ObserveCompletedScan(Network, second);
        data = await store.SaveAsync(data, Guid.Empty);
        var evidence = await store.QueryAnalyticsAsync(Request(data));
        Assert.Equal(2, evidence.Scans.Count);
        Assert.Equal(2, evidence.Scans.Select(scan => scan.ScanId).Distinct().Count());
        Assert.Equal(second.ScanId, evidence.LatestScan!.ScanId);
        var unknown = new ScanResult(IPAddress.Parse("192.0.2.99"), HostStatus.Alive, 1, TimeSpan.Zero);
        data = await Save(store, data, Scan(Day.AddHours(11), unknown));
        evidence = await store.QueryAnalyticsAsync(Request(data));
        Assert.Equal(1, evidence.LatestScan!.UnidentifiedResponses);
        Assert.Equal(AnalyticsCoverage.Partial, evidence.LatestScan.Coverage);
    }

    [Theory]
    [InlineData("2026-10-25T00:30:00Z", "2026-10-25T01:30:00Z", 2, 2)]
    [InlineData("2026-03-29T00:30:00Z", "2026-03-29T01:30:00Z", 1, 3)]
    public async Task LocalCalendarKeepsRepeatedInstantsAndSkipsMissingHours(string a, string b, int hourA, int hourB)
    {
        var zone = TimeZoneInfo.FindSystemTimeZoneById("W. Europe Standard Time");
        var start = DateTimeOffset.Parse(a);
        var end = DateTimeOffset.Parse(b);
        var store = new DeviceInventoryStore(Database);
        var data = await Save(store, DeviceInventoryData.Empty, Scan(start, Response(A)));
        data = await Save(store, data, Scan(end));
        data = await Save(store, data, Scan(end.AddHours(3), Response(A)));
        var evidence = await store.QueryAnalyticsAsync(Request(data, days: 7) with { QueryTime = end, TimeZone = zone });
        Assert.Equal(2, evidence.Scans.Count);
        Assert.Equal(new[] { hourA, hourB }, evidence.Scans.Select(scan => scan.LocalCompletedAt.Hour));
        Assert.Equal(6, evidence.LastDate.DayNumber - evidence.FirstDate.DayNumber);
        Assert.Equal(0, TimeZoneInfo.ConvertTime(evidence.WindowStart, zone).Hour);
        Assert.Equal(end, evidence.LatestScan!.CompletedAt);
        Assert.Equal(start, evidence.Devices[0].FirstReliableSighting);
    }

    [Fact]
    public async Task WindowIsCalendarAlignedStartInclusiveAndClippedAtCapturedQueryTime()
    {
        var store = new DeviceInventoryStore(Database);
        var data = await Save(store, DeviceInventoryData.Empty, Scan(Day.AddDays(-6).AddTicks(-1), Response(A)));
        data = await Save(store, data, Scan(Day.AddDays(-6)));
        data = await Save(store, data, Scan(Day.AddHours(10), Response(A)));
        data = await Save(store, data, Scan(Day.AddHours(12)));
        data = await Save(store, data, Scan(Day.AddHours(12).AddTicks(1), Response(A)));
        var evidence = await store.QueryAnalyticsAsync(Request(data, 7));
        Assert.Equal(Day.AddDays(-6), evidence.WindowStart);
        Assert.Equal(3, evidence.Scans.Count);
        Assert.Equal(10, evidence.Scans[1].LocalCompletedAt.Hour);
        Assert.Equal(Day.AddHours(12), evidence.LatestScan!.CompletedAt);
        Assert.Equal(Day.AddDays(-6).AddTicks(-1), evidence.Devices[0].FirstReliableSighting);
    }

    [Fact]
    public async Task LedgerHistoryCheckpointAndRevisionRollbackTogetherAndFinalEvidenceCannotBeRewritten()
    {
        var store = new DeviceInventoryStore(Database);
        var pending = Scan(Day.AddHours(9), Response(A)) with { State = ScanCheckpointState.Pending };
        var data = await Save(store, DeviceInventoryData.Empty, pending);
        Sql("CREATE TRIGGER fail_history BEFORE INSERT ON scan_history BEGIN SELECT RAISE(ABORT,'fixture failure'); END;");
        await Assert.ThrowsAsync<IOException>(() => Save(store, data, pending with { State = ScanCheckpointState.Complete }));
        var restored = (await new DeviceInventoryStore(Database).LoadAsync())!;
        Assert.Equal(data.Revision, restored.Revision);
        Assert.Empty(restored.Devices[A].ScanHistory);
        Assert.Equal((long)ScanCheckpointState.Pending, Scalar("SELECT state FROM scan_evidence"));
        Sql("DROP TRIGGER fail_history;");
        data = await Save(store, data, pending with { State = ScanCheckpointState.Complete });
        var finalized = data.LatestScan!;
        data = await Save(store, data, Scan(Day.AddHours(10)));
        await Assert.ThrowsAsync<InvalidOperationException>(() => store.SaveAsync(data with
        {
            LatestScan = finalized with { CompletedAt = Day.AddHours(11) }
        }, data.Revision));
        await Assert.ThrowsAsync<IOException>(() => Save(store, data, finalized));
        Assert.Equal(2L, Scalar("SELECT COUNT(*) FROM scan_evidence"));
        Assert.Equal(2L, Scalar("SELECT COUNT(*) FROM scan_history"));
    }

    [Fact]
    public async Task InvalidSelectionsCorruptionAndStaleResultsAreExplicitErrors()
    {
        var store = new DeviceInventoryStore(Database);
        var data = await Save(store, DeviceInventoryData.Empty, Scan(Day.AddHours(10), Response(A)));
        var before = await store.QueryAnalyticsAsync(Request(data));
        data = await store.SaveAsync(data with { Names = new Dictionary<string, string> { [A] = "Updated" } }, data.Revision);
        Assert.NotEqual(data.Revision, before.Revision);
        await Assert.ThrowsAsync<InvalidOperationException>(() => store.QueryAnalyticsAsync(Request(data) with { ExpectedRevision = before.Revision }));
        await Assert.ThrowsAsync<ArgumentException>(() => store.QueryAnalyticsAsync(Request(data) with { CalendarDays = 8 }));
        await Assert.ThrowsAsync<ArgumentException>(() => store.QueryAnalyticsAsync(Request(data, devices: [LogicalDeviceId.Mac(B)])));
        Sql("UPDATE scan_history SET completed_at='malformed';");
        await Assert.ThrowsAsync<InvalidDataException>(() => store.QueryAnalyticsAsync(Request(data)));
        Sql($"UPDATE scan_history SET completed_at='{Day.AddHours(10):O}'; DELETE FROM scan_evidence;");
        await Assert.ThrowsAsync<InvalidDataException>(() => store.QueryAnalyticsAsync(Request(data)));
    }

    [Fact]
    public async Task CorruptVirtualMetadataKeyCannotMasqueradeAsAValidLogicalIdentity()
    {
        var store = new DeviceInventoryStore(Database);
        var data = await Save(store, DeviceInventoryData.Empty, Scan(Day.AddHours(10), Response(A, vendor: "Private")));
        Sql($"UPDATE virtual_devices SET id='{Guid.NewGuid():D}';");
        await Assert.ThrowsAsync<InvalidDataException>(() => store.QueryAnalyticsAsync(Request(data)));
    }

    [Fact]
    public async Task OutOfRangeStoredStatesCannotTruncateIntoValidEvidence()
    {
        var store = new DeviceInventoryStore(Database);
        var data = await Save(store, DeviceInventoryData.Empty, Scan(Day.AddHours(10), Response(A)));
        Sql("PRAGMA ignore_check_constraints=ON; UPDATE scan_evidence SET state=4294967296;");
        await Assert.ThrowsAsync<InvalidDataException>(() => store.QueryAnalyticsAsync(Request(data)));
        Sql("UPDATE scan_evidence SET state=0; PRAGMA ignore_check_constraints=ON; UPDATE scan_history SET present=4294967297;");
        await Assert.ThrowsAsync<InvalidDataException>(() => store.QueryAnalyticsAsync(Request(data)));
    }

    [Fact]
    public async Task CancellationAndWriterContentionReleaseTheReadConnectionPromptly()
    {
        var store = new DeviceInventoryStore(Database);
        var data = await Save(store, DeviceInventoryData.Empty, Scan(Day.AddHours(10), Response(A)));
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => store.QueryAnalyticsAsync(Request(data), cancelled.Token));
        using var writer = Open();
        using var transaction = writer.BeginTransaction();
        using var command = writer.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "UPDATE inventory SET revision=revision";
        command.ExecuteNonQuery();
        // A reserved writer permits a consistent reader; an exclusive lock does not.
        Assert.Equal(data.Revision, (await store.QueryAnalyticsAsync(Request(data))).Revision);
        transaction.Rollback();
        command.Transaction = null;
        command.CommandText = "BEGIN EXCLUSIVE";
        command.ExecuteNonQuery();
        await Assert.ThrowsAsync<IOException>(() => store.QueryAnalyticsAsync(Request(data)));
        using var cancellation = new CancellationTokenSource();
        var query = store.QueryAnalyticsAsync(Request(data), cancellation.Token);
        await Task.Delay(20);
        var clock = Stopwatch.StartNew();
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => query);
        Assert.True(clock.Elapsed < TimeSpan.FromMilliseconds(250), $"Cancellation took {clock.Elapsed}.");
        command.CommandText = "ROLLBACK";
        command.ExecuteNonQuery();
        data = await Save(store, data, Scan(Day.AddHours(11)));
        Assert.Equal(2, (await store.QueryAnalyticsAsync(Request(data))).Scans.Count);
    }

    private SqliteConnection Open()
    {
        var connection = new SqliteConnection($"Data Source={Database};Pooling=False");
        connection.Open();
        return connection;
    }
    private void Sql(string sql)
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }
    private object? Scalar(string sql)
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        return command.ExecuteScalar();
    }
    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }
}
