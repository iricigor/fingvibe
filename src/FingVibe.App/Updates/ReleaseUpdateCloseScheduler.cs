using System.Diagnostics;
using System.Security;
using System.Runtime.Versioning;
using FingVibe.Core.Updates;

namespace FingVibe.App;

[SupportedOSPlatform("windows")]
internal sealed class ReleaseUpdateCloseScheduler : IDisposable
{
    private readonly ReleaseUpdateSession _session;
    private readonly ReleaseUpdateActions _actions;
    private readonly ReleaseUpdateScheduleStore _store;
    private readonly TimeProvider _clock;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private Task? _reconcileTask;
    private ReleaseUpdateSchedule? _schedule;
    private bool _disposed;

    public ReleaseUpdateCloseScheduler(ReleaseUpdateSession session, ReleaseUpdateActions actions,
        ReleaseUpdateScheduleStore store, TimeProvider? clock = null)
    {
        _session = session;
        _actions = actions;
        _store = store;
        _clock = clock ?? TimeProvider.System;
        try
        {
            _schedule = store.Load();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
            or SecurityException or System.Text.Json.JsonException)
        {
            LastError = $"The postponed update schedule could not be loaded: {exception.GetBaseException().Message}";
            Trace.TraceWarning(LastError);
        }
        session.Changed += Session_Changed;
        actions.Changed += Actions_Changed;
        if (session.State.ConfirmedUpdate is not null)
            StartReconcile();
    }

    public bool IsScheduled => _schedule is not null;
    public bool IsPreparing => _reconcileTask is { IsCompleted: false };
    public bool IsReady => _schedule is not null && _actions.CanInstall &&
        _actions.Downloaded?.Version == ScheduledVersion;
    public Version? ScheduledVersion => _schedule is null ||
        !StableRelease.TryParseVersion(_schedule.Version, out var version) ? null : version;
    public string? ScheduledVersionText => ScheduledVersion is { } version
        ? version.ToString(version.Revision == 0 ? 3 : 4)
        : null;
    public double DownloadProgress { get; private set; }
    public string? LastError { get; private set; }
    public event EventHandler? Changed;

    public async Task ScheduleAsync(IProgress<double>? progress = null)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (!_actions.CanUpdateNow)
            throw new InvalidOperationException("This build is not eligible to postpone an update.");
        var release = _session.State.ConfirmedUpdate
            ?? throw new InvalidOperationException("No newer release has been confirmed.");
        var target = release.Version.ToString();
        var targetVersion = release.Version;
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            var current = _schedule;
            _schedule = current is not null &&
                StableRelease.TryParseVersion(current.Version, out var version) &&
                version == release.Version
                    ? current
                    : new ReleaseUpdateSchedule(target, _clock.GetUtcNow());
            _store.Save(_schedule);
            LastError = null;
            RaiseChanged();
        }
        finally
        {
            _gate.Release();
        }
        if (await TryPersistReadyScheduleAsync().ConfigureAwait(false))
            return;
        var reporter = new Progress<double>(value =>
        {
            DownloadProgress = value;
            progress?.Report(value);
            RaiseChanged();
        });
        try
        {
            if (await StartScheduledDownloadAsync(targetVersion, reporter).ConfigureAwait(false))
                await PersistReadyScheduleAsync(targetVersion).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            if (_schedule is null)
                LastError = null;
            RaiseChanged();
            throw;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
            or SecurityException or InvalidDataException or HttpRequestException
            or InvalidOperationException)
        {
            LastError = exception.GetBaseException().Message;
            RaiseChanged();
            throw;
        }
    }

    public async Task CancelAsync()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            _store.Clear();
            _schedule = null;
            LastError = null;
            DownloadProgress = 0;
            RaiseChanged();
        }
        finally
        {
            _gate.Release();
        }
        _actions.CancelDownload();
    }

    public async Task<bool> TryInstallOnCloseAsync()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_schedule is null) return false;
            var release = _session.State.ConfirmedUpdate;
            if (release is null || !StableRelease.TryParseVersion(_schedule.Version, out var version) ||
                version != release.Version)
                return false;
            if (!IsReady && _schedule.IsArmed)
                await TryRestoreReadyScheduleLockedAsync(release).ConfigureAwait(false);
            if (!IsReady)
                return false;
            await _actions.StartInstallHandoffAsync(relaunch: false).ConfigureAwait(false);
            _store.Clear();
            _schedule = null;
            DownloadProgress = 0;
            RaiseChanged();
            return true;
        }
        finally
        {
            _gate.Release();
        }
    }

    public async Task WaitForIdleAsync()
    {
        // A completed reconcile can raise events that start another one; wait until none is in flight.
        while (_reconcileTask is { IsCompleted: false } task)
            await task.ConfigureAwait(false);
    }

    private void Session_Changed(object? sender, UpdateState state)
    {
        if (!_disposed && !state.IsChecking && state.ConfirmedUpdate is not null && _schedule is not null)
            StartReconcile();
    }

    private void Actions_Changed(object? sender, EventArgs e)
    {
        if (!_disposed && _schedule is not null)
            StartReconcile();
    }

    private void StartReconcile()
    {
        if (_reconcileTask is { IsCompleted: false }) return;
        _reconcileTask = ReconcileAsync();
    }

    private async Task ReconcileAsync()
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        StableRelease? release = null;
        try
        {
            if (_disposed) return;
            if (_schedule is null || !StableRelease.TryParseVersion(_schedule.Version, out var scheduledVersion))
                return;
            if (!_session.IsEligible || !_actions.Deployment.IsInstalled)
                return;
            if (_session.InstalledVersion >= scheduledVersion)
            {
                _store.Clear();
                _schedule = null;
                RaiseChanged();
                return;
            }
            release = _session.State.ConfirmedUpdate;
            if (release is null) return;
            if (release.Version > scheduledVersion)
            {
                _schedule = new(release.Version.ToString(), _clock.GetUtcNow());
                _store.Save(_schedule);
                RaiseChanged();
            }
            if (!StableRelease.TryParseVersion(_schedule.Version, out var target) || release.Version != target)
                return;
            if (await TryRestoreReadyScheduleLockedAsync(release).ConfigureAwait(false))
                return;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
            or SecurityException or InvalidDataException or HttpRequestException or OperationCanceledException
            or InvalidOperationException or System.Text.Json.JsonException)
        {
            LastError = exception.GetBaseException().Message;
            RaiseChanged();
        }
        finally
        {
            _gate.Release();
        }
        if (release is null || _schedule is null || _actions.IsDownloading ||
            !StableRelease.TryParseVersion(_schedule.Version, out var targetVersion) ||
            release.Version != targetVersion || IsReady)
            return;
        var progress = new Progress<double>(value =>
        {
            DownloadProgress = value;
            RaiseChanged();
        });
        try
        {
            if (await StartScheduledDownloadAsync(release.Version, progress).ConfigureAwait(false))
                await PersistReadyScheduleAsync(release.Version).ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
            or SecurityException or InvalidDataException or HttpRequestException or OperationCanceledException
            or InvalidOperationException or System.Text.Json.JsonException)
        {
            LastError = exception.GetBaseException().Message;
            RaiseChanged();
        }
    }

    private async Task<bool> TryRestoreReadyScheduleLockedAsync(StableRelease release)
    {
        if (_schedule is null) return false;
        if (_actions.CanInstall && _actions.Downloaded?.Version == release.Version)
        {
            TryPersistReadySchedule();
            return true;
        }
        if (!_schedule.IsArmed)
            return false;
        if (!await _actions.RestoreDownloadedAsync(_schedule, release).ConfigureAwait(false))
        {
            _schedule = _schedule with
            {
                InstallerPath = null, InstallerSha256 = null, InstallerSize = null
            };
            _store.Save(_schedule);
            LastError = "The persisted update file could not be reverified and will be downloaded again.";
            RaiseChanged();
            return false;
        }
        TryPersistReadySchedule();
        return true;
    }

    private bool TryPersistReadySchedule()
    {
        var schedule = _schedule;
        var downloaded = _actions.Downloaded;
        if (schedule is null || downloaded is null ||
            !StableRelease.TryParseVersion(schedule.Version, out var version) ||
            downloaded.Version != version)
            return false;
        var armed = schedule with
        {
            InstallerPath = downloaded.Path,
            InstallerSha256 = downloaded.Sha256,
            InstallerSize = downloaded.Size
        };
        if (armed != schedule)
        {
            _schedule = armed;
            _store.Save(armed);
        }
        DownloadProgress = 100;
        LastError = null;
        RaiseChanged();
        return true;
    }

    private async Task<bool> TryPersistReadyScheduleAsync()
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            return TryPersistReadySchedule();
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task PersistReadyScheduleAsync(Version version)
    {
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_schedule is null || !StableRelease.TryParseVersion(_schedule.Version, out var target) ||
                target != version || _actions.Downloaded?.Version != version)
                return;
            TryPersistReadySchedule();
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task<bool> StartScheduledDownloadAsync(Version version, IProgress<double> progress)
    {
        Task task;
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_schedule is null || !StableRelease.TryParseVersion(_schedule.Version, out var scheduled) ||
                scheduled != version || IsReady || _actions.IsDownloading)
                return false;
            task = _actions.DownloadAsync(progress);
        }
        finally
        {
            _gate.Release();
        }
        await task.ConfigureAwait(false);
        return true;
    }

    private void RaiseChanged()
    {
        if (!_disposed) Changed?.Invoke(this, EventArgs.Empty);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _session.Changed -= Session_Changed;
        _actions.Changed -= Actions_Changed;
    }
}
