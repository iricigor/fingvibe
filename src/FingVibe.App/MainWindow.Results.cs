using System.Collections.ObjectModel;
using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App;

public sealed partial class MainWindow
{
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
        if (!Enum.TryParse(columnName, out ResultSortColumn column) || !Enum.IsDefined(column))
        {
            System.Diagnostics.Trace.TraceError($"Unknown Devices sort request: {columnName}");
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
        DevicesPage.SetVendorFilters(_allResults.Select(row => row.VendorText));
        var filter = DevicesPage.CreateFilter();
        foreach (var row in _allResults) row.SetSelectedNetwork(NetworkPicker.SelectedItem as LanNetwork);
        var sortedResults = _allResults
            .Where(filter.Matches)
            .ToList();
        sortedResults.Sort(CompareResults);

        if (!_isScanning || !_initialResultsPublished) _visibleResults.Clear();
        for (var index = 0; index < sortedResults.Count; index++)
        {
            var result = sortedResults[index];
            result.IsAlternateRow = index % 2 == 1;
            var existing = _visibleResults.IndexOf(result);
            if (existing < 0) _visibleResults.Insert(index, result);
            else if (existing != index) _visibleResults.Move(existing, index);
        }
        while (_visibleResults.Count > sortedResults.Count) _visibleResults.RemoveAt(_visibleResults.Count - 1);

        if (selectedResult is ScanResultRow selectedRow && _visibleResults.Contains(selectedRow))
        {
            DevicesPage.SelectedResult = selectedRow;
        }

        UpdateEmptyState();
    }

    private void UpdateLatencyRange(ScanResultRow row)
    {
        if (!row.HasLatency || row.Result?.RoundtripTimeMilliseconds is not long latency)
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

    private int CompareResults(ScanResultRow leftRow, ScanResultRow rightRow) =>
        DeviceResultSort.Compare(leftRow, rightRow, _sortColumn, _sortAscending);

    private void UpdateSortGlyphs()
    {
        if (DevicesPage is null)
        {
            return;
        }

        DevicesPage.ShowSort(_sortColumn, _sortAscending);
    }

    private void UpdateEmptyState()
    {
        if (DevicesPage is null)
        {
            return;
        }

        var total = _allResults.Count;
        var count = _visibleResults.Count == total
            ? $"Showing {total:N0} {(total == 1 ? "device" : "devices")}"
            : $"Showing {_visibleResults.Count:N0} of {total:N0} devices";
        DevicesPage.ShowInventorySummary(
            _allResults.Count(row => row.IsOnline), _allResults.Count(row => row.IsOffline),
            _allResults.Count(row => row.IsHistorical), _allResults.Count(row => row.IsFingOnly));
        DevicesPage.ShowLastScan(_currentScanSnapshot);
        UpdateOverview();

        string emptyMessage;
        if (_allResults.Count == 0)
        {
            emptyMessage = _isScanning && !_initialResultsPublished
                ? "Waiting for scan results..."
                : _displayedScan is null
                    ? "Select Scan LAN to discover devices on the detected subnet."
                    : "No devices answered this scan; active devices may not answer ICMP or ARP.";
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
