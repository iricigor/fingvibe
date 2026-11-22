using System.Diagnostics;
using System.Text.Json;

namespace FingVibe.Core.Updates;

public enum UpdateOutcome { NotChecked, Current, Available, Failed, Disabled }

public sealed record UpdateState(
    UpdateOutcome Outcome, bool IsChecking, StableRelease? Latest, StableRelease? ConfirmedUpdate,
    DateTimeOffset? ConfirmedAt, DateTimeOffset? CheckedAt, DateTimeOffset? NextCheckAt,
    DateTimeOffset? RetryAfter, string? Error);

public sealed class ReleaseUpdateSession : IDisposable
{
    private readonly object _gate = new();
    private readonly Func<CancellationToken, Task<StableRelease>> _check;
    private readonly TimeProvider _clock;
    private readonly CancellationTokenSource _lifetime = new();
    private Task? _inFlight;
    private bool _stopped;
    private UpdateState _state;

    public ReleaseUpdateSession(bool isRelease, string installedVersion,
        Func<CancellationToken, Task<StableRelease>> check, TimeProvider? clock = null)
    {
        _clock = clock ?? TimeProvider.System;
        _check = check;
        var validVersion = StableRelease.TryParseVersion(installedVersion, out var parsed);
        InstalledVersion = parsed;
        IsEligible = isRelease && validVersion;
        _state = new UpdateState(isRelease ? validVersion ? UpdateOutcome.NotChecked : UpdateOutcome.Failed : UpdateOutcome.Disabled,
            false, null, null, null, null, IsEligible ? _clock.GetUtcNow().AddMinutes(1) : null, null,
            isRelease && !validVersion ? "The installed release version is invalid; use the stable releases page." : null);
    }

    public bool IsEligible { get; }
    public Version InstalledVersion { get; }
    public UpdateState State { get { lock (_gate) return _state; } }
    public event EventHandler<UpdateState>? Changed;

    public Task RunDueAsync()
    {
        lock (_gate)
            return _stopped || _inFlight is not null || _state.NextCheckAt is not { } due || _clock.GetUtcNow() < due
                ? Task.CompletedTask : CheckAsync();
    }

    public Task CheckAsync()
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_stopped, this);
            if (!IsEligible) throw new InvalidOperationException("This build is not eligible for release checks.");
            return _inFlight ??= CheckCoreAsync();
        }
    }

    private async Task CheckCoreAsync()
    {
        await Task.Yield();
        try
        {
            await ExecuteCheckAsync().ConfigureAwait(false);
        }
        finally
        {
            lock (_gate) _inFlight = null;
        }
    }

    private async Task ExecuteCheckAsync()
    {
        UpdateState previous;
        lock (_gate)
        {
            if (_stopped) return;
            _state = _state with { IsChecking = true };
            previous = _state;
        }
        Changed?.Invoke(this, previous);
        StableRelease? release = null;
        string? error = null;
        var retry = previous.RetryAfter;
        try
        {
            if (retry is { } deadline && deadline > _clock.GetUtcNow())
                throw new ReleaseCheckException($"GitHub requests must wait until {deadline:u}.", deadline);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
            timeout.CancelAfter(TimeSpan.FromSeconds(25));
            release = await _check(timeout.Token).ConfigureAwait(false);
            retry = null;
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested)
        {
            return;
        }
        catch (Exception exception) when (exception is HttpRequestException or IOException or InvalidDataException or JsonException
            or KeyNotFoundException or InvalidOperationException or FormatException or OperationCanceledException)
        {
            Trace.TraceWarning($"Release update check failed: {exception}");
            error = exception is OperationCanceledException ? "The release check timed out." : exception.Message;
            retry = (exception as ReleaseCheckException)?.RetryAfter ?? retry;
        }
        UpdateState completed;
        lock (_gate)
        {
            if (_stopped) return;
            var now = _clock.GetUtcNow();
            var next = now.AddMinutes(10);
            if (retry is { } later && later > next) next = later;
            var newer = release is not null && release.Version > InstalledVersion;
            _state = _state with
            {
                IsChecking = false, CheckedAt = now, NextCheckAt = next, RetryAfter = retry, Error = error,
                Outcome = error is not null ? UpdateOutcome.Failed : newer ? UpdateOutcome.Available : UpdateOutcome.Current,
                Latest = release ?? previous.Latest,
                ConfirmedUpdate = error is not null ? previous.ConfirmedUpdate : newer ? release : null,
                ConfirmedAt = error is not null ? previous.ConfirmedAt : newer ? now : null
            };
            completed = _state;
        }
        Changed?.Invoke(this, completed);
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_stopped) return;
            _stopped = true;
        }
        _lifetime.Cancel();
    }
}
