using System.Diagnostics;
using FingVibe.Core.Models;

namespace FingVibe.App;

internal enum ScanTrigger
{
    Manual,
    Scheduled
}

internal sealed record ScanRequest(ScanTrigger Trigger, LanNetwork Network);

internal enum ScanRunStatus
{
    Completed,
    SaveFailed,
    Cancelled,
    Failed,
    Busy,
    Unavailable
}

internal sealed record ScanRunOutcome(ScanRunStatus Status)
{
    public string? Message { get; init; }

    public NetworkActivityKind? BlockingActivity { get; init; }

    public IReadOnlyList<DeviceDiscovery> Discoveries { get; init; } = [];
}

internal sealed record ScanSaveResult(IReadOnlyList<DeviceDiscovery> Discoveries, string? Error = null)
{
    public bool CheckpointCommitted { get; init; }
}

internal interface IScanExecutionSteps
{
    void BeginScan(ScanRequest request, CancellationTokenSource cancellation);

    string? CaptureNetworkIdentity(LanNetwork network);

    Task<IReadOnlyList<ScanResult>> ScanAsync(ScanRequest request, CancellationToken cancellationToken);

    Task<IReadOnlyList<ScanResult>> ScanAsync(ScanRequest request,
        Func<IReadOnlyList<ScanResult>, ScanCheckpointState, Task> checkpoint,
        CancellationToken cancellationToken) => ScanAsync(request, cancellationToken);

    Task<ScanSaveResult> SaveCheckpointAsync(ScanRequest request, ScanSnapshot snapshot) =>
        snapshot.State == ScanCheckpointState.Complete
            ? SaveAsync(request, snapshot.Results, snapshot.NetworkId, false, snapshot.Duration ?? TimeSpan.Zero)
            : Task.FromResult(new ScanSaveResult([]));

    Task<ScanSaveResult> SaveAsync(
        ScanRequest request,
        IReadOnlyList<ScanResult> results,
        string? networkId,
        bool networkChanged,
        TimeSpan duration);

    void EndScan(ScanRequest request, ScanRunOutcome outcome);
}

// The single LAN scan path for manual and scheduled requests. It holds the shared network-activity lease
// for the whole scan, so conflicting measurements never overlap and busy requests are rejected, not queued.
internal sealed class ScanExecution(NetworkActivityCoordinator coordinator, IScanExecutionSteps steps)
{
    private CancellationTokenSource? _runningCancellation;
    private TaskCompletionSource? _stopped;

    public async Task StopAsync()
    {
        var stopped = _stopped;
        _runningCancellation?.Cancel();
        if (stopped is not null) await stopped.Task;
    }

    public async Task<ScanRunOutcome> RunAsync(ScanRequest request, CancellationToken cancellationToken = default)
    {
        if (!coordinator.TryAcquire(NetworkActivityKind.LanScan, out var lease))
        {
            return new ScanRunOutcome(ScanRunStatus.Busy) { BlockingActivity = coordinator.ActiveKind };
        }

        using (lease)
        using (var cancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
        {
            _runningCancellation = cancellation;
            _stopped = new(TaskCreationOptions.RunContinuationsAsynchronously);
            var outcome = new ScanRunOutcome(ScanRunStatus.Failed) { Message = "The scan stopped unexpectedly." };
            ScanSnapshot? committed = null;
            IReadOnlyList<DeviceDiscovery> discoveries = [];
            try
            {
                steps.BeginScan(request, cancellation);
                var stopwatch = Stopwatch.StartNew();
                var networkId = steps.CaptureNetworkIdentity(request.Network);
                var scanId = Guid.NewGuid();
                var checkpointScheduler = SynchronizationContext.Current is null
                    ? TaskScheduler.Default : TaskScheduler.FromCurrentSynchronizationContext();
                var results = await steps.ScanAsync(request, CheckpointAsync, cancellation.Token);
                cancellation.Token.ThrowIfCancellationRequested();

                if (committed?.State == ScanCheckpointState.Complete)
                {
                    outcome = new ScanRunOutcome(ScanRunStatus.Completed) { Discoveries = discoveries };
                }
                else
                {
                    // Observations stay scoped only when one network identity spans the whole scan.
                    var networkChanged = steps.CaptureNetworkIdentity(request.Network) != networkId;
                    if (networkChanged)
                    {
                        networkId = null;
                    }

                    stopwatch.Stop();
                    var saved = await steps.SaveAsync(request, results, networkId, networkChanged, stopwatch.Elapsed);
                    outcome = saved.Error is null
                        ? new ScanRunOutcome(ScanRunStatus.Completed) { Discoveries = saved.Discoveries }
                        : new ScanRunOutcome(ScanRunStatus.SaveFailed) { Message = saved.Error };
                }

                Task CheckpointAsync(IReadOnlyList<ScanResult> observations, ScanCheckpointState state) =>
                    Task.Factory.StartNew(() => CommitAsync(observations, state), CancellationToken.None,
                        TaskCreationOptions.DenyChildAttach, checkpointScheduler).Unwrap();

                async Task CommitAsync(IReadOnlyList<ScanResult> observations, ScanCheckpointState state)
                {
                    cancellation.Token.ThrowIfCancellationRequested();
                    if (steps.CaptureNetworkIdentity(request.Network) != networkId)
                        throw new InvalidOperationException("The network changed during this scan. Retained checkpoints are incomplete.");
                    var snapshot = new ScanSnapshot(request.Network.Cidr, DateTimeOffset.UtcNow, observations, stopwatch.Elapsed)
                    {
                        ScanId = scanId, State = state, NetworkId = networkId
                    };
                    // Persistence is deliberately not cancelled: close/cancellation awaits this atomic checkpoint.
                    var savedCheckpoint = await steps.SaveCheckpointAsync(request, snapshot);
                    if (savedCheckpoint.CheckpointCommitted) committed = snapshot;
                    if (savedCheckpoint.Error is not null) throw new IOException(savedCheckpoint.Error);
                    committed = snapshot;
                    discoveries = savedCheckpoint.Discoveries;
                }
            }
            catch (OperationCanceledException)
            {
                outcome = committed?.State == ScanCheckpointState.Complete
                    ? new ScanRunOutcome(ScanRunStatus.Completed) { Discoveries = discoveries }
                    : new ScanRunOutcome(ScanRunStatus.Cancelled);
            }
            catch (Exception exception) when (exception is InvalidOperationException or IOException
                or UnauthorizedAccessException or InvalidDataException)
            {
                outcome = new ScanRunOutcome(ScanRunStatus.Failed) { Message = exception.Message };
            }
            finally
            {
                if (committed is { State: ScanCheckpointState.Pending })
                {
                    try
                    {
                        var saved = await steps.SaveCheckpointAsync(request,
                            committed with { State = ScanCheckpointState.Incomplete });
                        if (saved.Error is not null)
                            outcome = new ScanRunOutcome(ScanRunStatus.SaveFailed) { Message = saved.Error };
                    }
                    catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
                        or InvalidDataException or InvalidOperationException)
                    {
                        outcome = new ScanRunOutcome(ScanRunStatus.SaveFailed) { Message = exception.Message };
                    }
                }
                try { steps.EndScan(request, outcome); }
                finally
                {
                    _runningCancellation = null;
                    _stopped.TrySetResult();
                    _stopped = null;
                }
            }

            return outcome;
        }
    }
}
