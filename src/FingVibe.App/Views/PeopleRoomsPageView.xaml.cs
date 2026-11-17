using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App.Views;

public sealed partial class PeopleRoomsPageView : UserControl
{
    private bool _canEdit;
    private IReadOnlyList<ManagedPersonListRow> _peopleRows = [];
    private IReadOnlyList<ManagedRoomListRow> _roomRows = [];

    public PeopleRoomsPageView() => InitializeComponent();

    public event RoutedEventHandler? AddRequested;
    public event RoutedEventHandler? AddRoomRequested;
    public event EventHandler<ManagedPerson>? PersonRequested;
    public event EventHandler<Guid>? EditRequested;
    public event EventHandler<Guid>? DeleteRequested;
    public event EventHandler<ManagedRoom>? RoomRequested;
    public event EventHandler<Guid>? EditRoomRequested;
    public event EventHandler<Guid>? DeleteRoomRequested;

    internal string Status
    {
        set
        {
            PeopleRoomsStatusText.Text = value;
            PeopleStatusText.Text = value;
            RoomsStatusText.Text = value;
        }
    }

    internal void ShowPeopleRooms(PeopleRoomsData data, IReadOnlyList<AssignedDeviceListRow> devices,
        bool hasCurrentScan, bool canEdit)
    {
        _canEdit = canEdit;
        _peopleRows = PeopleRoomsPresentation.PeopleRows(data, devices, hasCurrentScan);
        _roomRows = PeopleRoomsPresentation.RoomRows(data, devices, hasCurrentScan);
        AddPersonButton.IsEnabled = canEdit;
        AddRoomButton.IsEnabled = canEdit;
        ApplySearch();
    }

    private void ApplySearch()
    {
        var query = PeopleRoomsSearchBox.Text;

        var peopleRows = _peopleRows.Where(row => PeopleRoomsPresentation.MatchesSearch(
            row.Person.ShortName, row.Person.Name, query)).ToArray();
        var roomRows = _roomRows.Where(row => PeopleRoomsPresentation.MatchesSearch(
            row.Room.ShortName, row.Room.Name, query)).ToArray();

        PeopleList.ItemsSource = peopleRows;
        RoomsList.ItemsSource = roomRows;

        var hasPeopleRows = peopleRows.Length > 0;
        var hasRoomRows = roomRows.Length > 0;
        var hasPeopleData = _peopleRows.Count > 0;
        var hasRoomData = _roomRows.Count > 0;

        PeopleTableBorder.Visibility = hasPeopleRows ? Visibility.Visible : Visibility.Collapsed;
        RoomsTableBorder.Visibility = hasRoomRows ? Visibility.Visible : Visibility.Collapsed;

        PeopleEmptyState.Visibility = hasPeopleRows ? Visibility.Collapsed : Visibility.Visible;
        RoomsEmptyState.Visibility = hasRoomRows ? Visibility.Collapsed : Visibility.Visible;

        PeopleEmptyText.Text = hasPeopleData ? "No people match your search." : "No people yet";
        RoomsEmptyText.Text = hasRoomData ? "No rooms match your search." : "No rooms yet";

        PeopleCountText.Text = $"{peopleRows.Length} shown";
        RoomsCountText.Text = $"{roomRows.Length} shown";
    }

    private void PeopleRoomsSearchBox_TextChanged(object sender, TextChangedEventArgs e) => ApplySearch();

    private void AddPersonButton_Click(object sender, RoutedEventArgs e) => AddRequested?.Invoke(this, e);

    private void AddRoomButton_Click(object sender, RoutedEventArgs e) => AddRoomRequested?.Invoke(this, e);

    private void PeopleList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is ManagedPersonListRow row)
        {
            PersonRequested?.Invoke(this, row.Person);
        }
    }

    private void RoomsList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is ManagedRoomListRow row)
        {
            RoomRequested?.Invoke(this, row.Room);
        }
    }

    private void PersonActionsButton_Click(object sender, RoutedEventArgs e)
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

    private void RoomActionsButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: Guid id } button)
        {
            return;
        }

        var menu = new MenuFlyout();
        var edit = new MenuFlyoutItem { Text = "Edit", IsEnabled = _canEdit };
        edit.Click += (_, _) => EditRoomRequested?.Invoke(this, id);
        var delete = new MenuFlyoutItem { Text = "Delete", IsEnabled = _canEdit };
        delete.Click += (_, _) => DeleteRoomRequested?.Invoke(this, id);
        menu.Items.Add(edit);
        menu.Items.Add(delete);
        menu.ShowAt(button);
    }
}
