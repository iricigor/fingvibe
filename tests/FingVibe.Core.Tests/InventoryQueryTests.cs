using System.Diagnostics;
using System.Text;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Microsoft.Data.Sqlite;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class InventoryQueryTests : IDisposable
{
    private const string Mac = "001122334455";
    private const string EmptyMac = "001122334466";
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"fingvibe-report-{Guid.NewGuid():N}");
    private string DatabasePath => Path.Combine(_directory, "device-inventory.sqlite");
    private InventoryQueryService Service => new(DatabasePath);
    private static readonly DateTimeOffset Time = DateTimeOffset.Parse("2026-11-01T12:00:00+02:00");

    private async Task<(DeviceInventoryStore Store, DeviceInventoryData Data)> SeedAsync()
    {
        var observation = new DeviceObservation("network", "192.0.2.0/24", "192.0.2.1", "observed", "Vendor",
            new(DeviceOperatingSystem.Linux, DeviceType.Computer), [new(443, "HTTPS")],
            7, TimeSpan.FromMilliseconds(8), Time, Time, Time, true,
            [new(53, "DNS", UdpServiceState.NoResponse, "Inconclusive")]);
        var person = new ManagedPerson(Guid.NewGuid(), "Alice", "A");
        var room = new ManagedRoom(Guid.NewGuid(), "Office", "O");
        var history = new DeviceScanObservation[] { new(Time, "network", "192.0.2.0/24", true),
            new(Time.AddMinutes(1), "network", "192.0.2.0/24", true) };
        var data = DeviceInventoryData.Empty with
        {
            Devices = new Dictionary<string, InventoryDevice>
            {
                [Mac] = new(Mac, new(Name: "Imported", Model: "Model", Address: "198.51.100.1"),
                    [observation, observation with { Address = "192.0.2.2", Hostname = null, Ports = [], UdpObservations = null },
                        observation with { NetworkId = null, Subnet = "198.51.100.0/24", Address = "198.51.100.2", Ports = [], UdpObservations = [] }])
                    { ScanHistory = history },
                [EmptyMac] = new(EmptyMac, new(), [])
            },
            Names = new Dictionary<string, string> { [Mac] = "Manual" },
            Classifications = new Dictionary<string, DeviceClassificationOverride> { [Mac] = new(Brand: "Override") },
            PeopleRooms = new PeopleRoomsData([person], [room]).AssignPerson(Mac, person.Id).AssignRoom(Mac, room.Id),
            VirtualDevices = [new(Guid.NewGuid(), "network", "192.0.2.0/24", "001122", 1, Mac, Time, true,
                [new(Mac, observation with { Hostname = "Historical embedded", Ports = [new(80, "HTTP")] }, true)],
                "Virtual manual", new(Type: DeviceType.Phone), new(person.Id, room.Id)) { ScanHistory = history }],
            DiscoveryBaselines = [new("network", "192.0.2.0/24")]
        };
        var store = new DeviceInventoryStore(DatabasePath);
        return (store, await store.SaveAsync(data, Guid.Empty));
    }

    [Fact]
    public async Task EveryDocumentedViewAndExampleExecutesWithMatchingColumns()
    {
        await SeedAsync();
        foreach (var view in InventoryReportingSchema.Views)
        {
            var result = await Service.RunAsync($"SELECT * FROM {view.Name}");
            Assert.Equal(view.Columns.Split(", "), result.Columns);
            Assert.Null(result.Limit);
        }
        foreach (var example in InventoryReportingSchema.Examples)
            Assert.NotEmpty((await Service.RunAsync(example.Sql)).Rows);
    }

    [Fact]
    public async Task ReportingPreservesKeysEmbeddedEvidenceNullsEmptyCollectionsAndMetadataProvenance()
    {
        await SeedAsync();
        var result = await Service.RunAsync("""
            SELECT o.device_kind, o.observation_index, o.hostname, p.port, u.state, o.network_id
            FROM r_observations o
            LEFT JOIN r_ports p USING(device_kind,device_id,observation_index)
            LEFT JOIN r_udp_evidence u USING(device_kind,device_id,observation_index)
            ORDER BY o.device_kind,o.observation_index
            """);
        Assert.Equal(4, result.Rows.Count);
        Assert.Equal(new[] { "mac", "0", "observed", "443", "1", "network" }, result.Rows[0]);
        Assert.Equal(new[] { "mac", "1", null, null, null, "network" }, result.Rows[1]);
        Assert.Null(result.Rows[2][5]);
        Assert.Equal(new[] { "virtual", "0", "Historical embedded", "80", "1", "network" }, result.Rows[3]);
        var imported = await Service.RunAsync("SELECT imported_name,imported_address FROM r_devices ORDER BY device_id");
        Assert.Equal(new[] { "Imported", "198.51.100.1" }, imported.Rows[0]);
        Assert.All(imported.Rows[1], Assert.Null);
        Assert.Equal("0", (await Service.RunAsync($"SELECT count(*) FROM r_observations WHERE device_id='{EmptyMac}'")).Rows[0][0]);
        var history = await Service.RunAsync("SELECT sequence,completed_at,completed_ticks,present FROM r_scan_history WHERE device_kind='mac' ORDER BY sequence");
        Assert.Equal(2, history.Rows.Count);
        Assert.Equal(Time.ToString("O"), history.Rows[0][1]);
        Assert.Equal(Time.UtcTicks.ToString(), history.Rows[0][2]);
        Assert.Equal("1", history.Rows[1][0]);
        Assert.Equal("1", history.Rows[1][3]);
        var assignments = await Service.RunAsync("""
            SELECT a.device_kind, p.name, r.name, n.name
            FROM r_assignments a
            JOIN r_people p USING(person_id) JOIN r_rooms r USING(room_id)
            JOIN r_names n USING(device_kind,device_id) ORDER BY a.device_kind
            """);
        Assert.Equal(new[] { "mac", "Alice", "Office", "Manual" }, assignments.Rows[0]);
        Assert.Equal(new[] { "virtual", "Alice", "Office", "Virtual manual" }, assignments.Rows[1]);
        var overrides = await Service.RunAsync("SELECT device_kind,brand,device_type FROM r_classification_overrides ORDER BY device_kind");
        Assert.Equal(new[] { "mac", "Override", null }, overrides.Rows[0]);
        Assert.Equal(new[] { "virtual", null, "2" }, overrides.Rows[1]);
    }

    [Theory]
    [InlineData("UPDATE devices SET data='{}'")]
    [InlineData("DELETE FROM main.scan_history")]
    [InlineData("CREATE TABLE stolen(id)")]
    [InlineData("CREATE TEMP TABLE stolen(id)")]
    [InlineData("DROP VIEW r_devices")]
    [InlineData("ATTACH DATABASE 'escape.sqlite' AS stolen")]
    [InlineData("VACUUM INTO 'escape.sqlite'")]
    [InlineData("PRAGMA query_only=OFF")]
    [InlineData("PRAGMA writable_schema=ON")]
    [InlineData("SELECT load_extension('escape')")]
    [InlineData("SELECT writefile('escape.sqlite','content')")]
    [InlineData("SELECT readfile('escape.sqlite')")]
    [InlineData("SELECT * FROM sqlite_master")]
    [InlineData("SELECT * FROM pragma_database_list")]
    [InlineData("SELECT * FROM main.inventory")]
    [InlineData("SELECT * FROM main.scan_checkpoint")]
    [InlineData("WITH r_devices AS (SELECT * FROM sqlite_master) SELECT * FROM r_devices")]
    [InlineData("SELECT * FROM pragma_table_info('devices')")]
    [InlineData("SELECT * FROM dbstat")]
    [InlineData("EXPLAIN DELETE FROM devices")]
    [InlineData("BEGIN")]
    [InlineData("SELECT 1; SELECT 2")]
    [InlineData("SELECT 1; UPDATE devices SET data='{}'")]
    [InlineData("SELECT 1\0; SELECT 2")]
    public async Task ForbiddenOperationsNeverChangeInventoryOrCreateFiles(string sql)
    {
        await SeedAsync();
        var before = await File.ReadAllBytesAsync(DatabasePath);
        sql = sql.Replace("escape.sqlite", Path.Combine(_directory, "escape.sqlite").Replace("'", "''"));
        await Assert.ThrowsAsync<InvalidOperationException>(() => Service.RunAsync(sql));
        Assert.Equal(before, await File.ReadAllBytesAsync(DatabasePath));
        Assert.DoesNotContain(Directory.GetFiles(_directory),
            path => path != DatabasePath && path != Path.ChangeExtension(DatabasePath, ".json") + ".lock");
        Assert.Equal("1", (await Service.RunAsync("SELECT 1; -- trailing comment")).Rows[0][0]);
    }

    [Fact]
    public async Task EmptyInvalidAndMalformedDataAreErrorsNotEmptySuccess()
    {
        await Assert.ThrowsAsync<FileNotFoundException>(() => Service.RunAsync("SELECT 1"));
        Assert.False(Directory.Exists(_directory));
        await SeedAsync();
        await Assert.ThrowsAsync<ArgumentException>(() => Service.RunAsync(" "));
        await Assert.ThrowsAsync<InvalidOperationException>(() => Service.RunAsync("-- only a comment"));
        await Assert.ThrowsAsync<InvalidOperationException>(() => Service.RunAsync("SELECT missing FROM r_devices"));
        Execute("UPDATE devices SET data='broken JSON'");
        await Assert.ThrowsAsync<InvalidDataException>(() => Service.RunAsync("SELECT COUNT(*) FROM r_devices"));
        await Assert.ThrowsAsync<InvalidDataException>(() => Service.RunAsync("SELECT 1"));
    }

    [Fact]
    public async Task ValuesBlobsNullsCommentsAndCteCountsRoundTripWithoutRewriting()
    {
        await SeedAsync();
        var result = await Service.RunAsync("""
            /* Leading comment */ WITH items(x) AS (SELECT 1 UNION ALL SELECT 2)
            SELECT count(*) AS total, 'semicolon;inside' AS text_value, char(0)||'after' AS nul_text,
                   x'00ff' AS binary_value, NULL AS missing FROM items; /* trailing comment */
            """);
        Assert.Equal(new[] { "2", "semicolon;inside", "\0after", "00FF", null }, result.Rows[0]);
        Assert.Null(result.Limit);
    }

    [Fact]
    public async Task QueryNeverCreatesPersistentViewsOrChangesSchemaOrRevision()
    {
        await SeedAsync();
        var bytes = await File.ReadAllBytesAsync(DatabasePath);
        foreach (var example in InventoryReportingSchema.Examples) await Service.RunAsync(example.Sql);
        Assert.Equal(bytes, await File.ReadAllBytesAsync(DatabasePath));
        using var connection = new SqliteConnection($"Data Source={DatabasePath};Mode=ReadOnly;Pooling=False");
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT COUNT(*) FROM sqlite_schema WHERE name GLOB 'r_*'";
        Assert.Equal(0L, command.ExecuteScalar());
    }

    [Fact]
    public async Task RowColumnSqlValueAndUtf8PayloadLimitsAreExplicit()
    {
        await SeedAsync();
        const string numbers = "WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<";
        var exact = await Service.RunAsync(numbers + "1000) SELECT i FROM n");
        Assert.Equal(1000, exact.Rows.Count);
        Assert.Null(exact.Limit);
        var truncated = await Service.RunAsync(numbers + "1001) SELECT i FROM n");
        Assert.Equal(1000, truncated.Rows.Count);
        Assert.Contains("1,000-row", truncated.Limit);
        var bytes = await Service.RunAsync(numbers + "1000) SELECT replace(hex(zeroblob(1000)), '00', 'é') AS value FROM n");
        Assert.Contains("1 MiB", bytes.Limit);
        Assert.Equal((InventoryQueryService.MaximumResultBytes - Encoding.UTF8.GetByteCount("value")) / 2000, bytes.Rows.Count);
        var oversized = await Service.RunAsync("SELECT zeroblob(600000) AS blob");
        Assert.Empty(oversized.Rows);
        Assert.Contains("1 MiB", oversized.Limit);
        await Assert.ThrowsAsync<InvalidOperationException>(() => Service.RunAsync("SELECT randomblob(8388609)"));
        await Assert.ThrowsAsync<InvalidOperationException>(() => Service.RunAsync("SELECT " + string.Join(",", Enumerable.Repeat("1", 65))));
        await Assert.ThrowsAsync<InvalidOperationException>(() => Service.RunAsync("SELECT 1 --" + new string('x', 65536)));
    }

    private const string Expensive = "WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n) SELECT sum(i) FROM n";

    [Fact]
    public async Task DeadlineStopsExpensiveWorkAndReleasesReadConnection()
    {
        var (store, data) = await SeedAsync();
        var clock = Stopwatch.StartNew();
        await Assert.ThrowsAsync<TimeoutException>(() => Service.RunAsync(Expensive));
        Assert.InRange(clock.Elapsed.TotalSeconds, 4.5, 8);
        await store.SaveAsync(data with { Names = new Dictionary<string, string> { [Mac] = "After timeout" } }, data.Revision);
    }

    [Fact]
    public async Task CancellationIsPromptAndConcurrentSaveKeepsRevisionAndHistory()
    {
        var (store, data) = await SeedAsync();
        using var cancel = new CancellationTokenSource();
        var query = Service.RunAsync(Expensive, cancel.Token);
        await Task.Delay(150);
        var save = Task.Run(() => store.SaveAsync(data with
            { Names = new Dictionary<string, string> { [Mac] = "Saved concurrently" } }, data.Revision));
        var clock = Stopwatch.StartNew();
        cancel.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => query);
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(2));
        var saved = await save;
        var loaded = (await new DeviceInventoryStore(DatabasePath).LoadAsync())!;
        Assert.NotEqual(data.Revision, saved.Revision);
        Assert.Equal(saved.Revision, loaded.Revision);
        Assert.Equal(data.Devices[Mac].ScanHistory, loaded.Devices[Mac].ScanHistory);
        Assert.Equal("Saved concurrently", (await Service.RunAsync("SELECT name FROM r_names WHERE device_kind='mac'")).Rows[0][0]);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Service.RunAsync("SELECT 1", cancel.Token));
    }

    [Fact]
    public async Task ContentionReturnsExplicitErrorWithoutWaitingForFullDeadline()
    {
        await SeedAsync();
        using var connection = new SqliteConnection($"Data Source={DatabasePath};Pooling=False");
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = "BEGIN EXCLUSIVE";
        command.ExecuteNonQuery();
        var clock = Stopwatch.StartNew();
        var error = await Assert.ThrowsAsync<InvalidOperationException>(() => Service.RunAsync("SELECT * FROM r_devices"));
        Assert.Contains("locked", error.Message);
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(3));
    }

    private void Execute(string sql)
    {
        using var connection = new SqliteConnection($"Data Source={DatabasePath};Pooling=False");
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }
}
