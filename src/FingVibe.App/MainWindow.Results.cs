using System.Collections.ObjectModel;
using FingVibe.Core.Formatting;
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
        MacAddress
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

    private bool ShouldShow(ScanResultRow row) =>
        (StatusFilter.SelectedIndex != 1 || row.IsOnline)
        && row.Result.MatchesFilter(ResultSearchBox.Text);

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
    }

    private string GetSortGlyph(ResultSortColumn column) =>
        _sortColumn == column ? (_sortAscending ? "\u2191" : "\u2193") : string.Empty;

    private void UpdateOverview()
    {
        if (OnlineDevicesText is null)
        {
            return;
        }

        var hasResults = _allResults.Count > 0;
        OnlineDevicesText.Text = hasResults ? _allResults.Count(row => row.IsOnline).ToString("N0") : "-";
        OfflineAddressesText.Text = hasResults ? _allResults.Count(row => row.IsOffline).ToString("N0") : "-";
        OpenPortDevicesText.Text = hasResults
            ? _allResults.Count(row => row.Result.OpenPortItems.Count > 0).ToString("N0")
            : "-";

        if (_isScanning)
        {
            LastScanText.Text = "Scan in progress";
            LastScanDetailText.Text = string.Empty;
        }
        else if (_lastCompletedScan is { } scan)
        {
            LastScanText.Text = $"{ScanAgeFormatter.FormatAge(DateTimeOffset.UtcNow - scan.CompletedAt)} ago";
            LastScanDetailText.Text = $"{scan.Subnet} · completed {scan.CompletedAt.ToLocalTime():g}";
        }
        else
        {
            LastScanText.Text = "Not scanned yet";
            LastScanDetailText.Text = string.Empty;
        }
    }

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
        else if (StatusFilter.SelectedIndex == 1)
        {
            EmptyResultsText.Text = "No alive hosts found in the current results.";
        }
    }
}
