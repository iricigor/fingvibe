using System.Net;
using System.Net.NetworkInformation;
using System.Threading.Channels;
using FingVibe.App;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using FingVibe.Core.Storage;
using Microsoft.Data.Sqlite;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class ScanCheckpointTests : IDisposable
{
    private const string NetworkId = "network-a";
    private const string Subnet = "192.0.2.0/24";
    private const string Known = "001122334455";
    private const string Added = "001122334466";
    private static readonly DateTimeOffset Start = DateTimeOffset.Parse("2026-11-07T12:00:00Z");
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"fingvibe-checkpoint-{Guid.NewGuid():N}");
    private string Database => Path.Combine(_directory, "inventory.sqlite");
    private string Cache => Path.Combine(_directory, "latest-scan.json");

    private static ScanResult Response(string mac, int host = 1, string vendor = "Example") =>
        new(IPAddress.Parse($"192.0.2.{host}"), HostStatus.Alive, null, TimeSpan.FromMilliseconds(5),
            MacAddress: PhysicalAddress.Parse(mac), VendorName: vendor);

    private static ScanSnapshot Checkpoint(Guid id, ScanCheckpointState state, params ScanResult[] results) =>
        new(Subnet, Start.AddMinutes(1), results, TimeSpan.FromSeconds(25))
        { ScanId = id, State = state, NetworkId = NetworkId };

    private static DeviceInventoryData Observe(DeviceInventoryData data, ScanSnapshot snapshot) =>
        data.ObserveCompletedScan(NetworkId, snapshot, snapshot.State == ScanCheckpointState.Incomplete)
            with { LatestScan = snapshot };

    [Fact]
    public async Task PendingAndIncompleteCheckpointsRetainObservationsWithoutOfflineHistoryOrBaseline()
    {
        var store = new DeviceInventoryStore(Database);
        var before = DeviceInventoryData.Empty.ObserveCompletedScan(NetworkId,
            new(Subnet, Start, [Response(Known)]));
        before = await store.SaveAsync(before, Guid.Empty);
        var id = Guid.NewGuid();
        var pending = Observe(before, Checkpoint(id, ScanCheckpointState.Pending, Response(Added, 2)));
        Assert.True(before.Devices[Known].Observations[0].Present);
        Assert.True(pending.Devices[Known].Observations[0].Present);
        Assert.Equal(InventoryDeviceStatus.Online, pending.Devices[Known].Status);
        var unresolved = ScanResultRow.CreateInventoryRows(pending).Single(row => row.MacAddress?.ToString() == Known);
        Assert.True(new DeviceResultFilter(false, false, "", Status: InventoryDeviceStatus.Online).Matches(unresolved));
        Assert.True(unresolved.IsHistorical);
        Assert.False(unresolved.CanProbe);
        Assert.Equal(InventoryDeviceStatus.Online, pending.Devices[Added].Status);
        Assert.Empty(pending.Devices[Added].ScanHistory);
        Assert.Single(pending.Devices[Known].ScanHistory);
        Assert.Empty(DeviceDiscovery.FindNewDevices(before, pending, NetworkId, pending.LatestScan!));
        pending = await store.SaveAsync(pending, before.Revision);
        var interrupted = Observe(pending, pending.LatestScan! with { State = ScanCheckpointState.Incomplete });
        await store.SaveAsync(interrupted, pending.Revision);
        var restored = (await new DeviceInventoryStore(Database).LoadMetadataAsync())!;
        Assert.Equal(ScanCheckpointState.Incomplete, restored.LatestScan!.State);
        Assert.Equal(id, restored.LatestScan.ScanId);
        Assert.All(restored.Devices.Values, device => Assert.Equal(InventoryDeviceStatus.Online, device.Status));
        Assert.All(ScanResultRow.CreateInventoryRows(restored), row => Assert.False(row.IsCurrentScanResponse));
        Assert.True(restored.Devices[Known].Observations[0].Present);
        Assert.Empty(restored.Devices[Added].ScanHistory);

        var first = Observe(DeviceInventoryData.Empty, Checkpoint(Guid.NewGuid(), ScanCheckpointState.Pending, Response(Added)));
        Assert.Empty(first.DiscoveryBaselines);
        first = Observe(first, first.LatestScan! with { State = ScanCheckpointState.Incomplete });
        Assert.Empty(first.DiscoveryBaselines);
    }

    [Fact]
    public async Task RepeatedCheckpointsFinalizeOneHistoryAndAlertAgainstTheOriginalBaseline()
    {
        var store = new DeviceInventoryStore(Database);
        var baseline = DeviceInventoryData.Empty.ObserveCompletedScan(NetworkId, new(Subnet, Start, [Response(Known)]));
        var data = await store.SaveAsync(baseline, Guid.Empty);
        var id = Guid.NewGuid();
        for (var phase = 0; phase < 2; phase++)
            data = await store.SaveAsync(Observe(data,
                Checkpoint(id, ScanCheckpointState.Pending, Response(Added, 2))), data.Revision);
        data = data with { Names = new Dictionary<string, string> { [Added] = "Edited during retries" } };
        data = await store.SaveAsync(data, data.Revision);
        var complete = Checkpoint(id, ScanCheckpointState.Complete, Response(Added, 2));
        var observed = Observe(data, complete);
        Assert.Equal(Added, Assert.Single(DeviceDiscovery.FindNewDevices(baseline, observed, NetworkId, complete)).Mac);
        data = await store.SaveAsync(observed, data.Revision);
        data = await store.SaveAsync(Observe(data, complete), data.Revision);
        var restored = (await new DeviceInventoryStore(Database).LoadAsync())!;
        Assert.Equal(2, restored.Devices.Count);
        Assert.Equal(2, restored.Devices[Known].ScanHistory.Count);
        Assert.False(restored.Devices[Known].ScanHistory[1].Present);
        Assert.Single(restored.Devices[Added].ScanHistory);
        Assert.Equal("Edited during retries", restored.Names[Added]);
        Assert.Single(restored.DiscoveryBaselines);
        Assert.Equal(ScanCheckpointState.Complete, restored.LatestScan!.State);
        Assert.Equal(InventoryDeviceStatus.Offline, restored.Devices[Known].Status);
        Assert.Equal(InventoryDeviceStatus.Online, restored.Devices[Added].Status);
    }

    [Fact]
    public async Task FailedFinalTransactionRollsBackInventoryHistoryAndCheckpointTogether()
    {
        var store = new DeviceInventoryStore(Database);
        var pending = Checkpoint(Guid.NewGuid(), ScanCheckpointState.Pending, Response(Added));
        var baseline = DeviceInventoryData.Empty.ObserveCompletedScan(NetworkId, new(Subnet, Start, [Response(Known)]));
        var data = await store.SaveAsync(Observe(baseline, pending), Guid.Empty);
        using (var connection = new SqliteConnection($"Data Source={Database};Pooling=False"))
        {
            connection.Open();
            using var command = connection.CreateCommand();
            command.CommandText = """
                CREATE TRIGGER fail_history BEFORE INSERT ON scan_history
                BEGIN SELECT RAISE(ABORT,'simulated disk failure'); END;
                """;
            command.ExecuteNonQuery();
        }
        await Assert.ThrowsAsync<IOException>(() =>
            store.SaveAsync(Observe(data, pending with { State = ScanCheckpointState.Complete }), data.Revision));
        var restored = (await new DeviceInventoryStore(Database).LoadAsync())!;
        Assert.Equal(data.Revision, restored.Revision);
        Assert.Equal(ScanCheckpointState.Pending, restored.LatestScan!.State);
        Assert.Equal(InventoryDeviceStatus.Online, restored.Devices[Known].Status);
        Assert.Equal(InventoryDeviceStatus.Online, restored.Devices[Added].Status);
        Assert.Empty(restored.Devices[Added].ScanHistory);
        Assert.Equal(baseline.DiscoveryBaselines, restored.DiscoveryBaselines);
    }

    [Fact]
    public async Task LateCheckpointCannotDowngradeAFinalizedScanOrChangeItsNetwork()
    {
        var store = new DeviceInventoryStore(Database);
        var complete = Checkpoint(Guid.NewGuid(), ScanCheckpointState.Complete, Response(Known));
        var data = await store.SaveAsync(Observe(DeviceInventoryData.Empty, complete), Guid.Empty);
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            store.SaveAsync(data with { LatestScan = complete with { State = ScanCheckpointState.Incomplete } }, data.Revision));
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            store.SaveAsync(data with { LatestScan = complete with { NetworkId = "another-network" } }, data.Revision));
        var restored = (await new DeviceInventoryStore(Database).LoadAsync())!;
        Assert.Equal(ScanCheckpointState.Complete, restored.LatestScan!.State);
        Assert.Equal(NetworkId, restored.LatestScan.NetworkId);
        Assert.Single(restored.Devices[Known].ScanHistory);
    }

    [Fact]
    public async Task RestartUsesDatabaseEvenWhenCacheIsStaleCompleteOrCorrupt()
    {
        var pending = Checkpoint(Guid.NewGuid(), ScanCheckpointState.Pending, Response(Added));
        await new DeviceInventoryStore(Database).SaveAsync(Observe(DeviceInventoryData.Empty, pending), Guid.Empty);
        var cache = new ScanSnapshotStore(Cache);
        await cache.SaveAsync(Checkpoint(Guid.NewGuid(), ScanCheckpointState.Complete, Response(Known)));
        var loaded = (await new DeviceInventoryStore(Database).LoadMetadataAsync())!;
        var restored = (await cache.LoadForRestoreAsync(loaded.LatestScan))!;
        Assert.Equal(pending.ScanId, restored.ScanId);
        Assert.Equal(ScanCheckpointState.Incomplete, restored.State);
        Assert.Equal(Added, Assert.Single(restored.Results).MacAddress!.ToString());
        await File.WriteAllTextAsync(Cache, "corrupt cache");
        Assert.Equal(restored, await cache.LoadForRestoreAsync(loaded.LatestScan));
    }

    [Fact]
    public async Task OldSavedEvidenceSurvivesEmptyCheckpointsLateResponsesAndOtherNetworkCompletion()
    {
        var store = new DeviceInventoryStore(Database);
        var baseline = DeviceInventoryData.Empty.ObserveCompletedScan(NetworkId,
            new(Subnet, Start.AddYears(-1), [Response(Known), Response(Added, 2)]));
        var saved = await store.SaveAsync(baseline, Guid.Empty);
        var restored = (await new DeviceInventoryStore(Database).LoadMetadataAsync())!;
        var online = new DeviceResultFilter(false, false, "", Status: InventoryDeviceStatus.Online);
        Assert.All(ScanResultRow.CreateInventoryRows(restored), row =>
        {
            Assert.True(online.Matches(row));
            Assert.Contains("saved scan evidence", row.StatusContext);
            Assert.False(row.CanProbe);
        });
        var id = Guid.NewGuid();
        var pending = Observe(restored, Checkpoint(id, ScanCheckpointState.Pending));
        Assert.All(pending.Devices.Values, device => Assert.Equal(InventoryDeviceStatus.Online, device.Status));
        var retry = Observe(pending, Checkpoint(id, ScanCheckpointState.Pending, Response(Known)));
        Assert.All(retry.Devices.Values, device => Assert.Equal(InventoryDeviceStatus.Online, device.Status));
        Assert.True(ScanResultRow.CreateInventoryRows(retry).Single(row => row.MacAddress?.ToString() == Known).CanProbe);
        var completed = Observe(retry, Checkpoint(id, ScanCheckpointState.Complete, Response(Known)));
        Assert.Equal(InventoryDeviceStatus.Online, completed.Devices[Known].Status);
        Assert.Equal(InventoryDeviceStatus.Offline, completed.Devices[Added].Status);
        var other = completed.ObserveCompletedScan("another-network",
            new(Subnet, Start.AddMinutes(2), []));
        Assert.Equal(InventoryDeviceStatus.Online, other.Devices[Known].Status);
        Assert.Equal(InventoryDeviceStatus.Offline, other.Devices[Added].Status);
        Assert.All(ScanResultRow.CreateInventoryRows(other), row => Assert.False(row.CanProbe));
        Assert.Single(restored.Devices[Known].ScanHistory);
        Assert.Single(restored.Devices[Added].ScanHistory);
        Assert.Equal(saved.Revision, restored.Revision);
    }

    [Fact]
    public async Task OrphanedModernCacheCannotClaimCompletionWithoutAnAuthoritativeCheckpoint()
    {
        var cache = new ScanSnapshotStore(Cache);
        await cache.SaveAsync(Checkpoint(Guid.NewGuid(), ScanCheckpointState.Complete, Response(Known)));
        Assert.Equal(ScanCheckpointState.Incomplete, (await cache.LoadForRestoreAsync(null))!.State);
    }

    [Fact]
    public void InterruptedFirstScanCannotBecomeAnImplicitCompletedDiscoveryBaseline()
    {
        var incomplete = Observe(DeviceInventoryData.Empty,
            Checkpoint(Guid.NewGuid(), ScanCheckpointState.Incomplete, Response(Known)));
        var scan = Checkpoint(Guid.NewGuid(), ScanCheckpointState.Complete, Response(Known), Response(Added, 2));
        var completed = Observe(incomplete, scan);
        Assert.Empty(DeviceDiscovery.FindNewDevices(incomplete, completed, NetworkId, scan));
        Assert.Single(completed.DiscoveryBaselines);
    }

    [Fact]
    public async Task CancelledCacheReplacementPreservesPriorCommittedDocument()
    {
        var cache = new ScanSnapshotStore(Cache);
        var initial = Checkpoint(Guid.NewGuid(), ScanCheckpointState.Pending, Response(Known));
        await cache.SaveAsync(initial);
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            cache.SaveAsync(initial with { State = ScanCheckpointState.Complete }, cancellation.Token));
        Assert.Equal(ScanCheckpointState.Pending, (await cache.LoadAsync())!.State);
        Assert.Single(Directory.GetFiles(_directory));
    }

    [Fact]
    public void ProvisionalVirtualIdentitiesRemainStableAndDoNotInferAbsenceAcrossCheckpoints()
    {
        var baseline = DeviceInventoryData.Empty.ObserveCompletedScan(NetworkId,
            new(Subnet, Start, [Response(Known, vendor: "Private")]));
        var initialSlot = Assert.Single(baseline.VirtualDevices);
        var id = Guid.NewGuid();
        var pending = Observe(baseline, Checkpoint(id, ScanCheckpointState.Pending, Response(Added, 2, "Private")));
        Assert.True(pending.VirtualDevices.Single(slot => slot.Id == initialSlot.Id).Present);
        var newSlot = pending.VirtualDevices.Single(slot => slot.Id != initialSlot.Id);
        var retry = Observe(pending, Checkpoint(id, ScanCheckpointState.Pending,
            Response(Added, 2, "Private"), Response(Known, vendor: "Private")));
        Assert.Equal(2, retry.VirtualDevices.Count);
        Assert.Equal(newSlot.Id, retry.VirtualDevices.Single(slot => slot.LastActiveMac == Added).Id);
        Assert.Empty(retry.VirtualDevices.Single(slot => slot.LastActiveMac == Added).ScanHistory);
        var complete = Observe(retry, retry.LatestScan! with { State = ScanCheckpointState.Complete });
        Assert.Equal(2, complete.VirtualDevices.Count);
        Assert.Equal(2, complete.VirtualDevices.Single(slot => slot.Id == initialSlot.Id).ScanHistory.Count);
        Assert.Single(complete.VirtualDevices.Single(slot => slot.Id == newSlot.Id).ScanHistory);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    [InlineData(4)]
    [InlineData(6)]
    public void NonReachableAndPermanentArpRowsCannotProveLife(int state) =>
        Assert.Null(FreshArpProbe.ReadFreshResponse(PhysicalAddress.Parse(Known).GetAddressBytes(), 6, state,
            IPAddress.Parse("192.0.2.1")));

    [Theory]
    [InlineData(nameof(ScanTrigger.Manual))]
    [InlineData(nameof(ScanTrigger.Scheduled))]
    public async Task SharedExecutionSerializesPendingCompleteAndIncompleteWritesForEitherTrigger(string trigger)
    {
        var steps = new CheckpointSteps();
        var coordinator = new NetworkActivityCoordinator();
        var execution = new ScanExecution(coordinator, steps);
        var run = execution.RunAsync(new ScanRequest(Enum.Parse<ScanTrigger>(trigger), ScanExecutionFixture.Network));
        var initial = await steps.Writes.ReadNextAsync();
        Assert.Equal(ScanCheckpointState.Pending, initial.State);
        Assert.Equal(ScanRunStatus.Busy, (await execution.RunAsync(new(ScanTrigger.Manual, ScanExecutionFixture.Network))).Status);
        var stop = execution.StopAsync();
        Assert.False(stop.IsCompleted);
        steps.ReleaseWrite.SetResult();
        Assert.Equal(ScanRunStatus.Cancelled, (await run.WaitAsync(ScanExecutionFixture.Timeout)).Status);
        await stop.WaitAsync(ScanExecutionFixture.Timeout);
        var incomplete = await steps.Writes.ReadNextAsync();
        Assert.Equal(initial.ScanId, incomplete.ScanId);
        Assert.Equal(ScanCheckpointState.Incomplete, incomplete.State);
        Assert.Equal(initial.Results, incomplete.Results);
        Assert.Null(coordinator.ActiveKind);
        Assert.Single(steps.Ended);
    }

    [Fact]
    public async Task SharedExecutionFinalizesOnceAndKeepsOneScanIdAcrossAllCheckpoints()
    {
        var steps = new CheckpointSteps { Finish = true };
        steps.ReleaseWrite.SetResult();
        var execution = new ScanExecution(new NetworkActivityCoordinator(), steps);
        var outcome = await execution.RunAsync(new(ScanTrigger.Manual, ScanExecutionFixture.Network));
        Assert.Equal(ScanRunStatus.Completed, outcome.Status);
        var first = await steps.Writes.ReadNextAsync();
        var final = await steps.Writes.ReadNextAsync();
        Assert.Equal(first.ScanId, final.ScanId);
        Assert.Equal(ScanCheckpointState.Complete, final.State);
        Assert.False(steps.Writes.Reader.TryRead(out _));
    }

    [Fact]
    public async Task FailedIncompleteStateWriteIsReportedRatherThanClaimingSuccessfulCancellation()
    {
        var steps = new CheckpointSteps { FailIncomplete = true };
        var execution = new ScanExecution(new NetworkActivityCoordinator(), steps);
        var run = execution.RunAsync(new(ScanTrigger.Manual, ScanExecutionFixture.Network));
        await steps.Writes.ReadNextAsync();
        var stop = execution.StopAsync();
        steps.ReleaseWrite.SetResult();
        var outcome = await run.WaitAsync(ScanExecutionFixture.Timeout);
        await stop.WaitAsync(ScanExecutionFixture.Timeout);
        Assert.Equal(ScanRunStatus.SaveFailed, outcome.Status);
        Assert.Equal("incomplete write failed", outcome.Message);
        Assert.Equal(ScanCheckpointState.Incomplete, (await steps.Writes.ReadNextAsync()).State);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ChangedNetworkOrCheckpointFailureStopsRetriesAndRetainsOnlyPriorCommittedResults(bool saveFailure)
    {
        var steps = new CheckpointSteps { Finish = true };
        var execution = new ScanExecution(new NetworkActivityCoordinator(), steps);
        var run = execution.RunAsync(new(ScanTrigger.Manual, ScanExecutionFixture.Network));
        var first = await steps.Writes.ReadNextAsync();
        if (saveFailure) steps.FailComplete = true;
        else steps.Identity = "network-b";
        steps.ReleaseWrite.SetResult();
        var outcome = await run.WaitAsync(ScanExecutionFixture.Timeout);
        Assert.Equal(ScanRunStatus.Failed, outcome.Status);
        Assert.NotNull(outcome.Message);
        var writes = new List<ScanSnapshot>();
        while (steps.Writes.Reader.TryRead(out var item)) writes.Add(item);
        Assert.Equal(ScanCheckpointState.Incomplete, writes[^1].State);
        Assert.Equal(first.ScanId, writes[^1].ScanId);
        Assert.Equal(first.Results, writes[^1].Results);
    }

    [Fact]
    public void IncrementalRowUpdatesPreserveIdentitySelectionAndCurrentEvidenceWithoutDuplicateCounts()
    {
        var id = Guid.NewGuid();
        var pending = Observe(DeviceInventoryData.Empty, Checkpoint(id, ScanCheckpointState.Pending, Response(Known)));
        var row = Assert.Single(ScanResultRow.CreateInventoryRows(pending));
        row.IsSelected = true;
        var updated = Observe(pending, Checkpoint(id, ScanCheckpointState.Pending, Response(Known), Response(Added, 2)));
        row.UpdateObservation(ScanResultRow.CreateInventoryRows(updated).Single(item => item.IdentityKey == Known));
        Assert.Equal(Known, row.IdentityKey);
        Assert.True(row.IsSelected);
        Assert.True(row.IsOnline);
        Assert.Null(row.Result!.RoundtripTimeMilliseconds);
        Assert.Equal(2, ScanResultRow.CreateInventoryRows(updated).Count(item => item.IsOnline));
        var incomplete = Observe(updated, updated.LatestScan! with { State = ScanCheckpointState.Incomplete });
        row.UpdateObservation(ScanResultRow.CreateInventoryRows(incomplete).Single(item => item.IdentityKey == Known));
        Assert.True(row.IsHistorical);
        Assert.False(row.CanProbe);
        Assert.Contains("Incomplete", new OverviewScanContext(Subnet, Start, ScanDisplayStatus.Incomplete).Freshness(Start));
    }

    private sealed class CheckpointSteps : IScanExecutionSteps
    {
        public Channel<ScanSnapshot> Writes { get; } = Channel.CreateUnbounded<ScanSnapshot>();
        public TaskCompletionSource ReleaseWrite { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public List<ScanRunOutcome> Ended { get; } = [];
        public string Identity { get; set; } = NetworkId;
        public bool Finish { get; set; }
        public bool FailComplete { get; set; }
        public bool FailIncomplete { get; set; }
        public void BeginScan(ScanRequest request, CancellationTokenSource cancellation) { }
        public string CaptureNetworkIdentity(LanNetwork network) => Identity;
        public Task<IReadOnlyList<ScanResult>> ScanAsync(ScanRequest request, CancellationToken cancellationToken) =>
            throw new InvalidOperationException("The checkpointed path must be used.");
        public async Task<IReadOnlyList<ScanResult>> ScanAsync(ScanRequest request,
            Func<IReadOnlyList<ScanResult>, ScanCheckpointState, Task> checkpoint, CancellationToken token)
        {
            await checkpoint([Response(Known)], ScanCheckpointState.Pending);
            token.ThrowIfCancellationRequested();
            if (Finish)
            {
                await checkpoint([Response(Known), Response(Added, 2)], ScanCheckpointState.Complete);
                return [Response(Known), Response(Added, 2)];
            }
            await Task.Delay(Timeout.InfiniteTimeSpan, token);
            throw new InvalidOperationException("Cancellation did not stop the scan.");
        }
        public async Task<ScanSaveResult> SaveCheckpointAsync(ScanRequest request, ScanSnapshot snapshot)
        {
            Assert.True(Writes.Writer.TryWrite(snapshot));
            if (snapshot.State == ScanCheckpointState.Pending) await ReleaseWrite.Task;
            if (snapshot.State == ScanCheckpointState.Complete && FailComplete) return new([], "disk failed");
            if (snapshot.State == ScanCheckpointState.Incomplete && FailIncomplete) return new([], "incomplete write failed");
            return new([]) { CheckpointCommitted = true };
        }
        public Task<ScanSaveResult> SaveAsync(ScanRequest request, IReadOnlyList<ScanResult> results,
            string? networkId, bool networkChanged, TimeSpan duration) =>
            throw new InvalidOperationException("A checkpointed scan must not finalize twice.");
        public void EndScan(ScanRequest request, ScanRunOutcome outcome) => Ended.Add(outcome);
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }
}
