using System.Net;
using System.Runtime.InteropServices;
using System.Text.Json;
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

public sealed partial class NetworkTroubleshootingPage : UserControl
{
    private readonly NetworkDiscoveryService _discovery = new();
    private readonly NetworkDiagnosticService _service = new(new NetworkDiagnosticProbes());
    private readonly RouterWanSettingsStore _store = new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FingVibe", "router-wan.json"));
    private readonly AccessibilitySettings _accessibility = new();
    private readonly UISettings _uiSettings = new();
    private readonly Dictionary<DiagnosticCheckpoint, DiagnosticObservation> _observations = [];
    private CancellationTokenSource? _cancellation;
    private Task? _runTask;
    private LanNetwork? _network;
    private LanNetwork? _shellNetwork;
    private Guid? _networkId;
    private bool _updatingInput;
    private bool _settingsLoaded;
    private bool _refreshing;
    private bool _open;
    private NetworkDiagnosticReport? _report;
    private static bool IsUiReview => Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW") == "1";

    public NetworkTroubleshootingPage()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            _uiSettings.ColorValuesChanged += ColorsChanged;
            NetworkInformation.NetworkStatusChanged += NetworkChanged;
        };
        Unloaded += (_, _) =>
        {
            _uiSettings.ColorValuesChanged -= ColorsChanged;
            NetworkInformation.NetworkStatusChanged -= NetworkChanged;
            _cancellation?.Cancel();
        };
        ActualThemeChanged += (_, _) => Render();
    }

    public event EventHandler? BackRequested;
    internal NetworkActivityCoordinator? ActivityCoordinator { get; set; }
    public bool HasActiveTest => _runTask is { IsCompleted: false };

    public void SetNetworkContext(LanNetwork? network) => _shellNetwork = network;

    public async Task OpenAsync()
    {
        _open = true;
        if (_runTask is { } run) await run;
        if (!_open) return;
        RefreshNetworks(_shellNetwork);
        RunButton.Focus(FocusState.Programmatic);
    }

    public async Task StopForNavigationAsync()
    {
        _open = false;
        _cancellation?.Cancel();
        if (_runTask is { } run) await run;
    }

    public Task StopForWindowCloseAsync() => StopForNavigationAsync();

    private void ColorsChanged(UISettings sender, object args) => DispatcherQueue.TryEnqueue(Render);

    private void NetworkChanged(object sender) => DispatcherQueue.TryEnqueue(async () =>
    {
        if (!_open) return;
        _cancellation?.Cancel();
        if (_runTask is { } run) await run;
        if (_open)
        {
            RefreshNetworks(_network);
            ProgressText.Text = "Windows reported a network change. Context refreshed; run checks again.";
        }
    });

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
            AdapterPicker.SelectedItem = networks.FirstOrDefault(item =>
                item.InterfaceId == preferred?.InterfaceId && item.LocalAddress.Equals(preferred?.LocalAddress))
                ?? networks.FirstOrDefault();
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
        finally { _updatingInput = false; }
        ContextText.Text = network is null ? "No active LAN adapter." : $"Selected: {network.DisplayLabel} - Gateway: {network.GatewayAddress?.ToString() ?? "unavailable"}";
        WanHelp.Text = $"Open your router administration page in a browser, usually http://{network?.GatewayAddress?.ToString() ?? "<gateway shown above>"}. Sign in there and find Internet, WAN, or Status. Copy the WAN/Internet IPv4 address, not the router LAN address. Never enter router credentials into FingVibe.";
        ResetResults();
    }

    private void AdapterPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_refreshing && !HasActiveTest) ApplyNetwork(AdapterPicker.SelectedItem as LanNetwork);
    }

    private void RefreshButton_Click(object sender, RoutedEventArgs e) => RefreshNetworks(_network);

    private void WanInput_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_updatingInput) return;
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
        _report = null;
        _observations.Clear();
        IPAddress? wan = null;
        try { wan = RouterWanAddress.Parse(WanInput.Text); }
        catch (ArgumentException) { /* The visible input error is set by the edit/run handler. */ }
        foreach (var observation in NetworkDiagnosticService.CreateCheckpoints(_network, wan))
            _observations.Add(observation.Checkpoint, observation);
        TracePanel.Children.Clear();
        TraceStatus.Text = "Not run. Up to 16 hops, one ICMP probe per hop, 1.5-second timeout.";
        ProgressText.Text = "Ready. No checks have run.";
        Render();
    }

    private void RunButton_Click(object sender, RoutedEventArgs e)
    {
        if (HasActiveTest) return;
        if (IsUiReview)
        {
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
            if (current != _network || currentId != _networkId)
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
        if (ActivityCoordinator is null || !ActivityCoordinator.TryAcquire(NetworkActivityKind.NetworkTroubleshooting, out var lease))
        {
            ProgressText.Text = "Network activity coordination is unavailable, or a LAN scan/speed test/diagnostic run is active or stopping. Wait and retry.";
            return;
        }
        ResetResults();
        _cancellation = new CancellationTokenSource();
        SetRunning(true);
        _runTask = RunAsync(wan, lease, _cancellation);
    }

    private async Task RunAsync(IPAddress? wan, IDisposable? lease, CancellationTokenSource cancellation)
    {
        using (lease)
        {
            var started = DateTimeOffset.Now;
            try
            {
                ProgressText.Text = $"Checking - started {started:g}.";
                var progress = new Progress<DiagnosticObservation>(observation =>
                {
                    if (_cancellation != cancellation || cancellation.IsCancellationRequested) return;
                    _observations[observation.Checkpoint] = observation;
                    ProgressText.Text = $"{Label(observation.Checkpoint)}: {observation.Detail}";
                    Render();
                });
                var traceProgress = new Progress<TraceHop>(hop =>
                {
                    if (_cancellation != cancellation || cancellation.IsCancellationRequested) return;
                    TracePanel.Children.Add(HopText(hop));
                    TraceStatus.Text = $"Observed hop {hop.Number} of at most 16: {hop.Observation.State}.";
                    ProgressText.Text = $"Traceroute hop {hop.Number}: {hop.Observation.Detail}";
                });
                _report = await _service.RunAsync(_network, wan, progress, cancellation.Token, traceProgress);
                foreach (var observation in _report.Observations) _observations[observation.Checkpoint] = observation;
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
                ProgressText.Text = $"Diagnostics failed: {exception.Message}";
                foreach (var observation in _observations.Values.ToArray())
                    if (observation.State is DiagnosticState.Untested or DiagnosticState.Running)
                        _observations[observation.Checkpoint] = observation with { State = DiagnosticState.Error, Detail = "Run stopped by a diagnostic error." };
                _report = new(_observations.Values.ToArray(), [], false, false);
            }
            finally
            {
                _cancellation = null;
                cancellation.Dispose();
                SetRunning(false);
                Render();
            }
        }
    }

    private static TextBlock HopText(TraceHop hop) => new()
    {
        Text = $"Hop {hop.Number}: {Describe(hop.Observation)}",
        TextWrapping = TextWrapping.Wrap
    };

    private void SetRunning(bool running)
    {
        RunButton.IsEnabled = !running;
        CancelRunButton.IsEnabled = running;
        AdapterPicker.IsEnabled = !running;
        RefreshButton.IsEnabled = !running;
        WanInput.IsEnabled = !running;
        RunProgress.IsActive = running;
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e)
    {
        _cancellation?.Cancel();
        CancelRunButton.IsEnabled = false;
        ProgressText.Text = "Cancelling; waiting for probes to stop safely...";
    }

    private void BackButton_Click(object sender, RoutedEventArgs e) => BackRequested?.Invoke(this, EventArgs.Empty);

    private void Render()
    {
        if (SummaryBanner is null) return;
        DiagnosticsPanel.Children.Clear();
        foreach (var observation in _observations.Values)
        {
            var row = new TextBlock { Text = $"{Label(observation.Checkpoint)} - {Describe(observation)}", TextWrapping = TextWrapping.Wrap };
            AutomationProperties.SetName(row, row.Text);
            DiagnosticsPanel.Children.Add(row);
        }
        Node(PcNode, "This PC", "\uE7F4", DiagnosticCheckpoint.Loopback, DiagnosticCheckpoint.LocalAddress);
        Node(RouterNode, "Home router", "\uE968", DiagnosticCheckpoint.Gateway, DiagnosticCheckpoint.RouterWan);
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

    private void Node(StackPanel panel, string title, string glyph, params DiagnosticCheckpoint[] checkpoints)
    {
        panel.Children.Clear();
        panel.Spacing = 8;
        panel.Children.Add(new TextBlock { Text = title, TextAlignment = TextAlignment.Center, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        panel.Children.Add(new FontIcon { Glyph = glyph, FontSize = 36 });
        var ports = new Grid { ColumnSpacing = 6 };
        for (var index = 0; index < checkpoints.Length; index++)
        {
            ports.ColumnDefinitions.Add(new ColumnDefinition());
            var checkpoint = checkpoints[index];
            if (!_observations.TryGetValue(checkpoint, out var observation)) continue;
            var kind = observation.State == DiagnosticState.Responded ? DiagnosticSummaryKind.Good
                : observation.State is DiagnosticState.Unanswered or DiagnosticState.Error ? DiagnosticSummaryKind.Problem : DiagnosticSummaryKind.Neutral;
            var text = new TextBlock
            {
                Text = $"{PortLabel(checkpoint)}\n{observation.State}",
                TextWrapping = TextWrapping.Wrap, FontSize = 11, TextAlignment = TextAlignment.Center,
                Foreground = _accessibility.HighContrast || kind == DiagnosticSummaryKind.Neutral
                    ? (Brush)Application.Current.Resources["TextFillColorPrimaryBrush"] : new SolidColorBrush(Microsoft.UI.Colors.White)
            };
            var port = new Border { Child = text, Padding = new Thickness(4), CornerRadius = new CornerRadius(4), Background = StatusBrush(kind) };
            ToolTipService.SetToolTip(port, Describe(observation));
            AutomationProperties.SetName(port, $"{Label(checkpoint)}: {Describe(observation)}");
            Grid.SetColumn(port, index);
            ports.Children.Add(port);
        }
        panel.Children.Add(ports);
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

    private static string Describe(DiagnosticObservation observation) =>
        $"{observation.Target} | {observation.State} | {observation.Detail}"
        + (observation.RespondingAddress is { } address ? $" | response from {address}" : string.Empty)
        + (observation.RoundtripMilliseconds is { } time ? $" | {time} ms" : string.Empty);

    private static string PortLabel(DiagnosticCheckpoint checkpoint) => checkpoint switch
    {
        DiagnosticCheckpoint.Loopback => "Loopback (left)",
        DiagnosticCheckpoint.LocalAddress => "LAN IP (right)",
        DiagnosticCheckpoint.Gateway => "LAN IP (left)",
        DiagnosticCheckpoint.RouterWan => "WAN IP (right)",
        DiagnosticCheckpoint.CloudflarePing or DiagnosticCheckpoint.GooglePing => "IP ping (left)",
        DiagnosticCheckpoint.CloudflareDns or DiagnosticCheckpoint.GoogleDns => "DNS (right)",
        _ => "Hop-2 response"
    };

    private static string Label(DiagnosticCheckpoint checkpoint) => checkpoint switch
    {
        DiagnosticCheckpoint.Loopback => "Loopback",
        DiagnosticCheckpoint.LocalAddress => "This PC LAN IPv4",
        DiagnosticCheckpoint.Gateway => "Default gateway LAN IPv4",
        DiagnosticCheckpoint.RouterWan => "Optional router WAN IPv4",
        DiagnosticCheckpoint.Hop2 => "Observed hop 2",
        DiagnosticCheckpoint.CloudflarePing => "Cloudflare IP ping",
        DiagnosticCheckpoint.GooglePing => "Google IP ping",
        DiagnosticCheckpoint.ConfiguredDns => "Windows configured DNS",
        DiagnosticCheckpoint.CloudflareDns => "Direct Cloudflare DNS",
        _ => "Direct Google DNS"
    };
}
