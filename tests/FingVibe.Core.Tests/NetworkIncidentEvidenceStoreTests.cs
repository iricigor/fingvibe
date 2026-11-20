using System.Net;
using FingVibe.App;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using FingVibe.Core.Storage;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class NetworkIncidentEvidenceStoreTests : IDisposable
{
    private static readonly DateTimeOffset Start = NetworkIncidentTrackerTests.Start;
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"fingvibe-evidence-{Guid.NewGuid():N}");
    private string Database => Path.Combine(_directory, "device-inventory.sqlite");

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }

    private Task<DeviceInventoryData> CreateInventoryAsync() =>
        new DeviceInventoryStore(Database).SaveAsync(DeviceInventoryData.Empty with
        {
            Names = new Dictionary<string, string> { ["001122334455"] = "Kept name" }
        }, Guid.Empty);

    private static NetworkIncident Incident(string context, DateTimeOffset first, DateTimeOffset? recovered = null) =>
        new(Guid.NewGuid(), context, "Wi-Fi", first, first.AddSeconds(30))
        {
            State = recovered is null ? NetworkIncidentState.Ongoing : NetworkIncidentState.Recovered,
            Symptoms = [new(NetworkHealthSymptomKind.WindowsDnsFailed, null, "Windows DNS did not resolve example.com", first)],
            LastObservedAt = recovered ?? first.AddSeconds(30),
            RecoveredAt = recovered,
            Gaps = [new(Guid.NewGuid(), NetworkObservationGapReason.Sleep, first.AddSeconds(40), recovered ?? first.AddSeconds(50))]
        };

    private static async Task<NetworkIncidentEvidence> EvidenceAsync(NetworkIncident incident)
    {
        var diagnostics = new NetworkIncidentDiagnostics(
            new NetworkDiagnosticService(NetworkMonitorReviewFixture.DiagnosticProbes), new FakeTimeProvider(incident.ConfirmedAt));
        return await diagnostics.RunAsync(diagnostics.Begin(incident),
            new("Wi-Fi", IPAddress.Parse("192.0.2.10"), IPAddress.Parse("192.0.2.0"), 24, true, IPAddress.Parse("192.0.2.1")),
            () => "unused", CancellationToken.None);
    }

    [Fact]
    public async Task EvidenceIsAttachedOnceAndRoundTripsWithAddressesAndHops()
    {
        await CreateInventoryAsync();
        var store = new NetworkHealthHistoryStore(Database);
        var incident = Incident("context", Start);
        var evidence = await EvidenceAsync(incident);
        var running = evidence with
        {
            Outcome = NetworkEvidenceOutcome.Running, CompletedAt = null, Observations = [], Hops = [], SummaryStatus = ""
        };

        Assert.True(await store.SaveAsync([incident], [running]));
        Assert.Equal(NetworkEvidenceOutcome.Running, Assert.Single((await store.LoadEvidenceAsync())!).Outcome);
        Assert.True(await store.SaveAsync([], [evidence]));
        var saved = Assert.Single((await store.LoadEvidenceAsync())!);
        Assert.Equal((evidence.Outcome, evidence.StartedAt, evidence.CompletedAt, evidence.SummaryStatus, evidence.TraceComplete),
            (saved.Outcome, saved.StartedAt, saved.CompletedAt, saved.SummaryStatus, saved.TraceComplete));
        Assert.Equal(evidence.Observations, saved.Observations, ObservationComparer.Instance);
        Assert.Equal(IPAddress.Parse("198.51.100.1"), saved.Hops[1].Observation.RespondingAddress);

        await Assert.ThrowsAsync<InvalidOperationException>(() => store.SaveAsync([], [evidence with { Detail = "replaced" }]));
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            store.SaveAsync([], [evidence with { IncidentId = Guid.NewGuid() }]));
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            store.SaveAsync([], [evidence with { ContextKey = "other" }]));
    }

    [Fact]
    public async Task RetentionPrunesOnlyResolvedIncidentsOlderThanNinetyDaysWithTheirEvidenceAndGaps()
    {
        var inventory = await CreateInventoryAsync();
        var store = new NetworkHealthHistoryStore(Database);
        var now = Start.AddDays(200);
        var expired = Incident("a", Start, now - NetworkHealthHistoryStore.RetentionPeriod - TimeSpan.FromSeconds(1));
        var boundary = Incident("b", Start.AddDays(1), now - NetworkHealthHistoryStore.RetentionPeriod);
        var oldOngoing = Incident("c", Start);
        var oldUnknown = Incident("d", Start) with { State = NetworkIncidentState.RecoveryUnknown };
        await store.SaveAsync([expired, boundary, oldOngoing, oldUnknown],
            [await EvidenceAsync(expired), await EvidenceAsync(oldOngoing)]);

        Assert.Equal([expired.Id], (await store.PruneAsync(now))!);

        Assert.Equal(new[] { boundary.Id, oldOngoing.Id, oldUnknown.Id }.Order(), (await store.LoadAsync())!.Select(item => item.Id).Order());
        Assert.Equal([oldOngoing.Id], (await store.LoadEvidenceAsync())!.Select(item => item.IncidentId));
        Assert.Equal(0L, Scalar($"SELECT COUNT(*) FROM network_observation_gaps WHERE incident_id='{expired.Id:D}'"));
        var reloaded = (await new DeviceInventoryStore(Database).LoadAsync())!;
        Assert.Equal((inventory.Revision, "Kept name"), (reloaded.Revision, reloaded.Names["001122334455"]));
    }

    [Fact]
    public async Task RetentionCapsResolvedIncidentsAtOneThousandKeepingTheNewestAndAllActive()
    {
        await CreateInventoryAsync();
        var store = new NetworkHealthHistoryStore(Database);
        var resolved = Enumerable.Range(0, NetworkHealthHistoryStore.MaximumResolvedIncidents + 2)
            .Select(index => Incident($"context-{index}", Start.AddMinutes(index), Start.AddMinutes(index + 1))).ToList();
        var ongoing = Incident("ongoing", Start.AddDays(-30));
        await store.SaveAsync([.. resolved, ongoing]);

        var removed = (await store.PruneAsync(Start.AddDays(1)))!;

        Assert.Equal(resolved.Take(2).Select(item => item.Id).Order(), removed.Order());
        var saved = (await store.LoadAsync())!;
        Assert.Equal(NetworkHealthHistoryStore.MaximumResolvedIncidents, saved.Count(item => item.State == NetworkIncidentState.Recovered));
        Assert.Contains(saved, item => item.Id == ongoing.Id);
        Assert.Empty((await store.PruneAsync(Start.AddDays(1)))!);
    }

    [Fact]
    public async Task BackupCopiesCommittedIncidentsEvidenceAndProgressButNotAConcurrentUncommittedSave()
    {
        var inventory = await CreateInventoryAsync();
        var store = new NetworkHealthHistoryStore(Database);
        var tracker = new NetworkIncidentTracker(new NetworkHealthEvaluator());
        tracker.Load([]);
        var context = NetworkIncidentTrackerTests.Context;
        NetworkIncidentUpdate Check(int check, long cloudflare = 12) => tracker.Evaluate(
            NetworkIncidentTrackerTests.Observation(Start.AddSeconds(30 * check), cloudflare), context, "Wi-Fi", false);
        Check(1, 215);
        var confirmed = Check(2, 215);
        await store.SaveAsync(confirmed.Changed, [await EvidenceAsync(confirmed.Confirmed!)]);
        await store.SaveAsync(Check(3).Changed);
        await store.SaveAsync(Check(4).Changed);

        // A concurrent incident save that has not committed must not leak into the copy.
        using var writer = new SqliteConnection($"Data Source={Database};Pooling=False");
        writer.Open();
        using var transaction = writer.BeginTransaction();
        using (var command = writer.CreateCommand())
        {
            command.Transaction = transaction;
            command.CommandText = "UPDATE network_recovery_progress SET healthy_checks=4; UPDATE network_incident_evidence SET outcome='Failed'";
            command.ExecuteNonQuery();
        }
        var backup = (await new InventoryBackupStore(Database).CreateAsync()).Backup!;
        transaction.Rollback();

        var copy = new NetworkHealthHistoryStore(backup.Path);
        var original = Assert.Single((await copy.LoadAsync())!);
        Assert.Equal((confirmed.Confirmed!.Id, NetworkIncidentState.Ongoing, 2), (original.Id, original.State, original.RecoveryChecks));
        var evidence = Assert.Single((await copy.LoadEvidenceAsync())!);
        Assert.Equal((original.Id, NetworkEvidenceOutcome.Complete), (evidence.IncidentId, evidence.Outcome));
        Assert.Equal(inventory.Revision, (await new DeviceInventoryStore(backup.Path).LoadAsync())!.Revision);

        // The copy stays independent: later saves to the source never change it.
        await store.SaveAsync(Check(5).Changed);
        Assert.Equal(2, Assert.Single((await new NetworkHealthHistoryStore(backup.Path).LoadAsync())!).RecoveryChecks);
        Assert.Equal(3, Assert.Single((await store.LoadAsync())!).RecoveryChecks);
    }

    [Fact]
    public async Task InconsistentSavedEvidenceIsReportedNotDiscarded()
    {
        await CreateInventoryAsync();
        var store = new NetworkHealthHistoryStore(Database);
        var incident = Incident("context", Start);
        await store.SaveAsync([incident], [await EvidenceAsync(incident)]);
        Execute("UPDATE network_incident_evidence SET outcome='Failed'");

        await Assert.ThrowsAsync<InvalidDataException>(() => store.LoadEvidenceAsync());
        Assert.Equal(1L, Scalar("SELECT COUNT(*) FROM network_incident_evidence"));
    }

    private object? Scalar(string sql) => ScalarAt(Database, sql);

    private static object? ScalarAt(string path, string sql)
    {
        using var connection = new SqliteConnection($"Data Source={path};Pooling=False");
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        return command.ExecuteScalar();
    }

    private void Execute(string sql)
    {
        using var connection = new SqliteConnection($"Data Source={Database};Pooling=False");
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        command.ExecuteNonQuery();
    }

    private sealed class ObservationComparer : IEqualityComparer<DiagnosticObservation>
    {
        public static ObservationComparer Instance { get; } = new();

        public bool Equals(DiagnosticObservation? x, DiagnosticObservation? y) =>
            x is not null && y is not null && x.Checkpoint == y.Checkpoint && x.Target == y.Target && x.State == y.State
            && x.Detail == y.Detail && Equals(x.RespondingAddress, y.RespondingAddress)
            && x.RoundtripMilliseconds == y.RoundtripMilliseconds;

        public int GetHashCode(DiagnosticObservation obj) => obj.Checkpoint.GetHashCode();
    }
}
