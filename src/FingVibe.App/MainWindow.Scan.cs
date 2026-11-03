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
            : network is null ? "Connect to a LAN to scan" : "Ready for your first scan";
        var targetWarning = _displayedScan is { } displayed && displayed.Subnet != network?.Cidr
            ? $"These results are not for the selected scan target ({network?.Cidr ?? "none"})."
            : null;
        ScanFreshnessText.Text = context;
        ScanActions.Visibility = _isScanning ? Visibility.Visible : Visibility.Collapsed;
        var status = string.Join(" · ", new[] { _scanMessage, _snapshotError, _inventoryError, targetWarning }
            .Where(value => !string.IsNullOrWhiteSpace(value)));
        ScanStatusText.Text = status;
        ScanStatusText.Visibility = string.IsNullOrWhiteSpace(status) ? Visibility.Collapsed : Visibility.Visible;
        ScanMessages.Visibility = _isScanning || !string.IsNullOrWhiteSpace(status)
            ? Visibility.Visible : Visibility.Collapsed;
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
        DevicesPage.SetScanEnabled(false);
        NetworkPicker.IsEnabled = false;
        CancelButton.IsEnabled = true;
        CancelButton.Visibility = Visibility.Visible;
        ScanProgressArea.Visibility = Visibility.Visible;
        _scanCancellation = new CancellationTokenSource();

        var total = SubnetCalculator.GetUsableHostCount(network.PrefixLength);
        ScanProgressBar.Maximum = total;
        ScanProgressBar.Value = 0;
        StartScanPulse();
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
            UpdateScanPulseWidth();
            _scanMessage = $"Scanning {progress.Completed:N0}/{progress.Total:N0} addresses{retainedResults}";
            UpdateScanStatus();
        });

        try
        {
            // The disposable UI test holds only its refresh until it has observed retained results.
            if (IsUiReview && Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW_SCAN_HOLD") is { Length: > 0 } holdPath)
            {
                var deadline = DateTimeOffset.UtcNow.AddSeconds(30);
                while (File.Exists(holdPath))
                {
                    if (DateTimeOffset.UtcNow >= deadline)
                        throw new InvalidOperationException("The UI-review scan hold was not released within 30 seconds.");
                    await Task.Delay(50, cancellation.Token);
                }
            }
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
            await SaveCompletedScanAsync(network, results, networkId, stopwatch.Elapsed);
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
            DevicesPage.SetScanEnabled(true);
            NetworkPicker.IsEnabled = true;
            CancelButton.IsEnabled = false;
            CancelButton.Visibility = Visibility.Collapsed;
            ScanProgressArea.Visibility = Visibility.Collapsed;
            StopScanPulse();
            UpdateScanStatus();
        }
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e)
    {
        _scanCancellation?.Cancel();
        StopScanPulse();
        CancelButton.IsEnabled = false;
        _scanMessage = "Cancelling..." + (_displayedScan is not null ? " · Displaying retained results" : string.Empty);
        UpdateScanStatus();
    }
}
