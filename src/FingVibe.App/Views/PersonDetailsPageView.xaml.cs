using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App.Views;

public sealed partial class PersonDetailsPageView : UserControl
{
    public PersonDetailsPageView() => InitializeComponent();

    public event RoutedEventHandler? BackRequested;
    public event RoutedEventHandler? EditRequested;
    public event RoutedEventHandler? DeleteRequested;
    public event RoutedEventHandler? AssignRequested;
    public event EventHandler<string>? UnassignRequested;
    public event EventHandler<ScanResultRow>? DeviceRequested;

    internal string Status { set => PersonDetailStatusText.Text = value; }
    internal ManagedPerson? SelectedPerson { get; set; }

    internal void Refresh(PeopleRoomsData data, IReadOnlyList<AssignedDeviceListRow> devices,
        bool hasCurrentScan, bool canEdit)
    {
        SetActionsEnabled(canEdit);
        if (SelectedPerson is not { } selected)
        {
            return;
        }

        SelectedPerson = data.People.FirstOrDefault(person => person.Id == selected.Id);
        if (SelectedPerson is { } person)
        {
            var assigned = PeopleRoomsPresentation.AssignedTo(data, devices, person.Id, null);
            ShowPerson(person, assigned, $"{PeopleRoomsPresentation.DeviceCount(assigned.Count)} assigned",
                PeopleRoomsPresentation.DetailResponses(assigned, hasCurrentScan), assigned.Count == 0);
        }
    }

    internal void SetActionsEnabled(bool enabled)
    {
        EditPersonDetailButton.IsEnabled = enabled;
        DeletePersonDetailButton.IsEnabled = enabled;
        AssignPersonDevicesButton.IsEnabled = enabled;
    }

    private void ShowPerson(ManagedPerson person, IReadOnlyList<AssignedDeviceListRow> devices,
        string count, string responses, bool isEmpty)
    {
        PersonDetailShortName.Text = person.ShortName;
        PersonDetailIcon.Glyph = PeopleRoomsIcons.Resolve(PeopleRoomsIcons.People, person.IconId).Glyph;
        PersonDetailName.Text = person.Name;
        PersonDetailNotes.Text = person.Notes ?? string.Empty;
        PersonDeviceCountText.Text = count;
        PersonRespondedCountText.Text = responses;
        PersonAssignedDevicesList.ItemsSource = devices;
        PersonAssignedDevicesEmptyText.Visibility = isEmpty ? Visibility.Visible : Visibility.Collapsed;
    }

    private void BackToPeopleButton_Click(object sender, RoutedEventArgs e) => BackRequested?.Invoke(this, e);
    private void EditPersonButton_Click(object sender, RoutedEventArgs e) => EditRequested?.Invoke(this, e);
    private void DeletePersonButton_Click(object sender, RoutedEventArgs e) => DeleteRequested?.Invoke(this, e);
    private void AssignPersonDeviceButton_Click(object sender, RoutedEventArgs e) => AssignRequested?.Invoke(this, e);

    private void UnassignPersonDeviceButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string mac })
        {
            UnassignRequested?.Invoke(this, mac);
        }
    }

    private void AssignedPersonDevice_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is AssignedDeviceListRow { ScanResult: { } row })
        {
            DeviceRequested?.Invoke(this, row);
        }
    }
}
