using FingVibe.Core.Models;

namespace FingVibe.App;

internal enum NetworkMonitorSchedulerState
{
    Stopped,
    Waiting,
    Running
}

internal enum NetworkMonitorRunStatus
{
    Completed,
    Cancelled,
    Skipped,
    Failed
}

internal sealed record NetworkMonitorRunOutcome(NetworkMonitorRunStatus Status)
{
    public NetworkMonitorObservation? Observation { get; init; }
    public NetworkActivityKind? BlockingActivity { get; init; }
    public string? Message { get; init; }
}

internal sealed record NetworkMonitorStatus(
    NetworkMonitorSchedulerState State,
    DateTimeOffset? NextCheckAt = null,
    NetworkMonitorRunOutcome? LastOutcome = null,
    NetworkMonitorObservation? LastObservation = null);

// Runs one raw background check at a time. The first check waits a full minute and every following wait
// starts after the previous check ends, so no catch-up queue can accumulate after sleep or long probes.
internal sealed class NetworkMonitorScheduler(
    Func<CancellationToken, Task<NetworkMonitorRunOutcome>> runCheck,
    TimeProvider? timeProvider = null)
{
    public static readonly TimeSpan Interval = TimeSpan.FromMinutes(1);

    private readonly TimeProvider _time = timeProvider ?? TimeProvider.System;
    private readonly object _sync = new();
    private CancellationTokenSource? _stop;
    private Task _loop = Task.CompletedTask;
    private NetworkMonitorStatus _status = new(NetworkMonitorSchedulerState.Stopped);

    public event EventHandler<NetworkMonitorStatus>? StatusChanged;

    public NetworkMonitorStatus Status
    {
        get
        {
            lock (_sync)
            {
                return _status;
            }
        }
    }

    public void Start()
    {
        lock (_sync)
        {
            if (_stop is not null || !_loop.IsCompleted)
            {
                throw new InvalidOperationException("Network monitoring is already running or still stopping.");
            }

            _stop = new CancellationTokenSource();
            _loop = RunAsync(_stop.Token);
        }
    }

    public async Task StopAsync()
    {
        CancellationTokenSource? stop;
        Task loop;
        lock (_sync)
        {
            stop = _stop;
            _stop = null;
            loop = _loop;
        }

        if (stop is null)
        {
            await loop;
            return;
        }

        try
        {
            stop.Cancel();
            await loop;
        }
        finally
        {
            stop.Dispose();
        }
    }

    private async Task RunAsync(CancellationToken stop)
    {
        await Task.Yield();
        NetworkMonitorRunOutcome? last = null;
        NetworkMonitorObservation? lastObservation = null;
        var nextCheckAt = _time.GetUtcNow() + Interval;
        try
        {
            while (true)
            {
                stop.ThrowIfCancellationRequested();
                var wait = Task.Delay(
                    nextCheckAt - _time.GetUtcNow() > TimeSpan.Zero
                        ? nextCheckAt - _time.GetUtcNow()
                        : TimeSpan.Zero,
                    _time,
                    stop);
                Publish(new NetworkMonitorStatus(
                    NetworkMonitorSchedulerState.Waiting,
                    nextCheckAt,
                    last,
                    lastObservation));
                await wait;
                stop.ThrowIfCancellationRequested();
                Publish(new NetworkMonitorStatus(
                    NetworkMonitorSchedulerState.Running, null, last, lastObservation));
                last = await AttemptAsync(stop);
                lastObservation = last.Observation ?? lastObservation;
                stop.ThrowIfCancellationRequested();
                nextCheckAt += Interval;
                if (nextCheckAt <= _time.GetUtcNow())
                {
                    // A late/long run starts a new full wait, never an immediate catch-up queue.
                    nextCheckAt = _time.GetUtcNow() + Interval;
                }
            }
        }
        catch (OperationCanceledException) when (stop.IsCancellationRequested)
        {
        }
        finally
        {
            Publish(new NetworkMonitorStatus(
                NetworkMonitorSchedulerState.Stopped, null, last, lastObservation));
        }
    }

    private async Task<NetworkMonitorRunOutcome> AttemptAsync(CancellationToken stop)
    {
        try
        {
            return await runCheck(stop);
        }
        catch (OperationCanceledException) when (stop.IsCancellationRequested)
        {
            return new NetworkMonitorRunOutcome(NetworkMonitorRunStatus.Cancelled)
            {
                Message = "The network check was cancelled while FingVibe stopped monitoring."
            };
        }
        catch (Exception exception)
        {
            return new NetworkMonitorRunOutcome(NetworkMonitorRunStatus.Failed)
            {
                Message = exception.Message
            };
        }
    }

    private void Publish(NetworkMonitorStatus status)
    {
        lock (_sync)
        {
            _status = status;
        }

        StatusChanged?.Invoke(this, status);
    }
}
