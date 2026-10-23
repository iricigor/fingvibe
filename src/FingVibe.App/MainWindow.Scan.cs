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
            _lastCompletedScan = snapshot;
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
}
