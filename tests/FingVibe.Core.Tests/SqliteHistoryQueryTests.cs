using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using FingVibe.App;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Microsoft.Data.Sqlite;
using Xunit;
using Xunit.Abstractions;

namespace FingVibe.Core.Tests;

[CollectionDefinition("History workload", DisableParallelization = true)]
public sealed class HistoryWorkloadCollection;

[Collection("History workload")]
public sealed class SqliteHistoryQueryTests(ITestOutputHelper output) : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"fingvibe-history-query-{Guid.NewGuid():N}");
    private string PathName => Path.Combine(_directory, "inventory.sqlite");
    private const string Mac = "001122334455";
    private const string Network = "network";
    private const string Subnet = "192.0.2.0/24";
    private static readonly DateTimeOffset Start = DateTimeOffset.Parse("2026-11-01T12:00:00+02:00");
    private static ScanResult Response(string mac = Mac) => new(IPAddress.Parse("192.0.2.1"), HostStatus.Alive,
        1, TimeSpan.FromMilliseconds(1), null, PhysicalAddress.Parse(mac), mac.StartsWith("D0C907", StringComparison.Ordinal) ? "Private" : "Example");
    private static DeviceInventoryData Scan(DeviceInventoryData data, int second, bool present = true, string mac = Mac) =>
        data.ObserveCompletedScan(Network, new(Subnet, Start.AddSeconds(second), present ? [Response(mac)] : []));

    [Fact]
    public async Task PagesPreserveTiesOffsetsBackdatedScansAndSnapshotDuringAppends()
    {
        var store = new DeviceInventoryStore(PathName);
        await store.LoadMetadataAsync();
        var data = DeviceInventoryData.Empty;
        var times = new[] { 0, 3, 3, 1, 2, 3, 4, 4, 5 };
        foreach (var time in times) data = Scan(data, time);
        var saved = await store.SaveAsync(data, Guid.Empty);
        var history = saved.Devices[Mac].ScanHistory;
        var expected = data.Devices[Mac].ScanHistory.Select((item, sequence) => (item, sequence))
            .OrderByDescending(row => row.item.CompletedAt).ThenBy(row => row.sequence).ToArray();
        var seen = new List<DeviceScanObservation>();
        var sequences = new List<int>();
        DeviceHistoryCursor? cursor = null;
        DeviceHistoryPage? second = null;
        do
        {
            var page = DeviceHistoryQuery.ReadPage(history, Network, Subnet, cursor, pageSize: 2);
            if (seen.Count == 2) second = page;
            seen.AddRange(page.Items);
            if (page.First is not null) sequences.Add(page.First.Sequence);
            cursor = page.Last;
            if (page.Items.Count < 2) break;
            if (seen.Count == 2) saved = await store.SaveAsync(Scan(saved, 10), saved.Revision);
        } while (cursor is not null);
        Assert.Equal(expected.Select(row => row.item), seen);
        Assert.Equal(new[] { 8, 7, 2, 4, 0 }, sequences);
        Assert.Equal(9, DeviceHistoryQuery.ReadPage(history, Network, Subnet).TotalCount);
        Assert.Equal(10, DeviceHistoryQuery.ReadPage(saved.Devices[Mac].ScanHistory, Network, Subnet).TotalCount);
        var previous = DeviceHistoryQuery.ReadPage(history, Network, Subnet, second!.First, newer: true, pageSize: 2);
        Assert.Equal(expected.Take(2).Select(row => row.item), previous.Items);
        Assert.Empty(DeviceHistoryQuery.ReadPage(history, "other", Subnet).Items);
        Assert.Empty(DeviceHistoryQuery.ReadPage(history, Network, "198.51.100.0/24").Items);
        Assert.Empty(DeviceHistoryQuery.ReadPage(history, null, Subnet).Items);
        Assert.Throws<ArgumentOutOfRangeException>(() => DeviceHistoryQuery.ReadPage(history, Network, Subnet, pageSize: 201));
    }

    [Fact]
    public async Task BoundedSummariesMatchMemoryIncludingStateRunsTiesAndAggregateProvenance()
    {
        var store = new DeviceInventoryStore(PathName);
        var data = Scan(DeviceInventoryData.Empty, 0);
        data = Scan(data, 1);
        data = Scan(data, 2, false);
        data = Scan(data, 2, false);
        data = Scan(data, 3);
        await store.SaveAsync(data, Guid.Empty);
        var loaded = (await store.LoadMetadataAsync())!;
        var expected = DeviceHistorySummary.Create(data.Devices[Mac].ScanHistory, data.Devices[Mac].Observations, Network, Subnet);
        AssertSummary(expected, DeviceHistorySummary.Create(loaded.Devices[Mac].ScanHistory,
            loaded.Devices[Mac].Observations, Network, Subnet));
        var pending = Scan(Scan(loaded, 4, false), 5, false);
        var memoryPending = Scan(Scan(data, 4, false), 5, false);
        AssertSummary(DeviceHistorySummary.Create(memoryPending.Devices[Mac].ScanHistory,
                memoryPending.Devices[Mac].Observations, Network, Subnet),
            DeviceHistorySummary.Create(pending.Devices[Mac].ScanHistory,
                pending.Devices[Mac].Observations, Network, Subnet));
        Assert.Equal(7, DeviceHistoryQuery.ReadPage(pending.Devices[Mac].ScanHistory, Network, Subnet).TotalCount);
        var aggregate = loaded.Devices[Mac].Observations[0] with { FirstSeen = Start.AddDays(-1), LastSeen = Start.AddDays(1), LastChecked = Start.AddDays(1) };
        var summary = DeviceHistorySummary.Create(loaded.Devices[Mac].ScanHistory, [aggregate], Network, Subnet);
        Assert.True(summary.FirstSeenIsAggregate);
        Assert.True(summary.LastSeenIsAggregate);
        Assert.Equal(Start.AddSeconds(3), summary.Since);
        Assert.Null(DeviceHistorySummary.Create(loaded.Devices[Mac].ScanHistory, [aggregate], "other", Subnet).LastSeen);
    }

    [Fact]
    public async Task VirtualHistorySurvivesActiveMacChangeRestartAndUsesBoundedPages()
    {
        var data = Scan(DeviceInventoryData.Empty, 0, mac: "D0C907000001");
        data = Scan(data, 1, mac: "D0C907000002");
        data = Scan(data, 2, false);
        var store = new DeviceInventoryStore(PathName);
        await store.SaveAsync(data, Guid.Empty);
        var loaded = (await store.LoadMetadataAsync())!;
        var slot = Assert.Single(loaded.VirtualDevices);
        Assert.Equal("D0C907000002", slot.LastActiveMac);
        var page = DeviceHistoryQuery.ReadPage(slot.ScanHistory, Network, Subnet, pageSize: 2);
        Assert.Equal(3, page.TotalCount);
        Assert.False(page.Items[0].Present);
        Assert.True(page.Items[1].Present);
        Assert.Single(DeviceHistoryQuery.ReadPage(slot.ScanHistory, Network, Subnet, page.Last, pageSize: 2).Items);
        var row = new ScanResultRow(slot, loaded, 24);
        Assert.Equal(Start, row.GetHistorySummary(Network, Subnet).FirstSeen);
        Assert.Equal(Start.AddSeconds(1), row.GetHistorySummary(Network, Subnet).LastSeen);
    }

    [Fact]
    public async Task DiscoveryUsesDurableBoundedPresenceAndFailedWritesCanRetryWithoutHistoryCopy()
    {
        var store = new DeviceInventoryStore(PathName);
        await store.LoadMetadataAsync();
        var persisted = await store.SaveAsync(Scan(DeviceInventoryData.Empty, 0), Guid.Empty);
        var scan = new ScanSnapshot(Subnet, Start.AddSeconds(1), [Response("001122334466")]);
        var observed = persisted.ObserveCompletedScan(Network, scan);
        Assert.Equal("001122334466", Assert.Single(DeviceDiscovery.FindNewDevices(persisted, observed, Network, scan)).Mac);
        Sql("CREATE TRIGGER fail_scan BEFORE INSERT ON scan_history BEGIN SELECT RAISE(ABORT,'fixture failure'); END;");
        await Assert.ThrowsAsync<IOException>(() => store.SaveAsync(observed, persisted.Revision));
        Assert.Equal(2, DeviceHistoryQuery.ReadPage(observed.Devices[Mac].ScanHistory, Network, Subnet).TotalCount);
        Assert.Equal(1, DeviceHistoryQuery.ReadPage(persisted.Devices[Mac].ScanHistory, Network, Subnet).TotalCount);
        Sql("DROP TRIGGER fail_scan;");
        var retry = await store.SaveAsync(observed, persisted.Revision);
        Assert.Empty(DeviceDiscovery.FindNewDevices(retry, retry.ObserveCompletedScan(Network, scan), Network, scan));
        Assert.Equal(2, retry.Devices[Mac].ScanHistory.Count);
    }

    [Fact]
    public async Task VersionOneUpgradeIsTransactionalAndKeepsOriginalTimestampOffsets()
    {
        var store = new DeviceInventoryStore(PathName);
        await store.SaveAsync(Scan(DeviceInventoryData.Empty, 0), Guid.Empty);
        DowngradeFixture();
        var loaded = (await store.LoadMetadataAsync())!;
        Assert.Equal(Start, Assert.Single(DeviceHistoryQuery.ReadPage(loaded.Devices[Mac].ScanHistory, Network, Subnet).Items).CompletedAt);
        Assert.Equal(2L, Scalar("SELECT version FROM inventory"));
        DowngradeFixture();
        Sql("UPDATE scan_history SET completed_at='invalid';");
        await Assert.ThrowsAsync<InvalidDataException>(() => store.LoadMetadataAsync());
        Assert.Equal(1L, Scalar("SELECT version FROM inventory"));
        Assert.Equal(0L, Scalar("SELECT COUNT(*) FROM sqlite_master WHERE name='history_counts'"));
    }

    [Fact]
    public async Task IndexedQueriesAndRoutineOperationsMeetPredeclaredMillionRowTargets()
    {
        var store = new DeviceInventoryStore(PathName);
        var results = Enumerable.Range(1, 100).Select(index => Response($"00112233{index:X4}")).ToArray();
        var data = DeviceInventoryData.Empty.ObserveCompletedScan(Network, new(Subnet, Start, results));
        await store.SaveAsync(data, Guid.Empty);
        using (var connection = Open())
        using (var command = connection.CreateCommand())
        {
            command.CommandText = """
                WITH RECURSIVE numbers(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM numbers WHERE n<9999)
                INSERT INTO scan_history
                SELECT 'mac',devices.id,n,
                    strftime('%Y-%m-%dT%H:%M:%S+00:00',$start,'+' || CAST(n/2 AS TEXT) || ' seconds'),
                    CASE WHEN n%10=0 THEN 'other' ELSE 'network' END,'192.0.2.0/24',
                    CASE WHEN n%4<2 THEN 1 ELSE 0 END,$ticks+(n/2)*10000000
                FROM devices CROSS JOIN numbers;
                """;
            command.Parameters.AddWithValue("$start", Start.UtcDateTime.ToString("yyyy-MM-ddTHH:mm:ss"));
            command.Parameters.AddWithValue("$ticks", Start.UtcTicks);
            command.ExecuteNonQuery();
        }
        Assert.Equal(1_000_000L, Scalar("SELECT COUNT(*) FROM scan_history"));
        output.WriteLine($"Environment: {RuntimeInformation.OSDescription}; {RuntimeInformation.FrameworkDescription}; {RuntimeInformation.ProcessArchitecture}; CPUs={Environment.ProcessorCount}. Fixture: 100 devices x 10,000 rows; ties, alternating states, 10% other-network rows.");
        var loaded = (await Measure("metadata startup", 10, 32, () => store.LoadMetadataAsync()))!;
        var history = loaded.Devices.Values.First().ScanHistory;
        var page = await Measure("100-row history page", 1, 1,
            () => Task.FromResult(DeviceHistoryQuery.ReadPage(history, Network, Subnet)));
        Assert.Equal(100, page.Items.Count);
        Assert.Equal(9001, page.TotalCount);
        await Measure("deep history page", 1, 1, () => Task.FromResult(
            DeviceHistoryQuery.ReadPage(history, Network, Subnet, new(Start.AddSeconds(50), 100))));
        await Measure("100 summaries and discovery", 5, 16, () =>
        {
            foreach (var device in loaded.Devices.Values)
            {
                var summary = DeviceHistorySummary.Create(device.ScanHistory, device.Observations, Network, Subnet);
                Assert.Single(summary.History);
                Assert.Equal(Start, summary.FirstSeen);
            }
            var scan = new ScanSnapshot(Subnet, Start.AddDays(1), results);
            Assert.Empty(DeviceDiscovery.FindNewDevices(loaded, loaded.ObserveCompletedScan(Network, scan), Network, scan));
            return Task.FromResult(true);
        });
        var saved = await Measure("100-device scan and save", 5, 16, () => store.SaveAsync(
            loaded.ObserveCompletedScan(Network, new(Subnet, Start.AddDays(1), results)), loaded.Revision));
        saved = await Measure("metadata edit", 5, 16, () => store.SaveAsync(saved with
        {
            Names = new Dictionary<string, string> { [results[0].MacAddress!.ToString()] = "Renamed" }
        }, saved.Revision));
        Assert.Equal(1_000_100L, Scalar("SELECT COUNT(*) FROM scan_history"));
        Assert.Equal(10001, saved.Devices.Values.First().ScanHistory.Count);
        var plan = Explain("""
            SELECT completed_at FROM scan_history INDEXED BY history_scope_time WHERE kind='mac' AND id='001122330001'
            AND network_id='network' AND subnet='192.0.2.0/24' AND sequence<10000
            ORDER BY completed_ticks DESC,sequence ASC LIMIT 100
            """);
        Assert.Contains("history_scope_time", plan);
        Assert.DoesNotContain("TEMP B-TREE", plan);
        Assert.Contains("history_scope_presence", Explain("""
            SELECT completed_at FROM scan_history INDEXED BY history_scope_presence WHERE kind='mac' AND id='001122330001'
            AND network_id='network' AND subnet='192.0.2.0/24' AND present=1
            ORDER BY completed_ticks DESC,sequence ASC LIMIT 1
            """));
    }

    private async Task<T> Measure<T>(string label, double seconds, int mebibytes, Func<Task<T>> operation)
    {
        var allocated = GC.GetTotalAllocatedBytes(precise: true);
        var clock = Stopwatch.StartNew();
        var result = await operation();
        clock.Stop();
        var bytes = GC.GetTotalAllocatedBytes(precise: true) - allocated;
        output.WriteLine($"{label}: {clock.Elapsed.TotalMilliseconds:F1} ms; {bytes / 1048576d:F3} MiB allocated; ceilings {seconds:F0}s / {mebibytes} MiB.");
        Assert.True(clock.Elapsed.TotalSeconds <= seconds, $"{label} exceeded {seconds}s: {clock.Elapsed}.");
        Assert.True(bytes <= mebibytes * 1048576L, $"{label} allocated {bytes} bytes, exceeding {mebibytes} MiB.");
        return result;
    }

    private static void AssertSummary(DeviceHistorySummary expected, DeviceHistorySummary actual)
    {
        Assert.Equal(expected.FirstSeen, actual.FirstSeen);
        Assert.Equal(expected.LastSeen, actual.LastSeen);
        Assert.Equal(expected.Since, actual.Since);
        Assert.Equal(expected.Latest, actual.Latest);
        Assert.Equal(expected.FirstSeenIsAggregate, actual.FirstSeenIsAggregate);
        Assert.Equal(expected.LastSeenIsAggregate, actual.LastSeenIsAggregate);
        Assert.True(actual.History.Count <= 1);
    }

    private void DowngradeFixture() => Sql("""
        DROP TRIGGER history_count_insert;
        DROP TABLE history_counts;
        DROP INDEX history_scope_time;
        DROP INDEX history_scope_presence;
        ALTER TABLE scan_history DROP COLUMN completed_ticks;
        UPDATE inventory SET version=1;
        """);

    private SqliteConnection Open()
    {
        var connection = new SqliteConnection($"Data Source={PathName};Pooling=False");
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
    private string Explain(string sql)
    {
        using var connection = Open();
        using var command = connection.CreateCommand();
        command.CommandText = "EXPLAIN QUERY PLAN " + sql;
        using var reader = command.ExecuteReader();
        var rows = new List<string>();
        while (reader.Read()) rows.Add(reader.GetString(3));
        return string.Join("\n", rows);
    }
    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }
}
