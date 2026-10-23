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

    private void StatusFilter_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (StatusFilter.SelectedIndex < 0)
        {
            StatusFilter.SelectedItem = e.RemovedItems.Count > 0 ? e.RemovedItems[0] : StatusFilter.Items[0];
            return;
        }

        RefreshVisibleResults();
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
            StatusFilter.SelectedIndex == 1,
            OpenPortsFilter.IsChecked == true,
            ResultSearchBox.Text,
            SelectedFilterChoice(PersonFilter)?.Id,
            SelectedFilterChoice(RoomFilter)?.Id,
            SelectedFilterChoice(PersonFilter)?.Unassigned == true,
            SelectedFilterChoice(RoomFilter)?.Unassigned == true).Matches(row);

    private static FilterChoice? SelectedFilterChoice(ComboBox picker) =>
        (picker?.SelectedItem as ComboBoxItem)?.Tag as FilterChoice;

    private void InsertSorted(ScanResultRow result)
    {
        var low = 0;
        var high = _visibleResults.Count;
        while (low < high)
        {
            var middle = low + ((high - low) / 2);
            if (CompareResults(_visibleResults[middle], result) <= 0)
            {
                low = middle + 1;
            }
            else
            {
                high = middle;
            }
        }

        _visibleResults.Insert(low, result);
    }

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

        ResultCountText.Text = $"{_visibleResults.Count:N0} {(_visibleResults.Count == 1 ? "host" : "hosts")}";
        EmptyResultsText.Visibility = _visibleResults.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        UpdateOverview();

        if (_allResults.Count == 0)
        {
            EmptyResultsText.Text = _isScanning
                ? "Waiting for scan results..."
                : "Select Scan LAN to probe every address on the detected subnet.";
        }
        else if (!string.IsNullOrWhiteSpace(ResultSearchBox.Text))
        {
            EmptyResultsText.Text = "No hosts match the current filter.";
        }
        else if (OpenPortsFilter.IsChecked == true)
        {
            EmptyResultsText.Text = "No devices with open ports match the current filters.";
        }
        else if (StatusFilter.SelectedIndex == 1)
        {
            EmptyResultsText.Text = "No alive hosts found in the current results.";
        }
    }
}
