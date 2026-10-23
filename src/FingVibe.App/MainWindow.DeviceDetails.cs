using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private readonly PortScannerService _portScanner = new();
    private ScanResultRow? _selectedDeviceRow;

    private void ResultsList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not ScanResultRow row)
        {
            return;
        }

        _selectedDeviceRow = row;
        var result = row.Result;
        DeviceTitleText.Text = row.NameText;
        DeviceNameInput.Text = result.MacAddress is { } macAddress
            && _deviceNameOverrides.TryGetValue(macAddress.ToString(), out var customName)
                ? customName
                : string.Empty;
        DeviceNameSaveButton.IsEnabled = result.MacAddress is not null && !_deviceNameOverridesUnavailable;
        DeviceNameResetButton.IsEnabled = result.MacAddress is not null && !_deviceNameOverridesUnavailable;
        DeviceNameStatusText.Text = _deviceNameOverridesUnavailable
            ? "Saved custom names could not be loaded."
            : string.Empty;
        DeviceAddressText.Text = result.AddressText;
        DeviceMacText.Text = result.MacAddressText;
        DeviceVendorText.Text = result.VendorText;
        DeviceStatusText.Text = row.IsOnline ? "Online" : "Offline (no ICMP response)";
        DeviceResponseText.Text = result.RoundtripText;
        DeviceProbeText.Text = $"{result.ProbeDuration.TotalMilliseconds:N0} ms";
        DevicePortsList.ItemsSource = result.OpenPortItems;
        DeviceNoPortsText.Visibility = result.OpenPortItems.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        DevicePortScanStatusText.Text = string.Empty;
        ShowPage(DevicePage);
    }

    private async void DeviceNameSaveButton_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(DeviceNameInput.Text))
        {
            DeviceNameStatusText.Text = "Enter a custom name, or reset it to use the discovered name.";
            return;
        }

        await SaveDeviceNameOverrideAsync(DeviceNameInput.Text.Trim());
    }

    private async void DeviceNameResetButton_Click(object sender, RoutedEventArgs e) =>
        await SaveDeviceNameOverrideAsync(null);

    private async Task SaveDeviceNameOverrideAsync(string? customName)
    {
        if (_deviceNameOverridesUnavailable || _selectedDeviceRow?.Result.MacAddress is not { } macAddress)
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

        try
        {
            await _deviceNameOverrideStore.SaveAsync(updatedNames);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException)
        {
            DeviceNameStatusText.Text = "The custom name could not be saved.";
            return;
        }

        _deviceNameOverrides = updatedNames;
        _selectedDeviceRow.SetCustomName(customName);
        DeviceTitleText.Text = _selectedDeviceRow.NameText;
        DeviceNameInput.Text = customName ?? string.Empty;
        DeviceNameStatusText.Text = customName is null ? "Using discovered name." : "Custom name saved.";
        RefreshVisibleResults();
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
            DevicePortsList.ItemsSource = openPorts;
            DeviceNoPortsText.Visibility = openPorts.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            DevicePortScanStatusText.Text = $"{additionalPorts.Count} additional open port(s) found.";
        }
        finally
        {
            DevicePortScanButton.IsEnabled = true;
        }
    }
}
