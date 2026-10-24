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
    private readonly DeviceNameOverrideStore _deviceNameOverrideStore = new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "FingVibe",
        "device-names.json"));
    private Dictionary<string, string> _deviceNameOverrides = new(StringComparer.OrdinalIgnoreCase);
    private bool _deviceNameOverridesUnavailable;
    private bool _hasRestoredSnapshot;

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
                var row = CreateResultRow(result, prefixLength);
                _allResults.Add(row);
                UpdateLatencyRange(row);
            }

            RefreshVisibleResults();
            UpdatePeopleRoomsPages();
            ShowSavedSnapshotStatus(snapshot);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            ShowSnapshotError("The saved scan could not be loaded. Scan LAN to create a new snapshot.");
        }
    }

    private async Task RestoreDeviceNameOverridesAsync()
    {
        try
        {
            var savedNames = await _deviceNameOverrideStore.LoadAsync();
            _deviceNameOverrides = savedNames.ToDictionary(
                pair => pair.Key,
                pair => pair.Value,
                StringComparer.OrdinalIgnoreCase);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            _deviceNameOverrides = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            _deviceNameOverridesUnavailable = true;
        }
    }

    private ScanResultRow CreateResultRow(ScanResult result, int prefixLength)
    {
        if (IsUiReview && System.Net.IPAddress.IsLoopback(result.Address))
        {
            result = result with { MacAddress = System.Net.NetworkInformation.PhysicalAddress.Parse("020000000001") };
        }

        var customName = result.MacAddress is { } macAddress
            && _deviceNameOverrides.TryGetValue(macAddress.ToString(), out var name)
                ? name
                : null;
        var classificationOverride = result.MacAddress is { } mac
            && _classificationOverrides.TryGetValue(mac.ToString(), out var saved) ? saved : null;
        var row = new ScanResultRow(result, prefixLength, customName, classificationOverride);
        ApplyPeopleRoomAssignments(row);
        return row;
    }

    private async Task SaveCompletedScanAsync(LanNetwork network, IEnumerable<ScanResultRow> results)
    {
        var snapshot = new ScanSnapshot(
            network.Cidr,
            DateTimeOffset.UtcNow,
            results.Select(row => row.Result).ToArray());
        _displayedScan = new OverviewScanContext(snapshot.Subnet, snapshot.CompletedAt, ScanDisplayStatus.Completed);
        UpdateOverview();
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
        _displayedScan = new OverviewScanContext(snapshot.Subnet, snapshot.CompletedAt, ScanDisplayStatus.Completed);
        var age = ScanAgeFormatter.FormatAge(DateTimeOffset.UtcNow - snapshot.CompletedAt);
        var completedAt = snapshot.CompletedAt.ToLocalTime().ToString("g");
        SnapshotStatusText.Text = $"Saved results for {snapshot.Subnet} · {age} old · completed {completedAt}";
        SnapshotStatusText.Visibility = Visibility.Visible;
        UpdateOverview();
    }

    private void ShowSnapshotError(string message)
    {
        SnapshotStatusText.Text = _displayedScan is { } scan
            ? $"{message} {scan.Describe((NetworkPicker.SelectedItem as LanNetwork)?.Cidr)}"
            : message;
        SnapshotStatusText.Visibility = Visibility.Visible;
    }
}
