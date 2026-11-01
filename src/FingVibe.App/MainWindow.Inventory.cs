using System.Runtime.InteropServices;
using System.Security.Cryptography;
using FingVibe.Core.Import;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private readonly DeviceInventoryStore _inventoryStore = new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FingVibe", "device-inventory.json"));
    private readonly SemaphoreSlim _deviceDataSaveLock = new(1, 1);
    private DeviceInventoryData _inventory = DeviceInventoryData.Empty;
    private bool _inventoryReady;
    private bool _inventoryUnavailable;
    private string? _inventoryError;
    private DateTimeOffset? _liveCompletedAt;
    private ScanSnapshot? _currentScanSnapshot;
    private IReadOnlyDictionary<string, string>? _legacyFingerprints;

    private DeviceInventoryData CurrentDeviceData => _inventory with
    {
        Names = _deviceNameOverrides,
        Classifications = _classificationOverrides,
        PeopleRooms = _peopleRooms
    };

    private async Task RestoreInventoryAsync()
    {
        try
        {
            var saved = IsUiReview ? null : await _inventoryStore.LoadAsync();
            if (saved is not null)
            {
                ApplyInventoryData(saved);
                _peopleRoomsReady = true;
                SetPeopleRoomsStatus("People and rooms are saved with the local device inventory.");
            }
            else
            {
                if (!IsUiReview)
                {
                    _legacyFingerprints = await ReadLegacyFingerprintsAsync();
                    await RestoreDeviceNameOverridesAsync();
                    await RestoreClassificationOverridesAsync();
                }
                await RestorePeopleRoomsAsync();
                _inventoryUnavailable = _deviceNameOverridesUnavailable
                    || _classificationOverridesUnavailable || _peopleRoomsUnavailable;
                if (!IsUiReview && _legacyFingerprints is { } fingerprints
                    && !SameFingerprints(fingerprints, await ReadLegacyFingerprintsAsync()))
                    _inventoryUnavailable = true;
                _inventory = CurrentDeviceData;
                if (_inventoryUnavailable)
                    _inventoryError = "Legacy device data could not be loaded. Inventory changes are disabled to protect it.";
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            _inventoryUnavailable = _deviceNameOverridesUnavailable = _classificationOverridesUnavailable = _peopleRoomsUnavailable = true;
            _inventoryError = $"Saved inventory could not be loaded. Changes are disabled: {exception.Message}";
            SetPeopleRoomsStatus(_inventoryError);
            _peopleRoomsReady = true;
        }
        UpdatePeopleRoomsPages();
        UpdatePeopleRoomFilters();
        ConfigureImportPage();
    }

    private void ApplyInventoryData(DeviceInventoryData data)
    {
        _inventory = data;
        _deviceNameOverrides = data.Names.ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.OrdinalIgnoreCase);
        _classificationOverrides = data.Classifications.ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.OrdinalIgnoreCase);
        _peopleRooms = data.PeopleRooms;
    }

    private async Task PersistDeviceDataAsync(DeviceInventoryData data)
    {
        if (!_inventoryReady || _inventoryUnavailable)
            throw new InvalidOperationException("Inventory changes are disabled until all saved data has been loaded.");
        if (!IsUiReview && _inventory.Revision == Guid.Empty && _legacyFingerprints is not null
            && !SameFingerprints(_legacyFingerprints, await ReadLegacyFingerprintsAsync()))
            throw new InvalidOperationException("Legacy saved data changed after loading. Restart and analyze again before migrating it.");
        var saved = IsUiReview ? data with { Revision = Guid.NewGuid() }
            : await _inventoryStore.SaveAsync(data, _inventory.Revision);
        ApplyInventoryData(saved);
        ToolsPage.InvalidateImportAnalysis("Saved device data changed. Analyze again before importing.");
    }

    private static async Task<IReadOnlyDictionary<string, string>> ReadLegacyFingerprintsAsync()
    {
        var fingerprints = new Dictionary<string, string>();
        var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FingVibe");
        foreach (var name in new[] { "device-names.json", "device-classifications.json", "people-rooms.json" })
        {
            try
            {
                await using var stream = File.OpenRead(Path.Combine(directory, name));
                fingerprints[name] = Convert.ToHexString(await SHA256.HashDataAsync(stream));
            }
            catch (FileNotFoundException) { fingerprints[name] = "missing"; }
            catch (DirectoryNotFoundException) { fingerprints[name] = "missing"; }
        }
        return fingerprints;
    }

    private static bool SameFingerprints(IReadOnlyDictionary<string, string> before, IReadOnlyDictionary<string, string> after) =>
        before.Count == after.Count && before.All(pair => after.GetValueOrDefault(pair.Key) == pair.Value);

    private void RefreshInventoryRows(IEnumerable<ScanResult>? unkeyed = null)
    {
        var selectedMac = DevicesPage.SelectedResult?.MacAddress?.ToString();
        _allResults.Clear();
        _minimumLatency = long.MaxValue;
        _maximumLatency = 0;
        foreach (var device in _inventory.Devices.Values)
        {
            var observation = device.LatestObservation;
            var prefix = observation is null ? 0 : int.Parse(observation.Subnet.Split('/')[1]);
            var row = new ScanResultRow(device, prefix, _deviceNameOverrides.GetValueOrDefault(device.Mac),
                _classificationOverrides.GetValueOrDefault(device.Mac),
                historical: observation is null || observation.LastChecked != _liveCompletedAt,
                showLatency: observation?.LastSeen == _currentScanSnapshot?.CompletedAt);
            ApplyPeopleRoomAssignments(row);
            _allResults.Add(row);
            UpdateLatencyRange(row);
        }
        foreach (var result in unkeyed ?? _currentScanSnapshot?.Results.Where(result =>
                     result.Status == HostStatus.Alive && result.MacAddress?.GetAddressBytes().Length != 6) ?? [])
        {
            var prefix = _currentScanSnapshot is null ? 0 : int.Parse(_currentScanSnapshot.Subnet.Split('/')[1]);
            var row = CreateResultRow(result, prefix, historical: _liveCompletedAt is null);
            _allResults.Add(row);
            UpdateLatencyRange(row);
        }
        RefreshVisibleResults();
        DevicesPage.SelectedResult = _allResults.FirstOrDefault(row => row.MacAddress?.ToString() == selectedMac);
        UpdatePeopleRoomsPages();
    }

    private string? GetScanNetworkIdentity(LanNetwork network)
    {
        if (IsUiReview) return "ui-review-network";
        try { return WindowsNetworkProfileIdentity.GetNetworkId(network).ToString("D"); }
        catch (Exception exception) when (exception is InvalidOperationException or COMException)
        {
            _inventoryError = $"Network identity is unavailable; this scan will not mark devices Offline: {exception.Message}";
            return null;
        }
    }

    private void ConfigureImportPage()
    {
        ToolsPage.ConfigureImport(
            () => CurrentDeviceData,
            () => _inventoryReady && !_inventoryUnavailable && !_isScanning,
            ImportAnalyzedDataAsync,
            category => MainNavigation.SelectedItem = category == "People" ? PeopleNavItem : RoomsNavItem,
            WinRT.Interop.WindowNative.GetWindowHandle(this));
    }

    private async Task<string> ImportAnalyzedDataAsync(FingImportAnalysis analysis)
    {
        await _deviceDataSaveLock.WaitAsync();
        try
        {
            if (_isScanning || !_inventoryReady || _inventoryUnavailable || analysis.Revision != _inventory.Revision)
                throw new InvalidOperationException("Device data or scan state changed. Analyze again before importing.");
            if (!analysis.CanImport) throw new InvalidOperationException("There are no eligible changes to import.");
            await PersistDeviceDataAsync(analysis.Updated);
            RefreshInventoryRows();
            UpdatePeopleRoomFilters();
            return $"Imported {analysis.Added:N0} new devices and {analysis.AppliedFields:N0} fields. "
                + $"{analysis.SkippedFields:N0} fields skipped or preserved; {analysis.Warnings.Count:N0} warnings. All changes saved locally.";
        }
        finally { _deviceDataSaveLock.Release(); }
    }
}
