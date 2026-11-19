using System.Collections;
using System.Globalization;
using FingVibe.Core.Models;
using Microsoft.Data.Sqlite;

namespace FingVibe.Core.Storage;

internal sealed class SqliteScanHistory(string path, string kind, string id, int savedCount,
    IReadOnlyList<DeviceScanObservation>? pending = null) : IReadOnlyList<DeviceScanObservation>, IDeviceHistoryQuery
{
    private readonly IReadOnlyList<DeviceScanObservation> _pending = pending ?? [];
    internal string DatabasePath => path;
    private string Kind => kind;
    private string Id => id;
    private int SavedCount => savedCount;
    private IReadOnlyList<DeviceScanObservation> Pending => _pending;
    public int Count => checked(savedCount + _pending.Count);
    internal SqliteScanHistory WithPending(IReadOnlyList<DeviceScanObservation> additions) =>
        new(path, kind, id, savedCount, additions);

    public DeviceScanObservation this[int index]
    {
        get
        {
            if (index < 0 || index >= Count) throw new ArgumentOutOfRangeException(nameof(index));
            if (index >= savedCount) return _pending[index - savedCount];
            return Query(connection =>
                Read(connection, "sequence=$sequence", "sequence", 1, ("$sequence", index)).Single().Item);
        }
    }

    public IEnumerator<DeviceScanObservation> GetEnumerator()
    {
        // Explicit full-history consumers remain supported; routine callers use the bounded query API.
        for (var index = 0; index < Count; index++) yield return this[index];
    }
    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();

    private T Query<T>(Func<SqliteConnection, T> query)
    {
        try
        {
            using var connection = DeviceInventoryStore.Open(path);
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT count FROM history_counts WHERE kind=$kind AND id=$id";
            command.Parameters.AddWithValue("$kind", kind);
            command.Parameters.AddWithValue("$id", id);
            if (Convert.ToInt32(command.ExecuteScalar() ?? 0, CultureInfo.InvariantCulture) < savedCount)
                throw new InvalidDataException("Saved scan history changed or is incomplete. Reload the inventory.");
            if (_pending.Count > 0)
            {
                DeviceInventoryStore.Execute(connection, null, """
                    CREATE TEMP TABLE pending_history (
                        kind TEXT, id TEXT, sequence INTEGER, completed_at TEXT,
                        network_id TEXT, subnet TEXT, present INTEGER, completed_ticks INTEGER, scan_id TEXT, virtual_id TEXT);
                    """);
                for (var index = 0; index < _pending.Count; index++)
                {
                    var item = _pending[index];
                    DeviceInventoryStore.Execute(connection, null, """
                        INSERT INTO pending_history VALUES($kind,$id,$sequence,$time,$network,$subnet,$present,$ticks,$scan,$virtual)
                        """, ("$kind", kind), ("$id", id), ("$sequence", savedCount + index),
                        ("$time", item.CompletedAt.ToString("O")), ("$network", item.NetworkId),
                        ("$subnet", item.Subnet), ("$present", item.Present ? 1 : 0),
                        ("$ticks", item.CompletedAt.UtcTicks), ("$scan", item.ScanId?.ToString("D")),
                        ("$virtual", item.VirtualDeviceId?.ToString("D")));
                }
            }
            return query(connection);
        }
        catch (SqliteException exception) { throw DeviceInventoryStore.StorageError(exception); }
        catch (Exception exception) when (exception is FormatException or OverflowException)
        {
            throw new InvalidDataException("Saved scan history contains invalid timestamps or sequences.", exception);
        }
    }

    private string Source => _pending.Count == 0 ? "scan_history"
        : "(SELECT * FROM scan_history WHERE kind=$kind AND id=$id AND sequence<$savedCount UNION ALL SELECT * FROM pending_history)";

    private SqliteCommand Command(SqliteConnection connection, string sql,
        params (string Name, object? Value)[] parameters)
    {
        var command = connection.CreateCommand();
        command.CommandText = sql;
        command.Parameters.AddWithValue("$kind", kind);
        command.Parameters.AddWithValue("$id", id);
        command.Parameters.AddWithValue("$savedCount", savedCount);
        command.Parameters.AddWithValue("$count", Count);
        foreach (var (name, value) in parameters) command.Parameters.AddWithValue(name, value ?? DBNull.Value);
        return command;
    }

    private string Identity => "kind=$kind AND id=$id AND sequence<$count";

    private List<(DeviceScanObservation Item, int Sequence)> Read(SqliteConnection connection,
        string filter, string order, int limit, params (string Name, object? Value)[] parameters)
    {
        var source = _pending.Count == 0 && filter.Contains("network_id=", StringComparison.Ordinal)
            ? $"scan_history INDEXED BY {(filter.Contains("present=", StringComparison.Ordinal) ? "history_scope_presence" : "history_scope_time")}"
            : Source;
        using var command = Command(connection,
            $"SELECT completed_at,network_id,subnet,present,sequence,completed_ticks,scan_id,virtual_id FROM {source} WHERE {Identity} AND {filter} ORDER BY {order} LIMIT {limit}",
            parameters);
        using var reader = command.ExecuteReader();
        var rows = new List<(DeviceScanObservation, int)>();
        while (reader.Read())
        {
            var timestamp = DateTimeOffset.Parse(reader.GetString(0), CultureInfo.InvariantCulture);
            var state = reader.GetInt32(3);
            if (timestamp == default || timestamp.UtcTicks != reader.GetInt64(5) || state is not (0 or 1))
                throw new InvalidDataException("Saved scan history contains an invalid time or state.");
            rows.Add((new(timestamp, reader.IsDBNull(1) ? null : reader.GetString(1),
                reader.GetString(2), state == 1)
                {
                    ScanId = reader.IsDBNull(6) ? null : Guid.Parse(reader.GetString(6)),
                    VirtualDeviceId = reader.IsDBNull(7) ? null : Guid.Parse(reader.GetString(7))
                }, reader.GetInt32(4)));
        }
        return rows;
    }

    public DeviceHistoryPage ReadPage(string networkId, string subnet, DeviceHistoryCursor? cursor = null,
        bool newer = false, int pageSize = DeviceHistoryQuery.DefaultPageSize)
    {
        if (pageSize is < 1 or > DeviceHistoryQuery.MaximumPageSize) throw new ArgumentOutOfRangeException(nameof(pageSize));
        return Query(connection =>
        {
            var parameters = new List<(string, object?)> { ("$network", networkId), ("$subnet", subnet) };
            var filter = "network_id=$network AND subnet=$subnet";
            using var countCommand = Command(connection, $"SELECT COUNT(*) FROM {Source} WHERE {Identity} AND {filter}", parameters.ToArray());
            var total = checked(Convert.ToInt32(countCommand.ExecuteScalar(), CultureInfo.InvariantCulture));
            if (cursor is not null)
            {
                parameters.Add(("$ticks", cursor.CompletedAt.UtcTicks));
                parameters.Add(("$sequence", cursor.Sequence));
                filter += newer ? " AND (completed_ticks>$ticks OR completed_ticks=$ticks AND sequence<$sequence)"
                    : " AND (completed_ticks<$ticks OR completed_ticks=$ticks AND sequence>$sequence)";
            }
            var rows = Read(connection, filter, newer ? "completed_ticks ASC,sequence DESC"
                : "completed_ticks DESC,sequence ASC", pageSize, parameters.ToArray());
            if (newer) rows.Reverse();
            return new DeviceHistoryPage(rows.Select(row => row.Item).ToArray(),
                rows.Count == 0 ? null : new(rows[0].Item.CompletedAt, rows[0].Sequence),
                rows.Count == 0 ? null : new(rows[^1].Item.CompletedAt, rows[^1].Sequence), total);
        });
    }

    /// <summary>
    /// One page of a linked device's combined completed scans (see <see cref="LinkedScanHistory"/>), computed in one
    /// grouped query over the members' indexed rows rather than by loading their histories.
    /// </summary>
    internal static DeviceHistoryPage ReadLinkedPage(IReadOnlyList<SqliteScanHistory> members, string networkId, string subnet,
        DeviceHistoryCursor? cursor, bool newer, int pageSize)
    {
        if (members.Count == 0) return new([], null, null, 0);
        var first = members[0];
        return first.Query(connection =>
        {
            var parameters = new List<(string, object?)> { ("$network", networkId), ("$subnet", subnet) };
            var sources = new List<string>();
            var pending = false;
            for (var index = 0; index < members.Count; index++)
            {
                var member = members[index];
                if (index > 0)
                {
                    using var count = connection.CreateCommand();
                    count.CommandText = "SELECT count FROM history_counts WHERE kind=$kind AND id=$id";
                    count.Parameters.AddWithValue("$kind", member.Kind);
                    count.Parameters.AddWithValue("$id", member.Id);
                    if (Convert.ToInt32(count.ExecuteScalar() ?? 0, CultureInfo.InvariantCulture) < member.SavedCount)
                        throw new InvalidDataException("Saved scan history changed or is incomplete. Reload the inventory.");
                }
                parameters.AddRange([($"$kind{index}", member.Kind), ($"$id{index}", member.Id), ($"$saved{index}", member.SavedCount)]);
                sources.Add($"""
                    SELECT id,completed_ticks,completed_at,scan_id,present FROM scan_history INDEXED BY history_scope_time
                    WHERE kind=$kind{index} AND id=$id{index} AND network_id=$network AND subnet=$subnet
                        AND sequence<$saved{index} AND virtual_id IS NULL
                    """);
                if (member.Pending.Count == 0) continue;
                if (!pending && index > 0)
                    DeviceInventoryStore.Execute(connection, null, """
                        CREATE TEMP TABLE IF NOT EXISTS pending_history (
                            kind TEXT, id TEXT, sequence INTEGER, completed_at TEXT,
                            network_id TEXT, subnet TEXT, present INTEGER, completed_ticks INTEGER, scan_id TEXT, virtual_id TEXT);
                        """);
                if (index > 0)
                    for (var item = 0; item < member.Pending.Count; item++)
                    {
                        var observation = member.Pending[item];
                        DeviceInventoryStore.Execute(connection, null, """
                            INSERT INTO pending_history VALUES($kind,$id,$sequence,$time,$network,$subnet,$present,$ticks,$scan,$virtual)
                            """, ("$kind", member.Kind), ("$id", member.Id), ("$sequence", member.SavedCount + item),
                            ("$time", observation.CompletedAt.ToString("O")), ("$network", observation.NetworkId),
                            ("$subnet", observation.Subnet), ("$present", observation.Present ? 1 : 0),
                            ("$ticks", observation.CompletedAt.UtcTicks), ("$scan", observation.ScanId?.ToString("D")),
                            ("$virtual", observation.VirtualDeviceId?.ToString("D")));
                    }
                pending = true;
            }
            if (pending)
                sources.Add("""
                    SELECT id,completed_ticks,completed_at,scan_id,present FROM pending_history
                    WHERE network_id=$network AND subnet=$subnet AND virtual_id IS NULL
                    """);
            // A response from any member wins; otherwise every member already seen there (by its first response)
            // needs a recorded nonresponse. Anything else is unknown and not listed, matching activity evidence.
            var known = $"""
                WITH src AS ({string.Join(" UNION ALL ", sources)}),
                firsts AS (SELECT id,MIN(completed_ticks) AS f FROM src WHERE present=1 GROUP BY id),
                grouped AS (
                    SELECT s.completed_ticks AS t,s.scan_id AS sid,MIN(s.completed_at) AS at,MAX(s.present) AS responded,
                        COUNT(DISTINCT CASE WHEN s.present=0 AND f.f<=s.completed_ticks THEN s.id END) AS absent
                    FROM src AS s LEFT JOIN firsts AS f ON f.id=s.id GROUP BY s.completed_ticks,s.scan_id),
                known AS (
                    SELECT t,sid,at,responded,ROW_NUMBER() OVER (PARTITION BY t ORDER BY sid) - 1 AS idx FROM grouped AS g
                    WHERE responded=1 OR (absent>0 AND absent=(SELECT COUNT(*) FROM firsts WHERE f<=g.t)))
                """;
            using var countCommand = connection.CreateCommand();
            countCommand.CommandText = known + " SELECT COUNT(*) FROM known";
            foreach (var (name, value) in parameters) countCommand.Parameters.AddWithValue(name, value ?? DBNull.Value);
            var total = checked(Convert.ToInt32(countCommand.ExecuteScalar(), CultureInfo.InvariantCulture));
            var filter = "1=1";
            if (cursor is not null)
            {
                parameters.Add(("$ticks", cursor.CompletedAt.UtcTicks));
                parameters.Add(("$sequence", cursor.Sequence));
                filter = newer ? "(t>$ticks OR t=$ticks AND idx<$sequence)" : "(t<$ticks OR t=$ticks AND idx>$sequence)";
            }
            using var command = connection.CreateCommand();
            command.CommandText = known + $" SELECT at,t,sid,responded,idx FROM known WHERE {filter} ORDER BY "
                + (newer ? "t ASC,idx DESC" : "t DESC,idx ASC") + $" LIMIT {pageSize}";
            foreach (var (name, value) in parameters) command.Parameters.AddWithValue(name, value ?? DBNull.Value);
            var rows = new List<(DeviceScanObservation Item, int Sequence)>();
            using (var reader = command.ExecuteReader())
                while (reader.Read())
                {
                    var timestamp = DateTimeOffset.Parse(reader.GetString(0), CultureInfo.InvariantCulture);
                    if (timestamp == default || timestamp.UtcTicks != reader.GetInt64(1))
                        throw new InvalidDataException("Saved scan history contains an invalid time or state.");
                    rows.Add((new(timestamp, networkId, subnet, reader.GetInt64(3) == 1)
                    {
                        ScanId = reader.IsDBNull(2) ? null : Guid.Parse(reader.GetString(2))
                    }, reader.GetInt32(4)));
                }
            if (newer) rows.Reverse();
            return new DeviceHistoryPage(rows.Select(row => row.Item).ToArray(),
                rows.Count == 0 ? null : new(rows[0].Item.CompletedAt, rows[0].Sequence),
                rows.Count == 0 ? null : new(rows[^1].Item.CompletedAt, rows[^1].Sequence), total);
        });
    }

    public bool HasPresence(string networkId, string subnet) => Query(connection =>
        Read(connection, "network_id=$network AND subnet=$subnet AND present=1",
            "completed_ticks DESC,sequence ASC", 1, ("$network", networkId), ("$subnet", subnet)).Count != 0);

    public DeviceHistorySummary Summarize(IEnumerable<DeviceObservation> aggregates, string networkId, string subnet) =>
        Query(connection =>
        {
            const string scope = "network_id=$network AND subnet=$subnet";
            var parameters = new (string, object?)[] { ("$network", networkId), ("$subnet", subnet) };
            var latest = Read(connection, scope, "completed_ticks DESC,sequence ASC", 1, parameters).FirstOrDefault();
            var firstPresence = Read(connection, scope + " AND present=1", "completed_ticks ASC,sequence DESC", 1, parameters)
                .Select(row => (DateTimeOffset?)row.Item.CompletedAt).FirstOrDefault();
            var lastPresence = Read(connection, scope + " AND present=1", "completed_ticks DESC,sequence ASC", 1, parameters)
                .Select(row => (DateTimeOffset?)row.Item.CompletedAt).FirstOrDefault();
            DateTimeOffset? since = null;
            if (latest.Item is not null)
            {
                var opposite = Read(connection, scope + " AND present=$opposite", "completed_ticks DESC,sequence ASC", 1,
                    [.. parameters, ("$opposite", latest.Item.Present ? 0 : 1)]).FirstOrDefault();
                var filter = scope;
                var sinceParameters = parameters;
                if (opposite.Item is not null)
                {
                    filter += " AND (completed_ticks>$ticks OR completed_ticks=$ticks AND sequence<$sequence)";
                    sinceParameters = [.. parameters, ("$ticks", opposite.Item.CompletedAt.UtcTicks), ("$sequence", opposite.Sequence)];
                }
                since = Read(connection, filter, "completed_ticks ASC,sequence DESC", 1, sinceParameters).Single().Item.CompletedAt;
            }
            var matching = aggregates.Where(item => item.NetworkId == networkId && item.Subnet == subnet).ToArray();
            var first = matching.Select(item => (DateTimeOffset?)item.FirstSeen).Append(firstPresence).Min();
            var last = matching.Select(item => (DateTimeOffset?)item.LastSeen).Append(lastPresence).Max();
            return new DeviceHistorySummary(latest.Item is null ? [] : [latest.Item], first, last, since,
                first is not null && first != firstPresence, last is not null && last != lastPresence);
        });
}
