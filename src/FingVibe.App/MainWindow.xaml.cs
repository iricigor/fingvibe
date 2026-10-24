using System.Diagnostics;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App;

public sealed partial class MainWindow : Window
{
    private readonly NetworkActivityCoordinator _networkActivityCoordinator = new();
    private bool _allowWindowClose;
    private bool _closingAfterSpeedTest;

    private static readonly bool IsUiReview =
        Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW") == "1";

    public MainWindow()
    {
        InitializeComponent();
        ToolsPage.ActivityCoordinator = _networkActivityCoordinator;
        this.AppWindow.Closing += MainWindow_Closing;
        InitializeAppearance();
        InitializeClassificationPickers();
        InitializePeopleRoomsViews();

        ResultsList.ItemsSource = _visibleResults;
        StatusFilter.SelectedIndex = 0;
        UpdateSortGlyphs();
        MainNavigation.SelectedItem = OverviewNavItem;
        InitializeOverview();
    }

    public DeviceColumnLayout Columns => DeviceColumnLayout.Current;

    private async void MainWindow_Closing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_allowWindowClose || !ToolsPage.HasActiveTest)
        {
            return;
        }

        args.Cancel = true;
        if (_closingAfterSpeedTest)
        {
            return;
        }

        _closingAfterSpeedTest = true;
        try
        {
            await ToolsPage.StopForWindowCloseAsync();
        }
        catch (Exception exception)
        {
            Debug.WriteLine(exception);
        }
        finally
        {
            _allowWindowClose = true;
            Close();
        }
    }

    private async void RootGrid_Loaded(object sender, RoutedEventArgs e)
    {
        if (MainNavigation.SettingsItem is NavigationViewItem settingsItem)
        {
            settingsItem.Content = "Settings";
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(settingsItem, "Settings");
        }

        await RestoreDeviceNameOverridesAsync();
        await RestoreClassificationOverridesAsync();
        await RestorePeopleRoomsAsync();
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
        else if (args.InvokedItemContainer == PeopleNavItem && PersonDetailPage.Visibility == Visibility.Visible)
        {
            ShowPage(PeoplePage);
        }
        else if (args.InvokedItemContainer == RoomsNavItem && RoomDetailPage.Visibility == Visibility.Visible)
        {
            ShowPage(RoomsPage);
        }
    }

    private UIElement GetPage(string tag) => tag switch
    {
        "Network" => NetworkPage,
        "Devices" => DevicesPage,
        "People" => PeoplePage,
        "Rooms" => RoomsPage,
        "Tools" => ToolsPage,
        _ => OverviewPage
    };

    private void ShowPage(UIElement page)
    {
        if (ToolsPage.Visibility == Visibility.Visible && page != ToolsPage)
        {
            _ = ToolsPage.StopForNavigationAsync();
        }

        foreach (var candidate in new UIElement[]
                 {
                     OverviewPage, NetworkPage, DevicesPage, DevicePage, PeoplePage, RoomsPage,
                     PersonDetailPage, RoomDetailPage, ToolsPage, SettingsPage
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

    private void BackToDevicesButton_Click(object sender, RoutedEventArgs e) =>
        ShowPage(DevicesPage);

    private void ResetColumnsButton_Click(object sender, RoutedEventArgs e) =>
        Columns.Reset();

}
