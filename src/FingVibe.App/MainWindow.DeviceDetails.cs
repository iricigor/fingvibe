using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private readonly PortScannerService _portScanner = new();
    private readonly UdpServiceProbe _udpServiceProbe = new();
    private CancellationTokenSource? _devicePortScanCancellation;
    private TaskCompletionSource? _devicePortScanCompletion;
    private ScanResultRow? _selectedDeviceRow;
    private bool _isSavingDeviceNameOverride;

    private void DeviceRequested(object? sender, ScanResultRow row) => ShowDeviceDetails(row);

    private void ShowDeviceDetails(ScanResultRow row)
    {
        _devicePortScanCancellation?.Cancel();
        if (_isScanning)
        {
            return;
        }

        _selectedDeviceRow = row;
        DevicePage.NameInput = row.MacAddress is { } macAddress
            && _deviceNameOverrides.TryGetValue(macAddress.ToString(), out var customName)
                ? customName
                : row.NameText;
        DevicePage.NameSaveLabel = "Save";
        DevicePage.NameStatus = _deviceNameOverridesUnavailable
            ? "Saved custom names could not be loaded."
            : string.Empty;
        UpdateDeviceNameActions();
        DevicePage.ShowDevice(row);
        UpdateClassificationDetails();
        UpdateDeviceAssignmentPickers();
        MainNavigation.SelectedItem = DevicesNavItem;
        ShowPage(DevicePage);
        DevicePage.ResetScroll();
    }

    private void DeviceNameInput_TextChanged(object sender, TextChangedEventArgs e)
    {
        DevicePage.NameSaveLabel = "Save";
        UpdateDeviceNameActions();
    }

    private async void DeviceNameSaveButton_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(DevicePage.NameInput))
        {
            DevicePage.NameStatus = "A device name cannot be empty.";
            return;
        }

        await SaveDeviceNameOverrideAsync(DevicePage.NameInput.Trim());
    }

    private async void DeviceNameResetButton_Click(object sender, RoutedEventArgs e) =>
        await SaveDeviceNameOverrideAsync(null);

    private void UpdateDeviceNameActions()
    {
        var row = _selectedDeviceRow;
        if (row is null)
        {
            DevicePage.SetNameActions(false, false, null);
            return;
        }

        var macAddress = row.MacAddress;
        string? savedName = null;
        var hasCustomName = macAddress is not null
            && _deviceNameOverrides.TryGetValue(macAddress.ToString(), out savedName);
        var currentName = savedName ?? row.AutomaticName;
        var inputName = DevicePage.NameInput.Trim();

        var canSave = macAddress is not null
            && _inventoryReady && !_inventoryUnavailable
            && !_deviceNameOverridesUnavailable
            && !_isSavingDeviceNameOverride
            && !string.IsNullOrWhiteSpace(inputName)
            && !string.Equals(inputName, currentName, StringComparison.Ordinal);
        var canReset = hasCustomName
            && _inventoryReady && !_inventoryUnavailable
            && !_deviceNameOverridesUnavailable
            && !_isSavingDeviceNameOverride;
        DevicePage.SetNameActions(canSave, canReset,
            hasCustomName ? $"Revert to imported name or discovered hostname: {row.AutomaticName}" : null);
    }

    private async Task SaveDeviceNameOverrideAsync(string? customName)
    {
        var row = _selectedDeviceRow;
        if (_deviceNameOverridesUnavailable
            || _isSavingDeviceNameOverride
            || row?.MacAddress is not { } macAddress)
        {
            return;
        }

        _isSavingDeviceNameOverride = true;
        UpdateDeviceNameActions();
        await _deviceDataSaveLock.WaitAsync();
        var updatedNames = new Dictionary<string, string>(_deviceNameOverrides, StringComparer.OrdinalIgnoreCase);
        if (customName is null)
        {
            updatedNames.Remove(macAddress.ToString());
        }
        else
        {
            updatedNames[macAddress.ToString()] = customName;
        }

        try
        {
            await PersistDeviceDataAsync(CurrentDeviceData with { Names = updatedNames });
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException or InvalidOperationException)
        {
            if (ReferenceEquals(_selectedDeviceRow, row))
            {
                DevicePage.NameStatus = $"The custom name could not be saved: {exception.Message}";
            }

            return;
        }
        finally
        {
            _isSavingDeviceNameOverride = false;
            _deviceDataSaveLock.Release();
            UpdateDeviceNameActions();
        }

        _deviceNameOverrides = updatedNames;
        row.SetCustomName(customName);
        RefreshVisibleResults();
        if (ReferenceEquals(_selectedDeviceRow, row))
        {
            DevicePage.NameInput = row.NameText;
            DevicePage.NameSaveLabel = customName is null ? "✓ Reverted" : "✓ Saved";
            DevicePage.NameStatus = string.Empty;
            UpdateDeviceNameActions();
        }
    }

    private async void DevicePortScanButton_Click(object sender, RoutedEventArgs e)
    {
        if (_devicePortScanCancellation is { } active)
        {
            active.Cancel();
            return;
        }
        if (_selectedDeviceRow is not { CanProbe: true, Result: { } result } row)
        {
            DevicePage.PortScanStatus = "A current local observation is required. Historical or Fing-only addresses are not probed.";
            return;
        }

        if (NetworkPicker.SelectedItem is not LanNetwork network || _currentScanSnapshot?.Subnet != network.Cidr)
        {
            DevicePage.PortScanStatus = "Select the network used for this observation before probing its address.";
            return;
        }
        if (!_networkActivityCoordinator.TryAcquire(NetworkActivityKind.DeviceServiceScan, out var lease))
        {
            DevicePage.PortScanStatus = "Another network measurement is active or stopping. Wait before retrying.";
            return;
        }

        using var activity = lease;
        using var cancellation = new CancellationTokenSource();
        _devicePortScanCancellation = cancellation;
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _devicePortScanCompletion = completion;
        var includeUdp = DevicePage.IncludeUdp;
        var tcpRunning = true;
        var udpRunning = includeUdp;
        var changed = false;
        var tcpCompleted = 0;
        var udpCompleted = 0;
        bool IsSelected() => ReferenceEquals(_selectedDeviceRow, row);
        DevicePage.SetPortScanRunning(true, row.CanProbe);
        NetworkPicker.IsEnabled = false;
        DevicePage.PortScanStatus = "TCP: scanning 0/100 additional ports...";
        DevicePage.UdpScanStatus = includeUdp ? "UDP: checking 0/2 services..." : "UDP: not requested.";
        var tcpProgress = new Progress<ScanProgress>(progress =>
        {
            if (IsSelected() && tcpRunning && !cancellation.IsCancellationRequested)
            {
                tcpCompleted = Math.Max(tcpCompleted, progress.Completed);
                DevicePage.PortScanStatus = $"TCP: scanning {tcpCompleted}/100 additional ports...";
            }
        });
        var udpProgress = new Progress<ScanProgress>(progress =>
        {
            if (IsSelected() && udpRunning && !cancellation.IsCancellationRequested)
            {
                udpCompleted = Math.Max(udpCompleted, progress.Completed);
                DevicePage.UdpScanStatus = $"UDP: checking {udpCompleted}/2 services...";
            }
        });
        try
        {
            await Task.WhenAll(ScanTcpAsync(), includeUdp ? CheckUdpAsync() : Task.CompletedTask);
            if (changed)
            {
                try { await SaveDeviceProbeResultsAsync(row.Result!); }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException or ArgumentException)
                {
                    if (IsSelected()) DevicePage.PortScanStatus += $" Results could not be saved: {exception.Message}";
                    ShowSnapshotError($"Additional service results could not be saved: {exception.Message}");
                }
            }
        }
        finally
        {
            tcpRunning = udpRunning = false;
            _devicePortScanCancellation = null;
            NetworkPicker.IsEnabled = true;
            if (IsSelected()) DevicePage.SetPortScanRunning(false, row.CanProbe);
            _devicePortScanCompletion = null;
            completion.TrySetResult();
        }

        async Task ScanTcpAsync()
        {
            try
            {
                var ports = await _portScanner.ScanAdditionalAsync(result.Address, cancellation.Token, network.LocalAddress, tcpProgress);
                row.UpdateOpenPorts(row.OpenPortItems.Concat(ports).DistinctBy(port => port.Identity)
                    .OrderBy(port => port.Port).ThenBy(port => port.Protocol).ToArray());
                changed = true;
                RefreshVisibleResults();
                if (IsSelected())
                {
                    DevicePage.ShowPorts(row.OpenPortItems);
                    DevicePage.PortScanStatus = $"TCP: complete (100/100); {ports.Count} additional open port(s) found.";
                }
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
            {
                if (IsSelected()) DevicePage.PortScanStatus = "TCP: canceled; previous and completed results retained.";
            }
            catch (System.Net.Sockets.SocketException exception)
            {
                if (IsSelected()) DevicePage.PortScanStatus = $"TCP: scan failed: {exception.Message}";
            }
            finally { tcpRunning = false; }
        }

        async Task CheckUdpAsync()
        {
            try
            {
                var observations = await _udpServiceProbe.CheckAsync(result.Address, network.LocalAddress, cancellation.Token, udpProgress);
                row.UpdateUdpObservations(observations);
                var responding = observations.Where(item => item.State == UdpServiceState.Responded)
                    .Select(item => new OpenPort(item.Port, item.ServiceName, EndpointProtocol.Udp));
                row.UpdateOpenPorts(row.OpenPortItems.Where(port => port.Protocol != EndpointProtocol.Udp
                    || port.Port is not (53 or 123)).Concat(responding)
                    .DistinctBy(port => port.Identity).OrderBy(port => port.Port).ThenBy(port => port.Protocol).ToArray());
                changed = true;
                RefreshVisibleResults();
                if (IsSelected())
                {
                    DevicePage.ShowPorts(row.OpenPortItems);
                    DevicePage.ShowUdpObservations(observations);
                    DevicePage.UdpScanStatus = $"UDP: complete (2/2); {responding.Count()} responded, "
                        + $"{observations.Count(item => item.State == UdpServiceState.NoResponse)} inconclusive, "
                        + $"{observations.Count(item => item.State == UdpServiceState.Error)} error(s).";
                }
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
            {
                if (IsSelected()) DevicePage.UdpScanStatus = "UDP: canceled; previous observations retained.";
            }
            finally { udpRunning = false; }
        }
    }

    private async Task StopDevicePortScanAsync()
    {
        var completion = _devicePortScanCompletion;
        _devicePortScanCancellation?.Cancel();
        if (completion is not null) await completion.Task;
    }
}
