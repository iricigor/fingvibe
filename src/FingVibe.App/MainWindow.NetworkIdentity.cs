using System.Net;
using System.Text.Json;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private readonly NetworkDiscoveryService _networkDiscovery = new();
    private readonly PublicNetworkIdentityService _publicNetworkIdentity = new();
    private PublicNetworkIdentity? _publicIdentity;
    private int? _onlineDeviceCount;

    private async Task InitializeNetworkAsync()
    {
        var networks = IsUiReview
            ? new List<LanNetwork>
            {
                new(
                    "UI review loopback",
                    IPAddress.Loopback,
                    IPAddress.Loopback,
                    32,
                    false)
            }
            : _networkDiscovery.GetAvailableNetworks();
        NetworkPicker.ItemsSource = networks;
        NetworkPicker.DisplayMemberPath = nameof(LanNetwork.DisplayLabel);

        if (networks.Count == 0)
        {
            NetworkPage.ShowSummary("No active IPv4 network");
            OverviewPage.ShowNetwork("No active IPv4 network", string.Empty);
            NetworkPage.ShowPublicIdentity(null);
            NetworkPage.ShowLocalNetwork(null);
            ScanStatusText.Text = "Connect to a LAN to scan";
            ScanButton.IsEnabled = false;
            UpdateOverview();
            return;
        }

        NetworkPicker.SelectedIndex = 0;

        if (IsUiReview)
        {
            _publicIdentity = new PublicNetworkIdentity(
                IPAddress.Parse("203.0.113.10"),
                "UI review ISP",
                "Example City, Example Country");
            ShowPublicNetworkIdentity(_publicIdentity);
            UpdateNetworkIdentity();
            return;
        }

        await LoadPublicNetworkIdentityAsync();
    }

    private void NetworkPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        var selectedNetwork = NetworkPicker.SelectedItem as LanNetwork;
        ToolsPage.SetNetworkContext(selectedNetwork);
        OverviewPage.ShowSubnet(selectedNetwork);
        NetworkPage.ShowLocalNetwork(selectedNetwork);
        if (NetworkPicker.SelectedItem is not LanNetwork network)
        {
            UpdateOverview();
            return;
        }

        _onlineDeviceCount = null;
        UpdateNetworkIdentity();
        UpdateOverview();
    }

    private async Task LoadPublicNetworkIdentityAsync()
    {
        try
        {
            _publicIdentity = await _publicNetworkIdentity.GetAsync();
            ShowPublicNetworkIdentity(_publicIdentity);
        }
        catch (HttpRequestException)
        {
            ShowPublicNetworkIdentityUnavailable();
        }
        catch (TaskCanceledException)
        {
            ShowPublicNetworkIdentityUnavailable();
        }
        catch (JsonException)
        {
            ShowPublicNetworkIdentityUnavailable();
        }
        catch (InvalidOperationException)
        {
            ShowPublicNetworkIdentityUnavailable();
        }

        UpdateNetworkIdentity();
    }

    private void ShowPublicNetworkIdentity(PublicNetworkIdentity identity)
    {
        if (_networkIdentityClosed)
        {
            return;
        }

        NetworkPage.ShowPublicIdentity(identity);
        UpdateIspLogo(identity.IspName);
    }

    private void ShowPublicNetworkIdentityUnavailable()
    {
        if (_networkIdentityClosed)
        {
            return;
        }

        _publicIdentity = null;
        NetworkPage.ShowPublicIdentity(null);
        UpdateIspLogo(null);
    }

    private void UpdateNetworkIdentity()
    {
        if (_networkIdentityClosed || NetworkPicker.SelectedItem is not LanNetwork network)
        {
            return;
        }

        NetworkPage.ShowSummary(NetworkIdentityFormatter.FormatSummary(
            network,
            _publicIdentity,
            _onlineDeviceCount));
        OverviewPage.ShowNetwork(network.InterfaceName, _publicIdentity is { } identity
            ? $"{network.Cidr} - ISP: {identity.IspName}"
            : network.Cidr);
    }
}
