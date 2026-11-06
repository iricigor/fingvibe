using FingVibe.Core.Models;

namespace FingVibe.App;

// Applies app lifecycle and user preferences to the recurring engine. Scheduling runs only after startup has
// finished, while enabled, and while Windows is awake. Requests record their state immediately and every
// reconciliation is serialized against the latest state, so overlapping preference, sleep, and close events
// cannot start a second loop, race a stop, or let an older request win.
internal sealed class PeriodicScanController(PeriodicScanScheduler scheduler, PeriodicScanSettings initialSettings)
{
    private readonly SemaphoreSlim _gate = new(1, 1);
    private PeriodicScanPolicy? _policy;
    private bool _ready;
    private bool _shutDown;

    public PeriodicScanSettings Settings { get; private set; } = initialSettings.Normalize();

    public bool IsSuspended { get; private set; }

    // True while scheduling is started or a transition, such as stopping an in-flight scan, is still running.
    public bool IsActive => _policy is not null || _gate.CurrentCount == 0;

    public static PeriodicScanPolicy PolicyFor(PeriodicScanSettings settings) =>
        new(TimeSpan.FromMinutes(settings.Normalize().IntervalMinutes));

    public Task ActivateAsync()
    {
        _ready = true;
        return ReconcileAsync();
    }

    public Task ApplyAsync(PeriodicScanSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        Settings = settings.Normalize();
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

    // Permanent: later activation, preference, or wake requests cannot restart scheduling.
    public Task ShutdownAsync()
    {
        _shutDown = true;
        return ReconcileAsync();
    }

    private async Task ReconcileAsync()
    {
        await _gate.WaitAsync();
        try
        {
            if (!_ready || _shutDown || IsSuspended || !Settings.IsEnabled)
            {
                if (_policy is not null)
                {
                    _policy = null;
                    // Cancels a pending wait and any scheduled scan in progress; manual scans are unaffected.
                    await scheduler.StopAsync();
                }

                return;
            }

            var policy = PolicyFor(Settings);
            if (_policy is null)
            {
                scheduler.Start(policy);
            }
            else if (policy != _policy)
            {
                scheduler.UpdatePolicy(policy);
            }

            _policy = policy;
        }
        finally
        {
            _gate.Release();
        }
    }
}

internal static class PeriodicScanTarget
{
    // A scheduled scan keeps using the selected LAN only while the same adapter still reports the same subnet.
    public static bool IsAvailable(IReadOnlyList<LanNetwork> networks, LanNetwork selected) =>
        networks.Any(network => SameAdapter(network, selected)
            && network.NetworkAddress.Equals(selected.NetworkAddress)
            && network.PrefixLength == selected.PrefixLength);

    private static bool SameAdapter(LanNetwork candidate, LanNetwork selected) =>
        !string.IsNullOrWhiteSpace(candidate.InterfaceId) || !string.IsNullOrWhiteSpace(selected.InterfaceId)
            ? string.Equals(candidate.InterfaceId, selected.InterfaceId, StringComparison.OrdinalIgnoreCase)
            : string.Equals(candidate.InterfaceName, selected.InterfaceName, StringComparison.Ordinal);
}
