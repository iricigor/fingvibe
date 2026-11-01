namespace FingVibe.App;

internal enum NetworkActivityKind
{
    LanScan,
    InternetSpeedTest,
    NetworkTroubleshooting,
    DeviceServiceScan
}

internal sealed class NetworkActivityCoordinator
{
    private readonly object _sync = new();
    private long _activeId;
    private long _nextId;
    private NetworkActivityKind? _activeKind;

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
        lock (_sync)
        {
            if (_activeKind is not null)
            {
                lease = null;
                return false;
            }

            _activeKind = kind;
            _activeId = ++_nextId;
            lease = new ActivityLease(this, _activeId);
            return true;
        }
    }

    private void Release(long id)
    {
        lock (_sync)
        {
            if (_activeId == id)
            {
                _activeKind = null;
                _activeId = 0;
            }
        }
    }

    private sealed class ActivityLease(NetworkActivityCoordinator owner, long id) : IDisposable
    {
        private NetworkActivityCoordinator? _owner = owner;

        public void Dispose() => Interlocked.Exchange(ref _owner, null)?.Release(id);
    }
}
