using FingVibe.App.Views;
using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private bool _deviceDetailsFromRoomMap;
    private bool _roomDetailsFromRoomMap;
    private NavigationViewItem? _roomMapReturnNavigationItem;
    private RoomMapOrigin _roomMapOrigin = RoomMapOrigin.PeopleRooms;

    private void ViewRoomMapButton_Click(object sender, RoutedEventArgs e) =>
        OpenRoomMap(RoomMapOrigin.PeopleRooms);

    private void ViewRoomMapFromToolsButton_Click(object? sender, RoomMapOrigin origin) =>
        OpenRoomMap(origin);

    private void OpenRoomMap(RoomMapOrigin origin)
    {
        // Device and room detail round trips return through ReturnToRoomMap, so the entry origin persists.
        _roomMapOrigin = origin;
        RoomMapPage.SetBackDestination(origin);
        RoomMapPage.ResetScroll();
        UpdateRoomMapPage();
        ShowPage(RoomMapPage);
    }

    private void RoomMapDeviceRequested(object? sender, string identityKey)
    {
        var row = _allResults.FirstOrDefault(item =>
                string.Equals(item.IdentityKey, identityKey, StringComparison.Ordinal));
        if (row is null && CurrentDeviceData.Devices.TryGetValue(identityKey, out var device))
        {
            row = ScanResultRow.ForDevice(device, CurrentDeviceData);
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
            RoomMapPage.SetNavigationError("That room is no longer saved. Return to Rooms or choose another room.");
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

    private async void BackToRoomsFromMapButton_Click(object sender, RoutedEventArgs e)
    {
        if (_roomMapOrigin == RoomMapOrigin.PeopleRooms)
        {
            MainNavigation.SelectedItem = PeopleRoomsNavItem;
            ShowPage(PeopleRoomsPage);
            return;
        }

        MainNavigation.SelectedItem = ToolsNavItem;
        if (ToolsPage.Visibility != Visibility.Visible) ShowPage(ToolsPage);
        if (_roomMapOrigin == RoomMapOrigin.NetworkHealth)
        {
            await ToolsPage.OpenNetworkHealthAsync();
        }
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
