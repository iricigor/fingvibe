using System.Globalization;
using FingVibe.Core.Models;
using Microsoft.Data.Sqlite;

namespace FingVibe.Core.Storage;

public sealed partial class DeviceInventoryStore
{
    private static void CreateHistoryIndexes(SqliteConnection connection, SqliteTransaction transaction)
    {
        Execute(connection, transaction, """
            ALTER TABLE scan_history ADD COLUMN completed_ticks INTEGER NOT NULL DEFAULT 0;
            CREATE INDEX history_scope_time ON scan_history(kind,id,network_id,subnet,completed_ticks DESC,sequence ASC);
            CREATE INDEX history_scope_presence ON scan_history(kind,id,network_id,subnet,present,completed_ticks DESC,sequence ASC);
            CREATE TABLE history_counts(kind TEXT NOT NULL,id TEXT NOT NULL,count INTEGER NOT NULL,PRIMARY KEY(kind,id));
            INSERT INTO history_counts SELECT kind,id,COUNT(*) FROM scan_history GROUP BY kind,id;
            CREATE TRIGGER history_count_insert AFTER INSERT ON scan_history BEGIN
                INSERT INTO history_counts VALUES(NEW.kind,NEW.id,1)
                ON CONFLICT(kind,id) DO UPDATE SET count=count+1;
            END;
            UPDATE inventory SET version=2;
            CREATE TABLE IF NOT EXISTS scan_checkpoint(id INTEGER PRIMARY KEY CHECK(id=1),data TEXT NOT NULL);
            """);
    }

    private static void EnsureHistorySchema(SqliteConnection connection, CancellationToken cancellationToken)
    {
        using var versionCommand = connection.CreateCommand();
        versionCommand.CommandText = "SELECT version FROM inventory WHERE id=1";
        var version = Convert.ToInt32(versionCommand.ExecuteScalar(), CultureInfo.InvariantCulture);
        if (version == 2)
        {
            Execute(connection, null, "CREATE TABLE IF NOT EXISTS scan_checkpoint(id INTEGER PRIMARY KEY CHECK(id=1),data TEXT NOT NULL)");
            return;
        }
        if (version != 1) throw new InvalidDataException("The SQLite inventory has an unsupported format.");
        using var transaction = connection.BeginTransaction();
        CreateHistoryIndexes(connection, transaction);
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT kind,id,sequence,completed_at FROM scan_history ORDER BY kind,id,sequence";
        using (var reader = command.ExecuteReader())
        {
            (string Kind, string Id)? previous = null;
            var expectedSequence = 0;
            while (reader.Read())
            {
                cancellationToken.ThrowIfCancellationRequested();
                var identity = (reader.GetString(0), reader.GetString(1));
                if (previous != identity) { previous = identity; expectedSequence = 0; }
                if (reader.GetInt32(2) != expectedSequence++)
                    throw new InvalidDataException("The inventory contains invalid scan sequences.");
                var timestamp = DateTimeOffset.Parse(reader.GetString(3), CultureInfo.InvariantCulture);
                if (timestamp == default) throw new InvalidDataException("The inventory contains invalid scan timestamps.");
                Execute(connection, transaction, """
                    UPDATE scan_history SET completed_ticks=$ticks WHERE kind=$kind AND id=$id AND sequence=$sequence
                    """, ("$ticks", timestamp.UtcTicks), ("$kind", identity.Item1), ("$id", identity.Item2),
                    ("$sequence", reader.GetInt32(2)));
            }
        }
        cancellationToken.ThrowIfCancellationRequested();
        transaction.Commit();
    }

    private Dictionary<(string Kind, string Id), IReadOnlyList<DeviceScanObservation>> ReadHistorySnapshots(
        SqliteConnection connection, SqliteTransaction transaction, CancellationToken cancellationToken)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = "SELECT kind,id,count FROM history_counts";
        using var reader = command.ExecuteReader();
        var histories = new Dictionary<(string, string), IReadOnlyList<DeviceScanObservation>>();
        while (reader.Read())
        {
            cancellationToken.ThrowIfCancellationRequested();
            var count = reader.GetInt32(2);
            if (count <= 0) throw new InvalidDataException("The inventory contains invalid scan counts.");
            var key = (reader.GetString(0), reader.GetString(1));
            histories.Add(key, new SqliteScanHistory(_databasePath, key.Item1, key.Item2, count));
        }
        return histories;
    }

    private DeviceInventoryData SnapshotHistories(DeviceInventoryData data) => data with
    {
        Devices = data.Devices.ToDictionary(pair => pair.Key, pair => pair.Value with
        {
            ScanHistory = new SqliteScanHistory(_databasePath, "mac", pair.Key, pair.Value.ScanHistory.Count)
        }),
        VirtualDevices = data.VirtualDevices.Select(slot => slot with
        {
            ScanHistory = new SqliteScanHistory(_databasePath, "virtual", slot.Id.ToString("D"), slot.ScanHistory.Count)
        }).ToArray()
    };
}
