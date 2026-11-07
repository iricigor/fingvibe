using System.Globalization;
using FingVibe.Core.Models;
using Microsoft.Data.Sqlite;

namespace FingVibe.Core.Storage;

public sealed partial class DeviceInventoryStore
{
    private static void CreateAnalyticsSchema(SqliteConnection connection, SqliteTransaction transaction)
    {
        Execute(connection, transaction, """
            CREATE TABLE scan_evidence (
                scan_id TEXT PRIMARY KEY NOT NULL, network_id TEXT, subnet TEXT NOT NULL,
                completed_at TEXT NOT NULL, completed_ticks INTEGER NOT NULL,
                state INTEGER NOT NULL CHECK(state IN (0,1,2)),
                unidentified_responses INTEGER NOT NULL CHECK(unidentified_responses>=0));
            CREATE INDEX evidence_scope_time ON scan_evidence(network_id,subnet,completed_ticks);
            ALTER TABLE scan_history ADD COLUMN scan_id TEXT;
            ALTER TABLE scan_history ADD COLUMN virtual_id TEXT;
            CREATE UNIQUE INDEX history_scan_identity ON scan_history(scan_id,kind,id) WHERE scan_id IS NOT NULL;
            UPDATE inventory SET version=3;
            """);
    }

    private static void WriteScanEvidence(SqliteConnection connection, SqliteTransaction transaction,
        DeviceInventoryData data, DeviceInventoryData previous, CancellationToken cancellationToken)
    {
        var writes = data.PendingScanEvidence;
        if (data.LatestScan is { ScanId: var id } latest && id != Guid.Empty
            && (previous.LatestScan is null || ScanEvidenceWrite.From(latest) != ScanEvidenceWrite.From(previous.LatestScan)))
            writes = [.. writes.Where(item => item.ScanId != id), ScanEvidenceWrite.From(latest)];
        foreach (var item in writes)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (item.ScanId == Guid.Empty || item.CompletedAt == default || !ValidSubnet(item.Subnet)
                || !Enum.IsDefined(item.State) || item.UnidentifiedResponses < 0
                || item.NetworkId is not null && string.IsNullOrWhiteSpace(item.NetworkId))
                throw new InvalidDataException("A scan evidence record is invalid.");
            using var command = connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText = """
                SELECT network_id,subnet,completed_at,state,unidentified_responses
                FROM scan_evidence WHERE scan_id=$id
                """;
            command.Parameters.AddWithValue("$id", item.ScanId.ToString("D"));
            using (var reader = command.ExecuteReader())
            {
                if (reader.Read())
                {
                    var network = reader.IsDBNull(0) ? null : reader.GetString(0);
                    var complete = reader.GetInt32(3) == (int)ScanCheckpointState.Complete;
                    if (network != item.NetworkId || reader.GetString(1) != item.Subnet
                        || complete && (item.State != ScanCheckpointState.Complete
                            || DateTimeOffset.Parse(reader.GetString(2), CultureInfo.InvariantCulture) != item.CompletedAt
                            || reader.GetInt32(4) != item.UnidentifiedResponses))
                        throw new InvalidOperationException("A logical scan cannot change scope or rewrite finalized evidence.");
                }
            }
            Execute(connection, transaction, """
                INSERT INTO scan_evidence VALUES($id,$network,$subnet,$time,$ticks,$state,$unknown)
                ON CONFLICT(scan_id) DO UPDATE SET completed_at=excluded.completed_at,
                    completed_ticks=excluded.completed_ticks,state=excluded.state,
                    unidentified_responses=excluded.unidentified_responses
                """, ("$id", item.ScanId.ToString("D")), ("$network", item.NetworkId), ("$subnet", item.Subnet),
                ("$time", item.CompletedAt.ToString("O")), ("$ticks", item.CompletedAt.UtcTicks),
                ("$state", (int)item.State), ("$unknown", item.UnidentifiedResponses));
        }
    }

    private static void ValidateScanLink(SqliteConnection connection, SqliteTransaction transaction,
        Guid scanId, DeviceScanObservation item)
    {
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            SELECT COUNT(*) FROM scan_evidence WHERE scan_id=$id AND network_id IS $network
                AND subnet=$subnet AND completed_ticks=$ticks AND state=0
            """;
        command.Parameters.AddWithValue("$id", scanId.ToString("D"));
        command.Parameters.AddWithValue("$network", (object?)item.NetworkId ?? DBNull.Value);
        command.Parameters.AddWithValue("$subnet", item.Subnet);
        command.Parameters.AddWithValue("$ticks", item.CompletedAt.UtcTicks);
        if ((long)command.ExecuteScalar()! != 1)
            throw new InvalidDataException("Device history does not match a completed logical scan.");
    }
}
