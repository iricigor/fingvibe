using System.Collections.ObjectModel;
using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

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
        foreach (var result in sortedResults)
        {
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
