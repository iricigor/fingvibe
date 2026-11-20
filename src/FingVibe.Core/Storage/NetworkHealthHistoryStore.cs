using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using FingVibe.Core.Networking;
using Microsoft.Data.Sqlite;

namespace FingVibe.Core.Storage;

/// <summary>
/// Owns the network incident, observation-gap, recovery-progress and incident-evidence tables inside the existing
/// device inventory database. Each load, save or prune is one short SQLite transaction; inventory rows and its revision
/// are never touched, and this store never creates the inventory database itself. Inventory backups copy the whole
/// database, so these tables are included in them.
/// </summary>
public sealed class NetworkHealthHistoryStore
{
    public const string MissingDatabaseMessage =
        "Incident history is saved with the local device inventory, which has not been created yet. It will be saved after the first inventory save, such as a completed scan.";

    private static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web)
    {
        Converters = { new JsonStringEnumConverter(), new IPAddressConverter() }
    };

    private readonly string _databasePath;
    private readonly SemaphoreSlim _gate = new(1, 1);

    public NetworkHealthHistoryStore(string inventoryPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(inventoryPath);
        _databasePath = Path.ChangeExtension(Path.GetFullPath(inventoryPath), ".sqlite");
    }

    /// <summary>Saved incidents, newest first, or null when the inventory database does not exist yet.</summary>
    public Task<IReadOnlyList<NetworkIncident>?> LoadAsync(CancellationToken cancellationToken = default) =>
        RunAsync<IReadOnlyList<NetworkIncident>?>(connection =>
        {
            using var transaction = connection.BeginTransaction();
            var incidents = Read(connection, transaction, cancellationToken);
            transaction.Commit();
            return incidents;
        }, cancellationToken);

    /// <summary>Writes the changed incidents with their gaps, recovery progress and evidence in one transaction.</summary>
    /// <param name="evidence">Deeper diagnostic evidence; each must reference a saved or co-saved incident.</param>
    /// <returns>False, without writing, when the inventory database does not exist yet.</returns>
    public async Task<bool> SaveAsync(IReadOnlyCollection<NetworkIncident> incidents,
        IReadOnlyCollection<NetworkIncidentEvidence>? evidence = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(incidents);
        evidence ??= [];
        foreach (var incident in incidents) Validate(incident);
        foreach (var item in evidence) Validate(item);
        if (incidents.GroupBy(item => item.Id).Any(group => group.Count() > 1)
            || evidence.GroupBy(item => item.IncidentId).Any(group => group.Count() > 1))
            throw new ArgumentException("Each incident and its evidence can be saved once per save.", nameof(incidents));
        return await RunAsync<bool?>(connection =>
        {
            using var transaction = connection.BeginTransaction();
            // Recovered incidents first, so an incident that recovered and a newer one on the same network can be
            // saved together without violating the one-active-incident-per-network constraint.
            foreach (var incident in incidents.OrderBy(item => item.IsActive))
            {
                cancellationToken.ThrowIfCancellationRequested();
                Write(connection, transaction, incident);
            }
            foreach (var item in evidence)
            {
                cancellationToken.ThrowIfCancellationRequested();
                Write(connection, transaction, item);
            }
            cancellationToken.ThrowIfCancellationRequested();
            transaction.Commit();
            return true;
        }, cancellationToken) ?? false;
    }

    /// <summary>Saved deeper diagnostic evidence, or null when the inventory database does not exist yet.</summary>
    public Task<IReadOnlyList<NetworkIncidentEvidence>?> LoadEvidenceAsync(CancellationToken cancellationToken = default) =>
        RunAsync<IReadOnlyList<NetworkIncidentEvidence>?>(connection =>
        {
            using var transaction = connection.BeginTransaction();
            using var command = connection.CreateCommand();
            command.Transaction = transaction;
            command.CommandText = """
                SELECT e.incident_id,e.context_key,e.outcome,e.data,i.context_key FROM network_incident_evidence e
                LEFT JOIN network_incidents i ON i.id=e.incident_id ORDER BY e.started_at
                """;
            var evidence = new List<NetworkIncidentEvidence>();
            using (var reader = command.ExecuteReader())
            {
                while (reader.Read())
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    var item = JsonSerializer.Deserialize<NetworkIncidentEvidence>(reader.GetString(3), Options)
                        ?? throw new InvalidDataException("Saved incident evidence is missing.");
                    if (reader.IsDBNull(4) || item.IncidentId.ToString("D") != reader.GetString(0)
                        || item.ContextKey != reader.GetString(1) || item.ContextKey != reader.GetString(4)
                        || item.Outcome.ToString() != reader.GetString(2))
                        throw new InvalidDataException("Saved incident evidence does not match its incident.");
                    Validate(item);
                    evidence.Add(item);
                }
            }
            transaction.Commit();
            return evidence;
        }, cancellationToken);

    /// <summary>
    /// Applies retention: removes recovered incidents whose recovery was observed more than 90 days ago, then the
    /// oldest recovered incidents beyond 1,000. Their evidence, gaps and progress are removed with them. Ongoing and
    /// recovery-unknown incidents, inventory and scan history are never removed.
    /// </summary>
    /// <returns>The removed incident identities, or null when the inventory database does not exist yet.</returns>
    public Task<IReadOnlyList<Guid>?> PruneAsync(DateTimeOffset now, CancellationToken cancellationToken = default) =>
        RunAsync<IReadOnlyList<Guid>?>(connection =>
        {
            using var transaction = connection.BeginTransaction();
            var recovered = new List<(string Id, DateTimeOffset RecoveredAt, long FirstTicks)>();
            using (var command = connection.CreateCommand())
            {
                command.Transaction = transaction;
                command.CommandText = "SELECT id,recovered_at,first_observed_ticks FROM network_incidents WHERE state='recovered'";
                using var reader = command.ExecuteReader();
                while (reader.Read())
                    recovered.Add((reader.GetString(0), ParseTime(reader.GetString(1)), reader.GetInt64(2)));
            }
            var cutoff = now - RetentionPeriod;
            var newestFirst = recovered.OrderByDescending(item => item.RecoveredAt).ThenByDescending(item => item.FirstTicks).ToList();
            var removed = newestFirst.Where((item, index) => item.RecoveredAt < cutoff || index >= MaximumResolvedIncidents)
                .Select(item => item.Id).ToList();
            foreach (var id in removed)
            {
                cancellationToken.ThrowIfCancellationRequested();
                DeviceInventoryStore.Execute(connection, transaction,
                    "DELETE FROM network_incidents WHERE id=$id AND state='recovered'", ("$id", id));
            }
            transaction.Commit();
            return removed.Select(Guid.Parse).ToList();
        }, cancellationToken);

    public static readonly TimeSpan RetentionPeriod = TimeSpan.FromDays(90);
    public const int MaximumResolvedIncidents = 1000;

    private async Task<T?> RunAsync<T>(Func<SqliteConnection, T> action, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            return await Task.Run(() =>
            {
                if (!File.Exists(_databasePath)) return default;
                try
                {
                    using var connection = DeviceInventoryStore.Open(_databasePath);
                    DeviceInventoryStore.Execute(connection, null, "PRAGMA foreign_keys=ON");
                    EnsureSchema(connection);
                    return action(connection);
                }
                catch (SqliteException exception) { throw DeviceInventoryStore.StorageError(exception); }
                catch (Exception exception) when (exception is JsonException or FormatException or ArgumentException
                    or OverflowException)
                {
                    throw new InvalidDataException("Saved network incident history is invalid.", exception);
                }
            }, cancellationToken).ConfigureAwait(false);
        }
        finally { _gate.Release(); }
    }

    private static void EnsureSchema(SqliteConnection connection)
    {
        using var transaction = connection.BeginTransaction();
        using (var command = connection.CreateCommand())
        {
            command.Transaction = transaction;
            command.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='inventory'";
            if (Convert.ToInt32(command.ExecuteScalar(), CultureInfo.InvariantCulture) != 1)
                throw new InvalidDataException("The database is not a FingVibe device inventory.");
        }
        DeviceInventoryStore.Execute(connection, transaction, """
            CREATE TABLE IF NOT EXISTS network_incidents (
                id TEXT PRIMARY KEY,
                context_key TEXT NOT NULL,
                network_label TEXT NOT NULL,
                state TEXT NOT NULL CHECK(state IN ('ongoing','recovered','recovery_unknown')),
                first_observed_at TEXT NOT NULL,
                first_observed_ticks INTEGER NOT NULL,
                confirmed_at TEXT NOT NULL,
                last_observed_at TEXT NOT NULL,
                recovered_at TEXT,
                recovery_time_uncertain INTEGER NOT NULL CHECK(recovery_time_uncertain IN (0,1)),
                symptoms TEXT NOT NULL,
                CHECK((state='recovered') = (recovered_at IS NOT NULL)));
            CREATE UNIQUE INDEX IF NOT EXISTS network_incidents_active ON network_incidents(context_key) WHERE state<>'recovered';
            CREATE INDEX IF NOT EXISTS network_incidents_newest ON network_incidents(first_observed_ticks DESC);
            CREATE TABLE IF NOT EXISTS network_observation_gaps (
                id TEXT PRIMARY KEY,
                incident_id TEXT NOT NULL REFERENCES network_incidents(id) ON DELETE CASCADE,
                reason TEXT NOT NULL CHECK(reason IN ('AppClosed','Sleep','MonitoringOff','NetworkChanged')),
                started_at TEXT NOT NULL,
                ended_at TEXT);
            CREATE INDEX IF NOT EXISTS network_observation_gaps_incident ON network_observation_gaps(incident_id);
            CREATE TABLE IF NOT EXISTS network_recovery_progress (
                context_key TEXT PRIMARY KEY,
                incident_id TEXT NOT NULL UNIQUE REFERENCES network_incidents(id) ON DELETE CASCADE,
                healthy_checks INTEGER NOT NULL CHECK(healthy_checks BETWEEN 0 AND 4),
                gap_since_problem INTEGER NOT NULL CHECK(gap_since_problem IN (0,1)),
                updated_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS network_incident_evidence (
                incident_id TEXT PRIMARY KEY REFERENCES network_incidents(id) ON DELETE CASCADE,
                context_key TEXT NOT NULL,
                outcome TEXT NOT NULL CHECK(outcome IN ('Running','Complete','Partial','NotRun','Failed')),
                started_at TEXT NOT NULL,
                completed_at TEXT,
                data TEXT NOT NULL,
                CHECK((outcome='Running') = (completed_at IS NULL)));
            """);
        transaction.Commit();
    }

    private static void Write(SqliteConnection connection, SqliteTransaction transaction, NetworkIncident incident)
    {
        var id = incident.Id.ToString("D");
        using (var existing = connection.CreateCommand())
        {
            existing.Transaction = transaction;
            existing.CommandText = "SELECT context_key,first_observed_at,confirmed_at,state FROM network_incidents WHERE id=$id";
            existing.Parameters.AddWithValue("$id", id);
            using var reader = existing.ExecuteReader();
            if (reader.Read())
            {
                if (reader.GetString(0) != incident.ContextKey || reader.GetString(1) != Time(incident.FirstObservedAt)
                    || reader.GetString(2) != Time(incident.ConfirmedAt))
                    throw new InvalidOperationException("A saved incident cannot change its network or confirmation times.");
                if (reader.GetString(3) == "recovered" && incident.IsActive)
                    throw new InvalidOperationException("A recovered incident cannot become active again; a new problem is a new incident.");
            }
        }

        DeviceInventoryStore.Execute(connection, transaction, """
            INSERT INTO network_incidents VALUES($id,$context,$label,$state,$first,$firstTicks,$confirmed,$last,$recovered,$uncertain,$symptoms)
            ON CONFLICT(id) DO UPDATE SET network_label=excluded.network_label, state=excluded.state,
                last_observed_at=excluded.last_observed_at, recovered_at=excluded.recovered_at,
                recovery_time_uncertain=excluded.recovery_time_uncertain, symptoms=excluded.symptoms
            """, ("$id", id), ("$context", incident.ContextKey), ("$label", incident.NetworkLabel),
            ("$state", State(incident.State)), ("$first", Time(incident.FirstObservedAt)),
            ("$firstTicks", incident.FirstObservedAt.UtcTicks), ("$confirmed", Time(incident.ConfirmedAt)),
            ("$last", Time(incident.LastObservedAt)), ("$recovered", incident.RecoveredAt is { } recovered ? Time(recovered) : null),
            ("$uncertain", incident.RecoveryTimeUncertain ? 1 : 0),
            ("$symptoms", JsonSerializer.Serialize(incident.Symptoms, Options)));

        foreach (var gap in incident.Gaps)
            DeviceInventoryStore.Execute(connection, transaction, """
                INSERT INTO network_observation_gaps VALUES($gap,$id,$reason,$started,$ended)
                ON CONFLICT(id) DO UPDATE SET ended_at=excluded.ended_at
                WHERE network_observation_gaps.incident_id=excluded.incident_id AND network_observation_gaps.ended_at IS NULL
                """, ("$gap", gap.Id.ToString("D")), ("$id", id), ("$reason", gap.Reason.ToString()),
                ("$started", Time(gap.StartedAt)), ("$ended", gap.EndedAt is { } ended ? Time(ended) : null));

        DeviceInventoryStore.Execute(connection, transaction,
            "DELETE FROM network_recovery_progress WHERE incident_id=$id", ("$id", id));
        if (incident.IsActive)
            DeviceInventoryStore.Execute(connection, transaction, """
                INSERT INTO network_recovery_progress VALUES($context,$id,$checks,$gap,$updated)
                """, ("$context", incident.ContextKey), ("$id", id), ("$checks", incident.RecoveryChecks),
                ("$gap", incident.GapSinceLastProblem ? 1 : 0), ("$updated", Time(incident.LastObservedAt)));
    }

    private static List<NetworkIncident> Read(SqliteConnection connection, SqliteTransaction transaction,
        CancellationToken cancellationToken)
    {
        var gaps = new Dictionary<string, List<NetworkObservationGap>>(StringComparer.Ordinal);
        using (var command = connection.CreateCommand())
        {
            command.Transaction = transaction;
            command.CommandText = "SELECT id,incident_id,reason,started_at,ended_at FROM network_observation_gaps ORDER BY started_at,rowid";
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (!gaps.TryGetValue(reader.GetString(1), out var list)) gaps[reader.GetString(1)] = list = [];
                list.Add(new(Guid.Parse(reader.GetString(0)), Enum.Parse<NetworkObservationGapReason>(reader.GetString(2)),
                    ParseTime(reader.GetString(3)), reader.IsDBNull(4) ? null : ParseTime(reader.GetString(4))));
            }
        }

        var progress = new Dictionary<string, (string Context, int Checks, bool Gap)>(StringComparer.Ordinal);
        using (var command = connection.CreateCommand())
        {
            command.Transaction = transaction;
            command.CommandText = "SELECT context_key,incident_id,healthy_checks,gap_since_problem FROM network_recovery_progress";
            using var reader = command.ExecuteReader();
            while (reader.Read())
                progress[reader.GetString(1)] = (reader.GetString(0), reader.GetInt32(2), reader.GetInt32(3) == 1);
        }

        var incidents = new List<NetworkIncident>();
        using (var command = connection.CreateCommand())
        {
            command.Transaction = transaction;
            command.CommandText = """
                SELECT id,context_key,network_label,state,first_observed_at,confirmed_at,last_observed_at,recovered_at,
                    recovery_time_uncertain,symptoms
                FROM network_incidents ORDER BY first_observed_ticks DESC, confirmed_at DESC
                """;
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                cancellationToken.ThrowIfCancellationRequested();
                var id = reader.GetString(0);
                var state = ParseState(reader.GetString(3));
                var incident = new NetworkIncident(Guid.Parse(id), reader.GetString(1), reader.GetString(2),
                    ParseTime(reader.GetString(4)), ParseTime(reader.GetString(5)))
                {
                    State = state,
                    LastObservedAt = ParseTime(reader.GetString(6)),
                    RecoveredAt = reader.IsDBNull(7) ? null : ParseTime(reader.GetString(7)),
                    RecoveryTimeUncertain = reader.GetInt32(8) == 1,
                    Symptoms = JsonSerializer.Deserialize<NetworkIncidentSymptom[]>(reader.GetString(9), Options)
                        ?? throw new InvalidDataException("Saved incident symptoms are missing."),
                    Gaps = gaps.GetValueOrDefault(id) ?? []
                };
                if (progress.Remove(id, out var saved))
                {
                    if (!incident.IsActive || saved.Context != incident.ContextKey)
                        throw new InvalidDataException("Saved recovery progress does not match an active incident.");
                    incident = incident with { RecoveryChecks = saved.Checks, GapSinceLastProblem = saved.Gap };
                }
                else if (incident.IsActive)
                {
                    throw new InvalidDataException("An active saved incident has no recovery progress.");
                }
                Validate(incident);
                incidents.Add(incident);
            }
        }
        if (progress.Count > 0) throw new InvalidDataException("Saved recovery progress has no matching incident.");
        return incidents;
    }

    private static void Write(SqliteConnection connection, SqliteTransaction transaction, NetworkIncidentEvidence evidence)
    {
        var id = evidence.IncidentId.ToString("D");
        using (var incident = connection.CreateCommand())
        {
            incident.Transaction = transaction;
            incident.CommandText = """
                SELECT i.context_key, e.outcome FROM network_incidents i
                LEFT JOIN network_incident_evidence e ON e.incident_id=i.id WHERE i.id=$id
                """;
            incident.Parameters.AddWithValue("$id", id);
            using var reader = incident.ExecuteReader();
            if (!reader.Read() || reader.GetString(0) != evidence.ContextKey)
                throw new InvalidOperationException("Incident evidence must be attached to its saved incident and network.");
            // Evidence is collected once per incident: only a still-running record can be completed.
            if (!reader.IsDBNull(1) && reader.GetString(1) != nameof(NetworkEvidenceOutcome.Running))
                throw new InvalidOperationException("Saved incident evidence is final and cannot be replaced.");
        }
        DeviceInventoryStore.Execute(connection, transaction, """
            INSERT INTO network_incident_evidence VALUES($id,$context,$outcome,$started,$completed,$data)
            ON CONFLICT(incident_id) DO UPDATE SET outcome=excluded.outcome, completed_at=excluded.completed_at, data=excluded.data
            """, ("$id", id), ("$context", evidence.ContextKey), ("$outcome", evidence.Outcome.ToString()),
            ("$started", Time(evidence.StartedAt)),
            ("$completed", evidence.CompletedAt is { } completed ? Time(completed) : null),
            ("$data", JsonSerializer.Serialize(evidence, Options)));
    }

    private static void Validate(NetworkIncidentEvidence evidence)
    {
        if (evidence.IncidentId == Guid.Empty || string.IsNullOrWhiteSpace(evidence.ContextKey) || evidence.NetworkLabel is null
            || (evidence.Outcome == NetworkEvidenceOutcome.Running) != (evidence.CompletedAt is null)
            || evidence.CompletedAt < evidence.StartedAt
            || evidence.Outcome is NetworkEvidenceOutcome.Partial or NetworkEvidenceOutcome.NotRun or NetworkEvidenceOutcome.Failed
                && string.IsNullOrWhiteSpace(evidence.Detail))
            throw new InvalidDataException("The incident evidence record is incomplete or inconsistent.");
    }

    private sealed class IPAddressConverter : JsonConverter<System.Net.IPAddress>
    {
        public override System.Net.IPAddress? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
            reader.TokenType == JsonTokenType.Null ? null : System.Net.IPAddress.Parse(reader.GetString()!);

        public override void Write(Utf8JsonWriter writer, System.Net.IPAddress value, JsonSerializerOptions options) =>
            writer.WriteStringValue(value.ToString());
    }

    private static void Validate(NetworkIncident incident)
    {
        if (incident.Id == Guid.Empty || string.IsNullOrWhiteSpace(incident.ContextKey) || incident.NetworkLabel is null
            || incident.Symptoms.Count == 0 || incident.ConfirmedAt < incident.FirstObservedAt
            || incident.LastObservedAt < incident.ConfirmedAt
            || incident.RecoveryChecks is < 0 or >= NetworkHealthEvaluator.RecoveryCheckCount
            || (incident.State == NetworkIncidentState.Recovered) != (incident.RecoveredAt is not null)
            || incident.Gaps.Any(gap => gap.Id == Guid.Empty || gap.EndedAt < gap.StartedAt))
            throw new InvalidDataException("The network incident record is incomplete or inconsistent.");
    }

    private static string State(NetworkIncidentState state) => state switch
    {
        NetworkIncidentState.Ongoing => "ongoing",
        NetworkIncidentState.Recovered => "recovered",
        NetworkIncidentState.RecoveryUnknown => "recovery_unknown",
        _ => throw new ArgumentOutOfRangeException(nameof(state))
    };

    private static NetworkIncidentState ParseState(string state) => state switch
    {
        "ongoing" => NetworkIncidentState.Ongoing,
        "recovered" => NetworkIncidentState.Recovered,
        "recovery_unknown" => NetworkIncidentState.RecoveryUnknown,
        _ => throw new InvalidDataException("Saved incident state is invalid.")
    };

    private static string Time(DateTimeOffset value) => value.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture);

    private static DateTimeOffset ParseTime(string value) =>
        DateTimeOffset.ParseExact(value, "O", CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind);
}
