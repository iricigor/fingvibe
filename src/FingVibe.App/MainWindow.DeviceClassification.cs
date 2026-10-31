using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using FingVibe.Core.Storage;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private readonly DeviceClassificationOverrideStore _classificationOverrideStore = new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "FingVibe", "device-classifications.json"));
    private Dictionary<string, DeviceClassificationOverride> _classificationOverrides =
        new(StringComparer.OrdinalIgnoreCase);
    private bool _classificationOverridesUnavailable;
    private bool _isSavingClassification;

    private async Task RestoreClassificationOverridesAsync()
    {
        try
        {
            var saved = await _classificationOverrideStore.LoadAsync();
            _classificationOverrides = saved.ToDictionary(pair => pair.Key, pair => pair.Value,
                StringComparer.OrdinalIgnoreCase);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            _classificationOverridesUnavailable = true;
        }
    }

    private void UpdateClassificationDetails()
    {
        if (_selectedDeviceRow is not { } row)
        {
            return;
        }

        DevicePage.ShowClassification(row);
        DevicePage.ClassificationStatus = _classificationOverridesUnavailable
            ? "Saved classifications could not be loaded. Changes are disabled to protect the saved file."
            : row.Result.MacAddress is null
                ? "A MAC address is required to save corrections; IP addresses can change."
                : MacAddressResolver.IsPrivateOrRandomized(row.Result.MacAddress)
                    ? "This MAC is private/randomized. Corrections apply only while the MAC stays the same."
                    : "Corrections are saved by MAC address and take precedence over automatic detection.";
        UpdateClassificationActions();
    }

    private void ClassificationPicker_SelectionChanged(object sender, SelectionChangedEventArgs e) =>
        UpdateClassificationActions();

    private void UpdateClassificationActions()
    {
        var enabled = _selectedDeviceRow?.Result.MacAddress is not null
            && !_classificationOverridesUnavailable && !_isSavingClassification;
        var choices = DevicePage.ClassificationChoices;
        var current = _selectedDeviceRow?.ClassificationOverride ?? new DeviceClassificationOverride();
        DevicePage.SetClassificationActions(enabled, enabled && choices != current, enabled && !current.IsEmpty);
    }

    private async void DeviceClassificationSaveButton_Click(object sender, RoutedEventArgs e) =>
        await SaveClassificationOverrideAsync(DevicePage.ClassificationChoices);

    private async void DeviceClassificationResetButton_Click(object sender, RoutedEventArgs e) =>
        await SaveClassificationOverrideAsync(new DeviceClassificationOverride());

    private async Task SaveClassificationOverrideAsync(DeviceClassificationOverride value)
    {
        if (_classificationOverridesUnavailable || _isSavingClassification
            || _selectedDeviceRow is not { } row || row.Result.MacAddress is not { } mac)
        {
            return;
        }

        var updated = new Dictionary<string, DeviceClassificationOverride>(_classificationOverrides,
            StringComparer.OrdinalIgnoreCase);
        var key = mac.ToString();
        if (value.IsEmpty)
        {
            updated.Remove(key);
        }
        else
        {
            updated[key] = value;
        }

        _isSavingClassification = true;
        UpdateClassificationActions();
        try
        {
            await _classificationOverrideStore.SaveAsync(updated);
            _classificationOverrides = updated;
            foreach (var matching in _allResults.Append(row).Distinct()
                .Where(item => item.Result.MacAddress?.ToString() == key))
            {
                matching.SetClassificationOverride(value.IsEmpty ? null : value);
            }

            RefreshVisibleResults();
            if (_selectedDeviceRow?.Result.MacAddress?.ToString() == key)
            {
                UpdateClassificationDetails();
                DevicePage.ClassificationStatus = value.IsEmpty
                    ? "Automatic detection restored." : "Classification and icon choices saved.";
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException or FormatException)
        {
            DevicePage.ClassificationStatus = $"Corrections for {row.NameText} could not be saved.";
        }
        finally
        {
            _isSavingClassification = false;
            UpdateClassificationActions();
        }
    }
}
