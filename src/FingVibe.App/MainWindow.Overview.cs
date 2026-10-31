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

    private void OnlineDevicesCard_Click(object sender, RoutedEventArgs e) =>
        ShowOverviewDevices(openPortsOnly: false);

    private void OpenPortDevicesCard_Click(object sender, RoutedEventArgs e) =>
        ShowOverviewDevices(openPortsOnly: true);

    private void ShowOverviewDevices(bool openPortsOnly)
    {
        DevicesPage.SearchText = string.Empty;
        DevicesPage.OpenPortsOnly = openPortsOnly;
        RefreshVisibleResults();
        MainNavigation.SelectedItem = DevicesNavItem;
        ShowPage(DevicesPage);
        DevicesPage.FocusResults();
    }

    private void UpdateOverview()
    {
        if (OverviewPage is null)
        {
            return;
        }

        var network = NetworkPicker.SelectedItem as LanNetwork;
        var hasScan = _displayedScan is not null;
        var online = hasScan ? _allResults.Count(row => row.IsOnline).ToString("N0") : "Not scanned";
        var openPorts = hasScan
            ? _allResults.Count(row => row.Result.OpenPortItems.Count > 0).ToString("N0")
            : "Not scanned";
        var freshness = _displayedScan?.Freshness(DateTimeOffset.UtcNow) ?? "Not scanned yet";
        freshness = _displayedScan is { } context && context.Subnet != network?.Cidr
            ? $"{freshness} ({context.Subnet})"
            : freshness;
        var resultsContext = _displayedScan is { } scan
            ? $"{scan.Describe(network?.Cidr)}{(!_isScanning && _allResults.Count > 0 && !_allResults.Any(row => row.IsOnline) ? " No devices answered this scan; active devices may block ICMP." : string.Empty)}"
            : network is null
                ? "Connect to an IPv4 network to scan for devices."
                : "Run your first scan to discover devices.";

        var setup = network is null
            ? "No active IPv4 network."
            : $"Interface: {network.InterfaceName}\nThis computer: {network.LocalAddress}\nSubnet: {network.Cidr}";

        OverviewPage.ShowScan(online, openPorts, hasScan, freshness, resultsContext, setup);
        UpdateScanStatus();
    }
}
