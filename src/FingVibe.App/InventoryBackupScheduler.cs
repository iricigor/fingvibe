using FingVibe.Core.Storage;
using Microsoft.Data.Sqlite;

namespace FingVibe.App;

internal sealed record InventoryBackupStatus(bool Running = false, bool Pending = false,
    string? Error = null, bool Missing = false, bool ManualCooldown = false, bool ManualFailed = false);

internal sealed class InventoryBackupScheduler : IDisposable
{
    internal static readonly TimeSpan Delay = TimeSpan.FromSeconds(15);
    private readonly object _sync = new();
    private readonly Func<CancellationToken, Task<InventoryBackupResult>> _create;
    private readonly TimeProvider _time;
    private readonly CancellationTokenSource _stop = new();
    private readonly ITimer _timer;
    private readonly ITimer _cooldownTimer;
    private DateTimeOffset _due;
    private bool _manualPending;
    private bool _closed;
    private InventoryBackupStatus _status = new();
    private Task _execution = Task.CompletedTask;

    public InventoryBackupScheduler(Func<CancellationToken, Task<InventoryBackupResult>> create, TimeProvider? timeProvider = null)
    {
        _create = create;
        _time = timeProvider ?? TimeProvider.System;
        _timer = _time.CreateTimer(_ => StartDueWork(), null, Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
        _cooldownTimer = _time.CreateTimer(_ => EndManualCooldown(), null, Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
    }

    public event EventHandler? Changed;
    public InventoryBackupStatus Status { get { lock (_sync) return _status; } }
    internal Task Execution { get { lock (_sync) return _execution; } }

    public void Schedule() => Request(Delay, manual: false);
    public void BackUpNow() => Request(TimeSpan.Zero, manual: true);

    public void SetMissing()
    {
        lock (_sync) _status = _status with { Missing = true };
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void Request(TimeSpan delay, bool manual)
    {
        lock (_sync)
        {
            if (_closed || manual && (_status.Running || _status.ManualCooldown)) return;
            _manualPending = manual || _manualPending;
            _due = _time.GetUtcNow() + delay;
            _status = _status with { Pending = true, Error = null };
            if (!_status.Running) _timer.Change(delay, Timeout.InfiniteTimeSpan);
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void StartDueWork()
    {
        lock (_sync)
        {
            if (_closed || _status.Running || !_status.Pending) return;
            var remaining = _due - _time.GetUtcNow();
            if (remaining > TimeSpan.Zero)
            {
                _timer.Change(remaining, Timeout.InfiniteTimeSpan);
                return;
            }
            _status = _status with { Running = true, Pending = false, Error = null };
            var manual = _manualPending;
            _manualPending = false;
            _execution = Task.Run(() => RunAsync(manual));
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private async Task RunAsync(bool manual)
    {
        string? error = null;
        var deferred = false;
        var missing = false;
        var succeeded = false;
        try
        {
            var result = await _create(_stop.Token).ConfigureAwait(false);
            deferred = result.Deferred;
            missing = result.Missing;
            succeeded = result.Backup is not null;
        }
        catch (OperationCanceledException) when (_stop.IsCancellationRequested) { }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
            or InvalidDataException or InvalidOperationException or SqliteException)
        {
            error = $"Database backup failed: {exception.Message} Check the database and backup folder, then use Back up now.";
        }
        lock (_sync)
        {
            _status = _status with { Running = false, Error = error, Missing = missing };
            if (manual && (succeeded || error is not null) && !_closed)
            {
                _status = _status with { ManualCooldown = true, ManualFailed = error is not null };
                _cooldownTimer.Change(TimeSpan.FromMinutes(1), Timeout.InfiniteTimeSpan);
            }
            if (deferred && !_closed)
            {
                _status = _status with { Pending = true };
                _manualPending |= manual;
                _due = _time.GetUtcNow() + Delay;
            }
            if (!_closed && _status.Pending)
                _timer.Change(_due <= _time.GetUtcNow() ? TimeSpan.Zero : _due - _time.GetUtcNow(), Timeout.InfiniteTimeSpan);
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    private void EndManualCooldown()
    {
        lock (_sync)
        {
            if (_closed) return;
            _status = _status with { ManualCooldown = false, ManualFailed = false };
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void Dispose()
    {
        lock (_sync)
        {
            if (_closed) return;
            _closed = true;
            _status = _status with { Pending = false };
            _timer.Dispose();
            _cooldownTimer.Dispose();
        }
        // SQLite's synchronous backup cannot be interrupted mid-call; the store checks cancellation before publication.
        _stop.Cancel();
    }
}
