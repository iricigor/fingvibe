using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App.Views;

public sealed partial class PeoplePageView : UserControl
{
    private bool _canEdit;

    public PeoplePageView() => InitializeComponent();

    public event TextChangedEventHandler? SearchChanged;
    public event RoutedEventHandler? AddRequested;
    public event EventHandler<ManagedPerson>? PersonRequested;
    public event EventHandler<Guid>? EditRequested;
    public event EventHandler<Guid>? DeleteRequested;

    internal string SearchText => PeopleSearchBox.Text;
    internal string Status { set => PeopleStatusText.Text = value; }

    internal void ShowRows(IReadOnlyList<ManagedPersonListRow> rows, string emptyMessage, bool canEdit)
    {
        _canEdit = canEdit;
        PeopleList.ItemsSource = rows;
        PeopleTableBorder.Visibility = rows.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        PeopleEmptyState.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        PeopleEmptyText.Text = emptyMessage;
        AddPersonButton.IsEnabled = canEdit;
    }

    private void PeopleSearchBox_TextChanged(object sender, TextChangedEventArgs e) => SearchChanged?.Invoke(this, e);
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
