namespace FingVibe.App;

internal enum NetworkActivityKind
{
    LanScan,
    InternetSpeedTest,
    NetworkTroubleshooting,
    DeviceServiceScan,
    NetworkHealthMonitor
}

internal sealed class NetworkActivityCoordinator
{
    private readonly object _sync = new();
    private long _activeId;
    private long _nextId;
    private NetworkActivityKind? _activeKind;
    private CancellationTokenSource? _preemptibleCancellation;
    private TaskCompletionSource? _preemptibleReleased;

    public NetworkActivityKind? ActiveKind
    {
        get
        {
            lock (_sync)
            {
                return _activeKind;
            }
        }
    }

    public bool TryAcquire(NetworkActivityKind kind, out IDisposable? lease)
    {
        return TryAcquire(kind, null, out lease);
    }

    public bool TryAcquireBackground(
        NetworkActivityKind kind,
        CancellationTokenSource cancellation,
        out IDisposable? lease)
    {
        ArgumentNullException.ThrowIfNull(cancellation);
        if (kind != NetworkActivityKind.NetworkHealthMonitor)
        {
            throw new ArgumentException("Only network health monitoring can be preempted.", nameof(kind));
        }

        return TryAcquire(kind, cancellation, out lease);
    }

    // A foreground operation cancels an active background monitor and waits for its lease to be released.
    // Other foreground work keeps the existing immediate busy behavior; monitoring never overlaps it.
    public async Task<IDisposable?> AcquireAsync(NetworkActivityKind kind, CancellationToken cancellationToken = default)
    {
        if (kind == NetworkActivityKind.NetworkHealthMonitor)
        {
            throw new ArgumentOutOfRangeException(
                nameof(kind), kind, "Background monitoring must use TryAcquireBackground.");
        }
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            CancellationTokenSource? preempt;
            Task? released;
            lock (_sync)
            {
                if (_activeKind is null)
                {
                    if (!TryAcquireCore(kind, null, out var lease))
                    {
                        throw new InvalidOperationException("Network activity acquisition failed unexpectedly.");
                    }

                    return lease;
                }

                if (_preemptibleCancellation is null || _preemptibleReleased is null)
                {
                    return null;
                }

                preempt = _preemptibleCancellation;
                released = _preemptibleReleased.Task;
            }

            if (!preempt.IsCancellationRequested)
            {
                preempt.Cancel();
            }
            await released.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
    }

    private bool TryAcquire(NetworkActivityKind kind, CancellationTokenSource? preemptibleCancellation, out IDisposable? lease)
    {
        lock (_sync)
        {
            return TryAcquireCore(kind, preemptibleCancellation, out lease);
        }
    }

    private bool TryAcquireCore(
        NetworkActivityKind kind,
        CancellationTokenSource? preemptibleCancellation,
        out IDisposable? lease)
    {
        if (_activeKind is not null)
        {
            lease = null;
            return false;
        }

        _activeKind = kind;
        _activeId = ++_nextId;
        _preemptibleCancellation = preemptibleCancellation;
        _preemptibleReleased = preemptibleCancellation is null
            ? null
            : new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        lease = new ActivityLease(this, _activeId);
        return true;
    }

    private void Release(long id)
    {
        TaskCompletionSource? released;
        lock (_sync)
        {
            if (_activeId != id)
            {
                return;
            }

            _activeKind = null;
            _activeId = 0;
            _preemptibleCancellation = null;
            released = _preemptibleReleased;
            _preemptibleReleased = null;
        }

        released?.TrySetResult();
    }

    private sealed class ActivityLease(NetworkActivityCoordinator owner, long id) : IDisposable
    {
        private NetworkActivityCoordinator? _owner = owner;

        public void Dispose() => Interlocked.Exchange(ref _owner, null)?.Release(id);
    }
}
