using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App;

public sealed partial class MainWindow : Window
{
    private static readonly bool IsUiReview =
        Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW") == "1";

    public MainWindow()
    {
        InitializeComponent();
        if (IsUiReview)
        {
            RootGrid.RequestedTheme = ElementTheme.Dark;
        }

        ResultsList.ItemsSource = _visibleResults;
        StatusFilter.SelectedIndex = 0;
        UpdateSortGlyphs();
        MainNavigation.SelectedItem = OverviewNavItem;
    }

    public DeviceColumnLayout Columns => DeviceColumnLayout.Current;

    private async void RootGrid_Loaded(object sender, RoutedEventArgs e)
    {
        if (MainNavigation.SettingsItem is NavigationViewItem settingsItem)
        {
            settingsItem.Content = "Settings";
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(settingsItem, "Settings");
        }

        await RestoreSavedScanAsync();
        await InitializeNetworkAsync();
    }

    private void MainNavigation_SelectionChanged(
        NavigationView sender,
        NavigationViewSelectionChangedEventArgs args)
    {
        if (args.IsSettingsSelected)
        {
            ShowPage(SettingsPage);
        }
        else if (args.SelectedItem is NavigationViewItem { Tag: string tag })
        {
            ShowPage(GetPage(tag));
        }
    }

    private void MainNavigation_ItemInvoked(NavigationView sender, NavigationViewItemInvokedEventArgs args)
    {
        // Re-invoking the selected Devices item returns from a device page without a selection change.
        if (args.InvokedItemContainer == DevicesNavItem && DevicePage.Visibility == Visibility.Visible)
        {
            ShowPage(DevicesPage);
        }
    }

    private UIElement GetPage(string tag) => tag switch
    {
        "Network" => NetworkPage,
        "Devices" => DevicesPage,
        "People" => PeoplePage,
        "Rooms" => RoomsPage,
        _ => OverviewPage
    };

    private void ShowPage(UIElement page)
    {
        foreach (var candidate in new UIElement[]
                 {
                     OverviewPage, NetworkPage, DevicesPage, DevicePage, PeoplePage, RoomsPage, SettingsPage
                 })
        {
            candidate.Visibility = candidate == page ? Visibility.Visible : Visibility.Collapsed;
        }

        ScanBar.Visibility = page == OverviewPage || page == NetworkPage || page == DevicesPage || page == DevicePage
            ? Visibility.Visible
            : Visibility.Collapsed;
    }

    private void ViewNetworkButton_Click(object sender, RoutedEventArgs e) =>
        MainNavigation.SelectedItem = NetworkNavItem;

    private void ViewDevicesButton_Click(object sender, RoutedEventArgs e) =>
        MainNavigation.SelectedItem = DevicesNavItem;

    private void BackToDevicesButton_Click(object sender, RoutedEventArgs e) =>
        ShowPage(DevicesPage);

    private void ResetColumnsButton_Click(object sender, RoutedEventArgs e) =>
        Columns.Reset();

}
