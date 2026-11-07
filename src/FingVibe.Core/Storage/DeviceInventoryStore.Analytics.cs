using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using FingVibe.Core.Models;
using Microsoft.Data.Sqlite;
using SQLitePCL;

namespace FingVibe.Core.Storage;

public sealed partial class DeviceInventoryStore
{
    public Task<AnalyticsEvidence> QueryAnalyticsAsync(
        AnalyticsEvidenceRequest request, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(request);
        var captured = request with { Devices = request.Devices?.ToArray() };
        return Task.Run(() => ReadAnalytics(captured, cancellationToken), cancellationToken);
    }

    private AnalyticsEvidence ReadAnalytics(AnalyticsEvidenceRequest request, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(request.NetworkId);
        ArgumentNullException.ThrowIfNull(request.TimeZone);
        if (!ValidSubnet(request.Subnet) || request.CalendarDays is not (7 or 30)
            || request.QueryTime == default || request.ExpectedRevision == Guid.Empty)
            throw new ArgumentException("Analytics requires a network/subnet, captured time, 7 or 30 dates, and a saved revision.");
        var lastDate = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(request.QueryTime, request.TimeZone).DateTime);
        var firstDate = lastDate.AddDays(1 - request.CalendarDays);
        var localStart = firstDate.ToDateTime(TimeOnly.MinValue, DateTimeKind.Unspecified);
        while (request.TimeZone.IsInvalidTime(localStart)) localStart = localStart.AddMinutes(1);
        var offset = request.TimeZone.IsAmbiguousTime(localStart)
            ? request.TimeZone.GetAmbiguousTimeOffsets(localStart).Max() : request.TimeZone.GetUtcOffset(localStart);
        var start = new DateTimeOffset(localStart, offset);
        cancellationToken.ThrowIfCancellationRequested();
        if (!File.Exists(_databasePath))
            throw new FileNotFoundException("Saved inventory is unavailable. Save a scan or import before querying.", _databasePath);
        try
        {
            using var read = new AnalyticsReadSession(_databasePath, cancellationToken);
            read.Execute("BEGIN");
            var revision = read.Revision();
            CheckRevision(revision, request.ExpectedRevision);
            var slots = read.Entities<PrivateVirtualDevice>("virtual_devices");
            var people = read.Entities<ManagedPerson>("people");
            var rooms = read.Entities<ManagedRoom>("rooms");
            if (slots.Any(pair => pair.Key != pair.Value.Id.ToString("D"))
                || people.Any(pair => pair.Key != pair.Value.Id.ToString("D"))
                || rooms.Any(pair => pair.Key != pair.Value.Id.ToString("D")))
                throw new InvalidDataException("Saved analytics metadata contains mismatched identities.");
            var data = new DeviceInventoryData(revision,
                read.Entities<InventoryDevice>("devices"), read.Entities<string>("names"),
                read.Entities<DeviceClassificationOverride>("classifications"),
                new PeopleRoomsData(people.Values.ToArray(), rooms.Values.ToArray(), read.Entities<DeviceAssignment>("assignments")))
            {
                VirtualDevices = slots.Values.ToArray()
            };
            Validate(data);
            var selected = SelectAnalyticsDevices(data, request);
            var devices = new AnalyticsDevice[selected.Count];
            var scans = new Dictionary<Guid, AnalyticsScanBuilder>();
            var legacy = new Dictionary<long, AnalyticsScanBuilder>();
            const string scanColumns = "scan_id,completed_at,completed_ticks,state,unidentified_responses";
            var scope = new (string, object?)[]
                { ("$network", request.NetworkId), ("$subnet", request.Subnet), ("$end", request.QueryTime.UtcTicks) };
            foreach (var row in read.Rows($"""
                         SELECT {scanColumns} FROM scan_evidence
                         WHERE network_id=$network AND subnet=$subnet AND completed_ticks>=$start AND completed_ticks<=$end
                         ORDER BY completed_ticks,rowid
                         """, [.. scope, ("$start", start.UtcTicks)]))
            {
                var scan = ReadAnalyticsScan(row, selected.Count);
                scans.Add(scan.Id!.Value, scan);
            }
            AnalyticsScanBuilder? latest = null;
            foreach (var row in read.Rows($"""
                         SELECT {scanColumns} FROM scan_evidence
                         WHERE network_id=$network AND subnet=$subnet AND completed_ticks<=$end
                         ORDER BY completed_ticks DESC,rowid DESC LIMIT 1
                         """, scope))
            {
                var scan = ReadAnalyticsScan(row, selected.Count);
                if (!scans.TryGetValue(scan.Id!.Value, out latest))
                    scans.Add(scan.Id.Value, latest = scan);
            }
            for (var index = 0; index < selected.Count; index++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var (identity, ambiguous) = selected[index];
                var legacyMappingAmbiguous = identity.Kind == "mac" && data.VirtualDevices.Any(slot =>
                    slot.NetworkId == request.NetworkId && slot.Subnet == request.Subnet
                    && slot.History.Any(item => item.Mac == identity.Id));
                (string, object?)[] parameters =
                [
                    ("$kind", identity.Kind), ("$id", identity.Id),
                    ("$legacy", legacyMappingAmbiguous ? "ambiguous" : "known"), .. scope
                ];
                DateTimeOffset? first = null;
                if (!ambiguous)
                {
                    foreach (var row in read.Rows("""
                                 SELECT h.completed_at,h.completed_ticks,h.scan_id,e.completed_ticks,e.state,e.network_id,e.subnet
                                 FROM scan_history AS h INDEXED BY history_scope_presence
                                 LEFT JOIN scan_evidence AS e ON e.scan_id=h.scan_id
                                 WHERE h.kind=$kind AND h.id=$id AND h.network_id=$network AND h.subnet=$subnet
                                     AND h.present=1 AND h.completed_ticks<=$end
                                     AND h.virtual_id IS NULL AND (h.scan_id IS NOT NULL OR $legacy='known')
                                 ORDER BY h.completed_ticks ASC,h.sequence DESC LIMIT 1
                                 """, parameters))
                    {
                        first = AnalyticsReadSession.Timestamp(row, 0, 1);
                        if (raw.sqlite3_column_type(row, 2) != raw.SQLITE_NULL
                            && (raw.sqlite3_column_type(row, 3) == raw.SQLITE_NULL
                                || raw.sqlite3_column_int64(row, 3) != first.Value.UtcTicks
                                || raw.sqlite3_column_int64(row, 4) != (int)ScanCheckpointState.Complete
                                || AnalyticsReadSession.Text(row, 5) != request.NetworkId
                                || AnalyticsReadSession.Text(row, 6) != request.Subnet))
                            throw new InvalidDataException("First-sighting evidence does not match a completed scan.");
                    }
                }
                devices[index] = new(identity, first, ambiguous || legacyMappingAmbiguous);
                const string historySql = """
                    SELECT completed_at,completed_ticks,present,scan_id,virtual_id FROM scan_history INDEXED BY history_scope_time
                    WHERE kind=$kind AND id=$id AND network_id=$network AND subnet=$subnet
                        AND completed_ticks>=$start AND completed_ticks<=$end
                        AND ($scan IS NULL OR scan_id=$scan)
                    ORDER BY completed_ticks,sequence
                    """;
                AddRows(start.UtcTicks, request.QueryTime.UtcTicks);
                if (latest is not null && latest.Time < start)
                    AddRows(latest.Time.UtcTicks, latest.Time.UtcTicks, latest.Id);

                void AddRows(long from, long to, Guid? onlyScan = null)
                {
                    foreach (var row in read.Rows(historySql,
                                 [.. parameters.Where(pair => pair.Item1 != "$end"), ("$start", from), ("$end", to),
                                     ("$scan", onlyScan?.ToString("D"))]))
                    {
                        var time = AnalyticsReadSession.Timestamp(row, 0, 1);
                        var present = raw.sqlite3_column_int64(row, 2);
                        if (present is not (0 or 1))
                            throw new InvalidDataException("Saved analytics contains an invalid response.");
                        var mappedToVirtual = raw.sqlite3_column_type(row, 4) != raw.SQLITE_NULL;
                        if (mappedToVirtual && (identity.Kind != "mac" || present != 1
                            || raw.sqlite3_column_type(row, 3) == raw.SQLITE_NULL
                            || !Guid.TryParse(AnalyticsReadSession.Text(row, 4), out var virtualId)
                            || !data.VirtualDevices.Any(slot => slot.Id == virtualId && slot.NetworkId == request.NetworkId
                                && slot.Subnet == request.Subnet && slot.History.Any(item => item.Mac == identity.Id))))
                            throw new InvalidDataException("Saved evidence has an invalid virtual association.");
                        AnalyticsScanBuilder scan;
                        if (raw.sqlite3_column_type(row, 3) != raw.SQLITE_NULL)
                        {
                            var scanId = Guid.Parse(AnalyticsReadSession.Text(row, 3));
                            if (!scans.TryGetValue(scanId, out scan!) || scan.Time != time
                                || scan.State != ScanCheckpointState.Complete)
                                throw new InvalidDataException("Saved device evidence does not match its completed scan.");
                        }
                        else
                        {
                            if (time < start) continue;
                            if (!legacy.TryGetValue(time.UtcTicks, out scan!))
                                legacy.Add(time.UtcTicks, scan = new(null, time, null, 0, selected.Count));
                        }
                        // Only the recorded virtual identity is read. Raw MAC history is never backfilled into a slot.
                        if (!ambiguous && !mappedToVirtual
                            && !(legacyMappingAmbiguous && scan.Id is null) && first is not null && time >= first)
                        {
                            var response = present == 1 ? AnalyticsResponse.Responded : AnalyticsResponse.DidNotRespond;
                            var previous = scan.Responses[index];
                            if (scan.Id is not null && previous != AnalyticsResponse.Unknown)
                                throw new InvalidDataException("A logical device has duplicate evidence in one scan.");
                            if (previous != AnalyticsResponse.Responded)
                                scan.Responses[index] = response;
                        }
                    }
                }
            }
            var ordered = scans.Values.Concat(legacy.Values).Where(scan => scan.Time >= start)
                .OrderBy(scan => scan.Time).ThenBy(scan => scan.Id).ToArray();
            var result = new AnalyticsEvidence(revision, request.NetworkId, request.Subnet, request.QueryTime,
                request.TimeZone.Id, firstDate, lastDate, start, Array.AsReadOnly(devices),
                Array.AsReadOnly(ordered.Select(scan => scan.Finish(request.TimeZone)).ToArray()),
                latest?.Finish(request.TimeZone));
            cancellationToken.ThrowIfCancellationRequested();
            read.Execute("COMMIT");
            CheckRevision(read.Revision(), revision);
            return result;
        }
        catch (SqliteException exception)
        {
            cancellationToken.ThrowIfCancellationRequested();
            throw StorageError(exception);
        }
        catch (Exception exception) when (exception is JsonException or FormatException or OverflowException)
        {
            throw new InvalidDataException("Saved analytics evidence is malformed.", exception);
        }
    }

    private static List<(LogicalDeviceId Identity, bool Ambiguous)> SelectAnalyticsDevices(
        DeviceInventoryData data, AnalyticsEvidenceRequest request)
    {
        var slots = data.VirtualDevices.Where(slot => slot.NetworkId == request.NetworkId && slot.Subnet == request.Subnet)
            .ToDictionary(slot => LogicalDeviceId.Virtual(slot.Id));
        var aliases = new Dictionary<LogicalDeviceId, LogicalDeviceId[]>();
        foreach (var device in data.Devices.Values.Where(device => PrivateVirtualDeviceAllocator.IsEligible(data, device)))
        {
            var matches = slots.Where(pair => pair.Value.History.Any(item => item.Mac == device.Mac))
                .Select(pair => pair.Key).ToArray();
            if (matches.Length > 0) aliases.Add(LogicalDeviceId.Mac(device.Mac), matches);
        }
        var requested = request.Devices ?? data.Devices.Values
            .Where(device => device.Observations.Count == 0
                || device.Observations.Any(item => item.NetworkId == request.NetworkId && item.Subnet == request.Subnet))
            .Select(device => LogicalDeviceId.Mac(device.Mac)).Where(id => !aliases.ContainsKey(id))
            .Concat(slots.Keys).ToArray();
        var chosen = new Dictionary<LogicalDeviceId, bool>();
        foreach (var identity in requested)
        {
            if (identity is null || identity.Kind is not ("mac" or "virtual")
                || identity.Kind == "mac" && !data.Devices.ContainsKey(identity.Id)
                || identity.Kind == "virtual" && !slots.ContainsKey(identity))
                throw new ArgumentException("The analytics selection contains an unknown or out-of-network identity.");
            if (aliases.TryGetValue(identity, out var matches))
            {
                if (matches.Length == 1) chosen[matches[0]] = false;
                else chosen[identity] = true;
            }
            else chosen[identity] = false;
        }
        return chosen.OrderBy(pair => pair.Key.Kind, StringComparer.Ordinal).ThenBy(pair => pair.Key.Id, StringComparer.Ordinal)
            .Select(pair => (pair.Key, pair.Value)).ToList();
    }

    private static AnalyticsScanBuilder ReadAnalyticsScan(sqlite3_stmt row, int deviceCount)
    {
        var id = Guid.Parse(AnalyticsReadSession.Text(row, 0));
        var time = AnalyticsReadSession.Timestamp(row, 1, 2);
        var state = raw.sqlite3_column_int64(row, 3);
        var unidentified = raw.sqlite3_column_int64(row, 4);
        if (id == Guid.Empty || state is < 0 or > 2 || unidentified is < 0 or > int.MaxValue)
            throw new InvalidDataException("Saved scan evidence has an invalid identity, state or coverage.");
        return new(id, time, (ScanCheckpointState)state, (int)unidentified, deviceCount);
    }

    private sealed class AnalyticsScanBuilder(Guid? id, DateTimeOffset time, ScanCheckpointState? state,
        int unidentified, int deviceCount)
    {
        public Guid? Id { get; } = id;
        public DateTimeOffset Time { get; } = time;
        public ScanCheckpointState? State { get; } = state;
        public AnalyticsResponse[] Responses { get; } = new AnalyticsResponse[deviceCount];
        public AnalyticsScanEvidence Finish(TimeZoneInfo zone) =>
            new(Id, Time, TimeZoneInfo.ConvertTime(Time, zone), State, unidentified, Array.AsReadOnly(Responses));
    }

    // Native stepping avoids the provider's one-second busy retries and promptly releases
    // the read snapshot when a caller cancels during a query or writer contention.
    private sealed class AnalyticsReadSession : IDisposable
    {
        private readonly sqlite3 _database;
        private readonly CancellationToken _token;
        private readonly CancellationTokenRegistration _registration;
        private sqlite3 Database => _database;

        static AnalyticsReadSession() => Batteries_V2.Init();

        public AnalyticsReadSession(string path, CancellationToken token)
        {
            _token = token;
            var code = raw.sqlite3_open_v2(path, out _database, raw.SQLITE_OPEN_READONLY, null);
            try
            {
                Check(code);
                raw.sqlite3_busy_timeout(Database, 0);
                raw.sqlite3_progress_handler(Database, 1000, _ => token.IsCancellationRequested ? 1 : 0, null);
                _registration = token.Register(() => raw.sqlite3_interrupt(Database));
            }
            catch { _database.Dispose(); throw; }
        }

        public static string Text(sqlite3_stmt row, int column) => raw.sqlite3_column_text(row, column).utf8_to_string();
        public static DateTimeOffset Timestamp(sqlite3_stmt row, int text, int ticks)
        {
            var value = DateTimeOffset.Parse(Text(row, text), CultureInfo.InvariantCulture);
            if (value == default || value.UtcTicks != raw.sqlite3_column_int64(row, ticks))
                throw new InvalidDataException("Saved analytics contains inconsistent timestamps.");
            return value;
        }

        public IEnumerable<sqlite3_stmt> Rows(string sql, params (string Name, object? Value)[] parameters)
        {
            _token.ThrowIfCancellationRequested();
            using (var statement = Prepare(sql))
            {
                foreach (var (name, value) in parameters)
                {
                    var index = raw.sqlite3_bind_parameter_index(statement, name);
                    if (index == 0) continue;
                    Check(value switch
                    {
                        null => raw.sqlite3_bind_null(statement, index),
                        long number => raw.sqlite3_bind_int64(statement, index, number),
                        string text => raw.sqlite3_bind_text(statement, index, text),
                        _ => throw new ArgumentException("Unsupported analytics parameter.")
                    });
                }
                while (true)
                {
                    var started = Stopwatch.GetTimestamp();
                    var code = raw.sqlite3_step(statement);
                    while (code == raw.SQLITE_BUSY && WaitForRetry(started))
                        code = raw.sqlite3_step(statement);
                    Check(code);
                    if (code == raw.SQLITE_DONE) yield break;
                    yield return statement;
                }
            }
        }

        private sqlite3_stmt Prepare(string sql)
        {
            var started = Stopwatch.GetTimestamp();
            while (true)
            {
                var code = raw.sqlite3_prepare_v2(Database, sql, out var statement);
                if (code != raw.SQLITE_BUSY)
                {
                    try { Check(code); return statement; }
                    catch { statement.Dispose(); throw; }
                }
                statement.Dispose();
                if (!WaitForRetry(started)) Check(code);
            }
        }

        private bool WaitForRetry(long started)
        {
            _token.ThrowIfCancellationRequested();
            if (Stopwatch.GetElapsedTime(started).TotalMilliseconds >= 100) return false;
            _token.WaitHandle.WaitOne(5);
            _token.ThrowIfCancellationRequested();
            return true;
        }

        public void Execute(string sql)
        {
            foreach (var _ in Rows(sql)) { }
        }

        public Guid Revision()
        {
            Guid? revision = null;
            foreach (var row in Rows("SELECT id,version,revision FROM inventory"))
            {
                if (revision is not null || raw.sqlite3_column_int64(row, 0) != 1 || raw.sqlite3_column_int64(row, 1) != 3
                    || !Guid.TryParse(Text(row, 2), out var value) || value == Guid.Empty)
                    throw new InvalidDataException("Load the inventory to upgrade its analytics format before querying.");
                revision = value;
            }
            return revision ?? throw new InvalidDataException("Saved inventory has no revision.");
        }

        public Dictionary<string, T> Entities<T>(string table)
        {
            var result = new Dictionary<string, T>();
            foreach (var row in Rows($"SELECT id,data FROM {table}"))
                result.Add(Text(row, 0), JsonSerializer.Deserialize<T>(Text(row, 1), Options)
                    ?? throw new InvalidDataException($"Saved {table} contains invalid metadata."));
            return result;
        }

        private void Check(int code)
        {
            _token.ThrowIfCancellationRequested();
            if (code is not (raw.SQLITE_OK or raw.SQLITE_ROW or raw.SQLITE_DONE))
                throw new IOException($"Analytics query failed: {raw.sqlite3_errmsg(Database).utf8_to_string()} (SQLite {code}).");
        }

        public void Dispose()
        {
            _registration.Dispose();
            raw.sqlite3_progress_handler(Database, 0, null!, null);
            _database.Dispose();
        }
    }
}
