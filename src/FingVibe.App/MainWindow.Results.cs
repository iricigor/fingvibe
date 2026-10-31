using System.Collections.ObjectModel;
using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private enum ResultSortColumn
    {
        Address,
        Status,
        Response,
        MacAddress,
        OperatingSystem,
        DeviceType
    }

    private readonly List<ScanResultRow> _allResults = [];
    private readonly ObservableCollection<ScanResultRow> _visibleResults = [];
    private long _minimumLatency = long.MaxValue;
    private long _maximumLatency;
    private ResultSortColumn _sortColumn = ResultSortColumn.Address;
    private bool _sortAscending = true;

    private void ResultSearchBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        RefreshVisibleResults();
    }

    private void DeviceFilters_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        const double optionWidth = 180;
        const double spacing = 8;
        var inline = e.NewSize.Width >= 800;
        Grid.SetRow(DeviceFilterOptions, inline ? 0 : 1);
        Grid.SetColumn(DeviceFilterOptions, inline ? 1 : 0);
        Grid.SetColumnSpan(DeviceFilterOptions, inline ? 1 : 2);
        Grid.SetColumnSpan(ResultSearchBox, inline ? 1 : 2);
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
            row.IsSelected = !args.InRecycleQueue && args.ItemContainer.IsSelected;
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
        if (sender is FrameworkElement { DataContext: ScanResultRow row })
        {
            row.IsPointerOver = true;
        }
    }

    private void ResultRow_PointerExited(object sender, PointerRoutedEventArgs args)
    {
        if (sender is FrameworkElement { DataContext: ScanResultRow row })
        {
            row.IsPointerOver = false;
        }
    }

    private void SortHeader_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: string columnName }
            || !Enum.TryParse(columnName, out ResultSortColumn column))
        {
            return;
        }

        if (_sortColumn == column)
        {
            _sortAscending = !_sortAscending;
        }
        else
        {
            _sortColumn = column;
            _sortAscending = true;
        }

        UpdateSortGlyphs();
        RefreshVisibleResults();
    }

    private void RefreshVisibleResults()
    {
        if (ResultsList is null)
        {
            return;
        }

        var selectedResult = ResultsList.SelectedItem;
        var sortedResults = _allResults
            .Where(ShouldShow)
            .ToList();
        sortedResults.Sort(CompareResults);

        _visibleResults.Clear();
        for (var index = 0; index < sortedResults.Count; index++)
        {
            var result = sortedResults[index];
            result.IsAlternateRow = index % 2 == 1;
            _visibleResults.Add(result);
        }

        if (selectedResult is ScanResultRow selectedRow && _visibleResults.Contains(selectedRow))
        {
            ResultsList.SelectedItem = selectedRow;
        }

        UpdateEmptyState();
    }

    private void UpdateLatencyRange(ScanResultRow row)
    {
        if (!row.HasLatency || row.Result.RoundtripTimeMilliseconds is not long latency)
        {
            return;
        }

        var minimum = Math.Min(_minimumLatency, latency);
        var maximum = Math.Max(_maximumLatency, latency);
        if (minimum != _minimumLatency || maximum != _maximumLatency)
        {
            _minimumLatency = minimum;
            _maximumLatency = maximum;
            foreach (var result in _allResults)
            {
                result.UpdateLatencyRange(minimum, maximum);
            }
        }
        else
        {
            row.UpdateLatencyRange(minimum, maximum);
        }
    }

    private void OpenPortsFilter_Changed(object sender, RoutedEventArgs e) =>
        RefreshVisibleResults();

    private bool ShouldShow(ScanResultRow row) =>
        new DeviceResultFilter(
            true,
            OpenPortsFilter.IsChecked == true,
            ResultSearchBox.Text,
            SelectedFilterChoice(PersonFilter)?.Id,
            SelectedFilterChoice(RoomFilter)?.Id,
            SelectedFilterChoice(PersonFilter)?.Unassigned == true,
            SelectedFilterChoice(RoomFilter)?.Unassigned == true).Matches(row);

    private static FilterChoice? SelectedFilterChoice(ComboBox picker) =>
        (picker?.SelectedItem as ComboBoxItem)?.Tag as FilterChoice;

    private int CompareResults(ScanResultRow leftRow, ScanResultRow rightRow)
    {
        var left = leftRow.Result;
        var right = rightRow.Result;
        var comparison = _sortColumn switch
        {
            ResultSortColumn.OperatingSystem => string.Compare(leftRow.OperatingSystemText,
                rightRow.OperatingSystemText, StringComparison.OrdinalIgnoreCase),
            ResultSortColumn.DeviceType => string.Compare(leftRow.DeviceTypeText,
                rightRow.DeviceTypeText, StringComparison.OrdinalIgnoreCase),
            ResultSortColumn.Address => CompareAddresses(left.Address, right.Address),
            ResultSortColumn.Status => left.Status.CompareTo(right.Status),
            ResultSortColumn.Response => Nullable.Compare(
                left.RoundtripTimeMilliseconds,
                right.RoundtripTimeMilliseconds),
            ResultSortColumn.MacAddress => string.Compare(
                left.MacAddressText,
                right.MacAddressText,
                StringComparison.OrdinalIgnoreCase),
            _ => 0
        };

        if (comparison == 0)
        {
            comparison = CompareAddresses(left.Address, right.Address);
        }

        return _sortAscending ? comparison : -comparison;
    }

    private static int CompareAddresses(System.Net.IPAddress left, System.Net.IPAddress right)
    {
        var leftBytes = left.GetAddressBytes();
        var rightBytes = right.GetAddressBytes();
        for (var index = 0; index < leftBytes.Length; index++)
        {
            var comparison = leftBytes[index].CompareTo(rightBytes[index]);
            if (comparison != 0)
            {
                return comparison;
            }
        }

        return 0;
    }

    private void UpdateSortGlyphs()
    {
        if (AddressSortGlyph is null)
        {
            return;
        }

        AddressSortGlyph.Text = GetSortGlyph(ResultSortColumn.Address);
        StatusSortGlyph.Text = GetSortGlyph(ResultSortColumn.Status);
        ResponseSortGlyph.Text = GetSortGlyph(ResultSortColumn.Response);
        MacAddressSortGlyph.Text = GetSortGlyph(ResultSortColumn.MacAddress);
        OperatingSystemSortGlyph.Text = GetSortGlyph(ResultSortColumn.OperatingSystem);
        DeviceTypeSortGlyph.Text = GetSortGlyph(ResultSortColumn.DeviceType);
    }

    private string GetSortGlyph(ResultSortColumn column) =>
        _sortColumn == column ? (_sortAscending ? "\u2191" : "\u2193") : string.Empty;

    private void UpdateEmptyState()
    {
        if (EmptyResultsText is null)
        {
            return;
        }

        var total = _allResults.Count(row => row.IsOnline);
        ResultCountText.Text = _visibleResults.Count == total
            ? $"{total:N0} {(total == 1 ? "device" : "devices")}"
            : $"{_visibleResults.Count:N0} of {total:N0} devices";
        EmptyResultsText.Visibility = _visibleResults.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        UpdateOverview();

        if (_allResults.Count == 0)
        {
            EmptyResultsText.Text = _isScanning
                ? "Waiting for scan results..."
                : _displayedScan is null
                    ? "Select Scan LAN to discover devices on the detected subnet."
                    : "No devices answered this scan; active devices may block ICMP.";
        }
        else if (!string.IsNullOrWhiteSpace(ResultSearchBox.Text))
        {
            EmptyResultsText.Text = "No devices match the current filter.";
        }
        else if (OpenPortsFilter.IsChecked == true)
        {
            EmptyResultsText.Text = "No devices with open ports match the current filters.";
        }
        else
        {
            EmptyResultsText.Text = "No devices match the current filters.";
        }
    }
}
