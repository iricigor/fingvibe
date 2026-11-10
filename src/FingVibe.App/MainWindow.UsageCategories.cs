using FingVibe.App.Views;
using FingVibe.Core.Models;
using Microsoft.UI.Xaml;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private readonly DispatcherTimer _usageClock = new() { Interval = TimeSpan.FromSeconds(30) };
    private CancellationTokenSource? _usageCancellation;
    private int _usageGeneration;
    private bool _usageInitialized;
    private bool _usageClosed;
    private (Guid Revision, string? Network, string? Subnet, DateOnly Date, string Zone)? _usageKey;
    private IReadOnlyDictionary<LogicalDeviceId, DeviceUsageInference>? _usageResults;
    private string _usageStatus = "Usage evidence has not been loaded.";
    private bool _usageLoading;
    private bool UsageVisible => DevicesPage.Visibility == Visibility.Visible || DevicePage.Visibility == Visibility.Visible;

    private void InitializeUsageCategories()
    {
        _usageInitialized = true;
        _usageClock.Tick += (_, _) =>
        {
            TimeZoneInfo.ClearCachedData();
            _ = RefreshUsageCategoriesAsync();
        };
        _usageClock.Start();
        DevicePage.UsageCategorySaveRequested += UsageCategorySaveRequested;
        DevicePage.UsageCategoryReloadRequested += UsageCategoryReloadRequested;
        DevicePage.UsageCategoryRefreshRequested += (_, _) => _ = RefreshUsageCategoriesAsync(force: true);
        Closed += (_, _) =>
        {
            _usageClosed = true;
            _usageClock.Stop();
            CancelUsageQuery();
        };
    }

    private void CancelUsageQuery()
    {
        _usageGeneration++;
        _usageCancellation?.Cancel();
        _usageKey = null;
    }

    private async Task RefreshUsageCategoriesAsync(bool force = false)
    {
        if (!_usageInitialized || _usageClosed) return;
        if (!UsageVisible)
        {
            CancelUsageQuery();
            return;
        }
        var network = NetworkPicker.SelectedItem as LanNetwork;
        string? identityError = null;
        var networkId = network is null ? null : ResolveNetworkIdentity(network, out identityError);
        var time = DateTimeOffset.UtcNow;
        if (force) TimeZoneInfo.ClearCachedData();
        var zone = TimeZoneInfo.Local;
        var date = DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(time, zone).DateTime);
        var key = (_inventory.Revision, networkId, network?.Cidr, date, zone.Id);
        if (!force && _usageKey == key) return;
        CancelUsageQuery();
        _usageKey = key;
        var generation = _usageGeneration;
        _usageResults = null;
        _usageStatus = !_inventoryReady ? "Loading saved inventory..."
            : _inventoryUnavailable ? $"Usage evidence is unavailable: {_inventoryError}"
            : networkId is null ? $"Select a network with a reliable identity. {identityError}"
            : "Loading completed usage evidence...";
        _usageLoading = !_inventoryReady || !_inventoryUnavailable && networkId is not null;
        ApplyUsageCategories();
        if (!_inventoryReady || _inventoryUnavailable || networkId is null || network is null) return;

        using var cancellation = new CancellationTokenSource();
        _usageCancellation = cancellation;
        var revision = _inventory.Revision;
        var devices = _allResults.Select(row => row.UsageIdentity).OfType<LogicalDeviceId>().Distinct().ToArray();
        try
        {
            var results = await Task.Run(async () =>
            {
                if (revision == Guid.Empty || IsUiReview && string.IsNullOrEmpty(ReviewInventoryPath))
                    return (IReadOnlyDictionary<LogicalDeviceId, DeviceUsageInference>)devices.ToDictionary(id => id,
                        id => new DeviceUsageInference(id, DeviceUsageCategory.Unclassified,
                            new(0, 0), new(0, 0), new(0, 0), 0, true, date.AddDays(-6), date, networkId, network.Cidr, zone.Id));
                var evidence = await _inventoryStore.QueryAnalyticsAsync(
                    new(networkId, network.Cidr, time, 7, zone, revision), cancellation.Token);
                return DeviceUsageClassifier.Classify(evidence, cancellation.Token);
            }, cancellation.Token);
            if (generation != _usageGeneration || cancellation.IsCancellationRequested || _usageClosed
                || revision != _inventory.Revision || !UsageVisible) return;
            _usageResults = results;
            _usageLoading = false;
            _usageStatus = "No local evidence for this device on the selected network.";
            ApplyUsageCategories();
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
            or InvalidDataException or InvalidOperationException or ArgumentException)
        {
            if (generation != _usageGeneration || _usageClosed) return;
            _usageResults = null;
            _usageLoading = false;
            _usageStatus = $"Usage evidence could not be loaded: {exception.Message} Refresh to retry; restart if another writer changed the saved inventory.";
            ApplyUsageCategories();
        }
        finally
        {
            if (ReferenceEquals(_usageCancellation, cancellation)) _usageCancellation = null;
        }
    }

    private bool CanEditUsage(ScanResultRow row) => _inventoryReady && !_inventoryUnavailable && row.UsageIdentity is { } id
        && (id.Kind == "mac" ? _inventory.Devices.ContainsKey(id.Id)
            : _inventory.VirtualDevices.Any(slot => slot.Id.ToString("D") == id.Id));

    private void ApplyUsageCategories()
    {
        foreach (var row in _allResults.Concat(_selectedDeviceRow is { } selected ? [selected] : []).Distinct())
        {
            var id = row.UsageIdentity;
            var manual = id is not null && CanEditUsage(row)
                ? CurrentDeviceData.GetUsageCategoryOverride(id) : row.UsageCategoryOverride;
            var inference = id is not null ? _usageResults?.GetValueOrDefault(id) : null;
            if (inference is null && id is not null && _usageResults is not null && _usageKey is { Network: { } network, Subnet: { } subnet } key)
                inference = new(id, DeviceUsageCategory.Unclassified, new(0, 0), new(0, 0), new(0, 0),
                    0, true, key.Date.AddDays(-6), key.Date, network, subnet, key.Zone);
            row.SetUsageCategory(manual, inference, id is null ? "A stable saved identity is required." : _usageStatus,
                loading: id is not null && _usageLoading);
        }
        RefreshVisibleResults();
        DevicesPage.RefreshRowDescriptions();
        if (_selectedDeviceRow is { } current)
            DevicePage.ShowUsageCategory(current, CanEditUsage(current));
    }

    private async void UsageCategorySaveRequested(object? sender, UsageCategorySaveRequest request)
    {
        var row = _selectedDeviceRow;
        if (row is null) return;
        string? error = null;
        var conflict = false;
        await _deviceDataSaveLock.WaitAsync();
        try
        {
            if (CurrentDeviceData.GetUsageCategoryOverride(request.Identity) != request.Previous)
                throw new InvalidOperationException("The saved category changed during this edit. Reload before retrying.");
            await PersistDeviceDataAsync(CurrentDeviceData.SetUsageCategoryOverride(request.Identity, request.Category));
            ApplyUsageCategories();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
            or InvalidDataException or InvalidOperationException or ArgumentException)
        {
            error = exception.Message;
            conflict = exception is InvalidOperationException;
        }
        finally
        {
            _deviceDataSaveLock.Release();
            DevicePage.CompleteUsageCategorySave(request, row, error, conflict);
        }
        if (error is null) await RefreshUsageCategoriesAsync(force: true);
    }

    private async void UsageCategoryReloadRequested(object? sender, Guid token)
    {
        if (_isScanning)
        {
            DevicePage.UsageCategoryReloadFailed(token, "Wait for the current scan to finish before reloading saved data. Your draft is retained.");
            return;
        }
        var identity = _selectedDeviceRow?.UsageIdentity;
        await _deviceDataSaveLock.WaitAsync();
        try
        {
            var saved = await _inventoryStore.LoadMetadataAsync()
                ?? throw new InvalidOperationException("The saved inventory is no longer available.");
            if (_isScanning)
                throw new InvalidOperationException("A scan started while reloading. Wait for it to finish and reload again.");
            ApplyInventoryData(saved);
            _currentScanSnapshot = saved.LatestScan;
            _liveCompletedAt = null;
            RefreshInventoryRows();
            UpdatePeopleRoomFilters();
            if (_selectedDeviceRow?.UsageIdentity == identity
                && _allResults.FirstOrDefault(row => row.UsageIdentity == identity) is { } row)
            {
                _selectedDeviceRow = row;
                DevicePage.UpdateScanObservation(row);
                DevicePage.CompleteUsageCategoryReload(token, row, CanEditUsage(row));
                UpdateDeviceNameActions();
                UpdateDeviceAssignmentPickers();
                UpdateDeviceHistory();
            }
            else if (_selectedDeviceRow?.UsageIdentity == identity)
                throw new InvalidOperationException("The selected saved identity was removed. Return to Devices and choose an existing device.");
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
            or InvalidDataException or InvalidOperationException)
        {
            DevicePage.UsageCategoryReloadFailed(token, $"Saved category could not be reloaded: {exception.Message}. Your draft is retained.");
        }
        finally { _deviceDataSaveLock.Release(); }
        await RefreshUsageCategoriesAsync(force: true);
    }
}
