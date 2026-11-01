using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

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
    internal InventoryDeviceStatus? StatusFilter
    {
        get => InventoryStatusFilter.SelectedIndex switch
        {
            1 => InventoryDeviceStatus.Online,
            2 => InventoryDeviceStatus.Offline,
            3 => InventoryDeviceStatus.FingOnly,
            4 => InventoryDeviceStatus.Unknown,
            _ => null
        };
        set => InventoryStatusFilter.SelectedIndex = value is null ? 0 : (int)value + 1;
    }
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

    internal void ShowInventorySummary(string summary) => InventoryCountsText.Text = summary;

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
        const double optionWidth = 180;
        const double spacing = 8;
        const double minimumSearchWidth = 120;
        var inline = e.NewSize.Width >= minimumSearchWidth + (optionWidth + spacing) * 4;
        Grid.SetRow(DeviceFilterOptions, inline ? 0 : 1);
        Grid.SetColumn(DeviceFilterOptions, inline ? 1 : 0);
        Grid.SetColumnSpan(DeviceFilterOptions, inline ? 1 : 2);
        Grid.SetColumnSpan(DeviceSearchFilters, inline ? 1 : 2);
        var columns = inline ? 3 : Math.Clamp((int)((e.NewSize.Width + spacing) / (optionWidth + spacing)), 1, 3);
        var rows = (3 + columns - 1) / columns;
        if (DeviceFilterOptions.ColumnDefinitions.Count != columns)
        {
            DeviceFilterOptions.ColumnDefinitions.Clear();
            for (var column = 0; column < columns; column++)
            {
                DeviceFilterOptions.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(optionWidth) });
            }
        }
        if (DeviceFilterOptions.RowDefinitions.Count != rows)
        {
            DeviceFilterOptions.RowDefinitions.Clear();
            for (var row = 0; row < rows; row++)
            {
                DeviceFilterOptions.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            }
        }
        FrameworkElement[] filters = [PersonFilter, RoomFilter, OpenPortsFilterContainer];
        for (var index = 0; index < filters.Length; index++)
        {
            Grid.SetRow(filters[index], index / columns);
            Grid.SetColumn(filters[index], index % columns);
        }
    }

    private void ResultsList_ContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.Item is ScanResultRow row)
        {
            row.IsPointerOver = false;
            row.IsSelected = ReferenceEquals(ResultsList.SelectedItem, row);
            args.ItemContainer.RemoveHandler(PointerEnteredEvent, new PointerEventHandler(ResultRow_PointerEntered));
            args.ItemContainer.RemoveHandler(PointerExitedEvent, new PointerEventHandler(ResultRow_PointerExited));
            if (!args.InRecycleQueue)
            {
                args.ItemContainer.AddHandler(PointerEnteredEvent, new PointerEventHandler(ResultRow_PointerEntered), true);
                args.ItemContainer.AddHandler(PointerExitedEvent, new PointerEventHandler(ResultRow_PointerExited), true);
            }
        }
    }

    private void ResultsList_SelectionChanged(object sender, SelectionChangedEventArgs args)
    {
        foreach (var row in args.RemovedItems.OfType<ScanResultRow>())
        {
            row.IsSelected = false;
        }
        foreach (var row in args.AddedItems.OfType<ScanResultRow>())
        {
            row.IsSelected = true;
        }
    }

    private void ResultRow_PointerEntered(object sender, PointerRoutedEventArgs args)
    {
        if (sender is ListViewItem container && ResultsList.ItemFromContainer(container) is ScanResultRow row)
        {
            row.IsPointerOver = true;
        }
    }

    private void ResultRow_PointerExited(object sender, PointerRoutedEventArgs args)
    {
        if (sender is ListViewItem container && ResultsList.ItemFromContainer(container) is ScanResultRow row)
        {
            row.IsPointerOver = false;
        }
    }

    private void ResultSearchBox_TextChanged(object sender, TextChangedEventArgs e) => FiltersChanged?.Invoke(this, EventArgs.Empty);
    private void PeopleRoomFilter_SelectionChanged(object sender, SelectionChangedEventArgs e) => FiltersChanged?.Invoke(this, EventArgs.Empty);
    private void InventoryStatusFilter_SelectionChanged(object sender, SelectionChangedEventArgs e) => FiltersChanged?.Invoke(this, EventArgs.Empty);
    private void OpenPortsFilter_Changed(object sender, RoutedEventArgs e) => FiltersChanged?.Invoke(this, EventArgs.Empty);

    private void OpenPortsFilterContainer_Tapped(object sender, TappedRoutedEventArgs args)
    {
        if (ReferenceEquals(args.OriginalSource, OpenPortsFilterContainer))
        {
            OpenPortsFilter.IsChecked = !OpenPortsOnly;
            OpenPortsFilter.Focus(FocusState.Pointer);
            args.Handled = true;
        }
    }

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
