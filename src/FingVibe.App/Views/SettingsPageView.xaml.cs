using FingVibe.Core.Models;
using FingVibe.Core.Updates;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace FingVibe.App.Views;

public sealed partial class SettingsPageView : UserControl
{
    private static readonly ThemeVariant[] LightThemes =
        [ThemeVariant.StandardLight, ThemeVariant.WarmLight, ThemeVariant.ColorfulLight];
    private static readonly ThemeVariant[] DarkThemes =
        [ThemeVariant.StandardDark, ThemeVariant.OledDark, ThemeVariant.ColorfulDark];
    private bool _updatingAppearance;
    private bool _updatingPeriodicScan;
    private bool _updatingNetworkMonitor;
    private string? _appearanceSaveError;
    private string? _materialStatus;
    private ReleaseUpdateSession? _updates;
    private ReleaseUpdateActions? _updateActions;

    public SettingsPageView()
    {
        InitializeComponent();
        foreach (var minutes in PeriodicScanSettings.IntervalChoices)
        {
            ScanIntervalPicker.Items.Add(new ComboBoxItem { Content = PeriodicScanPresentation.IntervalLabel(minutes) });
        }
        ScheduledScanEvidenceNote.Text = PeriodicScanPresentation.EvidenceNote;
        NetworkMonitoringDisclosure.Text = NetworkMonitorPresentation.Disclosure;
        SetPeriodicScan(PeriodicScanSettings.Default);
        SetNetworkMonitor(NetworkMonitorSettings.Default);
        AboutSummary.Text = $"{BuildIdentity.Current.Version} \u00b7 Build information and links";
        AutomationProperties.SetHelpText(AboutSettingsButton, AboutSummary.Text);
        Columns.SettingsChanged += (_, _) => UpdateDevicesSummary();
        UpdateDevicesSummary();
    }

    public DeviceColumnLayout Columns => DeviceColumnLayout.Current;
    public IReadOnlyList<DeviceColumn> VisibilityChoices =>
        [Columns.Name, Columns.Address, Columns.Vendor, Columns.Type, Columns.Mac, Columns.Ports,
            Columns.Status, Columns.Response, Columns.OperatingSystem, Columns.UsageCategory, Columns.Person, Columns.Room, Columns.LastSeen];
    public event SelectionChangedEventHandler? AppearanceChanged;
    public event EventHandler? PeriodicScanChanged;
    public event EventHandler? NetworkMonitorChanged;

    private ThemeVariant[] ModeThemes => ModePicker.SelectedIndex == 1 ? DarkThemes : LightThemes;
    internal AppearanceSettings? SelectedAppearance =>
        ModePicker.SelectedIndex < 0 || ThemePicker.SelectedIndex < 0 || BackdropPicker.SelectedIndex < 0
            ? null
            : new AppearanceSettings((WindowBackdrop)BackdropPicker.SelectedIndex, ModeThemes[ThemePicker.SelectedIndex]);
    internal string? SaveError { set { _appearanceSaveError = value; UpdateAppearanceStatus(); } }
    internal string? MaterialStatus { set { _materialStatus = value; UpdateAppearanceStatus(); } }
    internal string ColumnSaveStatus
    {
        set
        {
            TableSaveStatus.Text = value;
            UpdateDevicesSummary();
        }
    }
    internal PeriodicScanSettings? SelectedPeriodicScan =>
        ScanIntervalPicker.SelectedIndex < 0
            ? null
            : new PeriodicScanSettings(ScheduledScansSwitch.IsOn, PeriodicScanSettings.IntervalChoices[ScanIntervalPicker.SelectedIndex]);
    internal NetworkMonitorSettings SelectedNetworkMonitor => new(NetworkMonitoringSwitch.IsOn);
    internal string PeriodicScanStatus
    {
        set
        {
            ScheduledScanStatus.Text = value;
            UpdateScheduledScansSummary();
        }
    }
    internal string NetworkMonitorStatus
    {
        set
        {
            NetworkMonitorStatusText.Text = value;
            UpdateScheduledScansSummary();
        }
    }

    public void ShowAbout()
    {
        SettingsPage.Visibility = Visibility.Collapsed;
        AboutView.Visibility = Visibility.Visible;
        AboutView.FocusHeading();
    }

    internal void ConfigureUpdates(ReleaseUpdateSession session, ReleaseUpdateActions actions, bool isFixture, Action close)
    {
        _updates = session;
        _updateActions = actions;
        AboutView.ConfigureUpdates(session, actions, isFixture, close);
        void Apply(UpdateState state)
        {
            var available = state.ConfirmedUpdate is not null;
            AboutUpdateIndicator.Visibility = available ? Visibility.Visible : Visibility.Collapsed;
            var canUpdate = actions.CanUpdateNow;
            SettingsUpdateNowButton.Visibility = canUpdate ? Visibility.Visible : Visibility.Collapsed;
            SettingsUpdateNowButton.IsEnabled = canUpdate && !state.IsChecking;
            AboutSummary.Text = available
                ? $"Update available: {state.ConfirmedUpdate!.VersionText} \u00b7 Last confirmed {state.ConfirmedAt:u}"
                : $"{BuildIdentity.Current.Version} \u00b7 Build information and updates";
            AutomationProperties.SetItemStatus(AboutSettingsButton, available ? "Update available" : "");
            AutomationProperties.SetHelpText(AboutSettingsButton, AboutSummary.Text);
        }
        session.Changed += (_, state) => DispatcherQueue.TryEnqueue(() => Apply(state));
        Apply(session.State);
    }

    internal void ShowPreferences()
    {
        AboutView.Visibility = Visibility.Collapsed;
        SettingsPage.Visibility = Visibility.Visible;
    }

    private void AboutSettingsButton_Click(object sender, RoutedEventArgs e) => ShowAbout();
    private async void SettingsUpdateNowButton_Click(object sender, RoutedEventArgs e)
    {
        if (_updateActions is null || _updates is null || !_updateActions.CanUpdateNow) return;
        ShowAbout();
        await AboutView.UpdateNowAsync();
    }

    private void AboutView_BackRequested(object? sender, EventArgs e)
    {
        ShowPreferences();
        SettingsPage.UpdateLayout();
        AboutSettingsButton.Focus(FocusState.Programmatic);
    }

    private void UpdateDevicesSummary()
    {
        DevicesSummary.Text = SettingsPresentation.DevicesSummary(
            Columns.CompactRows, Columns.EnlargedCellPreviews, VisibilityChoices.Count(column => column.IsVisible));
        AutomationProperties.SetHelpText(DevicesSection, $"{DevicesSummary.Text}. {TableSaveStatus.Text}");
    }

    private void UpdateScheduledScansSummary()
    {
        if (SelectedPeriodicScan is { } settings)
        {
            ScheduledScansSummary.Text = SettingsPresentation.BackgroundSummary(
                settings,
                SelectedNetworkMonitor,
                ScheduledScanStatus.Text,
                NetworkMonitorStatusText.Text);
            AutomationProperties.SetHelpText(ScheduledScansSection, ScheduledScansSummary.Text);
        }
    }

    internal void SetPeriodicScan(PeriodicScanSettings settings)
    {
        var normalized = settings.Normalize();
        _updatingPeriodicScan = true;
        try
        {
            ScheduledScansSwitch.IsOn = normalized.IsEnabled;
            ScanIntervalPicker.SelectedIndex = PeriodicScanSettings.IntervalChoices.ToList().IndexOf(normalized.IntervalMinutes);
        }
        finally
        {
            _updatingPeriodicScan = false;
        }
        UpdateScheduledScansSummary();
    }

    private void ScheduledScansSwitch_Toggled(object sender, RoutedEventArgs e) => RaisePeriodicScanChanged();

    private void ScanIntervalPicker_SelectionChanged(object sender, SelectionChangedEventArgs e) => RaisePeriodicScanChanged();

    internal void SetNetworkMonitor(NetworkMonitorSettings settings)
    {
        _updatingNetworkMonitor = true;
        try
        {
            NetworkMonitoringSwitch.IsOn = settings.IsEnabled;
        }
        finally
        {
            _updatingNetworkMonitor = false;
        }
        UpdateScheduledScansSummary();
    }

    private void NetworkMonitoringSwitch_Toggled(object sender, RoutedEventArgs e)
    {
        UpdateScheduledScansSummary();
        if (!_updatingNetworkMonitor)
        {
            NetworkMonitorChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    private void RaisePeriodicScanChanged()
    {
        UpdateScheduledScansSummary();
        if (!_updatingPeriodicScan && SelectedPeriodicScan is not null)
        {
            PeriodicScanChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    private void ScheduledScanOptions_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var inline = e.NewSize.Width >= 416;
        Grid.SetColumn(ScanIntervalPicker, inline ? 1 : 0);
        Grid.SetRow(ScanIntervalPicker, inline ? 0 : 1);
        Grid.SetColumnSpan(ScheduledScansSwitch, inline ? 1 : 2);
        Grid.SetColumnSpan(ScanIntervalPicker, inline ? 1 : 2);
    }

    private void UpdateAppearanceStatus()
    {
        AppearanceSaveStatus.Text = SettingsPresentation.AppearanceStatus(_appearanceSaveError, _materialStatus);
        if (SelectedAppearance is { } appearance)
            AppearanceSummary.Text = SettingsPresentation.AppearanceSummary(appearance, _materialStatus);
        AutomationProperties.SetHelpText(AppearanceSection,
            _appearanceSaveError is null ? AppearanceSummary.Text : $"{AppearanceSummary.Text}. {_appearanceSaveError}");
    }

    internal void SetAppearance(AppearanceSettings appearance)
    {
        _updatingAppearance = true;
        try
        {
            ModePicker.SelectedIndex = Array.IndexOf(DarkThemes, appearance.Theme) >= 0 ? 1 : 0;
            ThemePicker.SelectedIndex = Array.IndexOf(ModeThemes, appearance.Theme);
            BackdropPicker.SelectedIndex = (int)appearance.Backdrop;
        }
        finally
        {
            _updatingAppearance = false;
        }
        UpdateAppearanceStatus();
    }

    private void ModePicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        var styleIndex = ThemePicker.SelectedIndex;
        var wasUpdating = _updatingAppearance;
        _updatingAppearance = true;
        try
        {
            // Replace the item so the selected display and automation name refresh together.
            ThemePicker.Items[1] = new ComboBoxItem
            {
                Content = ModePicker.SelectedIndex == 1 ? "True Black (OLED)" : "Warm"
            };
            ThemePicker.SelectedIndex = styleIndex;
        }
        finally
        {
            _updatingAppearance = wasUpdating;
        }
        AppearancePicker_SelectionChanged(sender, e);
    }

    private void AppearancePicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_updatingAppearance)
            UpdateAppearanceStatus();
        if (!_updatingAppearance && SelectedAppearance is not null)
        {
            AppearanceChanged?.Invoke(this, e);
        }
    }

    private void AppearanceOptions_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var inline = e.NewSize.Width >= 632;
        AppearanceOptions.RowSpacing = inline ? 0 : 12;
        FrameworkElement[] pickers = [ModePicker, ThemePicker, BackdropPicker];
        for (var index = 0; index < pickers.Length; index++)
        {
            Grid.SetRow(pickers[index], inline ? 0 : index);
            Grid.SetColumn(pickers[index], inline ? index : 0);
            Grid.SetColumnSpan(pickers[index], inline ? 1 : 3);
        }
    }

    private void ColumnFooter_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var inline = e.NewSize.Width >= 632;
        ColumnFooter.RowSpacing = inline ? 0 : 8;
        Grid.SetColumnSpan(MandatoryColumnNote, inline ? 1 : 2);
        Grid.SetRow(ResetColumnsButton, inline ? 0 : 1);
        Grid.SetColumn(ResetColumnsButton, inline ? 1 : 0);
        Grid.SetColumnSpan(ResetColumnsButton, inline ? 1 : 2);
    }

    private void CombinationOptions_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var columns = SettingsPresentation.ColumnCount(e.NewSize.Width);
        FrameworkElement[] choices = [CombineNameType, CombineAddresses, CombineStatusResponse, CombinePersonRoom, CombineVendorOs];
        for (var index = 0; index < choices.Length; index++)
        {
            Grid.SetRow(choices[index], index / columns);
            Grid.SetColumn(choices[index], index % columns);
            Grid.SetColumnSpan(choices[index], 1);
        }
        CombinationOptions.ColumnDefinitions.Clear();
        for (var column = 0; column < columns; column++)
            CombinationOptions.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
    }

    private void DevicePreferences_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var inline = e.NewSize.Width >= 416;
        Grid.SetColumn(EnlargedCellPreviews, inline ? 1 : 0);
        Grid.SetRow(EnlargedCellPreviews, inline ? 0 : 1);
        Grid.SetColumnSpan(CompactRowsSwitch, inline ? 1 : 2);
        Grid.SetColumnSpan(EnlargedCellPreviews, inline ? 1 : 2);
    }

    private void DevicePreferenceSwitch_Loaded(object sender, RoutedEventArgs e)
    {
        var toggle = (ToggleSwitch)sender;
        toggle.ApplyTemplate();
        // ToggleSwitch is sealed; retain its native template and change only the four shape parts.
        foreach (var name in new[] { "OuterBorder", "SwitchKnobBounds", "SwitchKnobOff" })
        {
            if (FindSwitchPart(toggle, name) is not Rectangle rectangle)
                throw new InvalidOperationException($"The native ToggleSwitch template is missing rectangle '{name}'.");
            rectangle.RadiusX = rectangle.RadiusY = name == "SwitchKnobOff" ? 2 : 4;
        }
        if (FindSwitchPart(toggle, "SwitchKnobOn") is not Border knob)
            throw new InvalidOperationException("The native ToggleSwitch template is missing the on thumb.");
        knob.CornerRadius = new CornerRadius(2);
    }

    private static FrameworkElement? FindSwitchPart(DependencyObject parent, string name)
    {
        if (parent is FrameworkElement element && element.Name == name)
            return element;
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(parent); index++)
        {
            if (FindSwitchPart(VisualTreeHelper.GetChild(parent, index), name) is { } child)
                return child;
        }
        return null;
    }

    private void ColumnChoices_Loaded(object sender, RoutedEventArgs e) => UpdateColumnChoicesLayout();

    private void ColumnChoices_SizeChanged(object sender, SizeChangedEventArgs e) => UpdateColumnChoicesLayout();

    private void UpdateColumnChoicesLayout()
    {
        if (ColumnChoices.ItemsPanelRoot is not Grid panel)
        {
            return;
        }
        var columns = SettingsPresentation.ColumnCount(ColumnChoices.ActualWidth);
        var rows = (VisibilityChoices.Count + columns - 1) / columns;
        if (panel.ColumnDefinitions.Count != columns)
        {
            panel.ColumnDefinitions.Clear();
            for (var column = 0; column < columns; column++)
            {
                panel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            }
        }
        if (panel.RowDefinitions.Count != rows)
        {
            panel.RowDefinitions.Clear();
            for (var row = 0; row < rows; row++)
            {
                panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            }
        }
        for (var index = 0; index < panel.Children.Count; index++)
        {
            var container = (FrameworkElement)panel.Children[index];
            Grid.SetRow(container, index / columns);
            Grid.SetColumn(container, index % columns);
        }
    }

    private void ResetColumnsButton_Click(object sender, RoutedEventArgs e) => Columns.Reset();
}
