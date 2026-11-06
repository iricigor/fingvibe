using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.Json;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Microsoft.Windows.System.Power;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    // UI review never touches user preferences; native checks may supply an isolated review file.
    private readonly PeriodicScanSettingsStore? _periodicScanStore = !IsUiReview
        ? new(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "FingVibe",
            "periodic-scan.json"))
        : Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW_PERIODIC_SCAN") is { Length: > 0 } reviewPath
            ? new(reviewPath)
            : null;
    private readonly PeriodicScanController _periodicScanController;
    private bool _periodicScanLoadFailed;
    private string? _periodicScanPersistenceError;
    private string? _sleepMonitoringError;
    private bool _sleepMonitoring;
    private bool _periodicScansClosed;

    private PeriodicScanSettings LoadPeriodicScanSettings()
    {
        try
        {
            return _periodicScanStore?.Load() ?? PeriodicScanSettings.Default;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            // Keep scheduled scans off and never replace a file the user may want to recover.
            _periodicScanLoadFailed = true;
            _periodicScanPersistenceError = PeriodicScanPresentation.LoadFailedMessage;
            return PeriodicScanSettings.Default;
        }
    }

    private void InitializePeriodicScans()
    {
        SettingsPage.SetPeriodicScan(_periodicScanController.Settings);
        SettingsPage.PeriodicScanChanged += SettingsPage_PeriodicScanChanged;
        _periodicScans.StatusChanged += PeriodicScans_StatusChanged;
        try
        {
            PowerManager.SystemSuspendStatusChanged += PowerManager_SystemSuspendStatusChanged;
            _sleepMonitoring = true;
        }
        catch (Exception exception) when (exception is COMException or InvalidOperationException or NotSupportedException)
        {
            Debug.WriteLine(exception);
            _sleepMonitoringError = PeriodicScanPresentation.SleepMonitoringMessage;
        }

        Closed += (_, _) =>
        {
            _periodicScansClosed = true;
            SettingsPage.PeriodicScanChanged -= SettingsPage_PeriodicScanChanged;
            _periodicScans.StatusChanged -= PeriodicScans_StatusChanged;
            if (_sleepMonitoring)
            {
                PowerManager.SystemSuspendStatusChanged -= PowerManager_SystemSuspendStatusChanged;
            }

            _ = _periodicScanController.ShutdownAsync();
        };
        UpdatePeriodicScanPresentation();
    }

    // Scheduling starts only after saved inventory is restored; the first scan still waits a full interval.
    private async Task ActivatePeriodicScansAsync()
    {
        if (_periodicScansClosed)
        {
            return;
        }

        await _periodicScanController.ActivateAsync();
        UpdatePeriodicScanPresentation();
    }

    private async void SettingsPage_PeriodicScanChanged(object? sender, EventArgs e)
    {
        if (_periodicScansClosed || SettingsPage.SelectedPeriodicScan is not { } settings)
        {
            return;
        }

        SavePeriodicScanSettings(settings);
        var applied = _periodicScanController.ApplyAsync(settings);
        UpdatePeriodicScanPresentation();
        await applied;
        UpdatePeriodicScanPresentation();
    }

    private void SavePeriodicScanSettings(PeriodicScanSettings settings)
    {
        if (_periodicScanStore is null || _periodicScanLoadFailed)
        {
            return;
        }

        try
        {
            _periodicScanStore.Save(settings);
            _periodicScanPersistenceError = null;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            _periodicScanPersistenceError = PeriodicScanPresentation.SaveFailedMessage;
        }
    }

    private void PeriodicScans_StatusChanged(object? sender, PeriodicScanStatus status)
    {
        if (DispatcherQueue.HasThreadAccess)
        {
            UpdatePeriodicScanPresentation();
        }
        else
        {
            DispatcherQueue.TryEnqueue(UpdatePeriodicScanPresentation);
        }
    }

    // Raised on a background thread. Sleep cancels a scheduled scan in progress; waking starts a full interval.
    private void PowerManager_SystemSuspendStatusChanged(object? sender, object e)
    {
        SystemSuspendStatus status;
        try
        {
            status = PowerManager.SystemSuspendStatus;
        }
        catch (COMException exception)
        {
            Debug.WriteLine(exception);
            return;
        }

        Func<Task>? change = status switch
        {
            SystemSuspendStatus.Entering => _periodicScanController.SuspendAsync,
            SystemSuspendStatus.AutoResume or SystemSuspendStatus.ManualResume => _periodicScanController.ResumeAsync,
            _ => null
        };
        if (change is null)
        {
            return;
        }

        DispatcherQueue.TryEnqueue(async () =>
        {
            if (_periodicScansClosed)
            {
                return;
            }

            await change();
            UpdatePeriodicScanPresentation();
        });
    }

    private void UpdatePeriodicScanPresentation()
    {
        if (_periodicScansClosed)
        {
            return;
        }

        SettingsPage.PeriodicScanStatus = PeriodicScanPresentation.Status(
            _periodicScanController.Settings,
            _periodicScans.Status,
            _periodicScanController.IsSuspended,
            DateTimeOffset.UtcNow,
            TimeZoneInfo.Local,
            CultureInfo.CurrentCulture,
            _periodicScanPersistenceError,
            _sleepMonitoringError);
        UpdateScanStatus();
    }

    private string? PeriodicScanHeaderSummary() =>
        PeriodicScanPresentation.HeaderSummary(
            _periodicScanController.Settings, _periodicScans.Status, _periodicScanController.IsSuspended);

    // Lets disposable native checks observe minute-based intervals in seconds; real timestamps are unchanged.
    private static TimeProvider CreatePeriodicScanTimeProvider() =>
        IsUiReview
        && double.TryParse(
            Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW_PERIODIC_SCAN_TIME_SCALE"),
            NumberStyles.Float,
            CultureInfo.InvariantCulture,
            out var scale)
        && scale > 1
            ? new ScaledTimeProvider(scale)
            : TimeProvider.System;

    private sealed class ScaledTimeProvider(double scale) : TimeProvider
    {
        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period) =>
            base.CreateTimer(callback, state, Scale(dueTime), Scale(period));

        private TimeSpan Scale(TimeSpan value) =>
            value == Timeout.InfiniteTimeSpan ? value : TimeSpan.FromTicks((long)(value.Ticks / scale));
    }
}
