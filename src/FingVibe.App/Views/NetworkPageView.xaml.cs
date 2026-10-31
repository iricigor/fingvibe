using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace FingVibe.App.Views;

public sealed partial class NetworkPageView : UserControl
{
    public NetworkPageView() => InitializeComponent();

    internal void ShowSummary(string summary) => NetworkIdentityText.Text = summary;

    internal void ShowLocalNetwork(LanNetwork? network)
    {
        MachineAddressText.Text = network?.LocalAddress.ToString() ?? "No active IPv4 interface";
        LanAddressText.Text = network?.Cidr ?? "Unavailable";
        if (network is null)
        {
            SubnetSizeText.Text = "Unavailable";
            SubnetMaskText.Text = "Masked bits: unavailable";
            SubnetAddressCountText.Text = "Unavailable";
            SubnetScopeText.Text = "Unavailable";
            return;
        }

        var subnet = SubnetDescriptionFormatter.Format(network.LocalAddress, network.PrefixLength);
        SubnetSizeText.Text = subnet.Size;
        SubnetMaskText.Text = subnet.Mask;
        SubnetAddressCountText.Text = subnet.AddressCount;
        SubnetScopeText.Text = subnet.Scope;
    }

    internal void ShowPublicIdentity(PublicNetworkIdentity? identity)
    {
        PublicAddressText.Text = identity?.PublicAddress.ToString() ?? "Unavailable";
        IspNameText.Text = identity?.IspName ?? "Unavailable";
        LocationText.Text = identity?.LocationText ?? PublicNetworkIdentity.UnknownLocation;
    }

    internal void ShowLogo(ImageSource? source)
    {
        IspLogoImage.Source = source;
        IspLogoImage.Visibility = source is null ? Visibility.Collapsed : Visibility.Visible;
        IspLogoFallback.Visibility = source is null ? Visibility.Visible : Visibility.Collapsed;
    }
}
