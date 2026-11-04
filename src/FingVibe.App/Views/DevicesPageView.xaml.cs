using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace FingVibe.App.Views;

public sealed partial class DevicesPageView : UserControl
{
    private readonly Windows.UI.ViewManagement.UISettings _uiSettings = new();

    public DevicesPageView()
    {
        InitializeComponent();
        InitializeCellPreviews();
        InventoryStatusFilter.ItemsSource = new DeviceFilterChoice[]
        {
            new("Status", "All statuses", All: true),
            new("Status", "Online"), new("Status", "Offline"),
            new("Status", "Fing Only"), new("Status", "Unknown")
        };
        InventoryStatusFilter.SelectedIndex = 0;
    }

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
    internal DeviceFilterChoice? PersonChoice => SelectedFilterChoice(PersonFilter);
    internal DeviceFilterChoice? RoomChoice => SelectedFilterChoice(RoomFilter);

    internal void SetResults(IEnumerable<ScanResultRow> results)
    {
        DismissCellPreview();
        ResultsList.ItemsSource = results;
    }
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

    internal void ShowLastScan(ScanSnapshot? snapshot) =>
        LastScanText.Text = "Duration: " + (snapshot?.Duration is { } duration
            ? $"{duration.TotalSeconds:N1} s" : snapshot is null ? "—" : "not recorded");

    internal void ShowSort(string address, string status, string response, string mac, string os, string type)
    {
        AddressSortGlyph.Text = address;
        StatusSortGlyph.Text = status;
        ResponseSortGlyph.Text = response;
        MacAddressSortGlyph.Text = mac;
        MergedMacAddressSortGlyph.Text = mac;
        SeparateResponseSortGlyph.Text = response;
        SeparateDeviceTypeSortGlyph.Text = type;
        OperatingSystemSortGlyph.Text = os;
        DeviceTypeSortGlyph.Text = type;
    }

    internal void SetPeopleRoomFilters(IEnumerable<(Guid Id, string Label)> people,
        IEnumerable<(Guid Id, string Label)> rooms)
    {
        PopulateFilter(PersonFilter, "Person", "All people", people);
        PopulateFilter(RoomFilter, "Room", "All rooms", rooms);
    }

    private static DeviceFilterChoice? SelectedFilterChoice(ComboBox picker) =>
        picker.SelectedItem as DeviceFilterChoice;

    private static void PopulateFilter(ComboBox picker, string category, string allLabel,
        IEnumerable<(Guid Id, string Label)> values)
    {
        var selected = SelectedFilterChoice(picker);
        var choices = new List<DeviceFilterChoice>
        {
            new(category, allLabel, All: true),
            new(category, "Unassigned", Unassigned: true)
        };
        choices.AddRange(values.Select(value => new DeviceFilterChoice(category, value.Label, value.Id)));
        picker.ItemsSource = choices;
        picker.SelectedItem = choices.FirstOrDefault(choice => selected?.Unassigned == true
                ? choice.Unassigned
                : selected?.Id is { } id ? choice.Id == id : choice.All)
            ?? choices[0];
    }

    private void DeviceFilters_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        const double spacing = 8;
        const double minimumSearchWidth = 180;
        var textScale = _uiSettings.TextScaleFactor;
        double[] widths = [Math.Min(140 * textScale, e.NewSize.Width),
            Math.Min(140 * textScale, e.NewSize.Width), Math.Min(180 * textScale, e.NewSize.Width)];
        var statusWidth = Math.Min(210 * textScale, e.NewSize.Width);
        PersonFilter.Width = widths[0];
        RoomFilter.Width = widths[1];
        OpenPortsFilterContainer.Width = widths[2];
        InventoryStatusFilter.Width = statusWidth;
        var inline = e.NewSize.Width >= minimumSearchWidth + statusWidth + widths.Sum() + spacing * 4;
        Grid.SetRow(DeviceFilterOptions, inline ? 0 : 1);
        Grid.SetColumn(DeviceFilterOptions, inline ? 1 : 0);
        Grid.SetColumnSpan(DeviceFilterOptions, inline ? 1 : 2);
        Grid.SetColumnSpan(DeviceSearchFilters, inline ? 1 : 2);
        DeviceFilters.RowSpacing = inline ? 0 : spacing;
        var stackedSearch = e.NewSize.Width < minimumSearchWidth + statusWidth + spacing;
        DeviceSearchFilters.RowSpacing = stackedSearch ? spacing : 0;
        Grid.SetRow(InventoryStatusFilter, stackedSearch ? 1 : 0);
        Grid.SetColumn(InventoryStatusFilter, stackedSearch ? 0 : 1);
        Grid.SetColumnSpan(InventoryStatusFilter, stackedSearch ? 2 : 1);
        Grid.SetColumnSpan(ResultSearchBox, stackedSearch ? 2 : 1);
        var columns = inline || e.NewSize.Width >= widths.Sum() + spacing * 2 ? 3
            : e.NewSize.Width >= widths[2] + widths[0] + spacing ? 2 : 1;
        var rows = (3 + columns - 1) / columns;
        if (DeviceFilterOptions.ColumnDefinitions.Count != columns)
        {
            DeviceFilterOptions.ColumnDefinitions.Clear();
            for (var column = 0; column < columns; column++)
            {
                DeviceFilterOptions.ColumnDefinitions.Add(new ColumnDefinition());
            }
        }
        for (var column = 0; column < columns; column++)
        {
            DeviceFilterOptions.ColumnDefinitions[column].Width =
                new GridLength(widths.Where((_, index) => index % columns == column).Max());
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

    private void DeviceSummary_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var inline = e.NewSize.Width >= 760 * _uiSettings.TextScaleFactor;
        Grid.SetRow(LastScanText, inline ? 0 : 2);
        Grid.SetColumn(LastScanText, inline ? 1 : 0);
        Grid.SetColumnSpan(LastScanText, inline ? 1 : 2);
        LastScanText.Margin = inline ? new Thickness(0) : new Thickness(0, 4, 0, 0);
    }

    private void ResultsList_ContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (_previewAnchor is { } anchor && FindAncestor<ListViewItem>(anchor) == args.ItemContainer)
            DismissCellPreview();
        if (args.Item is ScanResultRow row)
        {
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetHelpText(args.ItemContainer, FullRowValues(row));
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
