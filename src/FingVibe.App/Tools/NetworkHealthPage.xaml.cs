using System.Net;
using System.Runtime.InteropServices;
using System.Text.Json;
using FingVibe.Core.Formatting;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using FingVibe.Core.Storage;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Networking.Connectivity;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace FingVibe.App;

public sealed partial class NetworkHealthPage : UserControl
{
    private readonly NetworkDiscoveryService _discovery = new();
    private readonly NetworkDiagnosticService _service = new(new NetworkDiagnosticProbes());
    private readonly RouterWanSettingsStore _store = new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FingVibe", "router-wan.json"));
    private readonly AccessibilitySettings _accessibility = new();
    private readonly UISettings _uiSettings = new();
    private readonly Dictionary<DiagnosticCheckpoint, DiagnosticObservation> _observations = [];
    private readonly DiagnosticContextState _contextState = new();
    private readonly AsyncSurfaceSession _runSurface = new();
    private Func<LanNetwork, Guid?, IReadOnlyList<IPAddress>>? _peerCandidates;
    private CancellationTokenSource? _cancellation;
    private Task? _runTask;
    private LanNetwork? _network;
    private LanNetwork? _shellNetwork;
    private Guid? _networkId;
    private bool _updatingInput;
    private bool _settingsLoaded;
    private bool _refreshing;
    private bool _open;
    private bool _processingNetworkChange;
    private bool _networkChangePending;
    private NetworkDiagnosticReport? _report;
    private static bool IsUiReview => Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW") == "1";

    public NetworkHealthPage()
    {
        InitializeComponent();
        _runSurface.StateChanged += (_, _) => AutomationProperties.SetItemStatus(NetworkHealthScroll, _runSurface.Status);
        AutomationProperties.SetItemStatus(NetworkHealthScroll, _runSurface.Status);
        _diagramTimer.Tick += DiagramTimer_Tick;
        Loaded += (_, _) =>
        {
            _uiSettings.ColorValuesChanged += ColorsChanged;
            if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
                _uiSettings.AnimationsEnabledChanged += AnimationSettingsChanged;
            NetworkInformation.NetworkStatusChanged += NetworkChanged;
        };
        Unloaded += (_, _) =>
        {
            _uiSettings.ColorValuesChanged -= ColorsChanged;
            if (OperatingSystem.IsWindowsVersionAtLeast(10, 0, 19041))
                _uiSettings.AnimationsEnabledChanged -= AnimationSettingsChanged;
            NetworkInformation.NetworkStatusChanged -= NetworkChanged;
            _contextState.Invalidate();
            _runSurface.Cancel();
            StopDiagramAnimation();
            _cancellation?.Cancel();
        };
        ActualThemeChanged += (_, _) => Render();
    }

    public event EventHandler? BackRequested;
    public event EventHandler? RoomMapRequested;
    public event EventHandler? ServiceStatusRequested;
    internal NetworkActivityCoordinator? ActivityCoordinator { get; set; }
    public bool HasActiveTest => _runTask is { IsCompleted: false };

    public void SetNetworkContext(LanNetwork? network) => _shellNetwork = network;

    internal void ShowNetworkMonitor(NetworkMonitorView view)
    {
        NetworkMonitorDots.Apply(HealthStateDot, view.Kind);
        HealthStateText.Text = view.Title;
        HealthStateDetailText.Text = view.Detail;
        LastCheckText.Text = view.LastCheck;
        NetworkMonitorDots.RenderRows(RawObservationsPanel, RawObservationRows, view.Rows, "NetworkHealthRawResult");
    }

    internal void ShowIncidentHistory(IReadOnlyList<NetworkIncidentRow> rows,
        IReadOnlyDictionary<Guid, NetworkEvidenceView> evidence, string? storageMessage)
    {
        IncidentStorageText.Text = storageMessage ?? "";
        IncidentStorageText.Visibility = storageMessage is null ? Visibility.Collapsed : Visibility.Visible;
        IncidentEmptyText.Visibility = rows.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        IncidentLayout.Visibility = rows.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        _incidentEvidence = evidence;
        _rebuildingIncidents = true;
        try
        {
            IncidentList.Items.Clear();
            ListViewItem? selected = null;
            for (var index = 0; index < rows.Count; index++)
            {
                var row = rows[index];
                var item = new StackPanel { Spacing = 2 };
                item.Children.Add(Line($"{row.Status}: {row.Symptoms}", semibold: true));
                foreach (var (text, secondary) in new[]
                         { (row.Times, false), (row.Recovery, false), (row.Network, true), (row.Gaps, true), (row.Evidence, true) })
                {
                    if (!string.IsNullOrWhiteSpace(text)) item.Children.Add(Line(text, secondary: secondary));
                }
                var listItem = new ListViewItem
                {
                    Tag = row.Id,
                    Content = new Border { Style = (Style)Application.Current.Resources["NetworkIncidentItemStyle"], Child = item },
                    HorizontalContentAlignment = HorizontalAlignment.Stretch
                };
                // The item carries the whole incident for assistive technology; its visual lines are raw.
                AutomationProperties.SetAutomationId(listItem, $"NetworkIncidentStatus{index}");
                AutomationProperties.SetName(listItem, row.AccessibleName);
                IncidentList.Items.Add(listItem);
                if (row.Id == _selectedIncident) selected = listItem;
            }
            IncidentList.SelectedItem = selected;
        }
        finally
        {
            _rebuildingIncidents = false;
        }
        if (IncidentList.SelectedItem is null) _selectedIncident = null;
        ShowSelectedEvidence();

        static TextBlock Line(string text, bool semibold = false, bool secondary = false)
        {
            var line = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap };
            if (semibold) line.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
            if (secondary) line.Foreground = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
            AutomationProperties.SetAccessibilityView(line, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
            return line;
        }
    }

    private IReadOnlyDictionary<Guid, NetworkEvidenceView> _incidentEvidence = new Dictionary<Guid, NetworkEvidenceView>();
    private Guid? _selectedIncident;
    private bool _rebuildingIncidents;

    private void IncidentList_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_rebuildingIncidents) return;
        _selectedIncident = (IncidentList.SelectedItem as ListViewItem)?.Tag as Guid?;
        ShowSelectedEvidence();
    }

    /// <summary>Shows saved evidence only; selecting an incident never sends probes or changes current status.</summary>
    private void ShowSelectedEvidence()
    {
        var view = _selectedIncident is { } id ? _incidentEvidence.GetValueOrDefault(id) : null;
        IncidentEvidenceContext.Text = view?.Context ?? NetworkIncidentPresentation.SelectText;
        Set(IncidentEvidenceOutcome, view?.Outcome);
        Set(IncidentEvidenceSummary, view?.Summary);
        Set(IncidentEvidenceTrace, view?.Trace);
        Rows(IncidentEvidenceChecks, view?.Checks ?? [], "NetworkIncidentEvidenceCheck");
        Rows(IncidentEvidenceHops, view?.Hops ?? [], "NetworkIncidentEvidenceHop");

        static void Set(TextBlock text, string? value)
        {
            text.Text = value ?? "";
            text.Visibility = value is null ? Visibility.Collapsed : Visibility.Visible;
        }

        static void Rows(Panel host, IReadOnlyList<NetworkEvidenceRow> rows, string prefix)
        {
            host.Children.Clear();
            for (var index = 0; index < rows.Count; index++)
            {
                var text = new TextBlock { Text = $"{rows[index].Label}: {rows[index].Result}", TextWrapping = TextWrapping.Wrap };
                AutomationProperties.SetAutomationId(text, $"{prefix}{index}");
                host.Children.Add(text);
            }
        }
    }

    // Saved evidence sits alongside the list on wide windows and below it on narrow ones.
    private void IncidentLayout_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var wide = e.NewSize.Width >= 640;
        Grid.SetRow(IncidentEvidencePanel, wide ? 0 : 1);
        Grid.SetColumn(IncidentEvidencePanel, wide ? 1 : 0);
        Grid.SetColumnSpan(IncidentList, wide ? 1 : 2);
        Grid.SetColumnSpan(IncidentEvidencePanel, wide ? 1 : 2);
        IncidentEvidenceColumn.Width = wide ? new GridLength(1.2, GridUnitType.Star) : new GridLength(0);
        IncidentLayout.ColumnSpacing = wide ? 24 : 0;
    }

    internal void ConfigurePeerCandidates(Func<LanNetwork, Guid?, IReadOnlyList<IPAddress>> peers) =>
        _peerCandidates = peers;

    public async Task OpenAsync(bool focusServiceStatus = false)
    {
        _open = true;
        if (_runTask is { } run) await run;
        if (!_open) return;
        RefreshNetworks(_shellNetwork);
        FocusAfterOpen(focusServiceStatus ? OpenServiceStatusButton : RunButton);
    }

    private void FocusAfterOpen(Control target)
    {
        if (target.Focus(FocusState.Programmatic)) return;
        // The page was collapsed until this open, so focus can only land after its first layout passes.
        var attempts = 0;
        void Retry(object? sender, object args)
        {
            if (!_open || !IsLoaded || target.Focus(FocusState.Programmatic) || ++attempts >= 3)
                target.LayoutUpdated -= Retry;
        }
        target.LayoutUpdated += Retry;
    }

    private void RoomMapButton_Click(object sender, RoutedEventArgs e) =>
        RoomMapRequested?.Invoke(this, EventArgs.Empty);

    public async Task StopForNavigationAsync()
    {
        _open = false;
        _contextState.Invalidate();
        _runSurface.Cancel();
        StopDiagramAnimation();
        _cancellation?.Cancel();
        if (_runTask is { } run) await run;
    }

    public Task StopForWindowCloseAsync() => StopForNavigationAsync();

    private void ColorsChanged(UISettings sender, object args) => DispatcherQueue.TryEnqueue(Render);

    private void NetworkChanged(object sender) => DispatcherQueue.TryEnqueue(async () =>
    {
        if (!_open || !IsLoaded || IsUiReview) return;
        _networkChangePending = true;
        if (_processingNetworkChange) return;
        _processingNetworkChange = true;
        try
        {
            do
            {
                _networkChangePending = false;
                await CheckNetworkContextAsync();
            } while (_open && IsLoaded && _networkChangePending);
        }
        finally { _processingNetworkChange = false; }
    });

    private async Task CheckNetworkContextAsync()
    {
        var revision = _contextState.Revision;
        try
        {
            var current = ReadCurrentNetworkContext();
            if (DiagnosticContextState.Matches(_network, _networkId, current.Network, current.Profile)) return;
            StopDiagramAnimation();
            _runSurface.Cancel();
            _cancellation?.Cancel();
            if (_runTask is { IsCompleted: false } run)
            {
                await run;
                if (!_open || !IsLoaded || revision != _contextState.Revision) return;
                current = ReadCurrentNetworkContext();
                if (DiagnosticContextState.Matches(_network, _networkId, current.Network, current.Profile)) return;
            }
            if (!_open || !IsLoaded || revision != _contextState.Revision) return;
            RefreshNetworks(current.Network);
            ProgressText.Text = "The selected network context changed. Context refreshed; run diagnostics again.";
        }
        catch (Exception exception) when (exception is COMException or InvalidOperationException or InvalidCastException
            or System.Net.NetworkInformation.NetworkInformationException or ArgumentException)
        {
            if (!_open || !IsLoaded || revision != _contextState.Revision) return;
            StopDiagramAnimation();
            _runSurface.Cancel();
            _cancellation?.Cancel();
            _settingsLoaded = false;
            SettingsStatus.Text = $"Network change verification failed: {exception.Message} Existing results are retained but may be stale; refresh adapters before running again. WAN persistence is disabled until refreshed.";
        }
    }

    private (LanNetwork? Network, Guid? Profile) ReadCurrentNetworkContext()
    {
        var current = DiagnosticContextState.Select(_discovery.GetAvailableNetworks(), _network);
        return (current, current is null ? null : WindowsNetworkProfileIdentity.GetNetworkId(current));
    }

    private void RefreshNetworks(LanNetwork? preferred)
    {
        try
        {
            _refreshing = true;
            var networks = IsUiReview
                ? _shellNetwork is { } fixture ? new[] { fixture } : Array.Empty<LanNetwork>()
                : _discovery.GetAvailableNetworks();
            AdapterPicker.ItemsSource = networks;
            AdapterPicker.DisplayMemberPath = nameof(LanNetwork.DisplayLabel);
            AdapterPicker.SelectedItem = DiagnosticContextState.Select(networks, preferred);
            ApplyNetwork(AdapterPicker.SelectedItem as LanNetwork);
        }
        catch (Exception exception) when (exception is System.Net.NetworkInformation.NetworkInformationException or InvalidOperationException)
        {
            AdapterPicker.ItemsSource = null;
            ApplyNetwork(null);
            ProgressText.Text = $"Adapter discovery failed: {exception.Message}";
        }
        finally { _refreshing = false; }
    }

    private void ApplyNetwork(LanNetwork? network)
    {
        _network = network;
        _networkId = null;
        _settingsLoaded = false;
        _updatingInput = true;
        WanInput.Text = string.Empty;
        try
        {
            if (IsUiReview)
                SettingsStatus.Text = "UI-review mode: WAN settings are not loaded or saved, and network probes are disabled.";
            else if (network is null)
                SettingsStatus.Text = "No adapter selected. WAN persistence is unavailable.";
            else
            {
                _networkId = WindowsNetworkProfileIdentity.GetNetworkId(network);
                WanInput.Text = _store.Load(_networkId.Value);
                _settingsLoaded = true;
                SettingsStatus.Text = "Valid WAN edits are saved for this Windows network profile; clearing removes only this network's value.";
            }
        }
        catch (Exception exception) when (exception is COMException or InvalidOperationException or InvalidCastException
            or IOException or UnauthorizedAccessException or JsonException or ArgumentException)
        {
            SettingsStatus.Text = $"WAN settings unavailable: {exception.Message} Edits will not overwrite saved settings.";
        }
        finally
        {
            _contextState.RecordWanText(WanInput.Text);
            _updatingInput = false;
        }
        ContextText.Text = network is null ? "No active LAN adapter." : $"Selected: {network.DisplayLabel} - Gateway: {network.GatewayAddress?.ToString() ?? "unavailable"}";
        WanHelp.Text = $"Open your router administration page in a browser, usually http://{network?.GatewayAddress?.ToString() ?? "<gateway shown above>"}. Sign in there and find Internet, WAN, or Status. Copy the WAN/Internet IPv4 address, not the router LAN address. Never enter router credentials into FingVibe.";
        ResetResults();
    }

    private void AdapterPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        var selected = AdapterPicker.SelectedItem as LanNetwork;
        if (!_refreshing && !HasActiveTest && selected != _network) ApplyNetwork(selected);
    }

    private void RefreshButton_Click(object sender, RoutedEventArgs e) => RefreshNetworks(_network);

    private void WanInput_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (!_contextState.AcceptWanEdit(WanInput.Text, _updatingInput)) return;
        try
        {
            RouterWanAddress.Parse(WanInput.Text);
            if (_settingsLoaded && _networkId is { } id && !IsUiReview)
            {
                _store.Save(id, WanInput.Text);
                SettingsStatus.Text = string.IsNullOrWhiteSpace(WanInput.Text)
                    ? "Cleared this network's remembered WAN address."
                    : "WAN address saved for this Windows network profile.";
            }
            else
                SettingsStatus.Text = "WAN address is valid (or blank), but persistence is unavailable for this context. No saved value was changed.";
        }
        catch (Exception exception) when (exception is ArgumentException or IOException or UnauthorizedAccessException or JsonException)
        {
            SettingsStatus.Text = $"WAN input/settings error: {exception.Message} The previously saved valid value was not replaced.";
        }
        ResetResults();
    }

    private void ResetResults()
    {
        _contextState.Invalidate();
        _runSurface.Cancel();
        StopDiagramAnimation();
        _report = null;
        _observations.Clear();
        IPAddress? wan = null;
        try { wan = RouterWanAddress.Parse(WanInput.Text); }
        catch (ArgumentException) { /* The visible input error is set by the edit/run handler. */ }
        foreach (var observation in NetworkDiagnosticService.CreateCheckpoints(_network, wan))
            _observations.Add(observation.Checkpoint, observation);
        _observations[DiagnosticCheckpoint.LanPeer] = _observations[DiagnosticCheckpoint.LanPeer] with
        {
            Detail = "Run diagnostics to select one online peer. Scan the selected LAN first if needed."
        };
        TracePanel.Children.Clear();
        TraceStatus.Text = "Not run. Up to 16 hops, one ICMP probe per hop, 1.5-second timeout.";
        ProgressText.Text = "Ready. No checks have run.";
        Render();
    }

    private async void RunButton_Click(object sender, RoutedEventArgs e)
    {
        if (HasActiveTest) return;
        if (IsUiReview)
        {
            LoadReviewPeer();
            ProgressText.Text = "UI-review mode does not send diagnostic probes.";
            return;
        }
        IPAddress? wan;
        try { wan = RouterWanAddress.Parse(WanInput.Text); }
        catch (ArgumentException exception)
        {
            SettingsStatus.Text = $"Invalid WAN address: {exception.Message}";
            WanInput.Focus(FocusState.Programmatic);
            return;
        }
        try
        {
            var current = _discovery.GetAvailableNetworks().FirstOrDefault(item =>
                item.InterfaceId == _network?.InterfaceId && item.LocalAddress.Equals(_network?.LocalAddress));
            var currentId = current is null ? (Guid?)null : WindowsNetworkProfileIdentity.GetNetworkId(current);
            if (!DiagnosticContextState.Matches(_network, _networkId, current, currentId))
            {
                RefreshNetworks(current);
                ProgressText.Text = "Network context changed. Review the adapter and this network's WAN input, then run again.";
                return;
            }
        }
        catch (Exception exception) when (exception is COMException or InvalidOperationException or InvalidCastException
            or System.Net.NetworkInformation.NetworkInformationException or ArgumentException)
        {
            // Probes may still run without persistence, but never reuse an address from an unverified profile.
            if (!string.IsNullOrWhiteSpace(WanInput.Text) && _networkId is not null)
            {
                SettingsStatus.Text = $"Network identity verification failed: {exception.Message} Refresh adapters before using the saved WAN address.";
                return;
            }
            SettingsStatus.Text = $"Network identity verification unavailable: {exception.Message} WAN persistence is disabled.";
            _settingsLoaded = false;
        }
        var lease = ActivityCoordinator is null
            ? null
            : await ActivityCoordinator.AcquireAsync(NetworkActivityKind.NetworkTroubleshooting);
        if (lease is null)
        {
            ProgressText.Text = "Network activity coordination is unavailable, or a LAN scan/speed test/diagnostic run is active or stopping. Wait and retry.";
            return;
        }
        ResetResults();
        var request = _runSurface.Start(_network?.DisplayLabel ?? "No active LAN")
            ?? throw new InvalidOperationException("The diagnostic session is closed.");
        _cancellation = CancellationTokenSource.CreateLinkedTokenSource(request.CancellationToken);
        BeginDiagramAnimation();
        SetRunning(true);
        _runTask = RunAsync(wan, lease, _cancellation, request);
    }

    private async Task RunAsync(IPAddress? wan, IDisposable? lease, CancellationTokenSource cancellation,
        AsyncSurfaceSession.Request request)
    {
        using (lease)
        {
            var started = DateTimeOffset.Now;
            var completed = false;
            var failed = false;
            try
            {
                var peers = _network is null || _networkId is null ? []
                    : (_peerCandidates ?? throw new InvalidOperationException("Online peer inventory is unavailable. Reopen the tool and try again."))
                        (_network, _networkId);
                ProgressText.Text = $"Checking - started {started:g}.";
                var progress = new Progress<DiagnosticObservation>(observation =>
                {
                    if (!_runSurface.IsCurrent(request) || cancellation.IsCancellationRequested) return;
                    _observations[observation.Checkpoint] = observation;
                    ObserveDiagram(observation);
                    ProgressText.Text = $"{Label(observation.Checkpoint)}: {observation.Detail}";
                    Render();
                });
                var traceProgress = new Progress<TraceHop>(hop =>
                {
                    if (!_runSurface.IsCurrent(request) || cancellation.IsCancellationRequested) return;
                    TracePanel.Children.Add(HopText(hop));
                    TraceStatus.Text = $"Observed hop {hop.Number} of at most 16: {hop.Observation.State}.";
                    ProgressText.Text = $"Traceroute hop {hop.Number}: {hop.Observation.Detail}";
                });
                var report = await _service.RunAsync(_network, wan, progress, cancellation.Token, traceProgress, peers);
                if (!_runSurface.IsCurrent(request)) return;
                _report = report;
                foreach (var observation in _report.Observations)
                {
                    _observations[observation.Checkpoint] = observation;
                    ObserveDiagram(observation);
                }
                Render();
                if (cancellation.IsCancellationRequested)
                    _report = _report with { Cancelled = true };
                if (!_report.Cancelled)
                {
                    CompleteDiagramAnimation(_report);
                    completed = true;
                }
                TracePanel.Children.Clear();
                foreach (var hop in _report.Hops)
                    TracePanel.Children.Add(HopText(hop));
                TraceStatus.Text = _report.Cancelled ? "Trace cancelled / incomplete."
                    : _report.TraceComplete ? "Destination reached. Unanswered earlier hops do not prove a broken link."
                    : "Incomplete trace: destination not reached within 16 hops. Filtering or routing may explain unanswered hops.";
                ProgressText.Text = $"{(_report.Cancelled ? "Cancelled / partial" : "Checks complete")} - started {started:g}; finished {DateTimeOffset.Now:g}.";
            }
            catch (Exception exception) when (exception is InvalidOperationException or System.Net.NetworkInformation.NetworkInformationException)
            {
                if (!_runSurface.IsCurrent(request)) return;
                failed = true;
                ProgressText.Text = $"Diagnostics failed: {exception.Message}";
                foreach (var observation in _observations.Values.ToArray())
                    if (observation.State is DiagnosticState.Untested or DiagnosticState.Running)
                        _observations[observation.Checkpoint] = observation with { State = DiagnosticState.Error, Detail = "Run stopped by a diagnostic error." };
                _report = new(_observations.Values.ToArray(), [], false, false);
            }
            finally
            {
                if (!completed) StopDiagramAnimation();
                _cancellation = null;
                cancellation.Dispose();
                SetRunning(false);
                _runSurface.Complete(request, failed ? AsyncSurfaceState.Error : AsyncSurfaceState.Ready, () =>
                {
                    Render();
                    NetworkHealthScroll.UpdateLayout();
                });
            }
        }
    }

    private static TextBlock HopText(TraceHop hop) => new()
    {
        Text = $"Hop {hop.Number}: {NetworkDiagnosticFormatter.Describe(hop.Observation)}",
        TextWrapping = TextWrapping.Wrap
    };

    private void SetRunning(bool running)
    {
        RunButton.IsEnabled = !running;
        UpdateAnimationCancelButton();
        AdapterPicker.IsEnabled = !running;
        RefreshButton.IsEnabled = !running;
        WanInput.IsEnabled = !running;
        RunProgress.IsActive = running;
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e)
    {
        StopDiagramAnimation();
        if (_cancellation is null) return;
        _cancellation?.Cancel();
        CancelRunButton.IsEnabled = false;
        ProgressText.Text = "Cancelling; waiting for probes to stop safely...";
    }

    private void BackButton_Click(object sender, RoutedEventArgs e) => BackRequested?.Invoke(this, EventArgs.Empty);

    private void CurrentHealthLayout_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var narrow = e.NewSize.Width < 560;
        Grid.SetRow(RunControls, narrow ? 1 : 0);
        Grid.SetColumn(RunControls, narrow ? 0 : 1);
        Grid.SetRow(ProgressText, narrow ? 2 : 1);
    }

    private void ServiceStatusEntryLayout_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var narrow = e.NewSize.Width < 560;
        Grid.SetRow(OpenServiceStatusButton, narrow ? 1 : 0);
        Grid.SetColumn(OpenServiceStatusButton, narrow ? 1 : 2);
        OpenServiceStatusButton.HorizontalAlignment = HorizontalAlignment.Left;
    }

    private void OpenServiceStatusButton_Click(object sender, RoutedEventArgs e) =>
        ServiceStatusRequested?.Invoke(this, EventArgs.Empty);

    private void Render()
    {
        if (SummaryBanner is null) return;
        _diagramPorts.Clear();
        DiagnosticsPanel.Children.Clear();
        foreach (var observation in _observations.Values)
        {
            var row = new TextBlock { Text = $"{Label(observation.Checkpoint)} - {NetworkDiagnosticFormatter.Describe(observation)}", TextWrapping = TextWrapping.Wrap };
            AutomationProperties.SetName(row, row.Text);
            DiagnosticsPanel.Children.Add(row);
        }
        Node(PcNode, "This PC", "\uE7F4", DiagnosticCheckpoint.Loopback, DiagnosticCheckpoint.LocalAddress);
        Node(RouterNode, "Home router", "\uE968", DiagnosticCheckpoint.Gateway, DiagnosticCheckpoint.RouterWan);
        PeerNode();
        Node(HopNode, "Upstream hop 2", "\uE968", DiagnosticCheckpoint.Hop2);
        Node(CloudflareNode, "Cloudflare", "\uEC06", DiagnosticCheckpoint.CloudflarePing, DiagnosticCheckpoint.CloudflareDns);
        Node(GoogleNode, "Google", "\uEC06", DiagnosticCheckpoint.GooglePing, DiagnosticCheckpoint.GoogleDns);
        var summary = _cancellation is not null
            ? new DiagnosticSummary(DiagnosticSummaryKind.Neutral, "Running / partial evidence", "Checks are in progress. Wait for completion before interpreting results, or cancel to stop.")
            : NetworkDiagnosticInterpreter.Summarize(_network, _report);
        SummaryTitle.Text = summary.Status;
        SummaryExplanation.Text = summary.Explanation;
        SummaryBanner.Background = StatusBrush(summary.Kind);
        SummaryTitle.Foreground = _accessibility.HighContrast || summary.Kind == DiagnosticSummaryKind.Neutral
            ? (Brush)Application.Current.Resources["TextFillColorPrimaryBrush"] : new SolidColorBrush(Microsoft.UI.Colors.White);
    }

    private void PeerNode()
    {
        PeerCheckpoint.Children.Clear();
        if (!_observations.TryGetValue(DiagnosticCheckpoint.LanPeer, out var observation)) return;
        var foreground = PortForeground();
        var marker = new Microsoft.UI.Xaml.Shapes.Ellipse
        {
            Width = 14, Height = 14, StrokeThickness = 2, Stroke = foreground,
            Fill = observation.State == DiagnosticState.Responded
                ? _accessibility.HighContrast ? foreground : StatusBrush(DiagnosticSummaryKind.Good) : null,
            VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 3, 0, 0)
        };
        AutomationProperties.SetAutomationId(marker, "DiagramPortLanPeer");
        AutomationProperties.SetName(marker, $"Selected LAN peer port: {observation.State}");
        _diagramPorts[DiagnosticCheckpoint.LanPeer] = marker;
        PeerCheckpoint.Children.Add(marker);
        var text = new StackPanel { Spacing = 2, Margin = new Thickness(8, 0, 0, 0), MaxWidth = 220 };
        var address = new TextBlock
        {
            Text = NetworkDiagnosticFormatter.CheckpointAddress(observation), FontSize = 11, TextWrapping = TextWrapping.Wrap
        };
        AutomationProperties.SetAutomationId(address, "DiagramAddressLanPeer");
        var state = new TextBlock
        {
            Text = $"{observation.State}" + (observation.State == DiagnosticState.Responded
                && observation.RoundtripMilliseconds is { } time ? $" - {time} ms" : string.Empty),
            FontSize = 11, TextWrapping = TextWrapping.Wrap
        };
        AutomationProperties.SetAutomationId(state, "DiagramCheckpointLanPeer");
        AutomationProperties.SetName(state, $"Selected LAN peer: {address.Text}; {state.Text}");
        text.Children.Add(address);
        text.Children.Add(state);
        PeerCheckpoint.Children.Add(text);
        ToolTipService.SetToolTip(PeerCheckpoint, NetworkDiagnosticFormatter.Describe(observation));
    }

    private void SelectedPeerNode_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (PeerCheckpoint is null) return;
        var bottom = Canvas.GetTop(SelectedPeerNode) + e.NewSize.Height;
        Canvas.SetTop(PeerCheckpoint, bottom + 2);
        var geometry = new PathGeometry();
        foreach (var (start, end) in new[]
        {
            (new Windows.Foundation.Point(395, 178), new Windows.Foundation.Point(395, bottom + 19)),
            (new Windows.Foundation.Point(395, bottom + 5), new Windows.Foundation.Point(395, bottom))
        })
        {
            var figure = new PathFigure { StartPoint = start };
            figure.Segments.Add(new LineSegment { Point = end });
            geometry.Figures.Add(figure);
        }
        RouterPeerConnector.Data = geometry;
    }

    private sealed record ReviewPeer(string? Address, DiagnosticState State, long? Latency);

    private void LoadReviewPeer()
    {
        if (Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW_PEER") is not { Length: > 0 } path) return;
        var fixture = JsonSerializer.Deserialize<ReviewPeer>(File.ReadAllText(path))
            ?? throw new InvalidDataException("A peer review fixture is required.");
        if (fixture.State is not (DiagnosticState.Responded or DiagnosticState.Unanswered or DiagnosticState.Unavailable))
            throw new InvalidDataException("Unsupported peer review state.");
        var address = fixture.Address is null ? null : IPAddress.Parse(fixture.Address);
        var peer = NetworkDiagnosticService.CreateCheckpoints(_network, null, address)
            .Single(item => item.Checkpoint == DiagnosticCheckpoint.LanPeer);
        _observations[DiagnosticCheckpoint.LanPeer] = peer with
        {
            State = fixture.State, RoundtripMilliseconds = fixture.Latency,
            Detail = address is null ? peer.Detail : "Synthetic UI-review peer evidence; no diagnostic probes sent."
        };
        Render();
        NetworkHealthScroll.UpdateLayout();
    }

    private Brush PortForeground() => new SolidColorBrush(_accessibility.HighContrast
        ? _uiSettings.GetColorValue(UIColorType.Foreground)
        : ActualTheme == ElementTheme.Dark ? Microsoft.UI.Colors.White : Microsoft.UI.Colors.Black);

    private void Node(StackPanel panel, string title, string glyph, params DiagnosticCheckpoint[] checkpoints)
    {
        panel.Children.Clear();
        panel.Spacing = 8;
        panel.Children.Add(new TextBlock { Text = title, TextAlignment = TextAlignment.Center, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        var device = new Grid { ColumnSpacing = 4 };
        foreach (var width in new[] { new GridLength(1, GridUnitType.Star), new GridLength(14), new GridLength(44), new GridLength(14), new GridLength(1, GridUnitType.Star) })
        {
            device.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        }
        device.RowDefinitions.Add(new RowDefinition { Height = new GridLength(40) });
        device.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var icon = new FontIcon { Glyph = glyph, FontSize = 36 };
        Grid.SetColumn(icon, 2);
        device.Children.Add(icon);
        var portForeground = PortForeground();
        for (var index = 0; index < checkpoints.Length; index++)
        {
            var checkpoint = checkpoints[index];
            if (!_observations.TryGetValue(checkpoint, out var observation)) continue;
            var kind = observation.State == DiagnosticState.Responded ? DiagnosticSummaryKind.Good
                : observation.State is DiagnosticState.Unanswered or DiagnosticState.Error ? DiagnosticSummaryKind.Problem : DiagnosticSummaryKind.Neutral;
            var address = NetworkDiagnosticFormatter.CheckpointAddress(observation);
            var marker = new Microsoft.UI.Xaml.Shapes.Ellipse
            {
                Width = 14, Height = 14, StrokeThickness = 2,
                Stroke = portForeground,
                Fill = kind == DiagnosticSummaryKind.Neutral ? null
                    : _accessibility.HighContrast ? portForeground : StatusBrush(kind),
                VerticalAlignment = VerticalAlignment.Center
            };
            AutomationProperties.SetName(marker, $"{Label(checkpoint)} port: {observation.State}");
            AutomationProperties.SetAutomationId(marker, $"DiagramPort{checkpoint}");
            _diagramPorts[checkpoint] = marker;
            var left = index == 0;
            var addressColumn = left ? 0 : 4;
            Grid.SetColumn(marker, left ? 1 : 3);
            device.Children.Add(marker);
            var addressText = new TextBlock
            {
                Text = address, FontSize = 11, VerticalAlignment = VerticalAlignment.Bottom,
                HorizontalAlignment = left ? HorizontalAlignment.Right : HorizontalAlignment.Left
            };
            AutomationProperties.SetAutomationId(addressText, $"DiagramAddress{checkpoint}");
            Grid.SetColumn(addressText, addressColumn);
            device.Children.Add(addressText);
            var description = new TextBlock
            {
                Text = $"{PortLabel(checkpoint)}\n{observation.State}",
                TextWrapping = TextWrapping.Wrap, FontSize = 11,
                TextAlignment = left ? TextAlignment.Right : TextAlignment.Left
            };
            AutomationProperties.SetAutomationId(description, $"DiagramCheckpoint{checkpoint}");
            ToolTipService.SetToolTip(marker, NetworkDiagnosticFormatter.Describe(observation));
            ToolTipService.SetToolTip(addressText, NetworkDiagnosticFormatter.Describe(observation));
            AutomationProperties.SetName(description, $"{Label(checkpoint)}: {address}; {observation.State}");
            Grid.SetRow(description, 1);
            Grid.SetColumn(description, addressColumn);
            device.Children.Add(description);
        }
        panel.Children.Add(device);
    }

    private Brush StatusBrush(DiagnosticSummaryKind kind)
    {
        if (_accessibility.HighContrast || kind == DiagnosticSummaryKind.Neutral)
            return (Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"];
        return new SolidColorBrush(kind switch
        {
            DiagnosticSummaryKind.Good => Color.FromArgb(255, 22, 101, 52),
            DiagnosticSummaryKind.Warning => Color.FromArgb(255, 154, 77, 0),
            _ => Color.FromArgb(255, 185, 28, 28)
        });
    }

    private static string PortLabel(DiagnosticCheckpoint checkpoint) => checkpoint switch
    {
        DiagnosticCheckpoint.Loopback => "Loopback",
        DiagnosticCheckpoint.LocalAddress => "LAN IP",
        DiagnosticCheckpoint.Gateway => "LAN IP",
        DiagnosticCheckpoint.RouterWan => "WAN IP",
        DiagnosticCheckpoint.CloudflarePing or DiagnosticCheckpoint.GooglePing => "IP ping",
        DiagnosticCheckpoint.CloudflareDns or DiagnosticCheckpoint.GoogleDns => "DNS",
        _ => "Hop-2 response"
    };

    private static string Label(DiagnosticCheckpoint checkpoint) => NetworkIncidentPresentation.CheckpointLabel(checkpoint);
}
