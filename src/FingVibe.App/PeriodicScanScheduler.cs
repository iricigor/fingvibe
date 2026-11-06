namespace FingVibe.App;

internal enum PeriodicScanState
{
    Stopped,
    Waiting,
    Running
}

internal sealed record PeriodicScanStatus(
    PeriodicScanState State,
    DateTimeOffset? NextAttemptAt = null,
    ScanRunOutcome? LastOutcome = null,
    int ConsecutiveUnsuccessfulAttempts = 0);

internal sealed record PeriodicScanPolicy
{
    public static readonly TimeSpan MinimumInterval = TimeSpan.FromMinutes(1);
    public static readonly TimeSpan MaximumInterval = TimeSpan.FromDays(1);
    public static readonly TimeSpan MinimumRetryDelay = TimeSpan.FromSeconds(10);
    public static readonly TimeSpan DefaultRetryDelay = TimeSpan.FromMinutes(1);

    public PeriodicScanPolicy(TimeSpan interval, TimeSpan? retryDelay = null)
    {
        if (interval < MinimumInterval || interval > MaximumInterval)
        {
            throw new ArgumentOutOfRangeException(
                nameof(interval), interval, $"The interval must be between {MinimumInterval} and {MaximumInterval}.");
        }

        var retry = retryDelay ?? (DefaultRetryDelay < interval ? DefaultRetryDelay : interval);
        if (retry < MinimumRetryDelay || retry > interval)
        {
            throw new ArgumentOutOfRangeException(
                nameof(retryDelay), retry, $"The retry delay must be between {MinimumRetryDelay} and the interval.");
        }

        Interval = interval;
        RetryDelay = retry;
    }

    public TimeSpan Interval { get; }

    public TimeSpan RetryDelay { get; }

    // Unsuccessful attempts back off exponentially from RetryDelay, never waiting longer than Interval.
    public TimeSpan DelayAfter(int consecutiveUnsuccessfulAttempts)
    {
        if (consecutiveUnsuccessfulAttempts <= 0)
        {
            return Interval;
        }

        var ticks = RetryDelay.Ticks;
        for (var attempt = 1; attempt < consecutiveUnsuccessfulAttempts && ticks < Interval.Ticks; attempt++)
        {
            ticks *= 2;
        }

        return TimeSpan.FromTicks(Math.Min(ticks, Interval.Ticks));
    }
}

// Runs at most one scheduled attempt at a time. Each wait starts only after the previous attempt finishes,
// so long scans, busy ticks, and late timers (for example after sleep) never build a catch-up queue.
// Start, UpdatePolicy, and StopAsync are called from the UI thread; attempts resume on the caller's synchronization context.
internal sealed class PeriodicScanScheduler(
    Func<CancellationToken, Task<ScanRunOutcome>> runScan,
    TimeProvider? timeProvider = null)
{
    private readonly TimeProvider _time = timeProvider ?? TimeProvider.System;
    private readonly object _sync = new();
    private CancellationTokenSource? _stop;
    private CancellationTokenSource? _restartWait;
    private PeriodicScanPolicy? _policy;
    private Task _loop = Task.CompletedTask;
    private PeriodicScanStatus _status = new(PeriodicScanState.Stopped);

    public event EventHandler<PeriodicScanStatus>? StatusChanged;

    public PeriodicScanStatus Status
    {
        get
        {
            lock (_sync)
            {
                return _status;
            }
        }
    }

    public void Start(PeriodicScanPolicy policy)
    {
        ArgumentNullException.ThrowIfNull(policy);
        lock (_sync)
        {
            if (_stop is not null || !_loop.IsCompleted)
            {
                throw new InvalidOperationException("Periodic scanning is already running or still stopping.");
            }

            _policy = policy;
            _stop = new CancellationTokenSource();
            _loop = RunAsync(_stop.Token);
        }
    }

    // A pending wait restarts from now under the new policy; an attempt in progress continues, and the
    // policy applies to the wait that follows it.
    public void UpdatePolicy(PeriodicScanPolicy policy)
    {
        ArgumentNullException.ThrowIfNull(policy);
        CancellationTokenSource? restart;
        lock (_sync)
        {
            if (_stop is null)
            {
                throw new InvalidOperationException("Periodic scanning is not running.");
            }

            _policy = policy;
            restart = _restartWait;
        }

        try
        {
            restart?.Cancel();
        }
        catch (ObjectDisposedException)
        {
            // The wait already finished; the next wait reads the new policy.
        }
    }

    // Cancels the pending wait and any in-flight scheduled scan, then waits until the loop has stopped.
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
        // Leave Start before publishing so status observers never run inside its lock.
        await Task.Yield();
        var unsuccessful = 0;
        ScanRunOutcome? last = null;
        try
        {
            while (true)
            {
                stop.ThrowIfCancellationRequested();
                using var restart = CancellationTokenSource.CreateLinkedTokenSource(stop);
                PeriodicScanPolicy policy;
                lock (_sync)
                {
                    policy = _policy!;
                    _restartWait = restart;
                }

                // Create the timer before publishing its due time so observers cannot advance past it unseen.
                var delay = policy.DelayAfter(unsuccessful);
                var wait = Task.Delay(delay, _time, restart.Token);
                Publish(new PeriodicScanStatus(PeriodicScanState.Waiting, _time.GetUtcNow() + delay, last, unsuccessful));
                try
                {
                    await wait;
                }
                catch (OperationCanceledException) when (!stop.IsCancellationRequested)
                {
                    continue;
                }
                finally
                {
                    lock (_sync)
                    {
                        _restartWait = null;
                    }
                }

                stop.ThrowIfCancellationRequested();
                Publish(new PeriodicScanStatus(PeriodicScanState.Running, null, last, unsuccessful));
                last = await AttemptAsync(stop);
                stop.ThrowIfCancellationRequested();

                // A user-cancelled attempt was deliberate, so it waits a full interval instead of retrying.
                unsuccessful = last.Status is ScanRunStatus.Completed or ScanRunStatus.Cancelled ? 0 : unsuccessful + 1;
            }
        }
        catch (OperationCanceledException) when (stop.IsCancellationRequested)
        {
        }
        finally
        {
            Publish(new PeriodicScanStatus(PeriodicScanState.Stopped, null, last, unsuccessful));
        }
    }

    private async Task<ScanRunOutcome> AttemptAsync(CancellationToken stop)
    {
        try
        {
            return await runScan(stop);
        }
        catch (OperationCanceledException) when (!stop.IsCancellationRequested)
        {
            return new ScanRunOutcome(ScanRunStatus.Cancelled);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            // Nothing awaits the background loop, so unexpected failures are recorded and retried with backoff.
            return new ScanRunOutcome(ScanRunStatus.Failed) { Message = exception.Message };
        }
    }

    private void Publish(PeriodicScanStatus status)
    {
        lock (_sync)
        {
            _status = status;
        }

        StatusChanged?.Invoke(this, status);
    }
}
