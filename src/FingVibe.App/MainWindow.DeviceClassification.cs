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

    private void InitializeClassificationPickers()
    {
        DeviceOsPicker.Items.Add(new ComboBoxItem { Content = "Automatic" });
        DeviceTypePicker.Items.Add(new ComboBoxItem { Content = "Automatic" });
        DeviceIconPicker.Items.Add(new ComboBoxItem { Content = "Follow device type" });
        foreach (var os in Enum.GetValues<DeviceOperatingSystem>())
        {
            DeviceOsPicker.Items.Add(new ComboBoxItem { Content = os.Label(), Tag = os });
        }

        foreach (var type in Enum.GetValues<DeviceType>())
        {
            DeviceTypePicker.Items.Add(new ComboBoxItem { Content = type.Label(), Tag = type });
            var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            content.Children.Add(new FontIcon
            {
                Glyph = ScanResultRow.GetIconGlyph(type),
                FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Segoe Fluent Icons"),
                FontSize = 16
            });
            content.Children.Add(new TextBlock { Text = type.Label() });
            var item = new ComboBoxItem { Content = content, Tag = type };
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(item, type.Label());
            DeviceIconPicker.Items.Add(item);
        }
    }

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

        DeviceTypeIcon.Glyph = row.IconGlyph;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(DeviceTypeIcon, row.IconSource);
        ToolTipService.SetToolTip(DeviceTypeIcon, row.IconSource);
        DeviceOsText.Text = row.OperatingSystemText;
        DeviceTypeValueText.Text = row.DeviceTypeText;
        DeviceOsEvidenceText.Text = row.OperatingSystemSource;
        DeviceTypeEvidenceText.Text = row.DeviceTypeSource;
        SelectChoice(DeviceOsPicker, row.ClassificationOverride?.OperatingSystem);
        SelectChoice(DeviceTypePicker, row.ClassificationOverride?.Type);
        SelectChoice(DeviceIconPicker, row.ClassificationOverride?.Icon);
        DeviceClassificationStatusText.Text = _classificationOverridesUnavailable
            ? "Saved classifications could not be loaded. Changes are disabled to protect the saved file."
            : row.Result.MacAddress is null
                ? "A MAC address is required to save corrections; IP addresses can change."
                : MacAddressResolver.IsPrivateOrRandomized(row.Result.MacAddress)
                    ? "This MAC is private/randomized. Corrections apply only while the MAC stays the same."
                    : "Corrections are saved by MAC address and take precedence over automatic detection.";
        UpdateClassificationActions();
    }

    private static void SelectChoice<T>(ComboBox picker, T? value) where T : struct
    {
        picker.SelectedItem = picker.Items.OfType<ComboBoxItem>()
            .First(item => value is null ? item.Tag is null : item.Tag is T tag && tag.Equals(value.Value));
    }

    private DeviceClassificationOverride ReadClassificationChoices() => new(
        (DeviceOsPicker.SelectedItem as ComboBoxItem)?.Tag as DeviceOperatingSystem?,
        (DeviceTypePicker.SelectedItem as ComboBoxItem)?.Tag as DeviceType?,
        (DeviceIconPicker.SelectedItem as ComboBoxItem)?.Tag as DeviceType?);

    private void ClassificationPicker_SelectionChanged(object sender, SelectionChangedEventArgs e) =>
        UpdateClassificationActions();

    private void UpdateClassificationActions()
    {
        var enabled = _selectedDeviceRow?.Result.MacAddress is not null
            && !_classificationOverridesUnavailable && !_isSavingClassification;
        DeviceOsPicker.IsEnabled = enabled;
        DeviceTypePicker.IsEnabled = enabled;
        DeviceIconPicker.IsEnabled = enabled;
        var choices = ReadClassificationChoices();
        var current = _selectedDeviceRow?.ClassificationOverride ?? new DeviceClassificationOverride();
        DeviceClassificationSaveButton.IsEnabled = enabled && choices != current;
        DeviceClassificationResetButton.IsEnabled = enabled && !current.IsEmpty;
    }

    private async void DeviceClassificationSaveButton_Click(object sender, RoutedEventArgs e) =>
        await SaveClassificationOverrideAsync(ReadClassificationChoices());

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
                DeviceClassificationStatusText.Text = value.IsEmpty
                    ? "Automatic detection restored." : "Classification and icon choices saved.";
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException or FormatException)
        {
            DeviceClassificationStatusText.Text = $"Corrections for {row.NameText} could not be saved.";
        }
        finally
        {
            _isSavingClassification = false;
            UpdateClassificationActions();
        }
    }
}
