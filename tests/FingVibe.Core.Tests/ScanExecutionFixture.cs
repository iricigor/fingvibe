using System.Net;
using System.Threading.Channels;
using FingVibe.App;
using FingVibe.Core.Models;
using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace FingVibe.Core.Tests;

internal static class ScanExecutionFixture
{
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(10);
    public static readonly LanNetwork Network = new(
        "Ethernet", IPAddress.Parse("192.0.2.10"), IPAddress.Parse("192.0.2.0"), 24, true, IPAddress.Parse("192.0.2.1"));

    public static Task<T> ReadNextAsync<T>(this Channel<T> channel) => channel.Reader.ReadAsync().AsTask().WaitAsync(Timeout);
}

internal sealed record ScanCall(ScanRequest Request, CancellationToken Token, TaskCompletionSource<IReadOnlyList<ScanResult>> Completion)
{
    public void Complete(params ScanResult[] results) => Completion.SetResult(results);

    public void Fail(Exception exception) => Completion.SetException(exception);
}

internal sealed record SaveCall(ScanRequest Request, IReadOnlyList<ScanResult> Results, string? NetworkId, bool NetworkChanged);

// Each scan waits until the test completes it, so overlap, collisions, and cancellation are fully controlled.
internal sealed class ScriptedScanSteps : IScanExecutionSteps
{
    private readonly object _sync = new();
    private readonly List<SaveCall> _saves = [];
    private readonly List<ScanRunOutcome> _ended = [];

    public Channel<(ScanRequest Request, CancellationTokenSource Cancellation)> Began { get; } =
        Channel.CreateUnbounded<(ScanRequest, CancellationTokenSource)>();

    public Channel<ScanCall> Scans { get; } = Channel.CreateUnbounded<ScanCall>();

    public Queue<string?> Identities { get; } = new();

    public string? DefaultIdentity { get; set; } = "network-a";

    public Func<SaveCall, Task<ScanSaveResult>> Save { get; set; } = _ => Task.FromResult(new ScanSaveResult([]));

    public IReadOnlyList<SaveCall> Saves { get { lock (_sync) return _saves.ToArray(); } }

    public IReadOnlyList<ScanRunOutcome> Ended { get { lock (_sync) return _ended.ToArray(); } }

    public NetworkActivityKind? ActiveKindDuringEnd { get; private set; }

    public NetworkActivityCoordinator? Coordinator { get; set; }

    public void BeginScan(ScanRequest request, CancellationTokenSource cancellation) =>
        Assert.True(Began.Writer.TryWrite((request, cancellation)));

    public string? CaptureNetworkIdentity(LanNetwork network)
    {
        lock (_sync) return Identities.Count > 0 ? Identities.Dequeue() : DefaultIdentity;
    }

    public Task<IReadOnlyList<ScanResult>> ScanAsync(ScanRequest request, CancellationToken cancellationToken)
    {
        var completion = new TaskCompletionSource<IReadOnlyList<ScanResult>>(TaskCreationOptions.RunContinuationsAsynchronously);
        Assert.True(Scans.Writer.TryWrite(new ScanCall(request, cancellationToken, completion)));
        return completion.Task.WaitAsync(cancellationToken);
    }

    public Task<ScanSaveResult> SaveAsync(
        ScanRequest request, IReadOnlyList<ScanResult> results, string? networkId, bool networkChanged, TimeSpan duration)
    {
        var call = new SaveCall(request, results, networkId, networkChanged);
        lock (_sync) _saves.Add(call);
        return Save(call);
    }

    public void EndScan(ScanRequest request, ScanRunOutcome outcome)
    {
        lock (_sync) _ended.Add(outcome);
        ActiveKindDuringEnd = Coordinator?.ActiveKind;
    }
}

internal sealed class SchedulerHarness : IAsyncDisposable
{
    public SchedulerHarness(Func<CancellationToken, Task<ScanRunOutcome>>? runScan = null)
    {
        Coordinator = new NetworkActivityCoordinator();
        Steps = new ScriptedScanSteps { Coordinator = Coordinator };
        Execution = new ScanExecution(Coordinator, Steps);
        Scheduler = new PeriodicScanScheduler(runScan ?? RunScheduledAsync, Time);
        Scheduler.StatusChanged += (_, status) => Assert.True(Statuses.Writer.TryWrite(status));
    }

    public static DateTimeOffset Start { get; } = new(2026, 11, 6, 8, 0, 0, TimeSpan.Zero);

    public FakeTimeProvider Time { get; } = new(Start);

    public NetworkActivityCoordinator Coordinator { get; }

    public ScriptedScanSteps Steps { get; }

    public ScanExecution Execution { get; }

    public PeriodicScanScheduler Scheduler { get; }

    public Channel<PeriodicScanStatus> Statuses { get; } = Channel.CreateUnbounded<PeriodicScanStatus>();

    public Task<ScanRunOutcome> RunScheduledAsync(CancellationToken cancellationToken) =>
        Execution.RunAsync(new ScanRequest(ScanTrigger.Scheduled, ScanExecutionFixture.Network), cancellationToken);

    public Task<ScanRunOutcome> RunManualAsync() =>
        Execution.RunAsync(new ScanRequest(ScanTrigger.Manual, ScanExecutionFixture.Network));

    public async Task<PeriodicScanStatus> ExpectAsync(PeriodicScanState state)
    {
        var status = await Statuses.ReadNextAsync();
        Assert.Equal(state, status.State);
        return status;
    }

    public async Task<PeriodicScanStatus> ExpectWaitingAsync(TimeSpan delay)
    {
        var status = await ExpectAsync(PeriodicScanState.Waiting);
        Assert.Equal(Time.GetUtcNow() + delay, status.NextAttemptAt);
        return status;
    }

    // Fires the pending wait; the scheduler then publishes Running before invoking the attempt.
    public async Task<PeriodicScanStatus> TickAsync(TimeSpan delay)
    {
        Time.Advance(delay);
        return await ExpectAsync(PeriodicScanState.Running);
    }

    public async Task<ScanCall> TickToScheduledScanAsync(TimeSpan delay)
    {
        await TickAsync(delay);
        var (request, _) = await Steps.Began.ReadNextAsync();
        Assert.Equal(ScanTrigger.Scheduled, request.Trigger);
        return await Steps.Scans.ReadNextAsync();
    }

    public void AssertNoPendingWork()
    {
        Assert.False(Steps.Began.Reader.TryRead(out _));
        Assert.False(Steps.Scans.Reader.TryRead(out _));
    }

    public async ValueTask DisposeAsync() => await Scheduler.StopAsync().WaitAsync(ScanExecutionFixture.Timeout);
}
