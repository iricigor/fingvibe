using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App.Views;

public sealed partial class OverviewPageView : UserControl
{
    public OverviewPageView() => InitializeComponent();

    public event RoutedEventHandler? NetworkRequested;
    public event RoutedEventHandler? OnlineDevicesRequested;
    public event RoutedEventHandler? OpenPortDevicesRequested;
    public event RoutedEventHandler? AboutRequested;

    internal void ShowBuild(string summary)
    {
        OverviewVersionText.Text = summary;
        AboutVersionText.Text = summary;
    }

    internal void ShowNetwork(string name, string detail)
    {
        NetworkNameText.Text = name;
        OverviewNetworkDetailText.Text = detail;
    }

    internal void ShowSubnet(LanNetwork? network)
    {
        NetworkSizeBadge.Visibility = network is null ? Visibility.Collapsed : Visibility.Visible;
        if (network is null)
        {
            return;
        }

        var subnet = SubnetDescriptionFormatter.Format(network.LocalAddress, network.PrefixLength);
        NetworkSizeBadgeText.Text = subnet.Badge;
        NetworkSizeBadgeLabel.Text = subnet.BadgeLabel;
        AutomationProperties.SetName(NetworkSizeBadgeText, $"{subnet.Size}. {subnet.Mask}");
    }

    internal void ShowScan(string online, string openPorts, bool hasScan, string freshness,
        string resultsContext, string setup)
    {
        OnlineDevicesText.Text = online;
        OpenPortDevicesText.Text = openPorts;
        OnlineDevicesCard.IsEnabled = hasScan;
        OpenPortDevicesCard.IsEnabled = hasScan;
        OverviewFreshnessText.Text = freshness;
        OverviewResultsContextText.Text = resultsContext;
        OverviewSetupText.Text = setup;
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

    private void ViewNetworkButton_Click(object sender, RoutedEventArgs e) => NetworkRequested?.Invoke(this, e);
    private void OnlineDevicesCard_Click(object sender, RoutedEventArgs e) => OnlineDevicesRequested?.Invoke(this, e);
    private void OpenPortDevicesCard_Click(object sender, RoutedEventArgs e) => OpenPortDevicesRequested?.Invoke(this, e);
    private void AboutFingVibe_Click(object sender, RoutedEventArgs e) => AboutRequested?.Invoke(this, e);
}
