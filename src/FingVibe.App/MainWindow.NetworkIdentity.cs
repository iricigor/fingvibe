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
                    IPAddress.Parse("127.0.0.0"),
                    24,
                    false)
            }
            : _networkDiscovery.GetAvailableNetworks();
        NetworkPicker.ItemsSource = networks;
        NetworkPicker.DisplayMemberPath = nameof(LanNetwork.DisplayLabel);

        if (networks.Count == 0)
        {
            NetworkIdentityText.Text = "No active IPv4 network";
            NetworkNameText.Text = "No active IPv4 network";
            OverviewNetworkDetailText.Text = string.Empty;
            PublicAddressText.Text = "Unavailable";
            IspNameText.Text = "Unavailable";
            LocationText.Text = PublicNetworkIdentity.UnknownLocation;
            MachineAddressText.Text = "No active IPv4 interface";
            LanAddressText.Text = "Unavailable";
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
        if (NetworkPicker.SelectedItem is not LanNetwork network)
        {
            NetworkSizeBadge.Visibility = Visibility.Collapsed;
            SubnetSizeText.Text = "Unavailable";
            SubnetMaskText.Text = "Masked bits: unavailable";
            SubnetAddressCountText.Text = "Unavailable";
            SubnetScopeText.Text = "Unavailable";
            UpdateOverview();
            return;
        }

        MachineAddressText.Text = network.LocalAddress.ToString();
        LanAddressText.Text = network.Cidr;
        var subnet = SubnetDescriptionFormatter.Format(network.LocalAddress, network.PrefixLength);
        NetworkSizeBadgeText.Text = subnet.Badge;
        NetworkSizeBadgeLabel.Text = subnet.BadgeLabel;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(
            NetworkSizeBadgeText, $"{subnet.Size}. {subnet.Mask}");
        NetworkSizeBadge.Visibility = Visibility.Visible;
        SubnetSizeText.Text = subnet.Size;
        SubnetMaskText.Text = subnet.Mask;
        SubnetAddressCountText.Text = subnet.AddressCount;
        SubnetScopeText.Text = subnet.Scope;
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
        PublicAddressText.Text = identity.PublicAddress.ToString();
        IspNameText.Text = identity.IspName;
        LocationText.Text = identity.LocationText;
    }

    private void ShowPublicNetworkIdentityUnavailable()
    {
        _publicIdentity = null;
        PublicAddressText.Text = "Unavailable";
        IspNameText.Text = "Unavailable";
        LocationText.Text = PublicNetworkIdentity.UnknownLocation;
    }

    private void UpdateNetworkIdentity()
    {
        if (NetworkPicker.SelectedItem is not LanNetwork network)
        {
            return;
        }

        NetworkIdentityText.Text = NetworkIdentityFormatter.FormatSummary(
            network,
            _publicIdentity,
            _onlineDeviceCount);
        NetworkNameText.Text = network.InterfaceName;
        OverviewNetworkDetailText.Text = _publicIdentity is { } identity
            ? $"{network.Cidr} - ISP: {identity.IspName}"
            : network.Cidr;
    }
}
