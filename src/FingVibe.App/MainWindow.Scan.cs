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
    private string? _scanMessage;

    private void UpdateScanStatus()
    {
        if (DevicesPage is null)
        {
            return;
        }

        var network = NetworkPicker.SelectedItem as LanNetwork;
        var context = _displayedScan is { } scan
            ? $"{scan.Freshness(DateTimeOffset.UtcNow)} · {scan.Subnet}"
                + (scan.Subnet != network?.Cidr ? $" · These results are not for the selected scan target ({network?.Cidr ?? "none"})." : string.Empty)
            : network is null ? "Connect to a LAN to scan" : "Ready for your first scan";
        var status = string.Join(" · ", new[] { _scanMessage, _snapshotError, _inventoryError, context }
            .Where(value => !string.IsNullOrWhiteSpace(value)));
        ScanStatusText.Text = status;
        DevicesPage.ShowScanStatus(status);
    }

    private async void ScanButton_Click(object sender, RoutedEventArgs e)
    {
        if (NetworkPicker.SelectedItem is not LanNetwork network)
        {
            return;
        }

        if (!_networkActivityCoordinator.TryAcquire(NetworkActivityKind.LanScan, out var activityLease))
        {
            _scanMessage = _networkActivityCoordinator.ActiveKind == NetworkActivityKind.InternetSpeedTest
                ? "A Cloudflare speed test is active or stopping. Wait for it to finish before starting a LAN scan."
                : "Another network measurement is in progress. Wait for it to finish before retrying.";
            UpdateScanStatus();
            return;
        }

        using var scanActivity = activityLease;
        _isScanning = true;
        ToolsPage.InvalidateImportAnalysis("A scan started. Wait for it to finish and analyze again.");
        DevicesPage.SetInteractionsEnabled(false);
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
        var retainedResults = _displayedScan is not null ? " · Displaying retained results" : string.Empty;
        _scanMessage = $"Scanning 0/{total:N0} addresses{retainedResults}";
        UpdateScanStatus();
        var stopwatch = Stopwatch.StartNew();

        var resultProgress = new ScanResultBuffer();
        var cancellation = _scanCancellation;
        var scanProgress = new Progress<ScanProgress>(progress =>
        {
            if (!_isScanning || _scanCancellation != cancellation || cancellation.IsCancellationRequested)
            {
                return;
            }
            ScanProgressBar.Value = progress.Completed;
            _scanMessage = $"Scanning {progress.Completed:N0}/{progress.Total:N0} addresses{retainedResults}";
            UpdateScanStatus();
        });

        try
        {
            var networkId = GetScanNetworkIdentity(network);
            var summary = await _scanner.ScanAsync(
                network,
                resultProgress,
                scanProgress,
                _scanCancellation.Token);
            var completedNetworkId = GetScanNetworkIdentity(network);
            if (completedNetworkId != networkId)
            {
                networkId = null;
                _inventoryError = "The Windows network profile changed during this scan. Observations are unscoped and no devices are marked Offline.";
            }

            stopwatch.Stop();
            _scanMessage =
                $"Complete in {stopwatch.Elapsed.TotalSeconds:N1}s - {summary.Alive:N0} responding {(summary.Alive == 1 ? "address" : "addresses")}";

            var results = resultProgress.Results.Select(result => IsUiReview && System.Net.IPAddress.IsLoopback(result.Address)
                ? result with { MacAddress = System.Net.NetworkInformation.PhysicalAddress.Parse("020000000001") } : result).ToArray();
            await SaveCompletedScanAsync(network, results, networkId);
        }
        catch (OperationCanceledException)
        {
            _scanMessage = $"Scan of {network.Cidr} cancelled{retainedResults}";
        }
        catch (InvalidOperationException exception)
        {
            _scanMessage = $"Unable to scan {network.Cidr}: {exception.Message}{retainedResults}";
        }
        finally
        {
            _isScanning = false;
            DevicesPage.SetInteractionsEnabled(true);
            UpdateEmptyState();
            UpdatePeopleRoomsPages();
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
        _scanMessage = "Cancelling..." + (_displayedScan is not null ? " · Displaying retained results" : string.Empty);
        UpdateScanStatus();
    }
}
