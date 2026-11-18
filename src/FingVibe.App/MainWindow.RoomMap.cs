using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private bool _deviceDetailsFromRoomMap;
    private bool _roomDetailsFromRoomMap;
    private NavigationViewItem? _roomMapReturnNavigationItem;

    private void ViewRoomMapButton_Click(object sender, RoutedEventArgs e)
    {
        RoomMapPage.ResetScroll();
        UpdateRoomMapPage();
        ShowPage(RoomMapPage);
    }

    private void ViewRoomMapFromToolsButton_Click(object? sender, EventArgs e) =>
        ViewRoomMapButton_Click(this, new RoutedEventArgs());

    private void RoomMapDeviceRequested(object? sender, string identityKey)
    {
        var row = _allResults.FirstOrDefault(item =>
                string.Equals(item.IdentityKey, identityKey, StringComparison.Ordinal));
        if (row is null && CurrentDeviceData.Devices.TryGetValue(identityKey, out var device))
        {
            row = new ScanResultRow(
                device, 0,
                _deviceNameOverrides.GetValueOrDefault(identityKey),
                _classificationOverrides.GetValueOrDefault(identityKey),
                historical: true);
        }
        if (row is null)
        {
            RoomMapPage.SetNavigationError("That device is no longer in the map. Refresh or choose another visible device.");
            return;
        }

        _roomMapReturnNavigationItem = MainNavigation.SelectedItem as NavigationViewItem;
        ShowDeviceDetails(row, fromRoomMap: true);
    }

    private void RoomMapRoomRequested(object? sender, Guid roomId)
    {
        var room = _peopleRooms.Rooms.FirstOrDefault(item => item.Id == roomId);
        if (room is null)
        {
            RoomMapPage.SetNavigationError("That room is no longer saved. Return to Manage rooms or choose another room.");
            return;
        }

        _roomMapReturnNavigationItem = MainNavigation.SelectedItem as NavigationViewItem;
        _roomDetailsFromRoomMap = true;
        RoomDetailPage.SetBackDestination(true);
        RoomDetailPage.SelectedRoom = room;
        UpdatePeopleRoomsPages();
        ShowPage(RoomDetailPage);
    }

    private void ReturnToRoomMap()
    {
        MainNavigation.SelectedItem = _roomMapReturnNavigationItem ?? PeopleRoomsNavItem;
        ShowPage(RoomMapPage);
        RoomMapPage.RestoreNavigation();
    }

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
