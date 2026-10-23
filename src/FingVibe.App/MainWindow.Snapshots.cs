using FingVibe.Core.Formatting;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Microsoft.UI.Xaml;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private readonly ScanSnapshotStore _snapshotStore = new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "FingVibe",
        "latest-scan.json"));
    private bool _hasRestoredSnapshot;
    private ScanSnapshot? _lastCompletedScan;

    private async Task RestoreSavedScanAsync()
    {
        if (_hasRestoredSnapshot)
        {
            return;
        }

        _hasRestoredSnapshot = true;
        try
        {
            var snapshot = await _snapshotStore.LoadAsync();
            if (snapshot is null)
            {
                return;
            }

            var prefixLength = int.Parse(snapshot.Subnet[(snapshot.Subnet.LastIndexOf('/') + 1)..]);
            _minimumLatency = long.MaxValue;
            _maximumLatency = 0;
            foreach (var result in snapshot.Results)
            {
                var row = new ScanResultRow(result, prefixLength);
                _allResults.Add(row);
                UpdateLatencyRange(row);
            }

            RefreshVisibleResults();
            ShowSavedSnapshotStatus(snapshot);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            ShowSnapshotError("The saved scan could not be loaded. Scan LAN to create a new snapshot.");
        }
    }

    private async Task SaveCompletedScanAsync(LanNetwork network, IEnumerable<ScanResultRow> results)
    {
        var snapshot = new ScanSnapshot(
            network.Cidr,
            DateTimeOffset.UtcNow,
            results.Select(row => row.Result).ToArray());
        _lastCompletedScan = snapshot;
        try
        {
            await _snapshotStore.SaveAsync(snapshot);
            ShowSavedSnapshotStatus(snapshot);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException)
        {
            ShowSnapshotError("The completed scan could not be saved.");
        }
    }

    private void ShowSavedSnapshotStatus(ScanSnapshot snapshot)
    {
        _lastCompletedScan = snapshot;
        var age = ScanAgeFormatter.FormatAge(DateTimeOffset.UtcNow - snapshot.CompletedAt);
        var completedAt = snapshot.CompletedAt.ToLocalTime().ToString("g");
        SnapshotStatusText.Text = $"Saved results for {snapshot.Subnet} · {age} old · completed {completedAt}";
        SnapshotStatusText.Visibility = Visibility.Visible;
        UpdateOverview();
    }

    private void ShowSnapshotError(string message)
    {
        SnapshotStatusText.Text = message;
        SnapshotStatusText.Visibility = Visibility.Visible;
    }
}
