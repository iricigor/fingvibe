using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using FingVibe.Core.Storage;
using Microsoft.Data.Sqlite;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class NetworkHealthHistoryStoreTests : IDisposable
{
    private static readonly DateTimeOffset Start = NetworkIncidentTrackerTests.Start;
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"fingvibe-health-{Guid.NewGuid():N}");
    private string Database => Path.Combine(_directory, "device-inventory.sqlite");

    public void Dispose()
    {
        SqliteConnection.ClearAllPools();
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }

    private async Task<DeviceInventoryData> CreateInventoryAsync() =>
        await new DeviceInventoryStore(Database).SaveAsync(DeviceInventoryData.Empty with
        {
            Names = new Dictionary<string, string> { ["001122334455"] = "Kept name" }
        }, Guid.Empty);

    private static NetworkIncidentTracker Tracker(IEnumerable<NetworkIncident>? saved = null)
    {
        var tracker = new NetworkIncidentTracker(new NetworkHealthEvaluator());
        tracker.Load(saved ?? []);
        return tracker;
    }

    private static NetworkIncidentUpdate Check(NetworkIncidentTracker tracker, int check, long cloudflare = 12) =>
        tracker.Evaluate(NetworkIncidentTrackerTests.Observation(Start.AddSeconds(30 * check), cloudflare),
            NetworkIncidentTrackerTests.Context, "Wi-Fi", false);

    [Fact]
    public async Task MissingInventoryIsReportedAndNeverCreated()
    {
        var store = new NetworkHealthHistoryStore(Database);
        Assert.Null(await store.LoadAsync());
        var tracker = Tracker();
        Check(tracker, 1, 215);
        Assert.False(await store.SaveAsync(Check(tracker, 2, 215).Changed));
        Assert.False(File.Exists(Database));
    }

    [Fact]
    public async Task RestartRestoresProgressGapsAndTheResumedFifthHealthyCheck()
    {
        await CreateInventoryAsync();
        var store = new NetworkHealthHistoryStore(Database);
        Assert.Empty((await store.LoadAsync())!);
        var tracker = Tracker();
        Check(tracker, 1, 215);
        Assert.True(await store.SaveAsync(Check(tracker, 2, 215).Changed));
        for (var check = 3; check <= 6; check++) Assert.True(await store.SaveAsync(Check(tracker, check).Changed));

        var reopened = new NetworkHealthHistoryStore(Database);
        var saved = Assert.Single((await reopened.LoadAsync())!);
        Assert.Equal((NetworkIncidentState.Ongoing, 4, Start.AddSeconds(30), Start.AddSeconds(60)),
            (saved.State, saved.RecoveryChecks, saved.FirstObservedAt, saved.ConfirmedAt));
        Assert.Equal(tracker.Incidents[0].Symptoms, saved.Symptoms);

        var restarted = new NetworkIncidentTracker(new NetworkHealthEvaluator());
        Assert.True(await reopened.SaveAsync(restarted.Load([saved])));
        var unknown = Assert.Single((await reopened.LoadAsync())!);
        Assert.Equal((NetworkIncidentState.RecoveryUnknown, NetworkObservationGapReason.AppClosed, 4, true),
            (unknown.State, Assert.Single(unknown.Gaps).Reason, unknown.RecoveryChecks, unknown.GapSinceLastProblem));

        Assert.True(await reopened.SaveAsync(Check(restarted, 20).Changed));
        var recovered = Assert.Single((await reopened.LoadAsync())!);
        Assert.Equal((NetworkIncidentState.Recovered, (DateTimeOffset?)Start.AddSeconds(600), true, 0),
            (recovered.State, recovered.RecoveredAt, recovered.RecoveryTimeUncertain, recovered.RecoveryChecks));
        Assert.Equal(recovered.RecoveredAt, Assert.Single(recovered.Gaps).EndedAt);
        Assert.Equal(0L, Scalar("SELECT COUNT(*) FROM network_recovery_progress"));
    }

    [Fact]
    public async Task RecoveredIncidentAndItsSuccessorSaveTogetherNewestFirst()
    {
        await CreateInventoryAsync();
        var store = new NetworkHealthHistoryStore(Database);
        var tracker = Tracker();
        var changed = new Dictionary<Guid, NetworkIncident>();
        for (var check = 1; check <= 11; check++)
            foreach (var incident in Check(tracker, check, check is 1 or 2 or 10 or 11 ? 215 : 12).Changed)
                changed[incident.Id] = incident;

        Assert.True(await store.SaveAsync(changed.Values));
        var saved = (await store.LoadAsync())!;
        Assert.Equal([NetworkIncidentState.Ongoing, NetworkIncidentState.Recovered], saved.Select(item => item.State));
        Assert.Equal(tracker.Incidents.Select(item => item.Id), saved.Select(item => item.Id));
    }

    [Fact]
    public async Task OneActiveIncidentPerNetworkAndNoReopeningAreEnforced()
    {
        await CreateInventoryAsync();
        var store = new NetworkHealthHistoryStore(Database);
        var tracker = Tracker();
        Check(tracker, 1, 215);
        var incident = Assert.Single(Check(tracker, 2, 215).Changed);
        await store.SaveAsync([incident]);

        await Assert.ThrowsAsync<IOException>(() => store.SaveAsync([incident with { Id = Guid.NewGuid() }]));
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            store.SaveAsync([incident with { ConfirmedAt = incident.ConfirmedAt.AddSeconds(1), LastObservedAt = incident.ConfirmedAt.AddSeconds(1) }]));
        var recovered = incident with { State = NetworkIncidentState.Recovered, RecoveredAt = incident.ConfirmedAt };
        await store.SaveAsync([recovered]);
        await Assert.ThrowsAsync<InvalidOperationException>(() => store.SaveAsync([incident]));
        Assert.Equal(NetworkIncidentState.Recovered, Assert.Single((await store.LoadAsync())!).State);
    }

    [Fact]
    public async Task ConcurrentInventoryAndIncidentSavesKeepBothAndTheInventoryRevision()
    {
        var inventory = await CreateInventoryAsync();
        var inventoryStore = new DeviceInventoryStore(Database);
        Assert.Equal(inventory.Revision, (await inventoryStore.LoadAsync())!.Revision);
        var store = new NetworkHealthHistoryStore(Database);
        var tracker = Tracker();
        Check(tracker, 1, 215);
        await store.SaveAsync(Check(tracker, 2, 215).Changed);
        Assert.Equal(inventory.Revision, (await new DeviceInventoryStore(Database).LoadAsync())!.Revision);

        var inventoryTask = Task.Run(async () =>
        {
            var current = inventory;
            for (var index = 0; index < 15; index++)
                current = await inventoryStore.SaveAsync(current with
                {
                    Names = new Dictionary<string, string>(current.Names) { [$"02000000{index:D4}"] = $"Name {index}" }
                }, current.Revision);
            return current;
        });
        var healthTask = Task.Run(async () =>
        {
            for (var check = 3; check <= 17; check++)
                await new NetworkHealthHistoryStore(Database).SaveAsync(Check(tracker, check, check % 6 == 0 ? 215 : 12).Changed);
        });
        var final = await inventoryTask;
        await healthTask;

        var reloaded = (await new DeviceInventoryStore(Database).LoadAsync())!;
        Assert.Equal(final.Revision, reloaded.Revision);
        Assert.Equal(16, reloaded.Names.Count);
        Assert.Equal("Kept name", reloaded.Names["001122334455"]);
        Assert.Equal(tracker.Incidents, (await store.LoadAsync())!, IncidentComparer.Instance);
    }

    [Fact]
    public async Task InvalidSavedProgressIsReportedNotDiscarded()
    {
        await CreateInventoryAsync();
        var store = new NetworkHealthHistoryStore(Database);
        var tracker = Tracker();
        Check(tracker, 1, 215);
        await store.SaveAsync(Check(tracker, 2, 215).Changed);
        Execute("DELETE FROM network_recovery_progress");

        await Assert.ThrowsAsync<InvalidDataException>(() => store.LoadAsync());
        Assert.Equal(1L, Scalar("SELECT COUNT(*) FROM network_incidents"));
    }

    private object? Scalar(string sql)
    {
        using var connection = new SqliteConnection($"Data Source={Database};Pooling=False");
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

    private sealed class IncidentComparer : IEqualityComparer<NetworkIncident>
    {
        public static IncidentComparer Instance { get; } = new();

        public bool Equals(NetworkIncident? x, NetworkIncident? y) =>
            x is not null && y is not null && x.Id == y.Id && x.State == y.State && x.RecoveryChecks == y.RecoveryChecks
            && x.LastObservedAt == y.LastObservedAt && x.RecoveredAt == y.RecoveredAt
            && x.Symptoms.SequenceEqual(y.Symptoms) && x.Gaps.SequenceEqual(y.Gaps);

        public int GetHashCode(NetworkIncident obj) => obj.Id.GetHashCode();
    }
}
