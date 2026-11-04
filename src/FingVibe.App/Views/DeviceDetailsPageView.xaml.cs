using FingVibe.Core.Models;
using FingVibe.Core.Import;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.System;

namespace FingVibe.App.Views;

public sealed record DeviceAssignmentChoice(Guid? Id = null, bool AddNew = false);

public sealed partial class DeviceDetailsPageView : UserControl
{
    private bool _updatingAssignments;
    private bool _updatingAddresses;
    private bool _editingClassification;
    private bool _classificationEnabled;
    private ScanResultRow? _row;

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
    public event EventHandler? ClassificationChanged;
    public event RoutedEventHandler? ClassificationSaveRequested;
    public event RoutedEventHandler? ClassificationResetRequested;
    public event EventHandler<DeviceAssignmentChoice>? PersonAssignmentRequested;
    public event EventHandler<DeviceAssignmentChoice>? RoomAssignmentRequested;
    public event EventHandler<string>? AddressRequested;

    internal string NameInput { get => DeviceNameInput.Text; set => DeviceNameInput.Text = value; }
    internal string NameSaveLabel { set => DeviceNameSaveButton.Content = value; }
    internal string NameStatus { set => DeviceNameStatusText.Text = value; }
    internal string PortScanStatus { get => DevicePortScanStatusText.Text; set => DevicePortScanStatusText.Text = value; }
    internal string UdpScanStatus { set => DeviceUdpScanStatusText.Text = value; }
    internal bool IncludeUdp => DeviceIncludeUdpCheckBox.IsChecked == true;
    internal string ClassificationStatus { set => DeviceClassificationStatusText.Text = value; }
    internal string ClassificationNotice { set => DeviceClassificationNoticeText.Text = value; }
    internal string AssignmentStatus { set => DeviceAssignmentStatusText.Text = value; }

    internal void ShowDevice(ScanResultRow row)
    {
        _row = row;
        SetClassificationEditing(false);
        DeviceClassificationStatusText.Text = string.Empty;
        _updatingAddresses = true;
        try
        {
            DeviceAddressPicker.ItemsSource = row.CurrentConnections.Select(item => item.AddressText).ToArray();
            DeviceAddressPicker.SelectedItem = row.AddressText;
            DeviceAddressPicker.Visibility = row.CurrentConnections.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
        }
        finally { _updatingAddresses = false; }
        ShowHistory(row);
        ShowConnection(row);
        DeviceIncludeUdpCheckBox.IsChecked = false;
        DeviceImportedMetadata.IsExpanded = false;
        DeviceBrowserStatusText.Text = string.Empty;
    }

    internal void ShowHistory(ScanResultRow row)
    {
        VirtualDeviceHistoryCard.Visibility = row.VirtualDevice is null ? Visibility.Collapsed : Visibility.Visible;
        VirtualDeviceHistoryText.Text = row.ConnectionHistoryText;
    }

    internal void ShowConnection(ScanResultRow row)
    {
        var result = row.Result;
        _row = row;
        DeviceNameValue.Value = row.NameText;
        DeviceAddressText.Value = row.AddressText;
        DeviceMacText.Value = row.MacAddressText;
        DeviceVendorText.Value = row.VendorText;
        DeviceVendorText.Opacity = row.VendorOpacity;
        DeviceStatusText.Text = row.StatusContext;
        DeviceResponseText.Value = row.LatencyLabel;
        DeviceProbeText.Value = result is null ? "-" : $"{result.ProbeDuration.TotalMilliseconds:N0} ms";
        DeviceHostnameText.Value = result?.DeviceName ?? "-";
        DeviceAddressSourceText.Text = result is null ? "Historical IP from Fing; never observed locally."
            : row.IsCurrentScanResponse ? "Responded in the current local scan."
            : "Last-known local address; not a current response.";
        DeviceBrowserStatusText.Text = string.Empty;
        DeviceImportedFields.Children.Clear();
        foreach (var field in DeviceDetailsPresentation.ImportedFields(row.ImportedMetadata))
            DeviceImportedFields.Children.Add(new DeviceDetailValue { Label = field.Label, Value = field.Value });
        if (DeviceImportedFields.Children.Count == 0)
            DeviceImportedFields.Children.Add(new TextBlock { Text = "No imported Fing metadata.", TextWrapping = TextWrapping.Wrap });
        SetPortScanRunning(false, row.CanProbe);
        ShowPorts(row.Result?.OpenPortItems ?? []);
        ShowUdpObservations(row.Result?.UdpObservationItems ?? []);
        DevicePortScanStatusText.Text = string.Empty;
        DeviceUdpScanStatusText.Text = string.Empty;
    }

    internal void ResetScroll() => DevicePage.ChangeView(null, 0, null, disableAnimation: true);

    internal void SetNameActions(bool canSave, bool canReset, string? resetToolTip)
    {
        if (_row is { } row) DeviceNameValue.Value = row.NameText;
        DeviceNameSaveButton.IsEnabled = canSave;
        DeviceNameResetButton.IsEnabled = canReset;
        ToolTipService.SetToolTip(DeviceNameResetButton, resetToolTip);
    }

    internal void ShowPorts(IReadOnlyList<OpenPort> ports)
    {
        DevicePortsList.Children.Clear();
        if (_row is { } row)
        {
            foreach (var port in ports)
            {
                var endpoint = DeviceDetailsPresentation.Endpoint(row, port);
                var panel = new Grid { ColumnSpacing = 8 };
                panel.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                panel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
                var icon = new FontIcon
                {
                    Glyph = PortServiceIcons.Glyph(port), FontFamily = new FontFamily("Segoe Fluent Icons"),
                    FontSize = 16, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 6, 0, 0)
                };
                AutomationProperties.SetName(icon, port.AccessibleLabel);
                ToolTipService.SetToolTip(icon, port.AccessibleLabel);
                panel.Children.Add(icon);
                var content = new StackPanel { Spacing = 4 };
                content.Children.Add(new DeviceDetailValue { Label = port.AccessibleLabel, Value = endpoint.Value });
                if (endpoint.HasBrowserAction)
                {
                    var browser = new Button { Content = endpoint.BrowserLabel, Tag = port };
                    AutomationProperties.SetName(browser, $"{endpoint.BrowserLabel}: {endpoint.Value}");
                    ToolTipService.SetToolTip(browser, endpoint.BrowserUri!.AbsoluteUri);
                    browser.Click += Browser_Click;
                    content.Children.Add(browser);
                }
                Grid.SetColumn(content, 1);
                panel.Children.Add(content);
                DevicePortsList.Children.Add(panel);
            }
        }
        DeviceNoPortsText.Visibility = ports.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private async void Browser_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: OpenPort port } || _row is not { } row) return;
        var uri = DeviceDetailsPresentation.Endpoint(row, port).BrowserUri;
        if (uri is null)
        {
            DeviceBrowserStatusText.Text = "This endpoint no longer has a current local observation. Scan again before opening it.";
            return;
        }
        try
        {
            DeviceBrowserStatusText.Text = await Launcher.LaunchUriAsync(uri)
                ? $"Opened {uri.AbsoluteUri} in your browser."
                : $"Could not open {uri.AbsoluteUri}. Check your default browser.";
        }
        catch (Exception exception) when (exception is System.Runtime.InteropServices.COMException
            or UnauthorizedAccessException or InvalidOperationException or ArgumentException)
        {
            DeviceBrowserStatusText.Text = $"Could not open {uri.AbsoluteUri}: {exception.Message}";
        }
    }

    internal void SetPortScanRunning(bool running, bool canProbe)
    {
        DevicePortScanButton.Content = running ? "Cancel additional scan" : "Scan additional ports";
        DevicePortScanButton.IsEnabled = running || canProbe;
        DeviceIncludeUdpCheckBox.IsEnabled = !running && canProbe;
        DeviceAddressPicker.IsEnabled = !running && canProbe;
    }

    internal void ShowUdpObservations(IReadOnlyList<UdpServiceObservation> observations) =>
        DeviceUdpObservationsList.ItemsSource = observations;

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
        DeviceOsText.Value = row.OperatingSystemText;
        DeviceTypeValueText.Value = row.DeviceTypeText;
        DeviceOsText.Source = row.ClassificationOverride?.OperatingSystem is not null ? "Saved correction"
            : FingClassificationMapper.OperatingSystem(row.ImportedMetadata?.OperatingSystem) is not null ? "Imported from Fing" : "Automatic detection";
        DeviceTypeValueText.Source = row.ClassificationOverride?.Type is not null ? "Saved correction"
            : FingClassificationMapper.Type(row.ImportedMetadata?.Type) is not null ? "Imported from Fing" : "Automatic detection";
        DeviceBrandText.Value = row.BrandText;
        DeviceBrandText.Source = row.BrandSource;
        DeviceFamilyText.Value = row.FamilyText;
        DeviceFamilyText.Source = row.FamilySource;
        DeviceModelText.Value = row.ModelText;
        DeviceModelText.Source = row.ModelSource;
        DeviceIconText.Value = row.Icon.Label();
        DeviceIconText.Source = row.ClassificationOverride?.Icon is not null ? "Saved correction" : "Follows device type";
        DeviceVendorText.Value = row.VendorText;
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
        if (!_editingClassification) PopulateClassificationInputs(row);
    }

    private void PopulateClassificationInputs(ScanResultRow row)
    {
        SelectChoice(DeviceOsPicker, row.ClassificationOverride?.OperatingSystem);
        SelectChoice(DeviceTypePicker, row.ClassificationOverride?.Type);
        SelectChoice(DeviceIconPicker, row.ClassificationOverride?.Icon);
        DeviceBrandInput.Text = row.ClassificationOverride?.Brand ?? "";
        DeviceFamilyInput.Text = row.ClassificationOverride?.Family ?? "";
        DeviceModelInput.Text = row.ClassificationOverride?.Model ?? "";
        DeviceBrandInput.PlaceholderText = row.BrandText;
        DeviceFamilyInput.PlaceholderText = row.FamilyText;
        DeviceModelInput.PlaceholderText = row.ModelText;
    }

    private static void SelectChoice<T>(ComboBox picker, T? value) where T : struct =>
        picker.SelectedItem = picker.Items.OfType<ComboBoxItem>()
            .First(item => value is null ? item.Tag is null : item.Tag is T tag && tag.Equals(value.Value));

    internal DeviceClassificationOverride ClassificationChoices => new(
        (DeviceOsPicker.SelectedItem as ComboBoxItem)?.Tag as DeviceOperatingSystem?,
        (DeviceTypePicker.SelectedItem as ComboBoxItem)?.Tag as DeviceType?,
        (DeviceIconPicker.SelectedItem as ComboBoxItem)?.Tag as DeviceType?,
        OptionalText(DeviceBrandInput.Text), OptionalText(DeviceFamilyInput.Text), OptionalText(DeviceModelInput.Text));

    private static string? OptionalText(string text) => string.IsNullOrWhiteSpace(text) ? null : text.Trim();

    private void ClassificationEdit_Click(object sender, RoutedEventArgs e)
    {
        if (_row is not { } row) return;
        PopulateClassificationInputs(row);
        SetClassificationEditing(true);
        DeviceClassificationStatusText.Text = string.Empty;
        DeviceTypePicker.Focus(FocusState.Programmatic);
    }

    private void ClassificationCancel_Click(object sender, RoutedEventArgs e)
    {
        SetClassificationEditing(false);
        if (_row is { } row) PopulateClassificationInputs(row);
        DeviceClassificationStatusText.Text = string.Empty;
        DeviceClassificationEditButton.Focus(FocusState.Programmatic);
    }

    internal void CompleteClassificationEdit()
    {
        SetClassificationEditing(false);
        DispatcherQueue.TryEnqueue(() => DeviceClassificationEditButton.Focus(FocusState.Programmatic));
    }

    private void SetClassificationEditing(bool editing)
    {
        _editingClassification = editing;
        IdentificationReadFields.Visibility = editing ? Visibility.Collapsed : Visibility.Visible;
        IdentificationEditFields.Visibility = editing ? Visibility.Visible : Visibility.Collapsed;
        DeviceClassificationEditButton.IsEnabled = _classificationEnabled && !editing;
    }

    internal void SetClassificationActions(bool enabled, bool canSave, bool canReset)
    {
        _classificationEnabled = enabled;
        DeviceOsPicker.IsEnabled = enabled;
        DeviceTypePicker.IsEnabled = enabled;
        DeviceIconPicker.IsEnabled = enabled;
        DeviceBrandInput.IsEnabled = enabled;
        DeviceFamilyInput.IsEnabled = enabled;
        DeviceModelInput.IsEnabled = enabled;
        DeviceClassificationEditButton.IsEnabled = enabled && !_editingClassification;
        DeviceClassificationCancelButton.IsEnabled = enabled;
        DeviceClassificationSaveButton.IsEnabled = canSave;
        DeviceClassificationResetButton.IsEnabled = canReset;
    }

    private void DetailsColumns_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var wide = e.NewSize.Width >= 1000;
        DetailsColumns.ColumnDefinitions[1].Width = wide ? new GridLength(1, GridUnitType.Star) : new GridLength(0);
        Grid.SetColumn(IdentificationCard, wide ? 1 : 0);
        Grid.SetRow(IdentificationCard, wide ? 0 : 1);
    }

    private void Fields_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (sender is not Grid grid) return;
        var columns = e.NewSize.Width >= 420 * new Windows.UI.ViewManagement.UISettings().TextScaleFactor ? 2 : 1;
        var rows = (grid.Children.Count + columns - 1) / columns;
        if (grid.ColumnDefinitions.Count == columns && grid.RowDefinitions.Count == rows) return;
        grid.ColumnDefinitions.Clear();
        grid.RowDefinitions.Clear();
        for (var index = 0; index < columns; index++)
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        for (var index = 0; index < rows; index++)
            grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        for (var index = 0; index < grid.Children.Count; index++)
        {
            Grid.SetColumn((FrameworkElement)grid.Children[index], index % columns);
            Grid.SetRow((FrameworkElement)grid.Children[index], index / columns);
        }
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
    private void DeviceAddressPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_updatingAddresses && DeviceAddressPicker.SelectedItem is string address)
            AddressRequested?.Invoke(this, address);
    }
    private void ClassificationPicker_SelectionChanged(object sender, SelectionChangedEventArgs e) => ClassificationChanged?.Invoke(this, EventArgs.Empty);
    private void ClassificationText_TextChanged(object sender, TextChangedEventArgs e) =>
        ClassificationChanged?.Invoke(this, EventArgs.Empty);
    private void DeviceClassificationSaveButton_Click(object sender, RoutedEventArgs e) => ClassificationSaveRequested?.Invoke(this, e);
    private void DeviceClassificationResetButton_Click(object sender, RoutedEventArgs e) => ClassificationResetRequested?.Invoke(this, e);
}
