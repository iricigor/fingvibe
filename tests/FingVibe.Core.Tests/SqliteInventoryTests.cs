using System.Net;
using System.Net.NetworkInformation;
using System.Text.Json.Nodes;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Microsoft.Data.Sqlite;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class SqliteInventoryTests : IDisposable
{
    private const string Mac = "001122334455";
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"fingvibe-sqlite-{Guid.NewGuid():N}");
    private string JsonPath => Path.Combine(_directory, "device-inventory.json");
    private string DatabasePath => Path.ChangeExtension(JsonPath, ".sqlite");
    private static readonly DateTimeOffset Start = DateTimeOffset.Parse("2026-11-01T12:00:00+02:00");

    private static DeviceInventoryData Scan(DeviceInventoryData data, int minute) =>
        data.ObserveCompletedScan("network", new("192.0.2.0/24", Start.AddMinutes(minute),
            [new(IPAddress.Parse("192.0.2.1"), HostStatus.Alive, 1, TimeSpan.FromMilliseconds(1),
                null, PhysicalAddress.Parse(Mac), "Example")]));

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    [InlineData(4)]
    public async Task MigrationPreservesOriginalAndRepeatedLoadsNeverDuplicateHistory(int version)
    {
        var original = await InventoryJsonFixture.WriteAsync(JsonPath, Scan(Scan(DeviceInventoryData.Empty, 0), 1));
        var json = JsonNode.Parse(await File.ReadAllTextAsync(JsonPath))!;
        json["version"] = version;
        if (version < 3) json["data"]!["devices"]![Mac]!.AsObject().Remove("scanHistory");
        if (version < 4) json["data"]!.AsObject().Remove("discoveryBaselines");
        await File.WriteAllTextAsync(JsonPath, json.ToJsonString());
        var bytes = await File.ReadAllBytesAsync(JsonPath);
        for (var i = 0; i < 3; i++)
        {
            var loaded = (await new DeviceInventoryStore(DatabasePath).LoadAsync())!;
            Assert.Equal(original.Revision, loaded.Revision);
            Assert.Equal(Start, loaded.Devices[Mac].Observations[0].FirstSeen);
            Assert.Equal(InventoryDeviceStatus.Unknown, loaded.Devices[Mac].Status);
            Assert.Equal(version < 3 ? 0 : 2, loaded.Devices[Mac].ScanHistory.Count);
            Assert.Equal(version < 4 ? 0 : 1, loaded.DiscoveryBaselines.Count);
            Assert.Equal(bytes, await File.ReadAllBytesAsync(JsonPath));
        }
    }

    [Fact]
    public async Task LegacyOnlyMigrationKeepsAssignmentsCorrectionsIconsAndOriginals()
    {
        Directory.CreateDirectory(_directory);
        var person = new ManagedPerson(Guid.NewGuid(), "Alice", "A", IconId: "profile");
        var room = new ManagedRoom(Guid.NewGuid(), "Office", "O", IconId: "office");
        var peopleRooms = new PeopleRoomsData([person], [room]).AssignPerson(Mac, person.Id).AssignRoom(Mac, room.Id);
        await new DeviceNameOverrideStore(Path.Combine(_directory, "device-names.json"))
            .SaveAsync(new Dictionary<string, string> { [Mac] = "My device" });
        await new DeviceClassificationOverrideStore(Path.Combine(_directory, "device-classifications.json"))
            .SaveAsync(new Dictionary<string, DeviceClassificationOverride> { [Mac] = new(Type: DeviceType.Computer) });
        await new PeopleRoomsStore(Path.Combine(_directory, "people-rooms.json")).SaveAsync(peopleRooms);
        var originals = Directory.GetFiles(_directory).ToDictionary(path => path, File.ReadAllText);
        var loaded = (await new DeviceInventoryStore(DatabasePath).LoadAsync())!;
        Assert.Empty(loaded.Devices);
        Assert.Equal("My device", loaded.Names[Mac]);
        Assert.Equal(DeviceType.Computer, loaded.Classifications[Mac].Type);
        Assert.Equal(person, Assert.Single(loaded.PeopleRooms.People));
        Assert.Equal(room, Assert.Single(loaded.PeopleRooms.Rooms));
        Assert.Equal(peopleRooms.Assignments[Mac], loaded.PeopleRooms.Assignments[Mac]);
        foreach (var (path, content) in originals) Assert.Equal(content, await File.ReadAllTextAsync(path));
    }

    [Fact]
    public async Task InvalidLegacyDataCannotPublishDatabaseOrFallBackToEmpty()
    {
        Directory.CreateDirectory(_directory);
        await File.WriteAllTextAsync(Path.Combine(_directory, "people-rooms.json"), "invalid");
        var store = new DeviceInventoryStore(DatabasePath);
        await Assert.ThrowsAsync<InvalidDataException>(() => store.LoadAsync());
        await Assert.ThrowsAsync<InvalidDataException>(() => store.SaveAsync(DeviceInventoryData.Empty, Guid.Empty));
        Assert.False(File.Exists(DatabasePath));
    }

    [Fact]
    public async Task InterruptedMigrationRetriesOriginalButExistingInvalidDatabaseNeverFallsBack()
    {
        await InventoryJsonFixture.WriteAsync(JsonPath, Scan(DeviceInventoryData.Empty, 0));
        await File.WriteAllTextAsync(DatabasePath + ".abandoned.tmp", "partial migration");
        var store = new DeviceInventoryStore(JsonPath);
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => store.LoadAsync(cancelled.Token));
        Assert.False(File.Exists(DatabasePath));
        Assert.Single((await store.LoadAsync())!.Devices[Mac].ScanHistory);
        await File.WriteAllTextAsync(DatabasePath, "broken authoritative database");
        await Assert.ThrowsAsync<IOException>(() => store.LoadAsync());
        await Assert.ThrowsAsync<IOException>(() => store.SaveAsync(DeviceInventoryData.Empty, Guid.Empty));
        Assert.Equal("broken authoritative database", await File.ReadAllTextAsync(DatabasePath));
    }

    [Fact]
    public async Task MetadataUpdatesNeverTouchHistoryAndScansOnlyAppend()
    {
        var store = new DeviceInventoryStore(JsonPath);
        var data = DeviceInventoryData.Empty;
        for (var i = 0; i < 1000; i++) data = Scan(data, i);
        var saved = await store.SaveAsync(data, Guid.Empty);
        Sql("""
            CREATE TRIGGER no_history_update BEFORE UPDATE ON scan_history BEGIN SELECT RAISE(ABORT,'history update'); END;
            CREATE TRIGGER no_history_delete BEFORE DELETE ON scan_history BEGIN SELECT RAISE(ABORT,'history delete'); END;
            CREATE TRIGGER no_history_insert BEFORE INSERT ON scan_history BEGIN SELECT RAISE(ABORT,'history insert'); END;
            """);
        saved = await store.SaveAsync(saved with { Names = new Dictionary<string, string> { [Mac] = "Renamed" } }, saved.Revision);
        Assert.Equal(1000L, Scalar("SELECT COUNT(*) FROM scan_history"));
        Sql("DROP TRIGGER no_history_insert");
        saved = await store.SaveAsync(Scan(saved, 1000), saved.Revision);
        Assert.Equal(1001L, Scalar("SELECT COUNT(*) FROM scan_history"));
        var restored = (await new DeviceInventoryStore(JsonPath).LoadAsync())!;
        Assert.Equal("Renamed", restored.Names[Mac]);
        Assert.Equal(saved.Devices[Mac].ScanHistory, restored.Devices[Mac].ScanHistory);
    }

    [Fact]
    public async Task SavingMetadataAndAppendedScansDoesNotEnumerateSavedHistory()
    {
        var store = new DeviceInventoryStore(JsonPath);
        var data = Scan(DeviceInventoryData.Empty, 0);
        var history = new GuardedHistory(data.Devices[Mac].ScanHistory);
        data = data with { Devices = new Dictionary<string, InventoryDevice>
            { [Mac] = data.Devices[Mac] with { ScanHistory = history } } };
        var saved = await store.SaveAsync(data, Guid.Empty);
        history.RejectReads = true;
        saved = await store.SaveAsync(saved with { Names = new Dictionary<string, string> { [Mac] = "Name" } }, saved.Revision);
        history.RejectReads = false;
        var next = Scan(saved, 1);
        history.RejectReads = true;
        await store.SaveAsync(next, saved.Revision);
        Assert.Equal(2L, Scalar("SELECT COUNT(*) FROM scan_history"));
    }

    [Fact]
    public async Task TransactionFailureRollsBackMetadataHistoryBaselineAndRevisionThenRetryCommits()
    {
        var store = new DeviceInventoryStore(JsonPath);
        var saved = await store.SaveAsync(Scan(DeviceInventoryData.Empty, 0), Guid.Empty);
        var next = Scan(saved, 1) with
        {
            Names = new Dictionary<string, string> { [Mac] = "Unsaved" },
            DiscoveryBaselines = [.. saved.DiscoveryBaselines, new("second-network", "192.0.2.0/24")]
        };
        Sql("CREATE TRIGGER fail_history BEFORE INSERT ON scan_history BEGIN SELECT RAISE(ABORT,'synthetic disk failure'); END");
        await Assert.ThrowsAsync<IOException>(() => store.SaveAsync(next, saved.Revision));
        var loaded = (await new DeviceInventoryStore(JsonPath).LoadAsync())!;
        Assert.Equal(saved.Revision, loaded.Revision);
        Assert.Empty(loaded.Names);
        Assert.Single(loaded.DiscoveryBaselines);
        Assert.Single(loaded.Devices[Mac].ScanHistory);
        Sql("DROP TRIGGER fail_history");
        await store.SaveAsync(next, saved.Revision);
        loaded = (await new DeviceInventoryStore(JsonPath).LoadAsync())!;
        Assert.Equal("Unsaved", loaded.Names[Mac]);
        Assert.Equal(2, loaded.DiscoveryBaselines.Count);
        Assert.Equal(2, loaded.Devices[Mac].ScanHistory.Count);
    }

    [Fact]
    public async Task StaleInstanceCannotOverwriteDeliveredScanOrMetadata()
    {
        var first = new DeviceInventoryStore(JsonPath);
        var saved = await first.SaveAsync(Scan(DeviceInventoryData.Empty, 0), Guid.Empty);
        var second = new DeviceInventoryStore(JsonPath);
        var stale = (await second.LoadAsync())!;
        var delivered = await first.SaveAsync(Scan(saved, 1), saved.Revision);
        await Assert.ThrowsAsync<InvalidOperationException>(() => second.SaveAsync(stale with
            { Names = new Dictionary<string, string> { [Mac] = "Stale" } }, stale.Revision));
        var loaded = (await second.LoadAsync())!;
        Assert.Equal(delivered.Revision, loaded.Revision);
        Assert.Empty(loaded.Names);
        Assert.Equal(2, loaded.Devices[Mac].ScanHistory.Count);
    }

    [Fact]
    public async Task HistoryReplacementCannotEraseOrAlterSavedObservations()
    {
        var store = new DeviceInventoryStore(JsonPath);
        var saved = await store.SaveAsync(Scan(DeviceInventoryData.Empty, 0), Guid.Empty);
        var changed = saved with { Devices = new Dictionary<string, InventoryDevice>
            { [Mac] = saved.Devices[Mac] with { ScanHistory = [] } } };
        await Assert.ThrowsAsync<InvalidDataException>(() => store.SaveAsync(changed, saved.Revision));
        Assert.Single((await store.LoadAsync())!.Devices[Mac].ScanHistory);
    }

    private void Sql(string sql)
    {
        using var connection = new SqliteConnection($"Data Source={DatabasePath};Pooling=False");
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }

    private object? Scalar(string sql)
    {
        using var connection = new SqliteConnection($"Data Source={DatabasePath};Pooling=False");
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        return command.ExecuteScalar();
    }

    private sealed class GuardedHistory(IReadOnlyList<DeviceScanObservation> items) : IReadOnlyList<DeviceScanObservation>
    {
        internal bool RejectReads { get; set; }
        public int Count => items.Count;
        public DeviceScanObservation this[int index] => !RejectReads ? items[index]
            : throw new InvalidOperationException("Saved history was read during persistence.");
        public IEnumerator<DeviceScanObservation> GetEnumerator() => !RejectReads ? items.GetEnumerator()
            : throw new InvalidOperationException("Saved history was enumerated during persistence.");
        System.Collections.IEnumerator System.Collections.IEnumerable.GetEnumerator() => GetEnumerator();
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }
}
