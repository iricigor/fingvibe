using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private readonly PortScannerService _portScanner = new();
    private readonly UdpServiceProbe _udpServiceProbe = new();
    private static readonly int AdditionalPortCount = PortScannerService.AdditionalPorts.Count;
    private CancellationTokenSource? _devicePortScanCancellation;
    private bool _devicePortScanIsFull;
    private TaskCompletionSource? _devicePortScanCompletion;
    private ScanResultRow? _deviceTargetResetPending;
    private ScanResultRow? _selectedDeviceRow;
    private bool _isSavingDeviceNameOverride;

    private void DeviceRequested(object? sender, ScanResultRow row) => ShowDeviceDetails(row);

    private void ShowDeviceDetails(ScanResultRow row, bool fromRoomMap = false)
    {
        _devicePortScanCancellation?.Cancel();
        if (_isScanning && !_initialResultsPublished)
        {
            return;
        }

        _selectedDeviceRow = row;
        // Reopening Device Details starts from the member shown in Devices.
        ResetDeviceTarget(row);
        _deviceDetailsFromRoomMap = fromRoomMap;
        DevicePage.SetBackDestination(fromRoomMap);
        DevicePage.NameInput = row.NameText;
        DevicePage.NameSaveLabel = "Save";
        DevicePage.NameStatus = _deviceNameOverridesUnavailable
            ? "Saved custom names could not be loaded."
            : string.Empty;
        UpdateDeviceNameActions();
        DevicePage.ShowDevice(row);
        ShowSelectedMatchSuggestions(opening: true);
        DevicePage.ShowUsageCategory(row, CanEditUsage(row), reset: true);
        UpdateDeviceHistory();
        UpdateClassificationDetails();
        UpdateDeviceAssignmentPickers();
        MainNavigation.SelectedItem = DevicesNavItem;
        ShowPage(DevicePage);
        DevicePage.ResetScroll();
    }

    private void UpdateDeviceHistory()
    {
        if (_selectedDeviceRow is not { } row) return;
        var network = NetworkPicker.SelectedItem as LanNetwork;
        DevicePage.ShowHistory(row, network is null ? null : GetScanNetworkIdentity(network), network?.Cidr);
        UpdateDeviceActivity();
    }

    /// <summary>
    /// Returns a linked device from a Device Details address choice to the member Devices shows. A running probe still
    /// reports results for its chosen address, so the reset waits until it finishes.
    /// </summary>
    private void ResetDeviceTarget(ScanResultRow? row)
    {
        if (row is null) return;
        if (_devicePortScanCompletion is not null)
        {
            _deviceTargetResetPending = row;
            return;
        }
        if (row.ResetTarget()) RefreshVisibleResults();
    }

    private void CompletePendingDeviceTargetReset()
    {
        if (_deviceTargetResetPending is not { } row) return;
        _deviceTargetResetPending = null;
        if (!row.ResetTarget()) return;
        RefreshVisibleResults();
        if (ReferenceEquals(_selectedDeviceRow, row) && DevicePage.Visibility == Visibility.Visible)
        {
            DevicePage.UpdateScanObservation(row);
            DevicePage.ShowPorts(row.Result?.OpenPortItems ?? []);
        }
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
        var linked = row.LinkedDevice;
        var hasCustomName = linked is not null ? (savedName = linked.Name) != linked.Confirmed.Name
            : row.VirtualDevice is { } virtualDevice
            ? (savedName = virtualDevice.Name) is not null
            : macAddress is not null && _deviceNameOverrides.TryGetValue(macAddress.ToString(), out savedName);
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
        DevicePage.SetNameResetLabel(linked is null ? "Use imported / discovered name" : "Restore name chosen when linked");
        DevicePage.SetNameActions(canSave, canReset,
            !hasCustomName ? null
            : linked is not null ? $"Restore the name chosen when linked: {linked.Confirmed.Name}"
            : $"Revert to imported name or discovered hostname: {row.AutomaticName}");
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
        var reverting = customName is null;
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
            if (row.LinkedDevice is { } linked)
                await SaveLinkedDeviceAsync(linked.Id, device => device with { Name = customName ?? device.Confirmed.Name });
            else if (row.VirtualDevice is not null)
                await SaveVirtualDeviceAsync(row, device => device with { Name = customName });
            else
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

        if (row.VirtualDevice is null && !row.IsLinked) _deviceNameOverrides = updatedNames;
        if (!row.IsLinked) row.SetCustomName(customName);
        RefreshVisibleResults();
        if (ReferenceEquals(_selectedDeviceRow, row))
        {
            DevicePage.NameInput = row.NameText;
            DevicePage.NameSaveLabel = reverting ? "✓ Reverted" : "✓ Saved";
            DevicePage.NameStatus = string.Empty;
            UpdateDeviceNameActions();
        }

    }

    private void DeviceAddressRequested(object? sender, string address)
    {
        if (_selectedDeviceRow is not { } row || _devicePortScanCancellation is not null) return;
        row.SelectTarget(address);
        UpdateLatencyRange(row);
        DevicePage.ShowConnection(row);
        RefreshVisibleResults();
    }

    private bool TryGetDeviceProbeTarget(out ScanResultRow row, out ScanResult result, out LanNetwork network)
    {
        row = null!;
        result = null!;
        network = null!;
        if (_selectedDeviceRow is not { CanProbe: true, Result: { } current } selected)
        {
            DevicePage.PortScanStatus = "A current local observation is required. Historical or Fing-only addresses are not probed.";
            return false;
        }
        if (NetworkPicker.SelectedItem is not LanNetwork selectedNetwork || _currentScanSnapshot?.Subnet != selectedNetwork.Cidr)
        {
            DevicePage.PortScanStatus = "Select the network used for this observation before probing its address.";
            return false;
        }
        if (selected.VirtualDevice is { } virtualDevice && GetScanNetworkIdentity(selectedNetwork) != virtualDevice.NetworkId)
        {
            DevicePage.PortScanStatus = "The selected Windows network profile does not match this virtual device's current observation.";
            return false;
        }
        if (selected.IsLinkedDeviceRow && GetScanNetworkIdentity(selectedNetwork) != selected.TargetNetworkId)
        {
            DevicePage.PortScanStatus = "The selected Windows network profile does not match the network of this linked device's selected address.";
            return false;
        }
        (row, result, network) = (selected, current, selectedNetwork);
        return true;
    }

    private bool TryAcquireDeviceProbeLease(out IDisposable? lease)
    {
        if (_networkActivityCoordinator.TryAcquire(NetworkActivityKind.DeviceServiceScan, out lease)) return true;
        DevicePage.PortScanStatus = "Another network measurement is active or stopping. Wait before retrying.";
        return false;
    }

    private async void DevicePortScanButton_Click(object sender, RoutedEventArgs e)
    {
        if (_devicePortScanCancellation is { } active)
        {
            if (!_devicePortScanIsFull) active.Cancel();
            return;
        }
        if (!TryGetDeviceProbeTarget(out var row, out var result, out var network)
            || !TryAcquireDeviceProbeLease(out var lease))
            return;

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
        var blockedPorts = 0;
        bool IsSelected() => ReferenceEquals(_selectedDeviceRow, row);
        DevicePage.SetPortScanRunning(true, row.CanProbe);
        NetworkPicker.IsEnabled = false;
        DevicePage.PortScanStatus = $"TCP: scanning 0/{AdditionalPortCount} additional ports...";
        DevicePage.UdpScanStatus = includeUdp ? "UDP: checking 0/2 services..." : "UDP: not requested.";
        var tcpProgress = new Progress<ScanProgress>(progress =>
        {
            if (IsSelected() && tcpRunning && !cancellation.IsCancellationRequested)
            {
                tcpCompleted = Math.Max(tcpCompleted, progress.Completed);
                DevicePage.PortScanStatus = $"TCP: scanning {tcpCompleted}/{AdditionalPortCount} additional ports...";
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
        var tcpResults = new Progress<OpenPort>(port =>
        {
            if (_devicePortScanCancellation != cancellation || !tcpRunning || cancellation.IsCancellationRequested)
                return;
            row.UpdateOpenPorts((row.Result?.OpenPortItems ?? []).Append(port).DistinctBy(item => item.Identity)
                .OrderBy(item => item.Port).ThenBy(item => item.Protocol).ToArray());
            changed = true;
            RefreshVisibleResults();
            if (IsSelected()) DevicePage.ShowPorts(row.Result?.OpenPortItems ?? []);
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
            CompletePendingDeviceTargetReset();
        }

        async Task ScanTcpAsync()
        {
            try
            {
                var ports = await _portScanner.ScanAdditionalAsync(result.Address, cancellation.Token, network.LocalAddress, tcpProgress, tcpResults,
                    _ => Interlocked.Increment(ref blockedPorts));
                row.UpdateOpenPorts((row.Result?.OpenPortItems ?? []).Concat(ports).DistinctBy(port => port.Identity)
                    .OrderBy(port => port.Port).ThenBy(port => port.Protocol).ToArray());
                changed = true;
                RefreshVisibleResults();
                if (IsSelected())
                {
                    DevicePage.ShowPorts(row.Result?.OpenPortItems ?? []);
                    DevicePage.PortScanStatus = $"TCP: complete ({AdditionalPortCount}/{AdditionalPortCount}); {ports.Count} additional open port(s) found."
                        + BlockedPortsNote(Volatile.Read(ref blockedPorts));
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
                row.UpdateOpenPorts((row.Result?.OpenPortItems ?? []).Where(port => port.Protocol != EndpointProtocol.Udp
                    || port.Port is not (53 or 123)).Concat(responding)
                    .DistinctBy(port => port.Identity).OrderBy(port => port.Port).ThenBy(port => port.Protocol).ToArray());
                changed = true;
                RefreshVisibleResults();
                if (IsSelected())
                {
                    DevicePage.ShowPorts(row.Result?.OpenPortItems ?? []);
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

    private async void DeviceFullPortScanRequested(object? sender, RoutedEventArgs e)
    {
        if (_devicePortScanCancellation is { } active)
        {
            if (_devicePortScanIsFull) active.Cancel();
            return;
        }
        if (!TryGetDeviceProbeTarget(out var row, out var result, out var network)) return;
        var address = result.Address;
        bool IsSelected() => ReferenceEquals(_selectedDeviceRow, row);
        if (!await DevicePage.ConfirmFullPortScanAsync(address.ToString()))
        {
            if (IsSelected()) DevicePage.PortScanStatus = "Full TCP: not started.";
            return;
        }
        // The dialog is asynchronous: start only for the same device, address and network that were confirmed.
        if (!IsSelected() || _devicePortScanCancellation is not null) return;
        if (!TryGetDeviceProbeTarget(out _, out var confirmed, out var confirmedNetwork)
            || !confirmed.Address.Equals(address) || !Equals(confirmedNetwork, network))
        {
            DevicePage.PortScanStatus = "Full TCP: not started because the device address or network changed. Confirm again to scan.";
            return;
        }
        if (!TryAcquireDeviceProbeLease(out var lease)) return;

        using var activity = lease;
        using var cancellation = new CancellationTokenSource();
        _devicePortScanCancellation = cancellation;
        _devicePortScanIsFull = true;
        var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _devicePortScanCompletion = completion;
        var total = PortScannerService.FullTcpPlan.Count;
        var running = true;
        var changed = false;
        var checkedPorts = 0;
        var blockedPorts = 0;
        var found = new HashSet<int>();
        DevicePage.SetPortScanRunning(true, row.CanProbe, fullScan: true);
        NetworkPicker.IsEnabled = false;
        DevicePage.UdpScanStatus = string.Empty;
        DevicePage.PortScanStatus = $"Full TCP: checking 0/{total:N0} ports...";
        var progress = new Progress<ScanProgress>(value =>
        {
            if (!running || cancellation.IsCancellationRequested) return;
            checkedPorts = Math.Max(checkedPorts, value.Completed);
            if (IsSelected())
                DevicePage.PortScanStatus = $"Full TCP: checking {checkedPorts:N0}/{total:N0} ports; {found.Count} open so far...";
        });
        var results = new Progress<OpenPort>(port =>
        {
            // Reports posted before cancellation or failure still describe this device; keep them.
            found.Add(port.Port);
            row.UpdateOpenPorts((row.Result?.OpenPortItems ?? []).Append(port).DistinctBy(item => item.Identity)
                .OrderBy(item => item.Port).ThenBy(item => item.Protocol).ToArray());
            changed = true;
            RefreshVisibleResults();
            if (IsSelected()) DevicePage.ShowPorts(row.Result?.OpenPortItems ?? []);
        });
        string outcome;
        try
        {
            try
            {
                var ports = await _portScanner.ScanFullTcpAsync(address, cancellation.Token, network.LocalAddress, progress, results,
                    _ => Interlocked.Increment(ref blockedPorts));
                running = false;
                row.UpdateOpenPorts((row.Result?.OpenPortItems ?? []).Concat(ports).DistinctBy(port => port.Identity)
                    .OrderBy(port => port.Port).ThenBy(port => port.Protocol).ToArray());
                changed = true;
                RefreshVisibleResults();
                if (IsSelected()) DevicePage.ShowPorts(row.Result?.OpenPortItems ?? []);
                outcome = $"Full TCP: complete ({total:N0}/{total:N0} ports checked); {ports.Count} open port(s) found.";
            }
            catch (OperationCanceledException) when (cancellation.IsCancellationRequested)
            {
                outcome = $"Full TCP: canceled after at least {checkedPorts:N0}/{total:N0} ports; coverage is incomplete. "
                    + $"{found.Count} open port(s) found before cancelling are retained.";
            }
            catch (System.Net.Sockets.SocketException exception)
            {
                outcome = $"Full TCP: failed after at least {checkedPorts:N0}/{total:N0} ports: {exception.Message} "
                    + $"Coverage is incomplete; {found.Count} open port(s) found are retained.";
            }
            running = false;
            outcome += BlockedPortsNote(Volatile.Read(ref blockedPorts));
            if (IsSelected()) DevicePage.PortScanStatus = outcome;
            if (changed)
            {
                try { await SaveDeviceProbeResultsAsync(row.Result!); }
                catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException or ArgumentException)
                {
                    if (IsSelected()) DevicePage.PortScanStatus += $" Results could not be saved: {exception.Message}";
                    ShowSnapshotError($"Full TCP scan results could not be saved: {exception.Message}");
                }
            }
        }
        finally
        {
            running = false;
            _devicePortScanCancellation = null;
            _devicePortScanIsFull = false;
            NetworkPicker.IsEnabled = true;
            if (IsSelected()) DevicePage.SetPortScanRunning(false, row.CanProbe);
            _devicePortScanCompletion = null;
            completion.TrySetResult();
            CompletePendingDeviceTargetReset();
        }
    }

    private static string BlockedPortsNote(int blocked) => blocked == 0 ? string.Empty
        : $" Windows blocked {blocked:N0} connection attempt(s); those ports could not be checked and are not counted as open.";

    private async Task StopDevicePortScanAsync()
    {
        var completion = _devicePortScanCompletion;
        _devicePortScanCancellation?.Cancel();
        if (completion is not null) await completion.Task;
    }
}
