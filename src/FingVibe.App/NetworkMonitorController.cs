using FingVibe.Core.Models;

namespace FingVibe.App;

// Serializes preference, startup, sleep, context-change and shutdown requests against the actual scheduler
// state. A stop always awaits the in-flight cancellation before a later enable or refreshed context can start.
internal sealed class NetworkMonitorController(
    NetworkMonitorScheduler scheduler,
    NetworkMonitorSettings initialSettings)
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private bool _ready;
    private bool _running;
    private bool _shutDown;

    public NetworkMonitorSettings Settings { get; private set; } = initialSettings;

    public bool IsSuspended { get; private set; }

    public bool IsActive => _running || _gate.CurrentCount == 0;

    public Task ActivateAsync()
    {
        _ready = true;
        return ReconcileAsync();
    }

    public Task ApplyAsync(NetworkMonitorSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        Settings = settings;
        return ReconcileAsync();
    }

    public Task SuspendAsync()
    {
        IsSuspended = true;
        return ReconcileAsync();
    }

    public Task ResumeAsync()
    {
        IsSuspended = false;
        return ReconcileAsync();
    }

    public Task RefreshContextAsync() => ReconcileAsync(restart: true);

    // Permanent: later activation, enable or wake requests cannot restart the monitor.
    public Task ShutdownAsync()
    {
        _shutDown = true;
        return ReconcileAsync();
    }

    private async Task ReconcileAsync(bool restart = false)
    {
        await _gate.WaitAsync();
        try
        {
            var shouldRun = _ready && !_shutDown && !IsSuspended && Settings.IsEnabled;
            if (_running && (!shouldRun || restart))
            {
                await scheduler.StopAsync();
                _running = false;
            }

            if (shouldRun && !_running)
            {
                scheduler.Start();
                _running = true;
            }
        }

        finally
        {
            _gate.Release();
        }
    }
}

internal static class NetworkMonitorContext
{
    public static bool Matches(
        LanNetwork expected,
        string? expectedIdentity,
        LanNetwork? actual,
        string? actualIdentity) =>
        actual is not null
        && PeriodicScanTarget.IsAvailable([actual], expected)
        && actual.LocalAddress.Equals(expected.LocalAddress)
        && Equals(actual.GatewayAddress, expected.GatewayAddress)
        && string.Equals(expectedIdentity, actualIdentity, StringComparison.Ordinal);
}
