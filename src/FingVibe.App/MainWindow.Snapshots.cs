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
            var snapshot = await _snapshotStore.LoadForRestoreAsync(_inventory.LatestScan);
            if (_inventoryUnavailable && snapshot is { ScanId: var id } && id != Guid.Empty)
                throw new InvalidDataException("The authoritative inventory checkpoint is unavailable.");
            if (snapshot is null)
            {
                RefreshInventoryRows();
                return;
            }

            _currentScanSnapshot = snapshot;
            var isCurrentReviewSnapshot = IsUiReview
                && _inventory.LatestScan is null
                && Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT") == "1"
                && Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW_SNAPSHOT") is { Length: > 0 }
                && snapshot.State == ScanCheckpointState.Complete;
            var missingObservations = snapshot.Results.Where(result => result.MacAddress is { } mac
                && (!_inventory.Devices.TryGetValue(mac.ToString(), out var device) || device.Observations.Count == 0)).ToArray();
            _inventory = _inventory.ObserveCompletedScan(
                isCurrentReviewSnapshot ? "ui-review-network" : null,
                snapshot with { Results = missingObservations },
                historical: !isCurrentReviewSnapshot);
            // Only explicit synthetic review fixtures can stand in for a current scan.
            if (isCurrentReviewSnapshot)
            {
                _liveCompletedAt = snapshot.CompletedAt;
            }
            RefreshInventoryRows();
            UpdatePeopleRoomsPages();
            ShowSavedSnapshotStatus(snapshot);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            RefreshInventoryRows();
            ShowSnapshotError($"The saved scan could not be loaded: {exception.Message}. Scan LAN to create a new snapshot.");
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

    private async Task<ScanSaveResult> SaveCompletedScanAsync(
        LanNetwork network, IEnumerable<ScanResult> results, string? networkId, TimeSpan duration)
    {
        var snapshot = new ScanSnapshot(
            network.Cidr,
            DateTimeOffset.UtcNow,
            results.ToArray(),
            duration) { ScanId = Guid.NewGuid(), NetworkId = networkId };
        return await SaveScanCheckpointAsync(snapshot);
    }

    private async Task<ScanSaveResult> SaveScanCheckpointAsync(ScanSnapshot snapshot)
    {
        var networkId = snapshot.NetworkId;
        IReadOnlyList<DeviceDiscovery> discoveries = [];
        string? persistenceError = null;
        await _deviceDataSaveLock.WaitAsync();
        try
        {
            var observed = CurrentDeviceData.ObserveCompletedScan(networkId, snapshot,
                historical: snapshot.State == ScanCheckpointState.Incomplete) with { LatestScan = snapshot };
            var candidates = DeviceDiscovery.FindNewDevices(_scanDiscoveryBaseline ?? _persistedInventory, observed, networkId, snapshot);
            try
            {
                await PersistDeviceDataAsync(observed);
                discoveries = candidates;
                _inventoryError = networkId is null && !IsUiReview ? _inventoryError : null;
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidDataException or InvalidOperationException)
            {
                persistenceError = exception.Message;
                _inventoryError = $"Scan checkpoint could not be saved; retaining the last committed observations: {exception.Message}";
            }
        }
        finally { _deviceDataSaveLock.Release(); }
        if (persistenceError is not null)
        {
            UpdateScanStatus();
            return new ScanSaveResult([], persistenceError);
        }
        _currentScanSnapshot = snapshot;
        _liveCompletedAt = snapshot.State == ScanCheckpointState.Incomplete ? null : snapshot.CompletedAt;
        RefreshInventoryRows();
        _initialResultsPublished = true;
        _retainedResultsMessage = " · Retaining checkpointed observations";
        DevicesPage.SetInteractionsEnabled(true);
        UpdateEmptyState();
        _scanMessage = snapshot.State == ScanCheckpointState.Pending
            ? "Initial results · background confirmation pending"
            : snapshot.State == ScanCheckpointState.Incomplete ? "Incomplete scan · checkpointed observations retained" : null;
        if (snapshot.State == ScanCheckpointState.Complete && networkId is null)
            _discoveryMessage = "New-device alerts and baseline establishment are disabled for this scan because network identity is unavailable.";
        ShowSavedSnapshotStatus(snapshot);
        UpdateOverview();
        try
        {
            await _snapshotStore.SaveAsync(snapshot);
            ShowSavedSnapshotStatus(snapshot);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException)
        {
            persistenceError = $"The inventory checkpoint was saved, but the latest-scan cache could not be updated: {exception.Message}";
            ShowSnapshotError(persistenceError);
        }
        return new ScanSaveResult(discoveries, persistenceError) { CheckpointCommitted = true };
    }

    private void ShowSavedSnapshotStatus(ScanSnapshot snapshot)
    {
        _displayedScan = new OverviewScanContext(snapshot.Subnet, snapshot.CompletedAt, snapshot.State switch
        {
            ScanCheckpointState.Pending => ScanDisplayStatus.Scanning,
            ScanCheckpointState.Incomplete => ScanDisplayStatus.Incomplete,
            _ => ScanDisplayStatus.Completed
        });
        _snapshotError = null;
        UpdateOverview();
    }

    private async Task SaveDeviceProbeResultsAsync(ScanResult result)
    {
        var errors = new List<string>();
        await _deviceDataSaveLock.WaitAsync();
        try
        {
            var updatedSnapshot = _currentScanSnapshot is { } current ? current with
            {
                Results = current.Results.Select(item => item.Address.Equals(result.Address) ? result : item).ToArray()
            } : null;
            if (result.MacAddress?.GetAddressBytes().Length == 6)
            {
                var updated = CurrentDeviceData.UpdateProbeResults(result) with
                {
                    LatestScan = updatedSnapshot ?? CurrentDeviceData.LatestScan
                };
                try { await PersistDeviceDataAsync(updated); }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidDataException or InvalidOperationException)
                {
                    _inventory = updated;
                    errors.Add($"Inventory: {exception.Message}");
                }
                if (_selectedDeviceRow?.VirtualDevice is { } slot)
                {
                    _selectedDeviceRow.UpdateVirtualDevice(_inventory.VirtualDevices.First(item => item.Id == slot.Id));
                    UpdateDeviceHistory();
                }
            }
            if (updatedSnapshot is not null)
            {
                _currentScanSnapshot = updatedSnapshot;
                try { await _snapshotStore.SaveAsync(_currentScanSnapshot); }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException)
                {
                    errors.Add($"Snapshot: {exception.Message}");
                }
            }
        }
        finally { _deviceDataSaveLock.Release(); }
        UpdateOverview();
        if (errors.Count > 0) throw new IOException(string.Join(" ", errors));
    }

    private void ShowSnapshotError(string message)
    {
        _snapshotError = message;
        UpdateScanStatus();
    }
}
