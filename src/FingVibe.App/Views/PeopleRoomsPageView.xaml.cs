using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App.Views;

public sealed partial class PeopleRoomsPageView : UserControl
{
    private readonly Windows.UI.ViewManagement.UISettings _uiSettings = new();
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
    public event RoutedEventHandler? RoomMapRequested;

    internal string Status
    {
        set
        {
            var visibility = string.IsNullOrEmpty(value) ? Visibility.Collapsed : Visibility.Visible;
            foreach (var text in new[] { PeopleRoomsStatusText, PeopleStatusText, RoomsStatusText })
            {
                text.Text = value;
                text.Visibility = visibility;
            }
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

        PeopleColumnHeaders.Visibility = PeopleList.Visibility = hasPeopleRows ? Visibility.Visible : Visibility.Collapsed;
        RoomsColumnHeaders.Visibility = RoomsList.Visibility = hasRoomRows ? Visibility.Visible : Visibility.Collapsed;

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

    private void RoomMapButton_Click(object sender, RoutedEventArgs e) =>
        RoomMapRequested?.Invoke(this, e);

    private void RoomsHeadingRow_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        // The title, count, View room map and Add room share one row until it would crowd the title.
        var inline = e.NewSize.Width >= 420 * _uiSettings.TextScaleFactor;
        Grid.SetRow(RoomsActions, inline ? 0 : 1);
        Grid.SetColumn(RoomsActions, inline ? 3 : 0);
        Grid.SetColumnSpan(RoomsActions, inline ? 1 : 4);
        RoomsActions.Margin = new Thickness(0, inline ? 0 : 8, 0, 0);
    }

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
        if (sender is Button { Tag: Guid id } button)
        {
            var name = _peopleRows.FirstOrDefault(row => row.Person.Id == id)?.Person.Name ?? "this person";
            ShowActionsMenu(button, name, () => EditRequested?.Invoke(this, id), () => DeleteRequested?.Invoke(this, id));
        }
    }

    private void RoomActionsButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: Guid id } button)
        {
            var name = _roomRows.FirstOrDefault(row => row.Room.Id == id)?.Room.Name ?? "this room";
            ShowActionsMenu(button, name, () => EditRoomRequested?.Invoke(this, id), () => DeleteRoomRequested?.Invoke(this, id));
        }
    }

    // Visible labels stay short; help text names the entry, and Delete still asks for confirmation.
    private void ShowActionsMenu(Button button, string name, Action edit, Action delete)
    {
        var menu = new MenuFlyout();
        var editItem = new MenuFlyoutItem { Text = "Edit", Icon = new FontIcon { Glyph = "\uE70F" }, IsEnabled = _canEdit };
        AutomationProperties.SetHelpText(editItem, $"Edit {name}");
        editItem.Click += (_, _) => edit();
        var deleteItem = new MenuFlyoutItem { Text = "Delete", Icon = new FontIcon { Glyph = "\uE74D" }, IsEnabled = _canEdit };
        AutomationProperties.SetHelpText(deleteItem, $"Delete {name} after confirmation");
        deleteItem.Click += (_, _) => delete();
        menu.Items.Add(editItem);
        menu.Items.Add(deleteItem);
        menu.ShowAt(button);
    }
}
