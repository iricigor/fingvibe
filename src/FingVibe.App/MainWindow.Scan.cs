using System.Diagnostics;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using Microsoft.UI.Xaml;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private readonly LanScannerService _scanner = IsUiReview
        ? new LanScannerService(timeoutMilliseconds: 100, maximumConcurrency: 1)
        : new LanScannerService();
    private CancellationTokenSource? _scanCancellation;
    private bool _isScanning;

    private async void ScanButton_Click(object sender, RoutedEventArgs e)
    {
        if (NetworkPicker.SelectedItem is not LanNetwork network)
        {
            return;
        }

        if (!_networkActivityCoordinator.TryAcquire(NetworkActivityKind.LanScan, out var activityLease))
        {
            ScanStatusText.Text = _networkActivityCoordinator.ActiveKind == NetworkActivityKind.InternetSpeedTest
                ? "A Cloudflare speed test is active or stopping. Wait for it to finish before starting a LAN scan."
                : "Another network measurement is in progress. Wait for it to finish before retrying.";
            return;
        }

        using var scanActivity = activityLease;
        _allResults.Clear();
        _visibleResults.Clear();
        _minimumLatency = long.MaxValue;
        _maximumLatency = 0;
        _onlineDeviceCount = null;
        _displayedScan = new OverviewScanContext(network.Cidr, DateTimeOffset.UtcNow, ScanDisplayStatus.Scanning);
        SnapshotStatusText.Text = _displayedScan.Describe(network.Cidr);
        SnapshotStatusText.Visibility = Visibility.Visible;
        UpdateNetworkIdentity();
        _isScanning = true;
        UpdateEmptyState();
        ScanButton.IsEnabled = false;
        NetworkPicker.IsEnabled = false;
        CancelButton.IsEnabled = true;
        CancelButton.Visibility = Visibility.Visible;
        ScanProgressBar.Visibility = Visibility.Visible;
        _scanCancellation = new CancellationTokenSource();

        var total = SubnetCalculator.GetUsableHostCount(network.PrefixLength);
        ScanProgressBar.Maximum = total;
        ScanProgressBar.Value = 0;
        ScanStatusText.Text = $"Scanning 0 of {total:N0}";
        var stopwatch = Stopwatch.StartNew();

        var resultProgress = new Progress<ScanResult>(result =>
        {
            var row = CreateResultRow(result, network.PrefixLength);
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

            await SaveCompletedScanAsync(network, _allResults);
        }
        catch (OperationCanceledException)
        {
            _displayedScan = _displayedScan with { Status = ScanDisplayStatus.Cancelled };
            SnapshotStatusText.Text = $"{_displayedScan.Freshness(DateTimeOffset.UtcNow)}. {_displayedScan.Describe(network.Cidr)}";
            ScanStatusText.Text = $"Cancelled after {_allResults.Count:N0} results";
        }
        catch (InvalidOperationException exception)
        {
            _displayedScan = _displayedScan with { Status = ScanDisplayStatus.Failed, FailureMessage = exception.Message };
            SnapshotStatusText.Text = _displayedScan.Describe(network.Cidr);
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
            CancelButton.Visibility = Visibility.Collapsed;
            ScanProgressBar.Visibility = Visibility.Collapsed;
        }
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e)
    {
        _scanCancellation?.Cancel();
        CancelButton.IsEnabled = false;
        ScanStatusText.Text = "Cancelling...";
    }
}
