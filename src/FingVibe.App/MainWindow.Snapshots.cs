using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Microsoft.UI.Xaml;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private readonly ScanSnapshotStore _snapshotStore = new(
        IsUiReview && Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW_SNAPSHOT") is { Length: > 0 } reviewSnapshot
            ? reviewSnapshot
            : Path.Combine(
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
    private string? _snapshotError;

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
                RefreshInventoryRows();
                return;
            }

            _currentScanSnapshot = snapshot;
            var missingObservations = snapshot.Results.Where(result => result.MacAddress is { } mac
                && (!_inventory.Devices.TryGetValue(mac.ToString(), out var device) || device.Observations.Count == 0)).ToArray();
            _inventory = _inventory.ObserveCompletedScan(null, snapshot with { Results = missingObservations }, historical: true);
            RefreshInventoryRows();
            UpdatePeopleRoomsPages();
            ShowSavedSnapshotStatus(snapshot);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            RefreshInventoryRows();
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

    private ScanResultRow CreateResultRow(ScanResult result, int prefixLength, bool historical = false)
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
        var row = new ScanResultRow(result, prefixLength, customName, classificationOverride, historical);
        ApplyPeopleRoomAssignments(row);
        return row;
    }

    private async Task SaveCompletedScanAsync(LanNetwork network, IEnumerable<ScanResult> results, string? networkId)
    {
        var snapshot = new ScanSnapshot(
            network.Cidr,
            DateTimeOffset.UtcNow,
            results.ToArray());
        _currentScanSnapshot = snapshot;
        _liveCompletedAt = snapshot.CompletedAt;
        await _deviceDataSaveLock.WaitAsync();
        try
        {
            var observed = CurrentDeviceData.ObserveCompletedScan(networkId, snapshot);
            try
            {
                await PersistDeviceDataAsync(observed);
                _inventoryError = networkId is null && !IsUiReview ? _inventoryError : null;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException)
            {
                _inventory = observed;
                _inventoryError = $"Scan completed, but inventory could not be saved: {exception.Message}";
            }
        }
        finally { _deviceDataSaveLock.Release(); }
        RefreshInventoryRows();
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
        _snapshotError = null;
        UpdateOverview();
    }

    private void ShowSnapshotError(string message)
    {
        _snapshotError = message;
        UpdateScanStatus();
    }
}
