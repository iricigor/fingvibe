using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private OverviewScanContext? _displayedScan;
    private readonly DispatcherTimer _overviewClock = new() { Interval = TimeSpan.FromSeconds(30) };

    private void InitializeOverview()
    {
        _overviewClock.Tick += (_, _) => UpdateOverview();
        Closed += (_, _) => _overviewClock.Stop();
        _overviewClock.Start();
        UpdateOverview();
    }

    private void OverviewPage_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var compact = e.NewSize.Width - 48 < 600;
        OverviewMetricsGrid.RowSpacing = compact ? 16 : 0;
        Grid.SetColumn(OpenPortDevicesCard, compact ? 0 : 1);
        Grid.SetRow(OpenPortDevicesCard, compact ? 1 : 0);
        Grid.SetColumnSpan(OnlineDevicesCard, compact ? 2 : 1);
        Grid.SetColumnSpan(OpenPortDevicesCard, compact ? 2 : 1);
    }

    private void OnlineDevicesCard_Click(object sender, RoutedEventArgs e) =>
        ShowOverviewDevices(openPortsOnly: false);

    private void OpenPortDevicesCard_Click(object sender, RoutedEventArgs e) =>
        ShowOverviewDevices(openPortsOnly: true);

    private void ShowOverviewDevices(bool openPortsOnly)
    {
        ResultSearchBox.Text = string.Empty;
        StatusFilter.SelectedIndex = openPortsOnly ? 0 : 1;
        OpenPortsFilter.IsChecked = openPortsOnly;
        RefreshVisibleResults();
        MainNavigation.SelectedItem = DevicesNavItem;
        ShowPage(DevicesPage);
        ResultsList.Focus(FocusState.Programmatic);
    }

    private void UpdateOverview()
    {
        if (OnlineDevicesText is null)
        {
            return;
        }

        var network = NetworkPicker.SelectedItem as LanNetwork;
        var hasScan = _displayedScan is not null;
        OnlineDevicesText.Text = hasScan ? _allResults.Count(row => row.IsOnline).ToString("N0") : "Not scanned";
        OpenPortDevicesText.Text = hasScan
            ? _allResults.Count(row => row.Result.OpenPortItems.Count > 0).ToString("N0")
            : "Not scanned";
        OnlineDevicesCard.IsEnabled = hasScan;
        OpenPortDevicesCard.IsEnabled = hasScan;

        var freshness = _displayedScan?.Freshness(DateTimeOffset.UtcNow) ?? "Not scanned yet";
        OverviewFreshnessText.Text = _displayedScan is { } context && context.Subnet != network?.Cidr
            ? $"{freshness} ({context.Subnet})"
            : freshness;
        OverviewResultsContextText.Text = _displayedScan is { } scan
            ? $"{scan.Describe(network?.Cidr)}{(!_isScanning && _allResults.Count > 0 && !_allResults.Any(row => row.IsOnline) ? " No devices answered this scan; active devices may block ICMP." : string.Empty)}"
            : network is null
                ? "Connect to an IPv4 network to scan for devices."
                : "Run your first scan to discover devices.";

        OverviewSetupText.Text = network is null
            ? "No active IPv4 network."
            : $"Interface: {network.InterfaceName}\nThis computer: {network.LocalAddress}\nSubnet: {network.Cidr}";

        if (!_isScanning)
        {
            ScanStatusText.Text = _displayedScan is { } displayed
                ? $"{freshness} - {displayed.Subnet}"
                : network is null ? "Connect to a LAN to scan" : "Ready for your first scan";
        }
    }
}
