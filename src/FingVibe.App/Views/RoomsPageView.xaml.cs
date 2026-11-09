using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App.Views;

public sealed partial class RoomsPageView : UserControl
{
    private bool _canEdit;
    private IReadOnlyList<ManagedRoomListRow> _rows = [];

    public RoomsPageView() => InitializeComponent();

    public event RoutedEventHandler? AddRequested;
    public event EventHandler<ManagedRoom>? RoomRequested;
    public event EventHandler<Guid>? EditRequested;
    public event EventHandler<Guid>? DeleteRequested;

    internal string Status { set => RoomsStatusText.Text = value; }

    internal void ShowRooms(PeopleRoomsData data, IReadOnlyList<AssignedDeviceListRow> devices,
        bool hasCurrentScan, bool canEdit)
    {
        _canEdit = canEdit;
        _rows = PeopleRoomsPresentation.RoomRows(data, devices, hasCurrentScan);
        ApplySearch();
        AddRoomButton.IsEnabled = canEdit;
    }

    private void ApplySearch()
    {
        var rows = _rows.Where(row => PeopleRoomsPresentation.MatchesSearch(
            row.Room.ShortName, row.Room.Name, RoomsSearchBox.Text)).ToArray();
        RoomsList.ItemsSource = rows;
        RoomsTableBorder.Visibility = rows.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        RoomsEmptyState.Visibility = rows.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        RoomsEmptyText.Text = _rows.Count == 0 ? "No rooms yet" : "No rooms match your search.";
    }

    private void RoomsSearchBox_TextChanged(object sender, TextChangedEventArgs e) => ApplySearch();
    private void AddRoomButton_Click(object sender, RoutedEventArgs e) => AddRequested?.Invoke(this, e);

    private void RoomsList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is ManagedRoomListRow row)
        {
            RoomRequested?.Invoke(this, row.Room);
        }
    }

    private void RoomActionsButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: Guid id } button)
        {
            return;
        }

        var menu = new MenuFlyout();
        var edit = new MenuFlyoutItem { Text = "Edit", IsEnabled = _canEdit };
        edit.Click += (_, _) => EditRequested?.Invoke(this, id);
        var delete = new MenuFlyoutItem { Text = "Delete", IsEnabled = _canEdit };
        delete.Click += (_, _) => DeleteRequested?.Invoke(this, id);
        menu.Items.Add(edit);
        menu.Items.Add(delete);
        menu.ShowAt(button);
    }
}
