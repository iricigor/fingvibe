using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Net;
using System.Text.Json;
using FingVibe.Core.Formatting;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using FingVibe.Core.Storage;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App;

public sealed partial class MainWindow : Window
{
    private enum ResultSortColumn
    {
        Address,
        Status,
        Response,
        MacAddress
    }

    private static readonly bool IsUiReview =
        Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW") == "1";

    private readonly NetworkDiscoveryService _networkDiscovery = new();
    private readonly PublicNetworkIdentityService _publicNetworkIdentity = new();
    private readonly ScanSnapshotStore _snapshotStore = new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "FingVibe",
        "latest-scan.json"));
    private readonly LanScannerService _scanner = IsUiReview
        ? new LanScannerService(timeoutMilliseconds: 100, maximumConcurrency: 1)
        : new LanScannerService();
    private readonly List<ScanResultRow> _allResults = [];
    private readonly ObservableCollection<ScanResultRow> _visibleResults = [];
    private long _minimumLatency = long.MaxValue;
    private long _maximumLatency;
    private CancellationTokenSource? _scanCancellation;
    private ResultSortColumn _sortColumn = ResultSortColumn.Address;
    private PublicNetworkIdentity? _publicIdentity;
    private int? _onlineDeviceCount;
    private bool _sortAscending = true;
    private bool _isScanning;
    private bool _hasRestoredSnapshot;

    public MainWindow()
    {
        InitializeComponent();
        if (IsUiReview)
        {
            RootGrid.RequestedTheme = ElementTheme.Dark;
        }

        ResultsList.ItemsSource = _visibleResults;
        StatusFilter.SelectedIndex = 0;
        UpdateSortGlyphs();
    }

    private async void RootGrid_Loaded(object sender, RoutedEventArgs e)
    {
        await RestoreSavedScanAsync();

        var networks = IsUiReview
            ? new List<LanNetwork>
            {
                new(
                    "UI review loopback",
                    IPAddress.Loopback,
                    IPAddress.Parse("127.0.0.0"),
                    24,
                    false)
            }
            : _networkDiscovery.GetAvailableNetworks();
        NetworkPicker.ItemsSource = networks;
        NetworkPicker.DisplayMemberPath = nameof(LanNetwork.DisplayLabel);

        if (networks.Count == 0)
        {
            NetworkIdentityText.Text = "No active IPv4 network";
            PublicAddressText.Text = "Unavailable";
            IspNameText.Text = "Unavailable";
            MachineAddressText.Text = "No active IPv4 interface";
            LanAddressText.Text = "Unavailable";
            ScanStatusText.Text = "Connect to a LAN to scan";
            ScanButton.IsEnabled = false;
            return;
        }

        NetworkPicker.SelectedIndex = 0;

        if (IsUiReview)
        {
            _publicIdentity = new PublicNetworkIdentity(
                IPAddress.Parse("203.0.113.10"),
                "UI review ISP");
            PublicAddressText.Text = _publicIdentity.PublicAddress.ToString();
            IspNameText.Text = _publicIdentity.IspName;
            UpdateNetworkIdentity();
            return;
        }

        await LoadPublicNetworkIdentityAsync();
    }

    private void NetworkPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (NetworkPicker.SelectedItem is not LanNetwork network)
        {
            return;
        }

        MachineAddressText.Text = network.LocalAddress.ToString();
        LanAddressText.Text = network.Cidr;
        _onlineDeviceCount = null;
        UpdateNetworkIdentity();
        ScanStatusText.Text = $"{SubnetCalculator.GetUsableHostCount(network.PrefixLength):N0} addresses ready";
    }

    private async Task LoadPublicNetworkIdentityAsync()
    {
        try
        {
            _publicIdentity = await _publicNetworkIdentity.GetAsync();
            PublicAddressText.Text = _publicIdentity.PublicAddress.ToString();
            IspNameText.Text = _publicIdentity.IspName;
        }
        catch (HttpRequestException)
        {
            ShowPublicNetworkIdentityUnavailable();
        }
        catch (TaskCanceledException)
        {
            ShowPublicNetworkIdentityUnavailable();
        }
        catch (JsonException)
        {
            ShowPublicNetworkIdentityUnavailable();
        }
        catch (InvalidOperationException)
        {
            ShowPublicNetworkIdentityUnavailable();
        }

        UpdateNetworkIdentity();
    }

    private void ShowPublicNetworkIdentityUnavailable()
    {
        _publicIdentity = null;
        PublicAddressText.Text = "Unavailable";
        IspNameText.Text = "Unavailable";
    }

    private void UpdateNetworkIdentity()
    {
        if (NetworkPicker.SelectedItem is not LanNetwork network)
        {
            return;
        }

        NetworkIdentityText.Text = NetworkIdentityFormatter.FormatSummary(
            network,
            _publicIdentity,
            _onlineDeviceCount);
    }

    private async void ScanButton_Click(object sender, RoutedEventArgs e)
    {
        if (NetworkPicker.SelectedItem is not LanNetwork network)
        {
            return;
        }

        _allResults.Clear();
        _visibleResults.Clear();
        _minimumLatency = long.MaxValue;
        _maximumLatency = 0;
        _onlineDeviceCount = null;
        SnapshotStatusText.Text = $"Current scan results for {network.Cidr}";
        SnapshotStatusText.Visibility = Visibility.Visible;
        UpdateNetworkIdentity();
        _isScanning = true;
        UpdateEmptyState();
        ScanButton.IsEnabled = false;
        NetworkPicker.IsEnabled = false;
        CancelButton.IsEnabled = true;
        _scanCancellation = new CancellationTokenSource();

        var total = SubnetCalculator.GetUsableHostCount(network.PrefixLength);
        ScanProgressBar.Maximum = total;
        ScanProgressBar.Value = 0;
        ScanStatusText.Text = $"Scanning 0 of {total:N0}";
        var stopwatch = Stopwatch.StartNew();

        var resultProgress = new Progress<ScanResult>(result =>
        {
            var row = new ScanResultRow(result, network.PrefixLength);
            _allResults.Add(row);
            UpdateLatencyRange(row);
            if (ShouldShow(row))
            {
                InsertSorted(row);
            }

            UpdateEmptyState();
        });
        var scanProgress = new Progress<ScanProgress>(progress =>
        {
            ScanProgressBar.Value = progress.Completed;
            ScanStatusText.Text = $"Scanning {progress.Completed:N0} of {progress.Total:N0}";
        });

        try
        {
            var summary = await _scanner.ScanAsync(
                network,
                resultProgress,
                scanProgress,
                _scanCancellation.Token);

            stopwatch.Stop();
            _onlineDeviceCount = summary.Alive;
            UpdateNetworkIdentity();
            ScanStatusText.Text =
                $"Complete in {stopwatch.Elapsed.TotalSeconds:N1}s - {summary.Alive:N0} alive, {summary.Unreachable:N0} unreachable";

            var snapshot = new ScanSnapshot(
                network.Cidr,
                DateTimeOffset.UtcNow,
                _allResults.Select(row => row.Result).ToArray());
            try
            {
                await _snapshotStore.SaveAsync(snapshot);
                ShowSavedSnapshotStatus(snapshot);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException)
            {
                ShowSnapshotError("The completed scan could not be saved.");
            }
        }
        catch (OperationCanceledException)
        {
            ScanStatusText.Text = $"Cancelled after {_allResults.Count:N0} results";
        }
        catch (InvalidOperationException exception)
        {
            EmptyResultsText.Text = exception.Message;
            EmptyResultsText.Visibility = Visibility.Visible;
            ScanStatusText.Text = "Unable to scan this subnet";
        }
        finally
        {
            _isScanning = false;
            UpdateEmptyState();
            _scanCancellation.Dispose();
            _scanCancellation = null;
            ScanButton.IsEnabled = true;
            NetworkPicker.IsEnabled = true;
            CancelButton.IsEnabled = false;
        }
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e)
    {
        _scanCancellation?.Cancel();
        CancelButton.IsEnabled = false;
        ScanStatusText.Text = "Cancelling...";
    }

    private async Task RestoreSavedScanAsync()
    {
        if (_hasRestoredSnapshot)
        {
            return;
        }

        _hasRestoredSnapshot = true;
        try
        {
            var snapshot = await _snapshotStore.LoadAsync();
            if (snapshot is null)
            {
                return;
            }

            var prefixLength = int.Parse(snapshot.Subnet[(snapshot.Subnet.LastIndexOf('/') + 1)..]);
            _minimumLatency = long.MaxValue;
            _maximumLatency = 0;
            foreach (var result in snapshot.Results)
            {
                var row = new ScanResultRow(result, prefixLength);
                _allResults.Add(row);
                UpdateLatencyRange(row);
            }

            RefreshVisibleResults();
            ShowSavedSnapshotStatus(snapshot);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            ShowSnapshotError("The saved scan could not be loaded. Scan LAN to create a new snapshot.");
        }
    }

    private void ShowSavedSnapshotStatus(ScanSnapshot snapshot)
    {
        var age = ScanAgeFormatter.FormatAge(DateTimeOffset.UtcNow - snapshot.CompletedAt);
        var completedAt = snapshot.CompletedAt.ToLocalTime().ToString("g");
        SnapshotStatusText.Text = $"Saved results for {snapshot.Subnet} · {age} old · completed {completedAt}";
        SnapshotStatusText.Visibility = Visibility.Visible;
    }

    private void ShowSnapshotError(string message)
    {
        SnapshotStatusText.Text = message;
        SnapshotStatusText.Visibility = Visibility.Visible;
    }

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

    private void UpdateEmptyState()
    {
        if (EmptyResultsText is null)
        {
            return;
        }

        ResultCountText.Text = $"{_visibleResults.Count:N0} {(_visibleResults.Count == 1 ? "host" : "hosts")}";
        EmptyResultsText.Visibility = _visibleResults.Count == 0 ? Visibility.Visible : Visibility.Collapsed;

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
