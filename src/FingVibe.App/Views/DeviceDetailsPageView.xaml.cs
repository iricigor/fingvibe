using FingVibe.Core.Models;
using FingVibe.Core.Import;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace FingVibe.App.Views;

public sealed record DeviceAssignmentChoice(Guid? Id = null, bool AddNew = false);

public sealed partial class DeviceDetailsPageView : UserControl
{
    private bool _updatingAssignments;

    public DeviceDetailsPageView()
    {
        InitializeComponent();
        InitializeClassificationPickers();
    }

    public event RoutedEventHandler? BackRequested;
    public event TextChangedEventHandler? NameChanged;
    public event RoutedEventHandler? NameSaveRequested;
    public event RoutedEventHandler? NameResetRequested;
    public event RoutedEventHandler? PortScanRequested;
    public event SelectionChangedEventHandler? ClassificationChanged;
    public event RoutedEventHandler? ClassificationSaveRequested;
    public event RoutedEventHandler? ClassificationResetRequested;
    public event EventHandler<DeviceAssignmentChoice>? PersonAssignmentRequested;
    public event EventHandler<DeviceAssignmentChoice>? RoomAssignmentRequested;

    internal string NameInput { get => DeviceNameInput.Text; set => DeviceNameInput.Text = value; }
    internal string NameSaveLabel { set => DeviceNameSaveButton.Content = value; }
    internal string NameStatus { set => DeviceNameStatusText.Text = value; }
    internal string PortScanStatus { set => DevicePortScanStatusText.Text = value; }
    internal bool PortScanEnabled { set => DevicePortScanButton.IsEnabled = value; }
    internal string ClassificationStatus { set => DeviceClassificationStatusText.Text = value; }
    internal string AssignmentStatus { set => DeviceAssignmentStatusText.Text = value; }

    internal void ShowDevice(ScanResultRow row)
    {
        var result = row.Result;
        DeviceAddressText.Text = row.AddressText;
        DeviceMacText.Text = row.MacAddressText;
        DeviceVendorText.Text = row.VendorText;
        DeviceVendorText.Opacity = row.VendorOpacity;
        DeviceStatusText.Text = row.StatusContext;
        DeviceResponseText.Text = row.LatencyLabel;
        DeviceProbeText.Text = result is null ? "-" : $"{result.ProbeDuration.TotalMilliseconds:N0} ms";
        DeviceHostnameText.Text = row.HostnameText;
        DeviceAddressSourceText.Text = result is null ? "Historical IP from Fing; never observed locally."
            : $"Last-known local address{(row.IsHistorical ? " (historical)" : string.Empty)}.";
        DeviceImportedMetadataText.Text = row.ImportedMetadata is { } imported
            ? $"Imported from Fing\nName: {imported.Name ?? "-"}\nHostname: {imported.Hostname ?? "-"}\n"
                + $"Type: {imported.Type ?? "-"}\nBrand: {imported.Brand ?? "-"}\nFamily: {imported.Family ?? "-"}\n"
                + $"Model: {imported.Model ?? "-"}\nOS: {imported.OperatingSystem ?? "-"} {imported.OperatingSystemVersion}\n"
                + $"Historical imported IP: {imported.Address ?? "-"}"
            : "No imported Fing metadata.";
        DevicePortScanButton.IsEnabled = row.CanProbe;
        ShowPorts(row.OpenPortItems);
        DevicePortScanStatusText.Text = string.Empty;
        DeviceIdentificationEditor.IsExpanded = false;
    }

    internal void ResetScroll() => DevicePage.ChangeView(null, 0, null, disableAnimation: true);

    internal void SetNameActions(bool canSave, bool canReset, string? resetToolTip)
    {
        DeviceNameSaveButton.IsEnabled = canSave;
        DeviceNameResetButton.IsEnabled = canReset;
        ToolTipService.SetToolTip(DeviceNameResetButton, resetToolTip);
    }

    internal void ShowPorts(IReadOnlyList<OpenPort> ports)
    {
        DevicePortsList.ItemsSource = ports;
        DeviceNoPortsText.Visibility = ports.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

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
                FontFamily = new FontFamily("Segoe Fluent Icons"),
                FontSize = 16
            });
            content.Children.Add(new TextBlock { Text = type.Label() });
            var item = new ComboBoxItem { Content = content, Tag = type };
            AutomationProperties.SetName(item, type.Label());
            DeviceIconPicker.Items.Add(item);
        }
    }

    internal void ShowClassification(ScanResultRow row)
    {
        DeviceTypeIcon.Glyph = row.IconGlyph;
        AutomationProperties.SetName(DeviceTypeIcon, row.IconSource);
        ToolTipService.SetToolTip(DeviceTypeIcon, row.IconSource);
        DeviceOsText.Text = row.OperatingSystemText;
        DeviceTypeValueText.Text = row.DeviceTypeText;
        DeviceOsText.Opacity = row.OperatingSystemOpacity;
        DeviceTypeValueText.Opacity = row.DeviceTypeOpacity;
        ToolTipService.SetToolTip(DeviceOsText, row.OperatingSystemSource);
        ToolTipService.SetToolTip(DeviceTypeValueText, row.DeviceTypeSource);
        DeviceOsEvidenceText.Text = row.OperatingSystemSource;
        DeviceTypeEvidenceText.Text = row.DeviceTypeSource;
        ((ComboBoxItem)DeviceOsPicker.Items[0]).Content = FingClassificationMapper.OperatingSystem(row.ImportedMetadata?.OperatingSystem) is not null
            ? "Use imported Fing OS" : "Automatic";
        ((ComboBoxItem)DeviceTypePicker.Items[0]).Content = FingClassificationMapper.Type(row.ImportedMetadata?.Type) is not null
            ? "Use imported Fing type" : "Automatic";
        DeviceClassificationResetButton.Content = row.ImportedMetadata is null
            ? "Use automatic detection" : "Clear saved corrections";
        SelectChoice(DeviceOsPicker, row.ClassificationOverride?.OperatingSystem);
        SelectChoice(DeviceTypePicker, row.ClassificationOverride?.Type);
        SelectChoice(DeviceIconPicker, row.ClassificationOverride?.Icon);
    }

    private static void SelectChoice<T>(ComboBox picker, T? value) where T : struct =>
        picker.SelectedItem = picker.Items.OfType<ComboBoxItem>()
            .First(item => value is null ? item.Tag is null : item.Tag is T tag && tag.Equals(value.Value));

    internal DeviceClassificationOverride ClassificationChoices => new(
        (DeviceOsPicker.SelectedItem as ComboBoxItem)?.Tag as DeviceOperatingSystem?,
        (DeviceTypePicker.SelectedItem as ComboBoxItem)?.Tag as DeviceType?,
        (DeviceIconPicker.SelectedItem as ComboBoxItem)?.Tag as DeviceType?);

    internal void SetClassificationActions(bool enabled, bool canSave, bool canReset)
    {
        DeviceOsPicker.IsEnabled = enabled;
        DeviceTypePicker.IsEnabled = enabled;
        DeviceIconPicker.IsEnabled = enabled;
        DeviceClassificationSaveButton.IsEnabled = canSave;
        DeviceClassificationResetButton.IsEnabled = canReset;
    }

    internal void SetAssignments(IEnumerable<(Guid Id, string Label)> people,
        IEnumerable<(Guid Id, string Label)> rooms, Guid? personId, Guid? roomId, bool enabled)
    {
        _updatingAssignments = true;
        try
        {
            PopulateAssignmentPicker(DevicePersonPicker, "Add person\u2026", people);
            PopulateAssignmentPicker(DeviceRoomPicker, "Add room\u2026", rooms);
            DevicePersonPicker.IsEnabled = enabled;
            DeviceRoomPicker.IsEnabled = enabled;
            SelectAssignment(DevicePersonPicker, personId);
            SelectAssignment(DeviceRoomPicker, roomId);
        }
        finally
        {
            _updatingAssignments = false;
        }
    }

    private static void PopulateAssignmentPicker(ComboBox picker, string addLabel,
        IEnumerable<(Guid Id, string Label)> values)
    {
        var options = values.OrderBy(item => item.Label, StringComparer.OrdinalIgnoreCase).ToArray();
        var existing = picker.Items.OfType<ComboBoxItem>().ToArray();
        if (existing.Length == options.Length + 2
            && existing[0].Tag is "unassigned" && existing[^1].Tag is "add"
            && Equals(existing[^1].Content, addLabel)
            && options.Select((option, index) =>
                Equals(existing[index + 1].Tag, option.Id)
                && Equals(existing[index + 1].Content, option.Label)).All(matches => matches))
        {
            return;
        }

        picker.Items.Clear();
        picker.Items.Add(new ComboBoxItem { Content = "Unassigned", Tag = "unassigned" });
        foreach (var (id, label) in options)
        {
            picker.Items.Add(new ComboBoxItem { Content = label, Tag = id });
        }
        picker.Items.Add(new ComboBoxItem { Content = addLabel, Tag = "add" });
    }

    private static void SelectAssignment(ComboBox picker, Guid? id) =>
        picker.SelectedItem = picker.Items.OfType<ComboBoxItem>()
            .FirstOrDefault(item => id is null ? Equals(item.Tag, "unassigned") : Equals(item.Tag, id));

    private async void DevicePersonPicker_SelectionChanged(object sender, SelectionChangedEventArgs e) =>
        await RequestAssignmentAsync(DevicePersonPicker, person: true);

    private async void DeviceRoomPicker_SelectionChanged(object sender, SelectionChangedEventArgs e) =>
        await RequestAssignmentAsync(DeviceRoomPicker, person: false);

    private async Task RequestAssignmentAsync(ComboBox picker, bool person)
    {
        if (_updatingAssignments || picker.SelectedItem is not ComboBoxItem { Tag: var tag })
        {
            return;
        }

        // Let the ComboBox commit its selection before refreshing it or opening a dialog.
        await Task.Yield();
        picker.IsDropDownOpen = false;
        var choice = new DeviceAssignmentChoice(tag is Guid id ? id : null, tag is "add");
        if (person)
        {
            PersonAssignmentRequested?.Invoke(this, choice);
        }
        else
        {
            RoomAssignmentRequested?.Invoke(this, choice);
        }
    }

    private void BackToDevicesButton_Click(object sender, RoutedEventArgs e) => BackRequested?.Invoke(this, e);
    private void DeviceNameInput_TextChanged(object sender, TextChangedEventArgs e) => NameChanged?.Invoke(this, e);
    private void DeviceNameSaveButton_Click(object sender, RoutedEventArgs e) => NameSaveRequested?.Invoke(this, e);
    private void DeviceNameResetButton_Click(object sender, RoutedEventArgs e) => NameResetRequested?.Invoke(this, e);
    private void DevicePortScanButton_Click(object sender, RoutedEventArgs e) => PortScanRequested?.Invoke(this, e);
    private void ClassificationPicker_SelectionChanged(object sender, SelectionChangedEventArgs e) => ClassificationChanged?.Invoke(this, e);
    private void DeviceClassificationSaveButton_Click(object sender, RoutedEventArgs e) => ClassificationSaveRequested?.Invoke(this, e);
    private void DeviceClassificationResetButton_Click(object sender, RoutedEventArgs e) => ClassificationResetRequested?.Invoke(this, e);
}
