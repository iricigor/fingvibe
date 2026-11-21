using System.Diagnostics;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App;

public sealed partial class MainWindow : Window
{
    private readonly NetworkActivityCoordinator _networkActivityCoordinator = new();
    private bool _allowWindowClose;
    private bool _closingAfterNetworkActivity;

    private static readonly bool IsUiReview =
        Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW") == "1";

    public MainWindow()
    {
        _periodicScans = new PeriodicScanScheduler(RunScheduledScanAsync, CreatePeriodicScanTimeProvider());
        _periodicScanController = new PeriodicScanController(_periodicScans, LoadPeriodicScanSettings());
        _networkMonitorScheduler = new NetworkMonitorScheduler(
            RunNetworkMonitorAsync, CreateNetworkMonitorTimeProvider(), () => _networkHealth.NextInterval);
        _networkMonitorController = new NetworkMonitorController(
            _networkMonitorScheduler, LoadNetworkMonitorSettings());
        InitializeComponent();
        InitializeNavigationPane();
        InitializeBuildIdentity();
        InitializeUpdates();
        InitializeIspLogo();
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Scanner.ico"));
        ToolsPage.ActivityCoordinator = _networkActivityCoordinator;
        ToolsPage.ConfigureSqlEditor(IsUiReview && string.IsNullOrEmpty(ReviewInventoryPath) ? null : InventoryPath);
        InitializeBackups();
        _scanExecution = new ScanExecution(_networkActivityCoordinator, this);
        this.AppWindow.Closing += MainWindow_Closing;
        InitializeAppearance();
        InitializeDeviceTableSettings();
        InitializePeopleRoomsViews();
        InitializePeriodicScans();
        InitializeNetworkMonitorIndicator();
        InitializeNetworkMonitoring();
        InitializeDiscoveryNotifications();
        InitializeUsageCategories();
        Closed += (_, _) => _devicePortScanCancellation?.Cancel();
        Closed += (_, _) => DevicePage.SetActivityActive(false);
        Closed += (_, _) => NetworkPage.SetActivityActive(false);
        Closed += (_, _) => PersonDetailPage.SetActivityActive(false);

        DevicesPage.SetResults(_visibleResults);
        UpdateSortGlyphs();
        MainNavigation.SelectedItem = OverviewNavItem;
        InitializeOverview();
    }

    private async void MainWindow_Closing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        StopUpdates();
        _backupScheduler?.Dispose();
        if (_allowWindowClose
            || (!ToolsPage.HasActiveTest && _devicePortScanCancellation is null
                && !_periodicScanController.IsActive && !_networkMonitorController.IsActive && !_isScanning))
        {
            return;
        }

        args.Cancel = true;
        if (_closingAfterNetworkActivity)
        {
            return;
        }

        _closingAfterNetworkActivity = true;
        try
        {
            // Stop scheduling first so no scheduled scan can start while other activity winds down.
            _scanCancellation?.Cancel();
            await Task.WhenAll(
                _periodicScanController.ShutdownAsync(),
                _networkMonitorController.ShutdownAsync());
            await _scanExecution.StopAsync();
            await StopDevicePortScanAsync();
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
        if (_updates is not null) ApplyUpdateIndicator(_updates.State);

        await RestoreInventoryAsync();
        ScheduleStartupBackup();
        await RestoreSavedScanAsync();
        _inventoryReady = true;
        OpenPendingDiscoveryNotification();
        UpdatePeopleRoomsPages();
        UpdatePeopleRoomFilters();
        await LoadNetworkIncidentHistoryAsync();
        await InitializeNetworkAsync();
        await ActivatePeriodicScansAsync();
        await ActivateNetworkMonitoringAsync();
    }

    private void MainNavigation_SelectionChanged(
        NavigationView sender,
        NavigationViewSelectionChangedEventArgs args)
    {
        if (args.IsSettingsSelected)
        {
            SettingsPage.ShowPreferences();
            ShowPage(SettingsPage);
        }
        else if (args.SelectedItem is NavigationViewItem { Tag: string tag })
        {
            ShowPage(GetPage(tag));
        }
    }

    private void MainNavigation_ItemInvoked(NavigationView sender, NavigationViewItemInvokedEventArgs args)
    {
        if (args.InvokedItemContainer == AppearanceShortcutNavItem)
        {
            Microsoft.UI.Xaml.Controls.Primitives.FlyoutBase.ShowAttachedFlyout(AppearanceShortcutNavItem);
            return;
        }

        if (args.IsSettingsInvoked)
        {
            SettingsPage.ShowPreferences();
        }
        // Re-invoking the selected Devices item returns from a device page without a selection change.
        if (args.InvokedItemContainer == DevicesNavItem && DevicePage.Visibility == Visibility.Visible)
        {
            ShowPage(DevicesPage);
        }
        else if (args.InvokedItemContainer == PeopleRoomsNavItem
                 && (PersonDetailPage.Visibility == Visibility.Visible
                     || RoomDetailPage.Visibility == Visibility.Visible
                     || RoomMapPage.Visibility == Visibility.Visible))
        {
            ShowPage(PeopleRoomsPage);
        }
        else if (args.InvokedItemContainer == ToolsNavItem && RoomMapPage.Visibility == Visibility.Visible)
        {
            ShowPage(ToolsPage);
        }
    }

    private UIElement GetPage(string tag) => tag switch
    {
        "Network" => NetworkPage,
        "Devices" => DevicesPage,
        "PeopleRooms" => PeopleRoomsPage,
        "Tools" => ToolsPage,
        _ => OverviewPage
    };

    private void ShowPage(UIElement page)
    {
        if (page != DevicePage)
        {
            _devicePortScanCancellation?.Cancel();
            // A Device Details address choice never changes the member Devices shows.
            ResetDeviceTarget(_selectedDeviceRow);
        }
        if (ToolsPage.Visibility == Visibility.Visible && page != ToolsPage)
        {
            _ = ToolsPage.StopForNavigationAsync();
        }

        foreach (var candidate in new UIElement[]
                 {
                     OverviewPage, NetworkPage, DevicesPage, DevicePage, PeopleRoomsPage,
                     PersonDetailPage, RoomDetailPage, RoomMapPage, ToolsPage, SettingsPage
                 })
        {
            candidate.Visibility = candidate == page ? Visibility.Visible : Visibility.Collapsed;
        }

        if (page == ToolsPage) ToolsPage.Open();
        if (page == RoomMapPage)
        {
            UpdateRoomMapPage();
        }
        UpdateDeviceActivity();
        DevicePage.SetActivityActive(page == DevicePage);
        UpdateNetworkActivity();
        NetworkPage.SetActivityActive(page == NetworkPage);
        UpdateEquipmentActivity();
        PersonDetailPage.SetActivityActive(page == PersonDetailPage);
        _ = RefreshUsageCategoriesAsync(force: true);
        UpdateScanStatus();
    }

    private void ViewNetworkButton_Click(object sender, RoutedEventArgs e) =>
        MainNavigation.SelectedItem = NetworkNavItem;

    private async void NetworkHealthRequested(object? sender, EventArgs e)
    {
        MainNavigation.SelectedItem = ToolsNavItem;
        if (ToolsPage.Visibility != Visibility.Visible) ShowPage(ToolsPage);
        await ToolsPage.OpenNetworkHealthAsync();
    }

    private void BackToDevicesButton_Click(object sender, RoutedEventArgs e)
    {
        if (_deviceDetailsFromRoomMap)
        {
            _deviceDetailsFromRoomMap = false;
            ReturnToRoomMap();
            return;
        }
        ShowPage(DevicesPage);
    }

}
