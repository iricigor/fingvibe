using System.ComponentModel;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text.Json;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;
using Ex220Inspector;
using Microsoft.Web.WebView2.Core;
using Microsoft.Win32;

namespace DecoX50Inspector;

public partial class MainWindow : Window
{
    private readonly RouterLoginSession _login = new();
    private readonly InspectorClickPacer _pacer = new();
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly string _profile = Path.Combine(Path.GetTempPath(), "FingVibe-DecoX50-" + Guid.NewGuid().ToString("N"));
    private CoreWebView2Environment? _environment;
    private DecoSnapshot? _snapshot;
    private CancellationTokenSource? _operation;
    private Task _initialization = Task.CompletedTask;
    private string _scripts = "";
    private string? _approvedCertificate;
    private string? _rejectedCertificate;
    private bool _closing;
    private bool _closed;
    private bool _refreshing;
    private bool _loginBusy;
    private bool _probing;
    private bool _exporting;
    private int _version;
    private int _pageVersion;

    public MainWindow()
    {
        InitializeComponent();
        DatabasePath.Text = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "FingVibe", "device-inventory.sqlite");
        _timer.Tick += LoginTimer_Tick;
    }

    private void Window_Loaded(object sender, RoutedEventArgs e) => _initialization = InitializeAsync();

    private async Task InitializeAsync()
    {
        try
        {
            foreach (var name in new[] { "ExtractDecoClients.js", "RouterLogin.js" })
            {
                using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream($"DecoX50Inspector.{name}")
                    ?? throw new InvalidOperationException($"Missing inspector script {name}.");
                using var reader = new StreamReader(stream);
                _scripts += await reader.ReadToEndAsync() + "\n";
            }
            _environment = await CoreWebView2Environment.CreateAsync(userDataFolder: _profile);
            if (_closing) return;
            await Browser.EnsureCoreWebView2Async(_environment);
            if (_closing) return;
            var core = Browser.CoreWebView2;
            core.Settings.IsPasswordAutosaveEnabled = false;
            core.Settings.IsGeneralAutofillEnabled = false;
            core.Settings.AreDevToolsEnabled = false;
            core.Settings.AreDefaultContextMenusEnabled = false;
            core.NavigationStarting += (_, args) =>
            {
                if (!DecoRouterPolicy.IsRouter(args.Uri))
                {
                    args.Cancel = true;
                    Status.Text = "Navigation blocked: only HTTPS on 192.168.0.100:443 is allowed.";
                }
                else _pageVersion++;
            };
            core.FrameNavigationStarting += (_, args) => args.Cancel = !DecoRouterPolicy.IsRouter(args.Uri);
            core.NewWindowRequested += (_, args) => args.Handled = true;
            core.DownloadStarting += (_, args) =>
            {
                args.Cancel = true;
                Status.Text = "Router downloads are disabled. Use Export full snapshot to save captured clients.";
            };
            core.PermissionRequested += (_, args) => args.State = CoreWebView2PermissionState.Deny;
            core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All);
            core.WebResourceRequested += (_, args) =>
            {
                if (DecoRouterPolicy.IsRouter(args.Request.Uri) ||
                    args.Request.Uri.StartsWith("data:", StringComparison.OrdinalIgnoreCase)) return;
                args.Response = _environment.CreateWebResourceResponse(null, 403, "External request blocked", "");
            };
            core.ServerCertificateErrorDetected += CertificateError;
            core.NavigationCompleted += (_, args) =>
            {
                if (_closing) return;
                if (_operation is null && !_refreshing)
                    Status.Text = args.IsSuccess
                        ? "Sign in locally, then capture connected clients. Router configuration controls remain live."
                        : $"Deco navigation failed ({args.WebErrorStatus}). Check certificate trust and use Forced refresh.";
                UpdateControls();
            };
            core.Navigate(DecoRouterPolicy.SourceUrl);
            _timer.Start();
            UpdateControls();
        }
        catch (Exception exception) when (BrowserFailure(exception) || exception is WebView2RuntimeNotFoundException
            or IOException or UnauthorizedAccessException)
        {
            Status.Text = $"Browser startup failed: {exception.Message}. Check the Edge WebView2 Runtime and reopen.";
        }
    }

    private void CertificateError(object? sender, CoreWebView2ServerCertificateErrorDetectedEventArgs args)
    {
        args.Action = CoreWebView2ServerCertificateErrorAction.Cancel;
        if (_closing || !DecoRouterPolicy.IsRouter(args.RequestUri)) return;
        try
        {
            var pem = args.ServerCertificate.ToPemEncoding();
            var fingerprint = DecoRouterPolicy.Fingerprint(pem);
            if (DecoRouterPolicy.IsTrusted(args.RequestUri, fingerprint, _approvedCertificate))
            {
                args.Action = CoreWebView2ServerCertificateErrorAction.AlwaysAllow;
                return;
            }
            if (fingerprint == _rejectedCertificate) return;
            using var certificate = X509Certificate2.CreateFromPem(pem);
            var approved = MessageBox.Show(this,
                $"Windows could not validate the Deco certificate ({args.ErrorStatus}).\n\n" +
                $"Router: 192.168.0.100:443\nSubject: {certificate.Subject}\nIssuer: {certificate.Issuer}\n" +
                $"Valid: {certificate.NotBefore:u} to {certificate.NotAfter:u}\n\nSHA-256:\n{fingerprint}\n\n" +
                "Only continue if you recognize this router and certificate. Trust this exact certificate " +
                "inside this inspector until it closes? No Windows/global trust settings will change.",
                "Approve this Deco certificate?", MessageBoxButton.YesNo, MessageBoxImage.Warning,
                MessageBoxResult.No) == MessageBoxResult.Yes;
            if (approved)
            {
                _approvedCertificate = fingerprint;
                _rejectedCertificate = null;
                args.Action = CoreWebView2ServerCertificateErrorAction.AlwaysAllow;
                Status.Text = "Approved this exact Deco certificate for this inspector session only.";
            }
            else
            {
                _rejectedCertificate = fingerprint;
                Status.Text = "Deco certificate declined. Forced refresh allows another trust decision.";
            }
        }
        catch (Exception exception) when (exception is CryptographicException or COMException or ArgumentException)
        {
            Status.Text = $"Certificate inspection failed: {exception.Message}. The request was blocked.";
        }
    }

    private static bool BrowserFailure(Exception exception) =>
        exception is COMException or InvalidOperationException or JsonException or TimeoutException or ArgumentException;

    private async Task<T> EvaluateAsync<T>(string expression, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var core = Browser.CoreWebView2 ?? throw new InvalidOperationException("The browser is not ready.");
        if (!DecoRouterPolicy.IsRouter(core.Source)) throw new InvalidOperationException("The router origin is not allowed.");
        var page = _pageVersion;
        var version = _version;
        var json = await core.ExecuteScriptAsync(
            $"(() => {{ {_scripts}\ntry {{ return {{Value: {expression}}}; }} " +
            "catch(error) { return {Error: error.message}; } })()")
            .WaitAsync(TimeSpan.FromSeconds(5), token);
        token.ThrowIfCancellationRequested();
        if (page != _pageVersion || version != _version)
            throw new InspectorTransientCaptureException("The Deco navigated or refreshed during a read.");
        using var result = JsonDocument.Parse(json);
        if (result.RootElement.TryGetProperty("Error", out var error))
            throw new InvalidDataException(error.GetString() ?? "The Deco page inspection failed.");
        return result.RootElement.GetProperty("Value").Deserialize<T>()
            ?? throw new InvalidDataException("The Deco page did not return the expected result.");
    }

    private bool ApplyPacing()
    {
        if (!int.TryParse(ClickDelayInput.Text, NumberStyles.None, CultureInfo.InvariantCulture, out var delay) ||
            delay is < 0 or > 10000)
        {
            Status.Text = "Click delay must be an integer from 0 to 10000 milliseconds.";
            return false;
        }
        _pacer.Delay = TimeSpan.FromMilliseconds(delay);
        return true;
    }

    private async void Capture_Click(object sender, RoutedEventArgs e)
    {
        if (_operation is not null || _loginBusy || _refreshing || !ApplyPacing()) return;
        var version = _version;
        using var cancellation = new CancellationTokenSource();
        _operation = cancellation;
        UpdateControls();
        try
        {
            var snapshot = await DecoCaptureRunner.CaptureAsync(PrepareAsync,
                token => EvaluateAsync<DecoProbe>("readDecoClients(document)", token),
                (attempt, message) =>
                {
                    if (!_closing && version == _version) Status.Text = $"Attempt {attempt}/5: {message}";
                }, cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            if (_closing || version != _version) return;
            _snapshot = snapshot;
            InvalidateComparison();
            RefreshRows();
            Status.Text = $"Captured {snapshot.ClientCount} clients. JSON export saves this entire snapshot.";
            await CompareAsync();
        }
        catch (OperationCanceledException)
        {
            if (!_closing && version == _version) Status.Text = "Capture cancelled. The previous completed snapshot was kept.";
        }
        catch (Exception exception) when (BrowserFailure(exception) || exception is IOException or UnauthorizedAccessException)
        {
            if (!_closing && version == _version)
                Status.Text = $"Capture failed: {exception.Message} Previous capture kept; use the router page or Forced refresh.";
        }
        finally
        {
            if (ReferenceEquals(_operation, cancellation)) _operation = null;
            if (!_closing) UpdateControls();
        }
    }

    private async Task PrepareAsync(CancellationToken token)
    {
        await EnsureSignedInAsync(token);
        var core = Browser.CoreWebView2 ?? throw new InvalidOperationException("The browser is not ready.");
        await _pacer.WaitAsync(token);
        var loaded = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        void Completed(object? sender, CoreWebView2NavigationCompletedEventArgs args) =>
            loaded.TrySetResult(args.IsSuccess);
        core.NavigationCompleted += Completed;
        try
        {
            core.Navigate(DecoRouterPolicy.SourceUrl);
            if (!await loaded.Task.WaitAsync(TimeSpan.FromSeconds(15), token))
                throw new IOException("The Deco page could not load. Check certificate trust and the router connection.");
        }
        finally { core.NavigationCompleted -= Completed; }
        var start = DateTimeOffset.UtcNow;
        while (DateTimeOffset.UtcNow - start < TimeSpan.FromSeconds(15))
        {
            await _pacer.WaitAsync(token);
            if (await EvaluateAsync<bool>("openDecoClients(document)", token)) return;
            await Task.Delay(300, token);
        }
        throw new TimeoutException("The Deco client-page control did not become ready.");
    }

    private async Task EnsureSignedInAsync(CancellationToken token)
    {
        var start = DateTimeOffset.UtcNow;
        while (DateTimeOffset.UtcNow - start < TimeSpan.FromMinutes(2))
        {
            var probe = await EvaluateAsync<LoginProbe>("inspectDecoLogin(document)", token);
            if (probe.State == "Authenticated")
            {
                _login.Observe(probe.State, false, DateTimeOffset.UtcNow);
                LoginPanel.Visibility = Visibility.Collapsed;
                LoginPassword.Clear();
                return;
            }
            if (probe.Error || probe.State is "Locked" or "Unsupported")
            {
                _login.FailSubmission();
                throw new InvalidDataException("Deco login was rejected, locked, or unsupported. Use the router page; automatic retries stopped.");
            }
            if (_login.IsPending)
            {
                if (_login.Observe(probe.State, probe.Error, DateTimeOffset.UtcNow,
                    retainPasswordOnTimeout: true) == LoginAction.Failed)
                    throw new TimeoutException("Deco sign-in did not finish within 15 seconds.");
            }
            else if (probe.State == "Login" && !_loginBusy)
            {
                if (_login.PasswordForLogin is { } password) await SubmitLoginAsync(password, token);
                else
                {
                    LoginPanel.Visibility = Visibility.Visible;
                    LoginMessage.Text = "Capture is waiting for local sign-in. Enter the password here or use the router page.";
                }
            }
            await Task.Delay(300, token);
        }
        throw new InvalidDataException("Local sign-in was not completed within two minutes. Capture stopped.");
    }

    private async Task SubmitLoginAsync(string password, CancellationToken token)
    {
        if (_loginBusy) return;
        var version = _version;
        _loginBusy = true;
        UpdateControls();
        try
        {
            await _pacer.WaitAsync(token);
            if (_closing || _refreshing || version != _version)
                throw new InspectorTransientCaptureException("Login stopped because the inspector refreshed.");
            if (!await EvaluateAsync<bool>($"submitDecoLogin(document, {JsonSerializer.Serialize(password)})", token))
            {
                _login.FailSubmission();
                throw new InvalidDataException("The known Deco local password form is not ready; no login was submitted.");
            }
            _login.Submitted(DateTimeOffset.UtcNow);
            LoginMessage.Text = "Local sign-in submitted. Waiting for the router...";
        }
        catch (OperationCanceledException)
        {
            if (version == _version) _login.FailSubmission(retainPassword: true);
            throw;
        }
        catch (TimeoutException)
        {
            if (version == _version) _login.FailSubmission(retainPassword: _operation is not null);
            throw;
        }
        catch (Exception exception) when (BrowserFailure(exception) || exception is IOException)
        {
            if (version == _version) _login.FailSubmission();
            throw;
        }
        finally
        {
            _loginBusy = false;
            if (!_closing) UpdateControls();
        }
    }

    private async void Login_Click(object sender, RoutedEventArgs e) => await LoginAsync();

    private async void LoginPassword_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        e.Handled = true;
        await LoginAsync();
    }

    private async Task LoginAsync()
    {
        if (_loginBusy || _login.IsPending || _refreshing || _closing) return;
        if (_operation is null && !ApplyPacing()) return;
        var password = LoginPassword.Password;
        if (password.Length == 0)
        {
            LoginMessage.Text = "Enter the local Deco password.";
            return;
        }
        var version = _version;
        try
        {
            _login.Remember(RememberPassword.IsChecked == true ? password : null);
            LoginPassword.Clear();
            var token = _operation?.Token ?? CancellationToken.None;
            var probe = await EvaluateAsync<LoginProbe>("inspectDecoLogin(document)", token);
            if (probe.State == "Authenticated")
            {
                LoginPanel.Visibility = Visibility.Collapsed;
                Status.Text = "Already signed in. Password memory updated; no request was sent.";
            }
            else await SubmitLoginAsync(password, token);
        }
        catch (OperationCanceledException)
        {
            if (!_closing && version == _version) Status.Text = "Local sign-in cancelled.";
        }
        catch (Exception exception) when (BrowserFailure(exception) || exception is IOException)
        {
            if (!_closing && version == _version)
                Status.Text = $"Local sign-in failed: {exception.Message}. Use the router page or Forced refresh.";
        }
    }

    private async void LoginTimer_Tick(object? sender, EventArgs e)
    {
        if (_closing || _refreshing || _operation is not null || _loginBusy || _probing ||
            Browser.CoreWebView2 is null) return;
        _probing = true;
        var version = _version;
        try
        {
            var probe = await EvaluateAsync<LoginProbe>("inspectDecoLogin(document)", CancellationToken.None);
            if (_closing || version != _version || _operation is not null) return;
            if (probe.State is "Locked" or "Unsupported" || probe.Error)
            {
                _login.FailSubmission();
                LoginMessage.Text = "Login rejected, locked, or unsupported. Use the router page; remembered password cleared.";
                Status.Text = LoginMessage.Text;
                return;
            }
            var action = _login.Observe(probe.State, probe.Error, DateTimeOffset.UtcNow);
            if (action == LoginAction.Prompt) LoginPanel.Visibility = Visibility.Visible;
            else if (action == LoginAction.Authenticated)
            {
                LoginPanel.Visibility = Visibility.Collapsed;
                LoginPassword.Clear();
            }
            else if (action == LoginAction.AutoLogin && _login.PasswordForLogin is { } password)
                await SubmitLoginAsync(password, CancellationToken.None);
            else if (action == LoginAction.Failed)
            {
                LoginPanel.Visibility = Visibility.Visible;
                LoginMessage.Text = "Sign-in timed out. Password memory cleared; enter it again or use the router page.";
            }
        }
        catch (Exception exception) when (BrowserFailure(exception) || exception is IOException)
        {
            if (!_closing && version == _version)
            {
                _timer.Stop();
                Status.Text = $"Login monitoring failed: {exception.Message}. Use Forced refresh to restart it.";
            }
        }
        finally
        {
            _probing = false;
            if (!_closing) UpdateControls();
        }
    }

    private void Password_Click(object sender, RoutedEventArgs e)
    {
        LoginPanel.Visibility = Visibility.Visible;
        LoginMessage.Text = "Enter a password for local sign-in or remember it for this session while already signed in.";
    }

    private void DismissLogin_Click(object sender, RoutedEventArgs e)
    {
        _login.DismissPrompt();
        LoginPassword.Clear();
        LoginPanel.Visibility = Visibility.Collapsed;
    }

    private void ForgetPassword_Click(object sender, RoutedEventArgs e)
    {
        _login.Forget();
        LoginPassword?.Clear();
        if (Status is not null) Status.Text = "Password memory cleared. The router session is unchanged.";
    }

    private void Cancel_Click(object sender, RoutedEventArgs e) => _operation?.Cancel();

    private async void Refresh_Click(object sender, RoutedEventArgs e)
    {
        if (_refreshing || _closing || Browser.CoreWebView2 is not { } core) return;
        _refreshing = true;
        _version++;
        _operation?.Cancel();
        _timer.Stop();
        _login.ResetForRefresh();
        _rejectedCertificate = null;
        LoginPassword.Clear();
        UpdateControls();
        try
        {
            core.Stop();
            await core.CallDevToolsProtocolMethodAsync("Network.clearBrowserCache", "{}")
                .WaitAsync(TimeSpan.FromSeconds(5));
            if (_closing) return;
            core.Navigate(DecoRouterPolicy.SourceUrl);
            _timer.Start();
            Status.Text = "Forced refresh requested. Previous snapshot, remembered password and approved certificate kept.";
        }
        catch (Exception exception) when (BrowserFailure(exception))
        {
            if (!_closing) Status.Text = $"Forced refresh failed: {exception.Message}. Try again or reopen the inspector.";
        }
        finally
        {
            _refreshing = false;
            if (!_closing) UpdateControls();
        }
    }

    private async void Export_Click(object sender, RoutedEventArgs e)
    {
        if (_exporting || _snapshot is not { } snapshot) return;
        var dialog = new SaveFileDialog
        {
            Filter = "JSON snapshot (*.json)|*.json", DefaultExt = ".json", AddExtension = true,
            FileName = $"deco-x50-{snapshot.CapturedAtUtc:yyyyMMdd-HHmmss}.json"
        };
        if (dialog.ShowDialog(this) != true) return;
        _exporting = true;
        UpdateControls();
        try
        {
            await snapshot.ExportAsync(dialog.FileName, CancellationToken.None);
            if (!_closing) Status.Text = $"Exported all {snapshot.ClientCount} captured clients to {dialog.FileName}.";
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
            or JsonException or ArgumentException or NotSupportedException)
        {
            if (!_closing) Status.Text = $"JSON export failed: {exception.Message}. No successful export is claimed.";
        }
        finally
        {
            _exporting = false;
            if (!_closing) UpdateControls();
        }
    }

    private void Filter_Changed(object sender, RoutedEventArgs e) => RefreshRows();

    private void RefreshRows()
    {
        if (ClientsGrid is null) return;
        var rows = (_snapshot?.ComparisonRows() ?? []).Select(row =>
            _matches.TryGetValue(row.Mac, out var match)
                ? row with { DbComparison = match.Status, DbName = match.Name, DbIp = match.Ip, DbDetails = match.Details }
                : row with { DbComparison = _database is null ? "DB not loaded" : "Not compared" }).ToArray();
        ClientsGrid.ItemsSource = ClientCapture.FilterRows(rows, HideSame.IsChecked == true);
        CaptureSummary.Text = _snapshot is null ? "No completed capture." :
            $"{_snapshot.ClientCount} clients captured at {_snapshot.CapturedAtUtc.ToLocalTime():G}. " +
            "Capture times can differ from EX220 and the saved database; absence does not prove offline.";
        UpdateControls();
    }

    private void UpdateControls()
    {
        if (CaptureButton is null) return;
        var available = !_closing && !_refreshing && Browser.CoreWebView2 is not null;
        CaptureButton.IsEnabled = available && _operation is null && !_loginBusy;
        CancelButton.IsEnabled = available && _operation is not null;
        RefreshButton.IsEnabled = available;
        ClickDelayInput.IsEnabled = available && _operation is null && !_loginBusy;
        LoginButton.IsEnabled = available && !_loginBusy && !_login.IsPending;
        ExportButton.IsEnabled = !_closing && !_exporting && _snapshot is not null;
    }

    private async void Window_Closing(object? sender, CancelEventArgs e)
    {
        if (_closed) return;
        e.Cancel = true;
        if (_closing) return;
        _closing = true;
        _version++;
        _operation?.Cancel();
        _databaseCancellation?.Cancel();
        _timer.Stop();
        _login.Forget();
        LoginPassword.Clear();
        _approvedCertificate = null;
        UpdateControls();
        await _initialization;
        var exited = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (_environment is not null) _environment.BrowserProcessExited += (_, _) => exited.TrySetResult();
        var hadBrowser = Browser.CoreWebView2 is not null;
        Browser.Dispose();
        if (hadBrowser) await Task.WhenAny(exited.Task, Task.Delay(TimeSpan.FromSeconds(10)));
        try
        {
            if (Directory.Exists(_profile)) Directory.Delete(_profile, recursive: true);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            MessageBox.Show(this, $"The temporary browser profile may contain login cookies. Remove only this folder " +
                $"after its browser processes exit:\n{_profile}\n\n{exception.Message}",
                "Profile cleanup failed", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        _closed = true;
        Close();
    }

    private sealed record LoginProbe(string State, bool Error);
}
