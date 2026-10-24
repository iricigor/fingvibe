using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.Web.WebView2.Core;

namespace FingVibe.App;

public sealed partial class SpeedTestPage : UserControl
{
    private const string VirtualHostName = "fingvibe-speedtest.local";
    private static readonly Uri EnginePageUri = new($"https://{VirtualHostName}/index.html");
    private static readonly Uri PrivacyPolicyUri = new("https://www.cloudflare.com/privacypolicy/");
    private readonly SpeedTestSessionState _session = new();
    private CoreWebView2? _configuredCore;
    private IDisposable? _activityLease;
    private Task? _cancellationTask;
    private string? _cancellationRunId;
    private bool _enginePageLoaded;
    private string? _gaugePhase;
    private double _gaugeMaximumMbps = 100;
    private Storyboard? _gaugeAnimation;

    public SpeedTestPage()
    {
        InitializeComponent();
    }

    public event EventHandler? BackRequested;

    internal NetworkActivityCoordinator? ActivityCoordinator { get; set; }

    public bool HasActiveTest => _session.IsActive || _activityLease is not null;

    public Task StopForNavigationAsync() =>
        CancelActiveTestAsync("Speed test cancelled because you left the page.");

    public Task StopForWindowCloseAsync() =>
        CancelActiveTestAsync("Speed test cancelled because FingVibe is closing.");

    public void FocusStartButton() => StartTestButton.Focus(FocusState.Programmatic);

    internal void ResetForNavigation()
    {
        if (!_session.TryReset())
        {
            return;
        }

        ResetResults();
        SetRunning(false);
        StatusText.Text = "Ready. Select Start test when you are ready.";
    }

    private async void StartTestButton_Click(object sender, RoutedEventArgs e)
    {
        if (HasActiveTest)
        {
            return;
        }

        if (!await ConfirmDataUseAsync())
        {
            return;
        }

        if (ActivityCoordinator is null)
        {
            StatusText.Text = "The speed test is unavailable because network activity coordination is not ready.";
            return;
        }

        if (!ActivityCoordinator.TryAcquire(NetworkActivityKind.InternetSpeedTest, out var lease))
        {
            StatusText.Text = ActivityCoordinator.ActiveKind == NetworkActivityKind.LanScan
                ? "A LAN scan is in progress. Wait for it to finish before starting a speed test."
                : "Another network measurement is in progress. Wait for it to finish before retrying.";
            return;
        }

        _activityLease = lease;
        var runId = Guid.NewGuid().ToString("N");
        if (!_session.TryStart(runId))
        {
            ReleaseActivity();
            StatusText.Text = "A previous speed test is still stopping. Wait a moment, then retry.";
            return;
        }

        ResetResults();
        SetRunning(true);
        StatusText.Text = "Preparing the Cloudflare measurement...";

        try
        {
            var core = await EnsureEnginePageAsync();
            if (!_session.CanStartEngine
                || !string.Equals(_session.RunId, runId, StringComparison.Ordinal))
            {
                return;
            }

            var available = await core.ExecuteScriptAsync(
                "typeof window.fingvibeSpeedTest === 'object' && typeof window.fingvibeSpeedTest.start === 'function'");
            if (!JsonSerializer.Deserialize<bool>(available))
            {
                throw new InvalidOperationException("The local Cloudflare measurement engine did not initialize.");
            }

            if (!_session.CanStartEngine
                || !string.Equals(_session.RunId, runId, StringComparison.Ordinal))
            {
                return;
            }

            await core.ExecuteScriptAsync(
                $"window.fingvibeSpeedTest.start({JsonSerializer.Serialize(runId)});");
            if (_session.IsActive && string.Equals(_session.RunId, runId, StringComparison.Ordinal))
            {
                StatusText.Text = "Connecting to Cloudflare...";
            }
        }
        catch (Exception exception)
        {
            FailWebViewRun(runId, exception);
        }
    }

    private async void CancelTestButton_Click(object sender, RoutedEventArgs e)
    {
        await CancelActiveTestAsync("Test cancelled. No completed results were recorded.");
    }

    private void BackButton_Click(object sender, RoutedEventArgs e) =>
        BackRequested?.Invoke(this, EventArgs.Empty);

    private async Task<bool> ConfirmDataUseAsync()
    {
        var content = new StackPanel { Spacing = 8 };
        content.Children.Add(new TextBlock
        {
            Text = "The test transfers data over the internet and measures this PC's connection to Cloudflare. Depending on your connection, a run may use over 1 GB; FingVibe does not set a data cap. Windows chooses the internet route, not the LAN scanner's selected adapter."
        });
        content.Children.Add(new TextBlock
        {
            Text = "Cloudflare's official engine sends measurement results to Cloudflare. This is not a local-only test."
        });

        var privacyLink = new HyperlinkButton
        {
            Content = "Cloudflare Privacy Policy",
            NavigateUri = PrivacyPolicyUri,
            Padding = new Thickness(0, 4, 0, 4)
        };
        AutomationProperties.SetName(privacyLink, "Cloudflare Privacy Policy (opens in browser)");
        content.Children.Add(privacyLink);

        var dialog = new ContentDialog
        {
            Title = "Before you start",
            Content = content,
            PrimaryButtonText = "Start test",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
            XamlRoot = XamlRoot
        };

        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    private async Task<CoreWebView2> EnsureEnginePageAsync()
    {
        await EngineWebView.EnsureCoreWebView2Async();
        var core = EngineWebView.CoreWebView2
            ?? throw new InvalidOperationException("WebView2 did not create a browser session.");

        if (_configuredCore != core)
        {
            var assetsPath = Path.Combine(AppContext.BaseDirectory, "Assets", "SpeedTest");
            if (!Directory.Exists(assetsPath))
            {
                throw new DirectoryNotFoundException("The bundled Cloudflare measurement files are missing.");
            }

            core.SetVirtualHostNameToFolderMapping(
                VirtualHostName,
                assetsPath,
                CoreWebView2HostResourceAccessKind.DenyCors);
            core.Settings.IsWebMessageEnabled = true;
            core.Settings.AreDevToolsEnabled = false;
            core.Settings.AreDefaultContextMenusEnabled = false;
            core.Settings.IsStatusBarEnabled = false;
            core.Settings.IsZoomControlEnabled = false;
            core.NavigationStarting += CoreWebView2_NavigationStarting;
            core.NewWindowRequested += CoreWebView2_NewWindowRequested;
            core.WebMessageReceived += CoreWebView2_WebMessageReceived;
            core.ProcessFailed += CoreWebView2_ProcessFailed;
            _configuredCore = core;
        }

        if (_enginePageLoaded)
        {
            return core;
        }

        var navigationCompleted = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        void OnNavigationCompleted(CoreWebView2 sender, CoreWebView2NavigationCompletedEventArgs args) =>
            navigationCompleted.TrySetResult(args.IsSuccess);

        core.NavigationCompleted += OnNavigationCompleted;
        try
        {
            core.Navigate(EnginePageUri.AbsoluteUri);
            var completed = await Task.WhenAny(navigationCompleted.Task, Task.Delay(TimeSpan.FromSeconds(15)));
            if (completed != navigationCompleted.Task)
            {
                throw new TimeoutException("The local Cloudflare measurement page did not load in time.");
            }

            if (!await navigationCompleted.Task)
            {
                throw new InvalidOperationException("The local Cloudflare measurement page could not be loaded.");
            }

            _enginePageLoaded = true;
            return core;
        }
        finally
        {
            core.NavigationCompleted -= OnNavigationCompleted;
        }
    }

    private void CoreWebView2_NavigationStarting(CoreWebView2 sender, CoreWebView2NavigationStartingEventArgs args)
    {
        if (!IsAllowedNavigation(args.Uri))
        {
            args.Cancel = true;
        }
    }

    private static bool IsAllowedNavigation(string target)
    {
        if (string.Equals(target, "about:blank", StringComparison.OrdinalIgnoreCase))
        {
            return true;
        }

        return Uri.TryCreate(target, UriKind.Absolute, out var uri)
            && uri.Scheme == Uri.UriSchemeHttps
            && uri.IsDefaultPort
            && string.Equals(uri.Host, VirtualHostName, StringComparison.OrdinalIgnoreCase)
            && string.Equals(uri.AbsolutePath, "/index.html", StringComparison.Ordinal);
    }

    private void CoreWebView2_NewWindowRequested(
        CoreWebView2 sender,
        CoreWebView2NewWindowRequestedEventArgs args) =>
        args.Handled = true;

    private void CoreWebView2_WebMessageReceived(CoreWebView2 sender, CoreWebView2WebMessageReceivedEventArgs args)
    {
        if (!IsTrustedMessageSource(args.Source) || _session.RunId is not { } runId)
        {
            return;
        }

        string payload;
        try
        {
            payload = args.TryGetWebMessageAsString();
        }
        catch (InvalidOperationException)
        {
            return;
        }

        if (!SpeedTestBridgeMessageParser.TryParse(payload, runId, out var message)
            || message is null
            || !_session.Apply(message))
        {
            return;
        }

        if (_session.Status == SpeedTestSessionStatus.Cancelled)
        {
            CompleteCancellation("Test cancelled. No completed results were recorded.");
            return;
        }

        switch (message.Kind)
        {
            case "sample":
                if (message.Phase == _gaugePhase)
                {
                    ShowGaugeSample(message.Bps!.Value);
                }
                break;
            case "progress":
                if (message.Phase != _gaugePhase)
                {
                    ResetGauge(message.Phase);
                }
                StatusText.Text = message.Phase switch
                {
                    "latency" => "Measuring HTTP latency...",
                    "latencyUnderLoad" => "Measuring latency under load...",
                    "download" => "Measuring download speed...",
                    "upload" => "Measuring upload speed...",
                    _ => "Measuring the internet connection..."
                };
                break;
            case "result":
                ShowResults(message);
                StatusText.Text = "Speed test complete. The official engine attempted to report results to Cloudflare.";
                SetRunning(false);
                ReleaseActivity();
                break;
            case "error":
                StatusText.Text = DescribeError(message);
                SetRunning(false);
                ReleaseActivity();
                break;
            case "cancelled":
                CompleteCancellation("Test cancelled. No completed results were recorded.");
                break;
        }
    }

    private static bool IsTrustedMessageSource(string source) =>
        Uri.TryCreate(source, UriKind.Absolute, out var uri)
        && uri.Scheme == Uri.UriSchemeHttps
        && uri.IsDefaultPort
        && string.Equals(uri.Host, VirtualHostName, StringComparison.OrdinalIgnoreCase)
        && string.Equals(uri.AbsolutePath, "/index.html", StringComparison.Ordinal);

    private void CoreWebView2_ProcessFailed(CoreWebView2 sender, CoreWebView2ProcessFailedEventArgs args)
    {
        _enginePageLoaded = false;
        try
        {
            sender.Stop();
            sender.Navigate("about:blank");
        }
        catch (Exception exception) when (exception is COMException or InvalidOperationException)
        {
            Debug.WriteLine(exception);
        }

        if (_session.IsActive && _session.RunId is { } runId)
        {
            FailWebViewRun(runId, new InvalidOperationException("The WebView2 measurement process stopped unexpectedly."));
        }
        else
        {
            StatusText.Text = "WebView2 stopped unexpectedly. Retry the speed test to create a new measurement session.";
        }
    }

    private void ShowResults(SpeedTestBridgeMessage message)
    {
        DownloadResultText.Text = (message.DownloadBps!.Value / 1_000_000)
            .ToString("0.##", CultureInfo.CurrentCulture);
        UploadResultText.Text = (message.UploadBps!.Value / 1_000_000)
            .ToString("0.##", CultureInfo.CurrentCulture);
        LatencyResultText.Text = message.LatencyMs!.Value.ToString("0.##", CultureInfo.CurrentCulture);
        LocationResultText.Text = message.Location is null
            ? "Serving location: Not provided by the Cloudflare engine."
            : $"Serving location: {message.Location}";
        ResultsCard.Visibility = Visibility.Visible;
    }

    private static string DescribeError(SpeedTestBridgeMessage message) => message.Category switch
    {
        "offline" => "This device is offline. Connect to the internet and retry.",
        "rate-limited" => "Cloudflare rate-limited this request. Wait before retrying; FingVibe will not bypass service limits.",
        "rejected" => $"Cloudflare rejected the measurement{FormatHttpStatus(message.HttpStatus)}. Retry later if appropriate.",
        "provider-unavailable" => $"Cloudflare is unavailable{FormatHttpStatus(message.HttpStatus)}. Retry later.",
        "timeout" => "The Cloudflare measurement timed out. Check the connection and retry.",
        "incomplete" => "Cloudflare did not return all required measurements. No successful result was recorded.",
        _ => $"The Cloudflare measurement failed: {message.ErrorMessage}"
    };

    private static string FormatHttpStatus(int? status) => status is null ? string.Empty : $" (HTTP {status})";

    private async Task CancelActiveTestAsync(string finalMessage)
    {
        var runId = _session.RunId;
        if (_cancellationTask is not null
            && string.Equals(_cancellationRunId, runId, StringComparison.Ordinal))
        {
            await _cancellationTask;
            return;
        }

        if (!_session.IsActive || runId is null)
        {
            return;
        }

        _session.RequestCancellation(runId);
        StatusText.Text = "Cancelling the Cloudflare measurement...";
        SetRunning(true, cancelling: true);
        var cancellationTask = CancelActiveTestCoreAsync(runId, finalMessage);
        _cancellationTask = cancellationTask;
        _cancellationRunId = runId;
        try
        {
            await cancellationTask;
        }
        finally
        {
            if (ReferenceEquals(_cancellationTask, cancellationTask))
            {
                _cancellationTask = null;
                _cancellationRunId = null;
            }
        }
    }

    private async Task CancelActiveTestCoreAsync(string runId, string finalMessage)
    {
        try
        {
            var core = EngineWebView.CoreWebView2;
            if (core is not null && _enginePageLoaded)
            {
                await core.ExecuteScriptAsync(
                    $"window.fingvibeSpeedTest.cancel({JsonSerializer.Serialize(runId)});");
            }

            if (_session.Status == SpeedTestSessionStatus.Cancelling)
            {
                CompleteCancellation(finalMessage);
            }
        }
        catch (Exception exception)
        {
            var core = EngineWebView.CoreWebView2;
            try
            {
                if (core is not null)
                {
                    core.Stop();
                    core.Navigate("about:blank");
                    _enginePageLoaded = false;
                }
            }
            catch (Exception navigationException) when (navigationException is COMException or InvalidOperationException)
            {
                Debug.WriteLine(navigationException);
            }

            if (_session.Status == SpeedTestSessionStatus.Cancelling)
            {
                CompleteCancellation(
                    $"Test cancelled and the WebView2 page was stopped. No completed results were recorded. {exception.Message}");
            }
        }
    }

    private void CompleteCancellation(string message)
    {
        StatusText.Text = message;
        SetRunning(false);
        ReleaseActivity();
    }

    private void FailWebViewRun(string runId, Exception exception)
    {
        if (!_session.IsActive || !string.Equals(_session.RunId, runId, StringComparison.Ordinal))
        {
            return;
        }

        if (_session.Status == SpeedTestSessionStatus.Cancelling)
        {
            CompleteCancellation("Test cancelled. No completed results were recorded.");
            return;
        }

        _session.Apply(new SpeedTestBridgeMessage("error", runId, Category: "measurement"));
        StatusText.Text = $"WebView2 could not run the Cloudflare measurement: {exception.Message}";
        SetRunning(false);
        ReleaseActivity();
    }

    private void SetRunning(bool isRunning, bool cancelling = false)
    {
        StartTestButton.IsEnabled = !isRunning;
        CancelTestButton.IsEnabled = isRunning && !cancelling;
        TestProgress.Visibility = isRunning ? Visibility.Visible : Visibility.Collapsed;
        LiveGaugeCard.Visibility = cancelling ? Visibility.Collapsed : Visibility.Visible;
        if (!isRunning || cancelling)
        {
            ResetGauge();
            GaugePhaseText.Text = "No active measurement";
        }
    }

    private void ResetGauge(string? phase = null)
    {
        _gaugeAnimation?.Stop();
        _gaugeAnimation = null;
        GaugeNeedle.Angle = -90;
        _gaugePhase = phase;
        _gaugeMaximumMbps = 100;
        GaugePhaseText.Text = phase switch
        {
            "download" => "Download - provisional",
            "upload" => "Upload - provisional",
            "latency" or "latencyUnderLoad" => "Measuring latency",
            _ => "Waiting for measurements"
        };
        GaugeValueText.Text = "-- Mbps";
        AutomationProperties.SetName(GaugeValueText, "Provisional Cloudflare speed: no sample");
        GaugeScaleText.Text = "Scale: 0-100 Mbps";
    }

    private void ShowGaugeSample(double bps)
    {
        var mbps = bps / 1_000_000;
        while (mbps > _gaugeMaximumMbps)
        {
            _gaugeMaximumMbps *= 10;
        }

        var angle = -90 + 180 * (mbps / _gaugeMaximumMbps);
        var previousAngle = GaugeNeedle.Angle;
        _gaugeAnimation?.Stop();
        GaugeNeedle.Angle = angle;
        if (new Windows.UI.ViewManagement.UISettings().AnimationsEnabled)
        {
            var animation = new DoubleAnimation
            {
                From = previousAngle,
                To = angle,
                Duration = new Duration(TimeSpan.FromMilliseconds(250)),
                EnableDependentAnimation = true
            };
            Storyboard.SetTarget(animation, GaugeNeedle);
            Storyboard.SetTargetProperty(animation, "Angle");
            _gaugeAnimation = new Storyboard();
            _gaugeAnimation.Children.Add(animation);
            _gaugeAnimation.Begin();
        }

        GaugeValueText.Text = $"{mbps.ToString("0.##", CultureInfo.CurrentCulture)} Mbps";
        AutomationProperties.SetName(GaugeValueText, $"{GaugePhaseText.Text}: {GaugeValueText.Text}");
        GaugeScaleText.Text = $"Scale: 0-{_gaugeMaximumMbps.ToString("N0", CultureInfo.CurrentCulture)} Mbps";
    }

    private void ResetResults()
    {
        ResetGauge();
        ResultsCard.Visibility = Visibility.Collapsed;
        DownloadResultText.Text = "—";
        UploadResultText.Text = "—";
        LatencyResultText.Text = "—";
        LocationResultText.Text = "Serving location: Not provided by the Cloudflare engine.";
    }

    private void ReleaseActivity()
    {
        _activityLease?.Dispose();
        _activityLease = null;
    }
}
