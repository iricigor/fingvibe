using System.Net.NetworkInformation;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using FingVibe.Core.Storage;
using Microsoft.UI.Xaml;

namespace FingVibe.App;

public sealed partial class MainWindow : IScanExecutionSteps
{
    private readonly LanScannerService _scanner = IsUiReview
        ? new LanScannerService(timeoutMilliseconds: 100, maximumConcurrency: 1)
        : new LanScannerService();
    private readonly ScanExecution _scanExecution;
    private readonly PeriodicScanScheduler _periodicScans;
    private CancellationTokenSource? _scanCancellation;
    private bool _isScanning;
    private bool _restoreScanActionFocus;
    private ScanTrigger _scanTrigger;
    private bool _scanCancelledByUser;
    private string? _scanMessage;
    private string? _discoveryMessage;
    private string _retainedResultsMessage = string.Empty;
    private DeviceInventoryData? _scanDiscoveryBaseline;
    private bool _initialResultsPublished;

    private string ScanProgressPrefix => _scanTrigger == ScanTrigger.Scheduled ? "Scheduled scan · " : string.Empty;

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
        if (PeriodicScanHeaderSummary() is { } schedule)
        {
            context += $" · {schedule}";
        }
        var targetWarning = _displayedScan is { } displayed && displayed.Subnet != network?.Cidr
            ? $"These results are not for the selected scan target ({network?.Cidr ?? "none"})."
            : null;
        ScanFreshnessText.Text = context;
        ScanActions.Visibility = _isScanning || DevicesPage.Visibility == Visibility.Visible
            ? Visibility.Visible : Visibility.Collapsed;
        ScanButton.Visibility = _isScanning ? Visibility.Collapsed : Visibility.Visible;
        ScanButton.IsEnabled = !_isScanning && network is not null;
        var status = string.Join(" · ", new[] { _scanMessage, _snapshotError, _inventoryError, _discoveryMessage, targetWarning }
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

        var outcome = await _scanExecution.RunAsync(new ScanRequest(ScanTrigger.Manual, network));
        if (outcome.Status == ScanRunStatus.Busy)
        {
            _scanMessage = outcome.BlockingActivity == NetworkActivityKind.InternetSpeedTest
                ? "A Cloudflare speed test is active or stopping. Wait for it to finish before starting a LAN scan."
                : "Another network measurement is in progress. Wait for it to finish before retrying.";
            UpdateScanStatus();
        }
    }

    // Scheduled requests share the manual scan path and always target the currently selected LAN. Outside UI
    // review they first confirm that the adapter still reports that subnet, so a disconnected LAN is retried
    // with backoff instead of being scanned and reported as empty.
    private Task<ScanRunOutcome> RunScheduledScanAsync(CancellationToken cancellationToken)
    {
        if (NetworkPicker.SelectedItem is not LanNetwork network)
        {
            return Task.FromResult(new ScanRunOutcome(ScanRunStatus.Unavailable) { Message = "No LAN is selected." });
        }

        if (!IsUiReview)
        {
            IReadOnlyList<LanNetwork> available;
            try
            {
                available = _networkDiscovery.GetAvailableNetworks();
            }
            catch (NetworkInformationException exception)
            {
                return Task.FromResult(new ScanRunOutcome(ScanRunStatus.Unavailable)
                {
                    Message = $"Network adapters could not be read: {exception.Message}"
                });
            }

            if (!PeriodicScanTarget.IsAvailable(available, network))
            {
                return Task.FromResult(new ScanRunOutcome(ScanRunStatus.Unavailable)
                {
                    Message = $"{network.InterfaceName} ({network.Cidr}) is not connected."
                });
            }
        }

        return _scanExecution.RunAsync(new ScanRequest(ScanTrigger.Scheduled, network), cancellationToken);
    }

    void IScanExecutionSteps.BeginScan(ScanRequest request, CancellationTokenSource cancellation)
    {
        var focusScanAction = ScanButton.FocusState != FocusState.Unfocused;
        _isScanning = true;
        _scanTrigger = request.Trigger;
        _scanCancelledByUser = false;
        _initialResultsPublished = false;
        _scanDiscoveryBaseline = _persistedInventory;
        ToolsPage.InvalidateImportAnalysis("A scan started. Wait for it to finish and analyze again.");
        DevicesPage.SetInteractionsEnabled(false);
        UpdateEmptyState();
        ScanButton.IsEnabled = false;
        NetworkPicker.IsEnabled = false;
        CancelButton.IsEnabled = true;
        CancelButton.Visibility = Visibility.Visible;
        ScanProgressArea.Visibility = Visibility.Visible;
        _scanCancellation = cancellation;

        var total = SubnetCalculator.GetUsableHostCount(request.Network.PrefixLength);
        ScanProgressBar.Maximum = total;
        ScanProgressBar.Value = 0;
        StartScanPulse();
        _retainedResultsMessage = _displayedScan is not null ? " · Displaying retained results" : string.Empty;
        _scanMessage = $"{ScanProgressPrefix}{ScanProgressPresentation.Message(new LanScanProgress(LanScanPhase.FirstPass, 0, total))}{_retainedResultsMessage}";
        UpdateScanStatus();
        if (focusScanAction) CancelButton.Focus(FocusState.Programmatic);
        _discoveryMessage = null;
    }

    string? IScanExecutionSteps.CaptureNetworkIdentity(LanNetwork network) => GetScanNetworkIdentity(network);

    Task<IReadOnlyList<ScanResult>> IScanExecutionSteps.ScanAsync(ScanRequest request, CancellationToken cancellationToken) =>
        ScanWithCheckpointsAsync(request, null, cancellationToken);

    Task<IReadOnlyList<ScanResult>> IScanExecutionSteps.ScanAsync(ScanRequest request,
        Func<IReadOnlyList<ScanResult>, ScanCheckpointState, Task> checkpoint, CancellationToken cancellationToken) =>
        ScanWithCheckpointsAsync(request, checkpoint, cancellationToken);

    private async Task<IReadOnlyList<ScanResult>> ScanWithCheckpointsAsync(ScanRequest request,
        Func<IReadOnlyList<ScanResult>, ScanCheckpointState, Task>? checkpoint, CancellationToken cancellationToken)
    {
        var network = request.Network;
        var total = SubnetCalculator.GetUsableHostCount(network.PrefixLength);
        var retainedResults = _retainedResultsMessage;
        var resultProgress = new ScanResultBuffer();
        var cancellation = _scanCancellation;
        var scanProgress = new Progress<LanScanProgress>(progress =>
        {
            if (!_isScanning || _scanCancellation != cancellation || cancellationToken.IsCancellationRequested
                || _initialResultsPublished && _currentScanSnapshot?.State != ScanCheckpointState.Pending)
            {
                return;
            }
            PresentScanProgress(progress, retainedResults);
        });

        // The disposable UI test holds only its refresh until it has observed retained results.
        if (IsUiReview && Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW_SCAN_HOLD") is { Length: > 0 } holdPath)
        {
            var fixturePath = holdPath + ".progress";
            if (File.Exists(holdPath) && File.Exists(fixturePath))
            {
                var fixture = System.Text.Json.JsonSerializer.Deserialize<ScanProgress>(File.ReadAllText(fixturePath));
                if (fixture.Total <= 0 || fixture.Completed < 0 || fixture.Completed > fixture.Total)
                    throw new InvalidOperationException("The UI-review progress fixture is invalid.");
                PresentScanProgress(new LanScanProgress(LanScanPhase.FirstPass, fixture.Completed, fixture.Total), retainedResults);
            }
            var deadline = DateTimeOffset.UtcNow.AddSeconds(30);
            while (File.Exists(holdPath))
            {
                if (DateTimeOffset.UtcNow >= deadline)
                    throw new InvalidOperationException("The UI-review scan hold was not released within 30 seconds.");
                await Task.Delay(50, cancellationToken);
            }
            PresentScanProgress(new LanScanProgress(LanScanPhase.FirstPass, 0, total), retainedResults);
        }
        if (IsUiReview && Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW_SCAN_RESULTS") is { Length: > 0 } completedFixturePath)
        {
            var fixtureStore = new ScanSnapshotStore(completedFixturePath);
            var fixture = await fixtureStore.LoadAsync(cancellationToken)
                ?? throw new InvalidOperationException("The UI-review completed-scan fixture is missing.");
            if (checkpoint is not null
                && Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW_CHECKPOINT_HOLD") is { Length: > 0 } checkpointHold)
            {
                await checkpoint(fixture.Results, ScanCheckpointState.Pending);
                var deadline = DateTimeOffset.UtcNow.AddSeconds(30);
                while (File.Exists(checkpointHold))
                {
                    if (DateTimeOffset.UtcNow >= deadline)
                        throw new InvalidOperationException("The UI-review checkpoint hold was not released within 30 seconds.");
                    await Task.Delay(50, cancellationToken);
                }
                fixture = await fixtureStore.LoadAsync(cancellationToken)
                    ?? throw new InvalidOperationException("The UI-review final checkpoint fixture is missing.");
                await checkpoint(fixture.Results, ScanCheckpointState.Complete);
            }
            return fixture.Results;
        }

        await _scanner.ScanAsync(network, resultProgress, scanProgress, cancellationToken, checkpoint);
        return resultProgress.Results.Select(result => IsUiReview && System.Net.IPAddress.IsLoopback(result.Address)
            ? result with { MacAddress = System.Net.NetworkInformation.PhysicalAddress.Parse("020000000001") } : result).ToArray();
    }

    Task<ScanSaveResult> IScanExecutionSteps.SaveCheckpointAsync(ScanRequest request, ScanSnapshot snapshot) =>
        SaveScanCheckpointAsync(snapshot);

    async Task<ScanSaveResult> IScanExecutionSteps.SaveAsync(
        ScanRequest request, IReadOnlyList<ScanResult> results, string? networkId, bool networkChanged, TimeSpan duration)
    {
        if (networkChanged)
            _inventoryError = "The Windows network profile changed during this scan. Observations are unscoped and no devices are marked Offline.";
        var saved = await SaveCompletedScanAsync(request.Network, results, networkId, duration);
        _scanMessage = null;
        if (networkId is null)
            _discoveryMessage = "New-device alerts and baseline establishment are disabled for this scan because network identity is unavailable.";
        return saved;
    }

    void IScanExecutionSteps.EndScan(ScanRequest request, ScanRunOutcome outcome)
    {
        if (_initialResultsPublished && _currentScanSnapshot is { State: ScanCheckpointState.Pending } pending)
        {
            // A failed incomplete-state write still leaves a durable Pending checkpoint, never a running scan.
            _currentScanSnapshot = pending with { State = ScanCheckpointState.Incomplete };
            _liveCompletedAt = null;
            _inventory = _inventory with
            {
                Devices = _inventory.Devices.ToDictionary(pair => pair.Key, pair => pair.Value with
                {
                    CurrentCompletedAt = null, CurrentNetworkId = null, CurrentSubnet = null
                }),
                VirtualDevices = _inventory.VirtualDevices.Select(slot => slot with { CurrentCompletedAt = null }).ToArray()
            };
            _displayedScan = new OverviewScanContext(pending.Subnet, pending.CompletedAt, ScanDisplayStatus.Incomplete);
            RefreshInventoryRows();
        }
        var scheduled = request.Trigger == ScanTrigger.Scheduled;
        if (outcome.Status == ScanRunStatus.Cancelled)
            _scanMessage = !scheduled
                ? $"Scan of {request.Network.Cidr} cancelled{_retainedResultsMessage}"
                : _scanCancelledByUser
                    ? $"Scheduled scan of {request.Network.Cidr} cancelled{_retainedResultsMessage}"
                    : $"Scheduled scan of {request.Network.Cidr} stopped{_retainedResultsMessage}";
        else if (outcome.Status == ScanRunStatus.SaveFailed)
            _scanMessage = $"Scan persistence failed: {outcome.Message}";
        else if (outcome.Status == ScanRunStatus.Failed)
            _scanMessage = scheduled
                ? $"Unable to complete scheduled scan of {request.Network.Cidr}: {outcome.Message}{_retainedResultsMessage}"
                : $"Unable to scan {request.Network.Cidr}: {outcome.Message}{_retainedResultsMessage}";

        var restoreFocus = _restoreScanActionFocus || CancelButton.FocusState != FocusState.Unfocused;
        _restoreScanActionFocus = false;
        _isScanning = false;
        _scanDiscoveryBaseline = null;
        DevicesPage.SetInteractionsEnabled(true);
        UpdateEmptyState();
        UpdatePeopleRoomsPages();
        _scanCancellation = null;
        NetworkPicker.IsEnabled = true;
        CancelButton.IsEnabled = false;
        CancelButton.Visibility = Visibility.Collapsed;
        ScanProgressArea.Visibility = Visibility.Collapsed;
        StopScanPulse();
        UpdateScanStatus();
        if (restoreFocus && ScanButton.Visibility == Visibility.Visible
            && ScanActions.Visibility == Visibility.Visible)
            ScanButton.Focus(FocusState.Programmatic);
        if (outcome.Discoveries.Count > 0) PresentDiscoveries(outcome.Discoveries);
    }

    private void PresentScanProgress(LanScanProgress progress, string retainedResults)
    {
        ScanProgressBar.Maximum = progress.Total;
        ScanProgressBar.Value = progress.Completed;
        UpdateScanPulseWidth();
        _scanMessage = _initialResultsPublished
            ? $"{ScanProgressPrefix}Initial results · background confirmation pending · {ScanProgressPresentation.Message(progress)}"
            : $"{ScanProgressPrefix}{ScanProgressPresentation.Message(progress)}{retainedResults}";
        UpdateScanStatus();
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e)
    {
        _restoreScanActionFocus = CancelButton.FocusState != FocusState.Unfocused;
        _scanCancelledByUser = true;
        _scanCancellation?.Cancel();
        StopScanPulse();
        CancelButton.IsEnabled = false;
        _scanMessage = "Cancelling..." + (_displayedScan is not null ? " · Displaying retained results" : string.Empty);
        UpdateScanStatus();
    }
}
