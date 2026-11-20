using System.Globalization;
using System.Text.Json;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using FingVibe.Core.Storage;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private readonly NetworkMonitorSettingsStore? _networkMonitorStore = !IsUiReview
        ? new(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "FingVibe",
            "network-monitor.json"))
        : Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW_NETWORK_MONITOR") is { Length: > 0 } reviewPath
            ? new(reviewPath)
            : null;
    private readonly NetworkMonitorService _networkMonitorService =
        new(new NetworkDiagnosticProbes(), CreateNetworkMonitorTimeProvider());
    private readonly NetworkMonitorScheduler _networkMonitorScheduler;
    private readonly NetworkMonitorController _networkMonitorController;
    private bool _networkMonitorLoadFailed;
    private string? _networkMonitorPersistenceError;

    internal event EventHandler<NetworkMonitorSnapshot>? NetworkMonitorStateChanged;

    internal NetworkMonitorSnapshot CurrentNetworkMonitorSnapshot { get; private set; } =
        new(NetworkMonitorState.Off, DateTimeOffset.UtcNow, null, null, NetworkMonitorPresentation.Status(
            NetworkMonitorSettings.Default,
            new NetworkMonitorStatus(NetworkMonitorSchedulerState.Stopped),
            false,
            DateTimeOffset.UtcNow,
            TimeZoneInfo.Local,
            CultureInfo.CurrentCulture));

    private NetworkMonitorSettings LoadNetworkMonitorSettings()
    {
        try
        {
            return _networkMonitorStore?.Load() ?? NetworkMonitorSettings.Default;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
        {
            _networkMonitorLoadFailed = true;
            _networkMonitorPersistenceError = NetworkMonitorPresentation.LoadFailedMessage;
            return NetworkMonitorSettings.Default;
        }
    }

    private void InitializeNetworkMonitoring()
    {
        SettingsPage.SetNetworkMonitor(_networkMonitorController.Settings);
        SettingsPage.NetworkMonitorChanged += SettingsPage_NetworkMonitorChanged;
        _networkMonitorScheduler.StatusChanged += NetworkMonitorScheduler_StatusChanged;
        Closed += (_, _) =>
        {
            SettingsPage.NetworkMonitorChanged -= SettingsPage_NetworkMonitorChanged;
            _networkMonitorScheduler.StatusChanged -= NetworkMonitorScheduler_StatusChanged;
            _ = _networkMonitorController.ShutdownAsync();
        };
        UpdateNetworkMonitorPresentation();
    }

    private async Task ActivateNetworkMonitoringAsync()
    {
        if (_periodicScansClosed)
        {
            return;
        }

        await _networkMonitorController.ActivateAsync();
        UpdateNetworkMonitorPresentation();
    }

    private async void SettingsPage_NetworkMonitorChanged(object? sender, EventArgs e)
    {
        if (_periodicScansClosed)
        {
            return;
        }

        var settings = SettingsPage.SelectedNetworkMonitor;
        SaveNetworkMonitorSettings(settings);
        var applied = _networkMonitorController.ApplyAsync(settings);
        UpdateNetworkMonitorPresentation();
        await applied;
        UpdateNetworkMonitorPresentation();
    }

    private void SaveNetworkMonitorSettings(NetworkMonitorSettings settings)
    {
        if (_networkMonitorStore is null || _networkMonitorLoadFailed)
        {
            return;
        }

        try
        {
            _networkMonitorStore.Save(settings);
            _networkMonitorPersistenceError = null;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            _networkMonitorPersistenceError = NetworkMonitorPresentation.SaveFailedMessage;
        }
    }

    private void NetworkMonitorScheduler_StatusChanged(object? sender, NetworkMonitorStatus status)
    {
        if (DispatcherQueue.HasThreadAccess)
        {
            UpdateNetworkMonitorPresentation();
        }
        else
        {
            DispatcherQueue.TryEnqueue(UpdateNetworkMonitorPresentation);
        }
    }

    private async Task RefreshNetworkMonitoringContextAsync()
    {
        if (_periodicScansClosed)
        {
            return;
        }

        await _networkMonitorController.RefreshContextAsync();
        UpdateNetworkMonitorPresentation();
    }

    private async Task<NetworkMonitorRunOutcome> RunNetworkMonitorAsync(CancellationToken stop)
    {
        if (NetworkPicker.SelectedItem is not LanNetwork network)
        {
            return new(NetworkMonitorRunStatus.Skipped)
            {
                Message = "No active IPv4 LAN is selected."
            };
        }

        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(stop);
        if (!_networkActivityCoordinator.TryAcquireBackground(
                NetworkActivityKind.NetworkHealthMonitor, cancellation, out var lease))
        {
            return new(NetworkMonitorRunStatus.Skipped)
            {
                BlockingActivity = _networkActivityCoordinator.ActiveKind,
                Message = "Another network measurement is active."
            };
        }

        using (lease)
        {
            if (IsUiReview)
            {
                return Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW_NETWORK_MONITOR_FIXTURE") == "1"
                    ? new(NetworkMonitorRunStatus.Completed)
                    {
                        Observation = NetworkMonitorReviewFixture.Create(network, DateTimeOffset.UtcNow)
                    }
                    : new(NetworkMonitorRunStatus.Skipped)
                    {
                        Message = "UI-review mode does not send background network probes."
                    };
            }

            var networkId = ResolveNetworkIdentity(network, out _);
            var observation = await _networkMonitorService.RunAsync(
                network, networkId, cancellation.Token).ConfigureAwait(true);
            var current = NetworkPicker.SelectedItem as LanNetwork;
            var currentId = current is null ? null : ResolveNetworkIdentity(current, out _);
            if (!NetworkMonitorContext.Matches(network, networkId, current, currentId))
            {
                return new(NetworkMonitorRunStatus.Cancelled)
                {
                    Message = "The network context changed; stale observations were rejected."
                };
            }

            return observation.Cancelled
                ? new(NetworkMonitorRunStatus.Cancelled)
                {
                    Observation = observation,
                    Message = observation.Detail
                }
                : new(NetworkMonitorRunStatus.Completed)
                {
                    Observation = observation
                };
        }
    }

    private void UpdateNetworkMonitorPresentation()
    {
        if (_periodicScansClosed)
        {
            return;
        }

        var now = DateTimeOffset.UtcNow;
        var text = NetworkMonitorPresentation.Status(
            _networkMonitorController.Settings,
            _networkMonitorScheduler.Status,
            _networkMonitorController.IsSuspended,
            now,
            TimeZoneInfo.Local,
            CultureInfo.CurrentCulture,
            _networkMonitorPersistenceError,
            _sleepMonitoringError is null ? null : NetworkMonitorPresentation.SleepMonitoringMessage);
        SettingsPage.NetworkMonitorStatus = text;
        CurrentNetworkMonitorSnapshot = NetworkMonitorPresentation.Snapshot(
            _networkMonitorController.Settings,
            _networkMonitorScheduler.Status,
            _networkMonitorController.IsSuspended,
            now,
            text);
        NetworkMonitorStateChanged?.Invoke(this, CurrentNetworkMonitorSnapshot);
    }

    // Lets disposable native checks observe the minute cadence in seconds; real timestamps are unchanged.
    private static TimeProvider CreateNetworkMonitorTimeProvider() =>
        IsUiReview
        && double.TryParse(
            Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW_NETWORK_MONITOR_TIME_SCALE"),
            NumberStyles.Float,
            CultureInfo.InvariantCulture,
            out var scale)
        && scale > 1
            ? new ScaledNetworkMonitorTimeProvider(scale)
            : TimeProvider.System;

    private sealed class ScaledNetworkMonitorTimeProvider(double scale) : TimeProvider
    {
        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period) =>
            base.CreateTimer(callback, state, Scale(dueTime), Scale(period));

        private TimeSpan Scale(TimeSpan value) =>
            value == Timeout.InfiniteTimeSpan ? value : TimeSpan.FromTicks((long)(value.Ticks / scale));
    }
}
