using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App.Views;

internal sealed record PeopleRoomFilterChoice(string Label, Guid? Id = null, bool All = false, bool Unassigned = false);

public sealed partial class DevicesPageView : UserControl
{
    public DevicesPageView() => InitializeComponent();

    public DeviceColumnLayout Columns => DeviceColumnLayout.Current;
    public event EventHandler? FiltersChanged;
    public event EventHandler<string>? SortRequested;
    public event EventHandler<ScanResultRow>? DeviceRequested;

    internal string SearchText { get => ResultSearchBox.Text; set => ResultSearchBox.Text = value; }
    internal bool OpenPortsOnly { get => OpenPortsFilter.IsChecked == true; set => OpenPortsFilter.IsChecked = value; }
    internal ScanResultRow? SelectedResult
    {
        get => ResultsList.SelectedItem as ScanResultRow;
        set => ResultsList.SelectedItem = value;
    }
    internal PeopleRoomFilterChoice? PersonChoice => SelectedFilterChoice(PersonFilter);
    internal PeopleRoomFilterChoice? RoomChoice => SelectedFilterChoice(RoomFilter);

    internal void SetResults(IEnumerable<ScanResultRow> results) => ResultsList.ItemsSource = results;
    internal void FocusResults() => ResultsList.Focus(FocusState.Programmatic);

    internal void SetInteractionsEnabled(bool enabled)
    {
        ResultsList.IsItemClickEnabled = enabled;
        ResultsList.SelectionMode = enabled ? ListViewSelectionMode.Single : ListViewSelectionMode.None;
    }

    internal void ShowSummary(string count, string emptyMessage, bool isEmpty)
    {
        ResultCountText.Text = count;
        EmptyResultsText.Text = emptyMessage;
        EmptyResultsText.Visibility = isEmpty ? Visibility.Visible : Visibility.Collapsed;
    }

    internal void ShowScanStatus(string status)
    {
        SnapshotStatusText.Text = status;
        SnapshotStatusText.Visibility = Visibility.Visible;
    }

    internal void ShowSort(string address, string status, string response, string mac, string os, string type)
    {
        AddressSortGlyph.Text = address;
        StatusSortGlyph.Text = status;
        ResponseSortGlyph.Text = response;
        MacAddressSortGlyph.Text = mac;
        OperatingSystemSortGlyph.Text = os;
        DeviceTypeSortGlyph.Text = type;
    }

    internal void SetPeopleRoomFilters(IEnumerable<(Guid Id, string Label)> people,
        IEnumerable<(Guid Id, string Label)> rooms)
    {
        PopulateFilter(PersonFilter, "All people", people);
        PopulateFilter(RoomFilter, "All rooms", rooms);
    }

    private static PeopleRoomFilterChoice? SelectedFilterChoice(ComboBox picker) =>
        (picker.SelectedItem as ComboBoxItem)?.Tag as PeopleRoomFilterChoice;

    private static void PopulateFilter(ComboBox picker, string allLabel, IEnumerable<(Guid Id, string Label)> values)
    {
        var selected = SelectedFilterChoice(picker);
        picker.Items.Clear();
        Add(new PeopleRoomFilterChoice(allLabel, All: true));
        Add(new PeopleRoomFilterChoice("Unassigned", Unassigned: true));
        foreach (var (id, label) in values)
        {
            Add(new PeopleRoomFilterChoice(label, id));
        }

        picker.SelectedItem = picker.Items.OfType<ComboBoxItem>().FirstOrDefault(candidate =>
            candidate.Tag is PeopleRoomFilterChoice choice && (selected?.Unassigned == true
                ? choice.Unassigned
                : selected?.Id is { } id ? choice.Id == id : choice.All))
            ?? picker.Items.OfType<ComboBoxItem>().First();

        void Add(PeopleRoomFilterChoice choice) =>
            picker.Items.Add(new ComboBoxItem { Content = choice.Label, Tag = choice });
    }

    private void DeviceFilters_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var columns = e.NewSize.Width >= 850 ? 4 : e.NewSize.Width >= 480 ? 2 : 1;
        var rows = 4 / columns;
        if (DeviceFilters.RowDefinitions.Count != rows)
        {
            DeviceFilters.RowDefinitions.Clear();
            for (var row = 0; row < rows; row++)
            {
                DeviceFilters.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            }
        }
        FrameworkElement[] filters = [ResultSearchBox, PersonFilter, RoomFilter, OpenPortsFilter];
        for (var index = 0; index < filters.Length; index++)
        {
            Grid.SetRow(filters[index], index / columns);
            Grid.SetColumn(filters[index], index % columns * (4 / columns));
            Grid.SetColumnSpan(filters[index], 4 / columns);
        }
    }

    private void ResultSearchBox_TextChanged(object sender, TextChangedEventArgs e) => FiltersChanged?.Invoke(this, EventArgs.Empty);
    private void PeopleRoomFilter_SelectionChanged(object sender, SelectionChangedEventArgs e) => FiltersChanged?.Invoke(this, EventArgs.Empty);
    private void OpenPortsFilter_Changed(object sender, RoutedEventArgs e) => FiltersChanged?.Invoke(this, EventArgs.Empty);

    private void SortHeader_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string column })
        {
            SortRequested?.Invoke(this, column);
        }
    }

    private void ResultsList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is ScanResultRow row)
        {
            DeviceRequested?.Invoke(this, row);
        }
    }

}
