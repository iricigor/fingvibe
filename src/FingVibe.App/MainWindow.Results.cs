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

    private void DeviceFiltersChanged(object? sender, EventArgs e)
    {
        RefreshVisibleResults();
    }

    private void DeviceSortRequested(object? sender, string columnName)
    {
        if (!Enum.TryParse(columnName, out ResultSortColumn column))
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
        if (DevicesPage is null)
        {
            return;
        }

        var selectedResult = DevicesPage.SelectedResult;
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
            DevicesPage.SelectedResult = selectedRow;
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
        new DeviceResultFilter(
            true,
            DevicesPage.OpenPortsOnly,
            DevicesPage.SearchText,
            DevicesPage.PersonChoice?.Id,
            DevicesPage.RoomChoice?.Id,
            DevicesPage.PersonChoice?.Unassigned == true,
            DevicesPage.RoomChoice?.Unassigned == true).Matches(row);

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
        if (DevicesPage is null)
        {
            return;
        }

        DevicesPage.ShowSort(
            GetSortGlyph(ResultSortColumn.Address),
            GetSortGlyph(ResultSortColumn.Status),
            GetSortGlyph(ResultSortColumn.Response),
            GetSortGlyph(ResultSortColumn.MacAddress),
            GetSortGlyph(ResultSortColumn.OperatingSystem),
            GetSortGlyph(ResultSortColumn.DeviceType));
    }

    private string GetSortGlyph(ResultSortColumn column) =>
        _sortColumn == column ? (_sortAscending ? "\u2191" : "\u2193") : string.Empty;

    private void UpdateEmptyState()
    {
        if (DevicesPage is null)
        {
            return;
        }

        var total = _allResults.Count(row => row.IsOnline);
        var count = _visibleResults.Count == total
            ? $"{total:N0} {(total == 1 ? "device" : "devices")}"
            : $"{_visibleResults.Count:N0} of {total:N0} devices";
        UpdateOverview();

        string emptyMessage;
        if (_allResults.Count == 0)
        {
            emptyMessage = _isScanning
                ? "Waiting for scan results..."
                : _displayedScan is null
                    ? "Select Scan LAN to discover devices on the detected subnet."
                    : "No devices answered this scan; active devices may block ICMP.";
        }
        else if (!string.IsNullOrWhiteSpace(DevicesPage.SearchText))
        {
            emptyMessage = "No devices match the current filter.";
        }
        else if (DevicesPage.OpenPortsOnly)
        {
            emptyMessage = "No devices with open ports match the current filters.";
        }
        else
        {
            emptyMessage = "No devices match the current filters.";
        }
        DevicesPage.ShowSummary(count, emptyMessage, _visibleResults.Count == 0);
    }
}
