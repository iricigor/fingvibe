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

internal sealed record ScanSaveResult(IReadOnlyList<DeviceDiscovery> Discoveries, string? Error = null);

internal interface IScanExecutionSteps
{
    void BeginScan(ScanRequest request, CancellationTokenSource cancellation);

    string? CaptureNetworkIdentity(LanNetwork network);

    Task<IReadOnlyList<ScanResult>> ScanAsync(ScanRequest request, CancellationToken cancellationToken);

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
    public async Task<ScanRunOutcome> RunAsync(ScanRequest request, CancellationToken cancellationToken = default)
    {
        if (!coordinator.TryAcquire(NetworkActivityKind.LanScan, out var lease))
        {
            return new ScanRunOutcome(ScanRunStatus.Busy) { BlockingActivity = coordinator.ActiveKind };
        }

        using (lease)
        using (var cancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken))
        {
            var outcome = new ScanRunOutcome(ScanRunStatus.Failed) { Message = "The scan stopped unexpectedly." };
            steps.BeginScan(request, cancellation);
            try
            {
                var stopwatch = Stopwatch.StartNew();
                var networkId = steps.CaptureNetworkIdentity(request.Network);
                var results = await steps.ScanAsync(request, cancellation.Token);
                cancellation.Token.ThrowIfCancellationRequested();

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
            catch (OperationCanceledException)
            {
                outcome = new ScanRunOutcome(ScanRunStatus.Cancelled);
            }
            catch (Exception exception) when (exception is InvalidOperationException or IOException
                or UnauthorizedAccessException or InvalidDataException)
            {
                outcome = new ScanRunOutcome(ScanRunStatus.Failed) { Message = exception.Message };
            }
            finally
            {
                steps.EndScan(request, outcome);
            }

            return outcome;
        }
    }
}
