using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App.Views;

public sealed partial class PeoplePageView : UserControl
{
    private bool _canEdit;
    private IReadOnlyList<ManagedPersonListRow> _rows = [];

    public PeoplePageView() => InitializeComponent();

    public event RoutedEventHandler? AddRequested;
    public event EventHandler<ManagedPerson>? PersonRequested;
    public event EventHandler<Guid>? EditRequested;
    public event EventHandler<Guid>? DeleteRequested;

    internal string Status { set => PeopleStatusText.Text = value; }

    internal void ShowPeople(PeopleRoomsData data, IReadOnlyList<AssignedDeviceListRow> devices,
        bool hasCurrentScan, bool canEdit)
    {
        _canEdit = canEdit;
        _rows = PeopleRoomsPresentation.PeopleRows(data, devices, hasCurrentScan);
        ApplySearch();
        AddPersonButton.IsEnabled = canEdit;
    }

    private void ApplySearch()
    {
        var rows = _rows.Where(row => PeopleRoomsPresentation.MatchesSearch(
            row.Person.ShortName, row.Person.Name, PeopleSearchBox.Text)).ToArray();
        PeopleList.ItemsSource = rows;
        PeopleTableBorder.Visibility = rows.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        PeopleEmptyState.Visibility = rows.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        PeopleEmptyText.Text = _rows.Count == 0 ? "No people yet" : "No people match your search.";
    }

    private void PeopleSearchBox_TextChanged(object sender, TextChangedEventArgs e) => ApplySearch();
    private void AddPersonButton_Click(object sender, RoutedEventArgs e) => AddRequested?.Invoke(this, e);

    private void PeopleList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is ManagedPersonListRow row)
        {
            PersonRequested?.Invoke(this, row.Person);
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
}
