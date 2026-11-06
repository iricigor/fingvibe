namespace FingVibe.App.Views;

// Owns the Devices page's minute refresh of Last seen ages. A refresh changes displayed age text only: it never
// scans, requeries history, writes inventory, or changes Online/status evidence, selection, or ordering.
// Timer callbacks are posted to the UI thread, where a stale generation is ignored after deactivation.
internal sealed class DeviceLastSeenAgeRefresh(
    Func<IEnumerable<ScanResultRow>> rows,
    Action<Action> postToUi,
    TimeProvider? timeProvider = null)
{
    internal static readonly TimeSpan Interval = TimeSpan.FromSeconds(60);
    private readonly TimeProvider _time = timeProvider ?? TimeProvider.System;
    private ITimer? _timer;
    private int _generation;

    internal bool IsActive => _timer is not null;

    internal void SetActive(bool active)
    {
        if (active == IsActive) return;
        _generation++;
        if (!active)
        {
            _timer!.Dispose();
            _timer = null;
            return;
        }

        Refresh(rows());
        var generation = _generation;
        _timer = _time.CreateTimer(_ => postToUi(() =>
        {
            if (generation == _generation) Refresh(rows());
        }), null, Interval, Interval);
    }

    // Rows that join an active table refresh immediately; an inactive page refreshes everything when shown again.
    internal void RefreshIfActive(IEnumerable<ScanResultRow> added)
    {
        if (IsActive) Refresh(added);
    }

    private void Refresh(IEnumerable<ScanResultRow> targets)
    {
        var now = _time.GetUtcNow();
        foreach (var row in targets) row.RefreshLastSeenAge(now);
    }
}
