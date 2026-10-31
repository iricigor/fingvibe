using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App.Views;

public sealed partial class RoomDetailsPageView : UserControl
{
    public RoomDetailsPageView() => InitializeComponent();

    public event RoutedEventHandler? BackRequested;
    public event RoutedEventHandler? EditRequested;
    public event RoutedEventHandler? DeleteRequested;
    public event RoutedEventHandler? AssignRequested;
    public event EventHandler<string>? UnassignRequested;
    public event EventHandler<ScanResultRow>? DeviceRequested;

    internal string Status { set => RoomDetailStatusText.Text = value; }

    internal void SetActionsEnabled(bool enabled)
    {
        EditRoomDetailButton.IsEnabled = enabled;
        DeleteRoomDetailButton.IsEnabled = enabled;
        AssignRoomDevicesButton.IsEnabled = enabled;
    }

    internal void ShowRoom(ManagedRoom room, IReadOnlyList<AssignedDeviceListRow> devices,
        string count, string responses, bool isEmpty)
    {
        RoomDetailShortName.Text = room.ShortName;
        RoomDetailName.Text = room.Name;
        RoomDetailNotes.Text = room.Notes ?? string.Empty;
        RoomDeviceCountText.Text = count;
        RoomRespondedCountText.Text = responses;
        RoomAssignedDevicesList.ItemsSource = devices;
        RoomAssignedDevicesEmptyText.Visibility = isEmpty ? Visibility.Visible : Visibility.Collapsed;
    }

    private void BackToRoomsButton_Click(object sender, RoutedEventArgs e) => BackRequested?.Invoke(this, e);
    private void EditRoomButton_Click(object sender, RoutedEventArgs e) => EditRequested?.Invoke(this, e);
    private void DeleteRoomButton_Click(object sender, RoutedEventArgs e) => DeleteRequested?.Invoke(this, e);
    private void AssignRoomDeviceButton_Click(object sender, RoutedEventArgs e) => AssignRequested?.Invoke(this, e);

    private void UnassignRoomDeviceButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string mac })
        {
            UnassignRequested?.Invoke(this, mac);
        }
    }

    private void AssignedRoomDevice_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is AssignedDeviceListRow { ScanResult: { } row })
        {
            DeviceRequested?.Invoke(this, row);
        }
    }
}
