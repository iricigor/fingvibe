using FingVibe.Core.Models;
using Microsoft.UI.Xaml;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private void ViewRoomMapButton_Click(object sender, RoutedEventArgs e)
    {
        UpdateRoomMapPage();
        ShowPage(RoomMapPage);
    }

    private void ViewRoomMapFromToolsButton_Click(object? sender, EventArgs e) =>
        ViewRoomMapButton_Click(this, new RoutedEventArgs());

    private void ManageRoomsFromMapButton_Click(object sender, RoutedEventArgs e)
    {
        MainNavigation.SelectedItem = PeopleRoomsNavItem;
        ShowPage(PeopleRoomsPage);
    }

    private void UpdateRoomMapPage()
    {
        if (RoomMapPage is null)
        {
            return;
        }

        var network = NetworkPicker.SelectedItem as LanNetwork;
        string? networkId = null;
        string? networkError = null;
        if (network is not null)
        {
            networkId = ResolveNetworkIdentity(network, out networkError);
        }
        RoomMapPage.Show(CurrentDeviceData, network, networkId, networkError);
    }
}
