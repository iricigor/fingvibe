using System.Security.Cryptography;
using System.Text.Json;
using FingVibe.Core.Models;
using Microsoft.Data.Sqlite;

namespace FingVibe.Core.Storage;

public sealed partial class DeviceInventoryStore
{
    private readonly string _jsonPath;
    private readonly string _databasePath;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private DeviceInventoryData? _loaded;
    private bool _metadataOnly;

    public DeviceInventoryStore(string path)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path);
        _jsonPath = Path.ChangeExtension(path, ".json");
        _databasePath = Path.ChangeExtension(path, ".sqlite");
    }

    public async Task<DeviceInventoryData?> LoadAsync(CancellationToken cancellationToken = default)
        => await LoadAsync(metadataOnly: false, cancellationToken);

    public async Task<DeviceInventoryData?> LoadMetadataAsync(CancellationToken cancellationToken = default)
        => await LoadAsync(metadataOnly: true, cancellationToken);

    private async Task<DeviceInventoryData?> LoadAsync(bool metadataOnly, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            _loaded = null;
            _metadataOnly = metadataOnly;
            if (!File.Exists(_databasePath))
            {
                var directory = Path.GetDirectoryName(_databasePath)!;
                if (!Directory.Exists(directory)) return _loaded = null;
                await using var fileLock = LockFile();
                if (!File.Exists(_databasePath))
                {
                    var data = await LoadMigrationAsync(cancellationToken);
                    if (data is null) return _loaded = null;
                    await PublishAsync(data.Data, cancellationToken, data);
                }
            }
            using var connection = Open(_databasePath);
            await using (var schemaLock = LockFile())
                EnsureHistorySchema(connection, cancellationToken);
            using var transaction = connection.BeginTransaction();
            var revision = ReadRevision(connection, transaction);
            var devices = ReadEntities<InventoryDevice>(connection, transaction, "devices", cancellationToken);
            var slots = ReadEntities<PrivateVirtualDevice>(connection, transaction, "virtual_devices", cancellationToken);
            var histories = metadataOnly ? ReadHistorySnapshots(connection, transaction, cancellationToken)
                : ReadHistories(connection, transaction, cancellationToken)
                    .ToDictionary(pair => pair.Key, pair => (IReadOnlyList<DeviceScanObservation>)pair.Value);
            foreach (var key in devices.Keys.ToArray())
                devices[key] = devices[key] with { ScanHistory = histories.GetValueOrDefault(("mac", key)) ?? [] };
            foreach (var key in slots.Keys.ToArray())
                slots[key] = slots[key] with { ScanHistory = histories.GetValueOrDefault(("virtual", key)) ?? [] };
            if (histories.Keys.Any(key => key.Kind == "mac" ? !devices.ContainsKey(key.Id)
                    : key.Kind != "virtual" || !slots.ContainsKey(key.Id)))
                throw new InvalidDataException("Saved scan history has no matching device.");
            var people = ReadEntities<ManagedPerson>(connection, transaction, "people", cancellationToken);
            var rooms = ReadEntities<ManagedRoom>(connection, transaction, "rooms", cancellationToken);
            var baselines = ReadEntities<DeviceDiscoveryBaseline>(connection, transaction, "baselines", cancellationToken);
            if (slots.Any(pair => pair.Key != pair.Value.Id.ToString("D"))
                || people.Any(pair => pair.Key != pair.Value.Id.ToString("D"))
                || rooms.Any(pair => pair.Key != pair.Value.Id.ToString("D"))
                || baselines.Any(pair => pair.Key != BaselineKey(pair.Value)))
                throw new InvalidDataException("The inventory contains mismatched saved identities.");
            var dataLoaded = new DeviceInventoryData(revision, devices,
                ReadEntities<string>(connection, transaction, "names", cancellationToken),
                ReadEntities<DeviceClassificationOverride>(connection, transaction, "classifications", cancellationToken),
                new PeopleRoomsData(people.Values.ToArray(), rooms.Values.ToArray(),
                    ReadEntities<DeviceAssignment>(connection, transaction, "assignments", cancellationToken)))
            {
                VirtualDevices = slots.Values.ToArray(),
                DiscoveryBaselines = baselines.Values.ToArray(),
                LatestScan = ReadLatestScan(connection, transaction)
            };
            Validate(dataLoaded, metadataOnly ? dataLoaded : null);
            transaction.Commit();
            return _loaded = dataLoaded;
        }
        catch (SqliteException exception) { throw StorageError(exception); }
        catch (Exception exception) when (exception is JsonException or ArgumentException or FormatException)
        {
            throw new InvalidDataException("The SQLite inventory contains invalid saved data.", exception);
        }
        finally { _gate.Release(); }
    }

    public async Task<DeviceInventoryData> SaveAsync(
        DeviceInventoryData data, Guid expectedRevision, CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try
        {
            var directory = Path.GetDirectoryName(_databasePath)
                ?? throw new ArgumentException("The inventory path must include a directory.");
            Directory.CreateDirectory(directory);
            await using var fileLock = LockFile();
            if (!File.Exists(_databasePath))
            {
                var migration = await LoadMigrationAsync(cancellationToken);
                if (migration is not null)
                {
                    await PublishAsync(migration.Data, cancellationToken, migration);
                    _loaded = migration.Data;
                }
                else
                {
                    CheckRevision(Guid.Empty, expectedRevision);
                    Validate(data);
                    var initial = data with { Revision = Guid.NewGuid() };
                    await PublishAsync(initial, cancellationToken);
                    return _loaded = _metadataOnly ? SnapshotHistories(initial) : Committed(initial);
                }
            }
            using var connection = Open(_databasePath);
            EnsureHistorySchema(connection, cancellationToken);
            using var transaction = connection.BeginTransaction();
            CheckRevision(ReadRevision(connection, transaction), expectedRevision);
            if (_loaded is null || _loaded.Revision != expectedRevision)
                throw new InvalidOperationException("Load the saved inventory before changing it.");
            Validate(data, _loaded);
            if (data.LatestScan is { } checkpoint && _loaded.LatestScan is { } previous
                && checkpoint.ScanId != Guid.Empty && checkpoint.ScanId == previous.ScanId
                && (checkpoint.NetworkId != previous.NetworkId || checkpoint.Subnet != previous.Subnet
                    || previous.State == ScanCheckpointState.Complete && checkpoint.State != ScanCheckpointState.Complete))
                throw new InvalidOperationException("A logical scan checkpoint cannot change network scope or downgrade a finalized scan.");
            var updated = data with { Revision = Guid.NewGuid() };
            WriteChanges(connection, transaction, updated, _loaded, cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            transaction.Commit();
            return _loaded = _metadataOnly ? SnapshotHistories(updated) : Committed(updated);
        }
        catch (SqliteException exception) { throw StorageError(exception); }
        finally { _gate.Release(); }
    }

    private FileStream LockFile() => new(_jsonPath + ".lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);

    internal static SqliteConnection Open(string path)
    {
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = path, Mode = SqliteOpenMode.ReadWrite, Pooling = false, DefaultTimeout = 5
        }.ToString());
        try
        {
            connection.Open();
            Execute(connection, null, "PRAGMA synchronous=FULL");
            return connection;
        }
        catch { connection.Dispose(); throw; }
    }

    private sealed record Migration(DeviceInventoryData Data, string[] Paths, string?[] Fingerprints);

    private async Task<Migration?> LoadMigrationAsync(CancellationToken cancellationToken)
    {
        var paths = new[] { _jsonPath }.Concat(new[] { "device-names.json", "device-classifications.json", "people-rooms.json" }
            .Select(name => Path.Combine(Path.GetDirectoryName(_jsonPath)!, name))).ToArray();
        var before = await FingerprintsAsync(paths, cancellationToken);
        var data = await LoadJsonAsync(cancellationToken);
        if (data is null && before.Skip(1).Any(value => value is not null))
        {
            data = DeviceInventoryData.Empty with
            {
                Revision = Guid.NewGuid(),
                Names = await new DeviceNameOverrideStore(paths[1]).LoadAsync(cancellationToken),
                Classifications = await new DeviceClassificationOverrideStore(paths[2]).LoadAsync(cancellationToken),
                PeopleRooms = await new PeopleRoomsStore(paths[3]).LoadAsync(cancellationToken)
            };
            Validate(data);
        }
        if (!before.SequenceEqual(await FingerprintsAsync(paths, cancellationToken)))
            throw new InvalidOperationException("Legacy saved data changed during migration. Restart before migrating it.");
        return data is null ? null : new(data, paths, before);
    }

    private static async Task<string?[]> FingerprintsAsync(string[] paths, CancellationToken cancellationToken)
    {
        var result = new string?[paths.Length];
        for (var i = 0; i < paths.Length; i++)
        {
            try
            {
                await using var stream = File.OpenRead(paths[i]);
                result[i] = Convert.ToHexString(await SHA256.HashDataAsync(stream, cancellationToken));
            }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
        }
        return result;
    }

    private async Task PublishAsync(DeviceInventoryData data, CancellationToken cancellationToken, Migration? migration = null)
    {
        var temporary = _databasePath + $".{Guid.NewGuid():N}.tmp";
        try
        {
            using (var connection = new SqliteConnection(new SqliteConnectionStringBuilder
                   { DataSource = temporary, Pooling = false }.ToString()))
            {
                await connection.OpenAsync(cancellationToken);
                Execute(connection, null, "PRAGMA synchronous=FULL");
                using var transaction = connection.BeginTransaction();
                Execute(connection, transaction, """
                    CREATE TABLE inventory (id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL, revision TEXT NOT NULL);
                    INSERT INTO inventory VALUES(1, 1, '');
                    CREATE TABLE scan_history (
                        kind TEXT NOT NULL CHECK(kind IN ('mac','virtual')), id TEXT NOT NULL,
                        sequence INTEGER NOT NULL, completed_at TEXT NOT NULL, network_id TEXT,
                        subnet TEXT NOT NULL, present INTEGER NOT NULL CHECK(present IN (0,1)),
                        PRIMARY KEY(kind,id,sequence));
                    """);
                CreateHistoryIndexes(connection, transaction);
                foreach (var table in EntityTables)
                    Execute(connection, transaction, $"CREATE TABLE {table} (id TEXT PRIMARY KEY, data TEXT NOT NULL)");
                WriteChanges(connection, transaction, data, DeviceInventoryData.Empty, cancellationToken);
                cancellationToken.ThrowIfCancellationRequested();
                transaction.Commit();
            }
            cancellationToken.ThrowIfCancellationRequested();
            if (migration is not null && !migration.Fingerprints.SequenceEqual(
                    await FingerprintsAsync(migration.Paths, cancellationToken)))
                throw new InvalidOperationException("Legacy saved data changed during migration. Restart before migrating it.");
            File.Move(temporary, _databasePath, overwrite: false);
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
            if (File.Exists(temporary + "-journal")) File.Delete(temporary + "-journal");
        }
    }

    private static readonly string[] EntityTables =
        ["devices", "virtual_devices", "names", "classifications", "people", "rooms", "assignments", "baselines"];

    private static void WriteChanges(SqliteConnection connection, SqliteTransaction transaction,
        DeviceInventoryData data, DeviceInventoryData previous, CancellationToken cancellationToken)
    {
        if (data.LatestScan is { } checkpoint)
            Execute(connection, transaction, """
                INSERT INTO scan_checkpoint(id,data) VALUES(1,$data)
                ON CONFLICT(id) DO UPDATE SET data=excluded.data
                """, ("$data", ScanSnapshotStore.Serialize(checkpoint)));
        Sync(connection, transaction, "devices",
            data.Devices.ToDictionary(pair => pair.Key, pair => pair.Value with { ScanHistory = [] }),
            previous.Devices.ToDictionary(pair => pair.Key, pair => pair.Value with { ScanHistory = [] }), cancellationToken);
        Sync(connection, transaction, "virtual_devices",
            data.VirtualDevices.ToDictionary(slot => slot.Id.ToString("D"), slot => slot with { ScanHistory = [] }),
            previous.VirtualDevices.ToDictionary(slot => slot.Id.ToString("D"), slot => slot with { ScanHistory = [] }), cancellationToken);
        Sync(connection, transaction, "names", data.Names, previous.Names, cancellationToken);
        Sync(connection, transaction, "classifications", data.Classifications, previous.Classifications, cancellationToken);
        Sync(connection, transaction, "people", data.PeopleRooms.People.ToDictionary(item => item.Id.ToString("D")),
            previous.PeopleRooms.People.ToDictionary(item => item.Id.ToString("D")), cancellationToken);
        Sync(connection, transaction, "rooms", data.PeopleRooms.Rooms.ToDictionary(item => item.Id.ToString("D")),
            previous.PeopleRooms.Rooms.ToDictionary(item => item.Id.ToString("D")), cancellationToken);
        Sync(connection, transaction, "assignments", data.PeopleRooms.Assignments, previous.PeopleRooms.Assignments, cancellationToken);
        Sync(connection, transaction, "baselines", data.DiscoveryBaselines.ToDictionary(BaselineKey),
            previous.DiscoveryBaselines.ToDictionary(BaselineKey), cancellationToken);
        foreach (var (key, device) in data.Devices)
            AppendHistory(connection, transaction, "mac", key, device.ScanHistory,
                previous.Devices.GetValueOrDefault(key)?.ScanHistory, cancellationToken);
        foreach (var slot in data.VirtualDevices)
            AppendHistory(connection, transaction, "virtual", slot.Id.ToString("D"), slot.ScanHistory,
                previous.VirtualDevices.FirstOrDefault(item => item.Id == slot.Id)?.ScanHistory, cancellationToken);
        if (previous.Devices.Keys.Except(data.Devices.Keys).Any()
            || previous.VirtualDevices.Any(slot => data.VirtualDevices.All(item => item.Id != slot.Id)))
            throw new InvalidOperationException("Removing saved device identities is not supported.");
        Execute(connection, transaction, "UPDATE inventory SET revision=$revision WHERE id=1",
            ("$revision", data.Revision.ToString("D")));
    }

    private static ScanSnapshot? ReadLatestScan(SqliteConnection connection, SqliteTransaction transaction)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT data FROM scan_checkpoint WHERE id=1";
        return command.ExecuteScalar() is string json ? ScanSnapshotStore.Deserialize(json) : null;
    }

    private static string BaselineKey(DeviceDiscoveryBaseline item) => JsonSerializer.Serialize(item, Options);

    private static DeviceInventoryData Committed(DeviceInventoryData data) => data with
    {
        Devices = data.Devices.ToDictionary(pair => pair.Key, pair => pair.Value with
        {
            ScanHistory = pair.Value.ScanHistory is AppendedScanHistory history ? history.Committed : pair.Value.ScanHistory
        }),
        VirtualDevices = data.VirtualDevices.Select(slot => slot with
        {
            ScanHistory = slot.ScanHistory is AppendedScanHistory history ? history.Committed : slot.ScanHistory
        }).ToArray()
    };

    private static void Sync<T>(SqliteConnection connection, SqliteTransaction transaction, string table,
        IReadOnlyDictionary<string, T> data, IReadOnlyDictionary<string, T> previous, CancellationToken cancellationToken)
    {
        foreach (var key in previous.Keys.Except(data.Keys))
        {
            cancellationToken.ThrowIfCancellationRequested();
            Execute(connection, transaction, $"DELETE FROM {table} WHERE id=$id", ("$id", key));
        }
        foreach (var (key, value) in data)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var json = JsonSerializer.Serialize(value, Options);
            if (previous.TryGetValue(key, out var old) && json == JsonSerializer.Serialize(old, Options)) continue;
            Execute(connection, transaction, $"INSERT INTO {table}(id,data) VALUES($id,$data) ON CONFLICT(id) DO UPDATE SET data=excluded.data",
                ("$id", key), ("$data", json));
        }
    }

    private static IReadOnlyList<DeviceScanObservation> AppendedHistory(
        IReadOnlyList<DeviceScanObservation> history, IReadOnlyList<DeviceScanObservation>? previous)
    {
        if (history is null) throw new InvalidDataException("Scan history is missing.");
        if (previous is null || previous.Count == 0) return history;
        if (ReferenceEquals(history, previous)) return [];
        var additions = new List<DeviceScanObservation>();
        var cursor = history;
        while (cursor is AppendedScanHistory appended && cursor.Count > previous.Count)
        {
            additions.Add(appended.Added);
            cursor = appended.Previous;
        }
        if (ReferenceEquals(cursor, previous))
        {
            additions.Reverse();
            return additions;
        }
        if (history.Count < previous.Count || !history.Take(previous.Count).SequenceEqual(previous))
            throw new InvalidDataException("Saved scan observations cannot be removed or changed.");
        return history.Skip(previous.Count).ToArray();
    }

    private static void AppendHistory(SqliteConnection connection, SqliteTransaction transaction, string kind,
        string id, IReadOnlyList<DeviceScanObservation> history, IReadOnlyList<DeviceScanObservation>? previous,
        CancellationToken cancellationToken)
    {
        var sequence = previous?.Count ?? 0;
        foreach (var item in AppendedHistory(history, previous))
        {
            cancellationToken.ThrowIfCancellationRequested();
            Execute(connection, transaction, """
                INSERT INTO scan_history VALUES($kind,$id,$sequence,$time,$network,$subnet,$present,$ticks)
                """, ("$kind", kind), ("$id", id), ("$sequence", sequence++),
                ("$time", item.CompletedAt.ToString("O")), ("$network", item.NetworkId),
                ("$subnet", item.Subnet), ("$present", item.Present ? 1 : 0), ("$ticks", item.CompletedAt.UtcTicks));
        }
    }

    private static Dictionary<string, T> ReadEntities<T>(SqliteConnection connection, SqliteTransaction transaction,
        string table, CancellationToken cancellationToken)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = $"SELECT id,data FROM {table} ORDER BY rowid";
        using var reader = command.ExecuteReader();
        var data = new Dictionary<string, T>();
        while (reader.Read())
        {
            cancellationToken.ThrowIfCancellationRequested();
            data.Add(reader.GetString(0), JsonSerializer.Deserialize<T>(reader.GetString(1), Options)
                ?? throw new InvalidDataException($"The inventory contains invalid {table}."));
        }
        return data;
    }

    private static Dictionary<(string Kind, string Id), List<DeviceScanObservation>> ReadHistories(
        SqliteConnection connection, SqliteTransaction transaction, CancellationToken cancellationToken)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT kind,id,sequence,completed_at,network_id,subnet,present FROM scan_history ORDER BY kind,id,sequence";
        using var reader = command.ExecuteReader();
        var histories = new Dictionary<(string, string), List<DeviceScanObservation>>();
        while (reader.Read())
        {
            cancellationToken.ThrowIfCancellationRequested();
            var key = (reader.GetString(0), reader.GetString(1));
            if (!histories.TryGetValue(key, out var history)) histories.Add(key, history = []);
            if (reader.GetInt32(2) != history.Count || reader.GetInt32(6) is not (0 or 1))
                throw new InvalidDataException("The inventory contains invalid scan sequences or states.");
            history.Add(new(DateTimeOffset.Parse(reader.GetString(3), System.Globalization.CultureInfo.InvariantCulture),
                reader.IsDBNull(4) ? null : reader.GetString(4), reader.GetString(5), reader.GetInt32(6) == 1));
        }
        return histories;
    }

    private static Guid ReadRevision(SqliteConnection connection, SqliteTransaction transaction)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT id,version,revision FROM inventory";
        using var reader = command.ExecuteReader();
        if (!reader.Read() || reader.GetInt32(0) != 1 || reader.GetInt32(1) != 2
            || !Guid.TryParse(reader.GetString(2), out var revision) || revision == Guid.Empty || reader.Read())
            throw new InvalidDataException("The SQLite inventory has an unsupported or incomplete format.");
        return revision;
    }

    private static void CheckRevision(Guid actual, Guid expected)
    {
        if (actual != expected)
            throw new InvalidOperationException("Saved device data changed in another app instance. Restart and analyze again before saving.");
    }

    internal static void Execute(SqliteConnection connection, SqliteTransaction? transaction, string sql,
        params (string Name, object? Value)[] parameters)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = sql;
        foreach (var (name, value) in parameters) command.Parameters.AddWithValue(name, value ?? DBNull.Value);
        command.ExecuteNonQuery();
    }

    internal static IOException StorageError(SqliteException exception) =>
        new($"The SQLite inventory could not be read or written: {exception.Message}", exception);
}
