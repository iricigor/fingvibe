using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App.Views;

public sealed partial class PersonDetailsPageView : UserControl
{
    public PersonDetailsPageView()
    {
        InitializeComponent();
        InitializeActivity();
    }

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
        PersonDetailIcon.IconId = person.IconId;
        PersonDetailName.Text = person.Name;
        PersonDetailNotes.Text = person.Notes ?? string.Empty;
        PersonDetailNotes.Visibility = string.IsNullOrWhiteSpace(person.Notes) ? Visibility.Collapsed : Visibility.Visible;
        PersonDeviceCountText.Text = count;
        PersonRespondedCountText.Text = responses;
        _assignedDevices = devices;
        RefreshAssignedCategories();
        PersonAssignedDevicesEmptyText.Visibility = isEmpty ? Visibility.Visible : Visibility.Collapsed;
    }

    private void BackToPeopleButton_Click(object sender, RoutedEventArgs e) => BackRequested?.Invoke(this, e);
    private void PersonDetailHeading_SizeChanged(object sender, SizeChangedEventArgs e) => LayoutHeading(e.NewSize.Width);

    // Edit and Delete follow the title and wrap beneath it when the title would keep less than 160 DIP (scaled with text).
    private void LayoutHeading(double width)
    {
        if (width <= 0) return;
        PersonDetailActions.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
        var columns = PersonDetailHeading.ColumnDefinitions;
        var title = width - columns[0].ActualWidth - columns[1].ActualWidth - 3 * PersonDetailHeading.ColumnSpacing
            - PersonDetailActions.DesiredSize.Width;
        var inline = title >= 160 * new Windows.UI.ViewManagement.UISettings().TextScaleFactor;
        Grid.SetRow(PersonDetailActions, inline ? 0 : 2);
        Grid.SetColumn(PersonDetailActions, inline ? 3 : 2);
        PersonDetailActions.Margin = new Thickness(0, inline ? 0 : 8, 0, 0);
    }

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
