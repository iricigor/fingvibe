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

    private void ResultsList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not ScanResultRow row)
        {
            return;
        }

        _selectedDeviceRow = row;
        var result = row.Result;
        DeviceNameInput.Text = result.MacAddress is { } macAddress
            && _deviceNameOverrides.TryGetValue(macAddress.ToString(), out var customName)
                ? customName
                : row.NameText;
        DeviceNameSaveButton.Content = "Save";
        DeviceNameStatusText.Text = _deviceNameOverridesUnavailable
            ? "Saved custom names could not be loaded."
            : string.Empty;
        UpdateDeviceNameActions();
        DeviceAddressText.Text = result.AddressText;
        DeviceMacText.Text = result.MacAddressText;
        DeviceVendorText.Text = result.VendorText;
        DeviceStatusText.Text = row.IsOnline ? "Online" : "Offline (no ICMP response)";
        DeviceResponseText.Text = result.RoundtripText;
        DeviceProbeText.Text = $"{result.ProbeDuration.TotalMilliseconds:N0} ms";
        DevicePortsList.ItemsSource = result.OpenPortItems;
        DeviceNoPortsText.Visibility = result.OpenPortItems.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        DevicePortScanStatusText.Text = string.Empty;
        DeviceIdentificationEditor.IsExpanded = false;
        UpdateClassificationDetails();
        ShowPage(DevicePage);
        DevicePage.ChangeView(null, 0, null, disableAnimation: true);
    }

    private void DeviceNameInput_TextChanged(object sender, TextChangedEventArgs e)
    {
        DeviceNameSaveButton.Content = "Save";
        UpdateDeviceNameActions();
    }

    private async void DeviceNameSaveButton_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(DeviceNameInput.Text))
        {
            DeviceNameStatusText.Text = "A device name cannot be empty.";
            return;
        }

        await SaveDeviceNameOverrideAsync(DeviceNameInput.Text.Trim());
    }

    private async void DeviceNameResetButton_Click(object sender, RoutedEventArgs e) =>
        await SaveDeviceNameOverrideAsync(null);

    private void UpdateDeviceNameActions()
    {
        var row = _selectedDeviceRow;
        if (row is null)
        {
            DeviceNameSaveButton.IsEnabled = false;
            DeviceNameResetButton.IsEnabled = false;
            return;
        }

        var macAddress = row.Result.MacAddress;
        string? savedName = null;
        var hasCustomName = macAddress is not null
            && _deviceNameOverrides.TryGetValue(macAddress.ToString(), out savedName);
        var currentName = savedName ?? row.Result.NameText;
        var inputName = DeviceNameInput.Text.Trim();

        DeviceNameSaveButton.IsEnabled = macAddress is not null
            && !_deviceNameOverridesUnavailable
            && !_isSavingDeviceNameOverride
            && !string.IsNullOrWhiteSpace(inputName)
            && !string.Equals(inputName, currentName, StringComparison.Ordinal);
        DeviceNameResetButton.IsEnabled = hasCustomName
            && !_deviceNameOverridesUnavailable
            && !_isSavingDeviceNameOverride;
        ToolTipService.SetToolTip(
            DeviceNameResetButton,
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
                DeviceNameStatusText.Text = "The custom name could not be saved.";
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
            DeviceNameInput.Text = row.NameText;
            DeviceNameSaveButton.Content = customName is null ? "✓ Reverted" : "✓ Saved";
            DeviceNameStatusText.Text = string.Empty;
            UpdateDeviceNameActions();
        }
    }

    private async void DevicePortScanButton_Click(object sender, RoutedEventArgs e)
    {
        if (_selectedDeviceRow is not { } row)
        {
            return;
        }

        DevicePortScanButton.IsEnabled = false;
        DevicePortScanStatusText.Text = $"Scanning {PortScannerService.AdditionalPorts.Count} additional TCP ports...";

        try
        {
            var additionalPorts = await _portScanner.ScanAdditionalAsync(row.Result.Address, CancellationToken.None);
            var openPorts = row.Result.OpenPortItems
                .Concat(additionalPorts)
                .DistinctBy(port => port.Port)
                .OrderBy(port => port.Port)
                .ToArray();
            row.UpdateOpenPorts(openPorts);
            if (ReferenceEquals(_selectedDeviceRow, row))
            {
                DevicePortsList.ItemsSource = openPorts;
                DeviceNoPortsText.Visibility = openPorts.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
                DevicePortScanStatusText.Text = $"{additionalPorts.Count} additional open port(s) found.";
            }
        }
        finally
        {
            DevicePortScanButton.IsEnabled = true;
        }
    }
}
