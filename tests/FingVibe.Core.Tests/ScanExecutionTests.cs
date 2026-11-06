using System.Net;
using System.Net.NetworkInformation;
using FingVibe.App;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class ScanExecutionTests : IDisposable
{
    private const string Known = "001122334455";
    private const string New = "001122334466";
    private const string Later = "001122334477";
    private const string Elsewhere = "001122334488";
    private static readonly DateTimeOffset Start = new(2026, 11, 6, 8, 0, 0, TimeSpan.Zero);
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"fingvibe-scan-execution-{Guid.NewGuid():N}");
    private readonly NetworkActivityCoordinator _coordinator = new();
    private readonly ScriptedScanSteps _steps = new();
    private readonly ScanExecution _execution;

    public ScanExecutionTests()
    {
        _steps.Coordinator = _coordinator;
        _execution = new ScanExecution(_coordinator, _steps);
    }

    private static ScanResult Result(string mac, string address = "192.0.2.20") =>
        new(IPAddress.Parse(address), HostStatus.Alive, 1, TimeSpan.FromMilliseconds(1),
            null, PhysicalAddress.Parse(mac), "Example");

    private static ScanRequest Request(ScanTrigger trigger = ScanTrigger.Scheduled) =>
        new(trigger, ScanExecutionFixture.Network);

    [Theory]
    [InlineData(nameof(ScanTrigger.Manual))]
    [InlineData(nameof(ScanTrigger.Scheduled))]
    public async Task ManualAndScheduledRequestsShareOneSerializedPath(string triggerName)
    {
        var trigger = Enum.Parse<ScanTrigger>(triggerName);
        var discovery = new DeviceDiscovery(New);
        _steps.Save = _ => Task.FromResult(new ScanSaveResult([discovery]));

        var run = _execution.RunAsync(Request(trigger));
        var (began, _) = await _steps.Began.ReadNextAsync();
        Assert.Equal(trigger, began.Trigger);
        Assert.Equal(NetworkActivityKind.LanScan, _coordinator.ActiveKind);
        var scan = await _steps.Scans.ReadNextAsync();
        scan.Complete(Result(Known), Result(New, "192.0.2.21"));
        var outcome = await run.WaitAsync(ScanExecutionFixture.Timeout);

        Assert.Equal(ScanRunStatus.Completed, outcome.Status);
        Assert.Equal([discovery], outcome.Discoveries);
        var save = Assert.Single(_steps.Saves);
        Assert.Equal("network-a", save.NetworkId);
        Assert.False(save.NetworkChanged);
        Assert.Equal([Known, New], save.Results.Select(result => result.MacAddress!.ToString()));
        Assert.Equal(outcome, Assert.Single(_steps.Ended));
        Assert.Equal(NetworkActivityKind.LanScan, _steps.ActiveKindDuringEnd);
        Assert.Null(_coordinator.ActiveKind);
    }

    [Theory]
    [InlineData(nameof(NetworkActivityKind.LanScan))]
    [InlineData(nameof(NetworkActivityKind.InternetSpeedTest))]
    [InlineData(nameof(NetworkActivityKind.NetworkTroubleshooting))]
    [InlineData(nameof(NetworkActivityKind.DeviceServiceScan))]
    public async Task ConflictingMeasurementRejectsTheRequestWithoutStartingOrQueueingAScan(string activeName)
    {
        var active = Enum.Parse<NetworkActivityKind>(activeName);
        Assert.True(_coordinator.TryAcquire(active, out var lease));

        var outcome = await _execution.RunAsync(Request());

        Assert.Equal(ScanRunStatus.Busy, outcome.Status);
        Assert.Equal(active, outcome.BlockingActivity);
        Assert.Empty(_steps.Ended);
        Assert.False(_steps.Began.Reader.TryRead(out _));
        Assert.Equal(active, _coordinator.ActiveKind);
        lease!.Dispose();
        Assert.Null(_coordinator.ActiveKind);
        Assert.False(_steps.Began.Reader.TryRead(out _));
    }

    [Fact]
    public async Task SecondRequestDuringARunningScanIsRejectedAndTheFirstCompletes()
    {
        var first = _execution.RunAsync(Request(ScanTrigger.Scheduled));
        var scan = await _steps.Scans.ReadNextAsync();

        var second = await _execution.RunAsync(Request(ScanTrigger.Manual));
        Assert.Equal(ScanRunStatus.Busy, second.Status);
        Assert.Equal(NetworkActivityKind.LanScan, second.BlockingActivity);
        Assert.False(scan.Token.IsCancellationRequested);

        scan.Complete(Result(Known));
        Assert.Equal(ScanRunStatus.Completed, (await first.WaitAsync(ScanExecutionFixture.Timeout)).Status);
        Assert.Single(_steps.Saves);
        Assert.Single(_steps.Ended);
        Assert.Null(_coordinator.ActiveKind);
    }

    [Fact]
    public async Task UserCancellationStopsTheScanWithoutSaving()
    {
        var run = _execution.RunAsync(Request());
        var (_, cancellation) = await _steps.Began.ReadNextAsync();
        var scan = await _steps.Scans.ReadNextAsync();

        cancellation.Cancel();
        var outcome = await run.WaitAsync(ScanExecutionFixture.Timeout);

        Assert.True(scan.Token.IsCancellationRequested);
        Assert.Equal(ScanRunStatus.Cancelled, outcome.Status);
        Assert.Empty(_steps.Saves);
        Assert.Equal(ScanRunStatus.Cancelled, Assert.Single(_steps.Ended).Status);
        Assert.Null(_coordinator.ActiveKind);
    }

    [Fact]
    public async Task CallerCancellationStopsTheScanWithoutSaving()
    {
        using var caller = new CancellationTokenSource();
        var run = _execution.RunAsync(Request(), caller.Token);
        var scan = await _steps.Scans.ReadNextAsync();

        caller.Cancel();
        var outcome = await run.WaitAsync(ScanExecutionFixture.Timeout);

        Assert.True(scan.Token.IsCancellationRequested);
        Assert.Equal(ScanRunStatus.Cancelled, outcome.Status);
        Assert.Empty(_steps.Saves);
        Assert.Null(_coordinator.ActiveKind);
    }

    public static TheoryData<Exception> ScanErrors => new()
    {
        new InvalidOperationException("adapter unavailable"),
        new IOException("socket failure"),
        new UnauthorizedAccessException("access denied"),
        new InvalidDataException("bad fixture")
    };

    [Theory]
    [MemberData(nameof(ScanErrors))]
    public async Task ScanErrorIsReportedWithoutSaving(Exception error)
    {
        var run = _execution.RunAsync(Request());
        (await _steps.Scans.ReadNextAsync()).Fail(error);
        var outcome = await run.WaitAsync(ScanExecutionFixture.Timeout);

        Assert.Equal(ScanRunStatus.Failed, outcome.Status);
        Assert.Equal(error.Message, outcome.Message);
        Assert.Empty(outcome.Discoveries);
        Assert.Empty(_steps.Saves);
        Assert.Equal(outcome, Assert.Single(_steps.Ended));
        Assert.Null(_coordinator.ActiveKind);
    }

    [Fact]
    public async Task UnexpectedErrorStillEndsTheScanAndReleasesTheLease()
    {
        var run = _execution.RunAsync(Request());
        (await _steps.Scans.ReadNextAsync()).Fail(new NotSupportedException("unexpected"));

        await Assert.ThrowsAsync<NotSupportedException>(() => run.WaitAsync(ScanExecutionFixture.Timeout));
        Assert.Equal(ScanRunStatus.Failed, Assert.Single(_steps.Ended).Status);
        Assert.Empty(_steps.Saves);
        Assert.Null(_coordinator.ActiveKind);
    }

    [Fact]
    public async Task StorageErrorWithholdsDiscoveries()
    {
        _steps.Save = _ => Task.FromResult(new ScanSaveResult([new DeviceDiscovery(New)], "disk full"));
        var run = _execution.RunAsync(Request());
        (await _steps.Scans.ReadNextAsync()).Complete(Result(New));
        var outcome = await run.WaitAsync(ScanExecutionFixture.Timeout);

        Assert.Equal(ScanRunStatus.SaveFailed, outcome.Status);
        Assert.Equal("disk full", outcome.Message);
        Assert.Empty(outcome.Discoveries);
        Assert.Empty(Assert.Single(_steps.Ended).Discoveries);
        Assert.Null(_coordinator.ActiveKind);
    }

    [Theory]
    [InlineData("network-a", "network-a", "network-a", false)]
    [InlineData("network-a", "network-b", null, true)]
    [InlineData("network-a", null, null, true)]
    [InlineData(null, "network-a", null, true)]
    [InlineData(null, null, null, false)]
    public async Task ObservationsStayScopedOnlyWhenOneNetworkIdentitySpansTheScan(
        string? atStart, string? atEnd, string? savedNetworkId, bool networkChanged)
    {
        _steps.Identities.Enqueue(atStart);
        _steps.Identities.Enqueue(atEnd);
        var run = _execution.RunAsync(Request());
        (await _steps.Scans.ReadNextAsync()).Complete(Result(Known));
        Assert.Equal(ScanRunStatus.Completed, (await run.WaitAsync(ScanExecutionFixture.Timeout)).Status);

        var save = Assert.Single(_steps.Saves);
        Assert.Equal(savedNetworkId, save.NetworkId);
        Assert.Equal(networkChanged, save.NetworkChanged);
    }

    // Mirrors the app's save step against a real SQLite inventory: observe, find candidates, then persist.
    [Fact]
    public async Task ScheduledScansPersistRepeatedObservationsAndOnlyDurableSavesProduceDiscoveries()
    {
        var path = Path.Combine(_directory, "device-inventory.json");
        var store = new DeviceInventoryStore(path);
        var persisted = DeviceInventoryData.Empty;
        var minute = 0;
        _steps.Save = async call =>
        {
            var snapshot = new ScanSnapshot(call.Request.Network.Cidr, Start.AddMinutes(++minute), call.Results.ToArray());
            var observed = persisted.ObserveCompletedScan(call.NetworkId, snapshot);
            var candidates = DeviceDiscovery.FindNewDevices(persisted, observed, call.NetworkId, snapshot);
            try
            {
                persisted = await store.SaveAsync(observed, persisted.Revision);
                return new ScanSaveResult(candidates);
            }
            catch (IOException exception)
            {
                return new ScanSaveResult([], exception.Message);
            }
        };

        var first = await RunAsync((scan, _) => scan.Complete(Result(Known)));
        Assert.Equal(ScanRunStatus.Completed, first.Status);
        Assert.Empty(first.Discoveries);

        var second = await RunAsync((scan, _) => scan.Complete(Result(Known), Result(New, "192.0.2.21")));
        Assert.Equal([New], second.Discoveries.Select(item => item.Mac));

        var revision = persisted.Revision;
        var failed = await RunAsync((scan, _) => scan.Fail(new IOException("socket failure")));
        Assert.Equal(ScanRunStatus.Failed, failed.Status);
        Assert.Equal(ScanRunStatus.Cancelled, (await RunAsync((_, cancellation) => cancellation.Cancel())).Status);
        Assert.Equal(revision, persisted.Revision);

        _steps.Identities.Enqueue("network-a");
        _steps.Identities.Enqueue("network-b");
        var changed = await RunAsync((scan, _) => scan.Complete(Result(Elsewhere, "192.0.2.30")));
        Assert.Equal(ScanRunStatus.Completed, changed.Status);
        Assert.Empty(changed.Discoveries);
        foreach (var (mac, historyCount) in new[] { (Known, 2), (New, 1) })
        {
            var observation = Assert.Single(persisted.Devices[mac].Observations);
            Assert.True(observation.Present);
            Assert.Equal(Start.AddMinutes(2), observation.LastChecked);
            Assert.Equal(historyCount, persisted.Devices[mac].ScanHistory.Count);
        }

        await using (new FileStream(path + ".lock", FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None))
        {
            var failedSave = await RunAsync((scan, _) => scan.Complete(Result(Known), Result(Later, "192.0.2.22")));
            Assert.Equal(ScanRunStatus.SaveFailed, failedSave.Status);
            Assert.Empty(failedSave.Discoveries);
        }

        var recovered = await RunAsync((scan, _) => scan.Complete(Result(Known), Result(Later, "192.0.2.22")));
        Assert.Equal(ScanRunStatus.Completed, recovered.Status);
        Assert.Equal([Later], recovered.Discoveries.Select(item => item.Mac));

        var saved = (await new DeviceInventoryStore(path).LoadAsync())!;
        Assert.Equal([Start.AddMinutes(1), Start.AddMinutes(2), Start.AddMinutes(5)],
            saved.Devices[Known].ScanHistory.Select(item => item.CompletedAt));
        Assert.All(saved.Devices[Known].ScanHistory, item => Assert.Equal("network-a", item.NetworkId));
        Assert.Equal([Start.AddMinutes(2)], saved.Devices[New].ScanHistory.Where(item => item.Present)
            .Select(item => item.CompletedAt));
        Assert.Equal(Start.AddMinutes(5), Assert.Single(saved.Devices[Later].ScanHistory).CompletedAt);
        var unscoped = Assert.Single(saved.Devices[Elsewhere].Observations);
        Assert.Null(unscoped.NetworkId);
        Assert.Equal(new DeviceDiscoveryBaseline("network-a", "192.0.2.0/24"), Assert.Single(saved.DiscoveryBaselines));
    }

    private async Task<ScanRunOutcome> RunAsync(Action<ScanCall, CancellationTokenSource> finish)
    {
        var run = _execution.RunAsync(Request());
        var (_, cancellation) = await _steps.Began.ReadNextAsync();
        finish(await _steps.Scans.ReadNextAsync(), cancellation);
        var outcome = await run.WaitAsync(ScanExecutionFixture.Timeout);
        Assert.Null(_coordinator.ActiveKind);
        return outcome;
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }
}
