using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private readonly PortScannerService _portScanner = new();
    private ScanResultRow? _selectedDeviceRow;
    private bool _isSavingDeviceNameOverride;

    private void DeviceRequested(object? sender, ScanResultRow row) => ShowDeviceDetails(row);

    private void ShowDeviceDetails(ScanResultRow row)
    {
        if (_isScanning)
        {
            return;
        }

        _selectedDeviceRow = row;
        var result = row.Result;
        DevicePage.NameInput = result.MacAddress is { } macAddress
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

        var macAddress = row.Result.MacAddress;
        string? savedName = null;
        var hasCustomName = macAddress is not null
            && _deviceNameOverrides.TryGetValue(macAddress.ToString(), out savedName);
        var currentName = savedName ?? row.Result.NameText;
        var inputName = DevicePage.NameInput.Trim();

        var canSave = macAddress is not null
            && !_deviceNameOverridesUnavailable
            && !_isSavingDeviceNameOverride
            && !string.IsNullOrWhiteSpace(inputName)
            && !string.Equals(inputName, currentName, StringComparison.Ordinal);
        var canReset = hasCustomName
            && !_deviceNameOverridesUnavailable
            && !_isSavingDeviceNameOverride;
        DevicePage.SetNameActions(canSave, canReset,
            hasCustomName ? $"Revert to discovered name: {row.Result.NameText}" : null);
    }

    private async Task SaveDeviceNameOverrideAsync(string? customName)
    {
        var row = _selectedDeviceRow;
        if (_deviceNameOverridesUnavailable
            || _isSavingDeviceNameOverride
            || row?.Result.MacAddress is not { } macAddress)
        {
            return;
        }

        var updatedNames = new Dictionary<string, string>(_deviceNameOverrides, StringComparer.OrdinalIgnoreCase);
        if (customName is null)
        {
            updatedNames.Remove(macAddress.ToString());
        }
        else
        {
            updatedNames[macAddress.ToString()] = customName;
        }

        _isSavingDeviceNameOverride = true;
        UpdateDeviceNameActions();
        try
        {
            await _deviceNameOverrideStore.SaveAsync(updatedNames);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException)
        {
            if (ReferenceEquals(_selectedDeviceRow, row))
            {
                DevicePage.NameStatus = "The custom name could not be saved.";
            }

            return;
        }
        finally
        {
            _isSavingDeviceNameOverride = false;
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
        if (_selectedDeviceRow is not { } row)
        {
            return;
        }

        DevicePage.PortScanEnabled = false;
        DevicePage.PortScanStatus = $"Scanning {PortScannerService.AdditionalPorts.Count} additional TCP ports...";

        try
        {
            var additionalPorts = await _portScanner.ScanAdditionalAsync(row.Result.Address, CancellationToken.None);
            var openPorts = row.Result.OpenPortItems
                .Concat(additionalPorts)
                .DistinctBy(port => port.Port)
                .OrderBy(port => port.Port)
                .ToArray();
            row.UpdateOpenPorts(openPorts);
            RefreshVisibleResults();
            if (ReferenceEquals(_selectedDeviceRow, row))
            {
                DevicePage.ShowPorts(openPorts);
                DevicePage.PortScanStatus = $"{additionalPorts.Count} additional open port(s) found.";
            }
        }
        finally
        {
            DevicePage.PortScanEnabled = true;
        }
    }
}
