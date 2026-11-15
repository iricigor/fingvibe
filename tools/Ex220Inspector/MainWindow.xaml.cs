using System.ComponentModel;
using System.IO;
using System.Reflection;
using System.Text.Json;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;
using Microsoft.Web.WebView2.Core;

namespace Ex220Inspector;

public partial class MainWindow : Window
{
    private ClientCapture _capture = new();
    private readonly RouterLoginSession _login = new();
    private readonly DispatcherTimer _loginTimer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly string _profile = Path.Combine(Path.GetTempPath(), "FingVibe-Ex220-" + Guid.NewGuid().ToString("N"));
    private CoreWebView2Environment? _environment;
    private bool _closing;
    private bool _closed;
    private bool _busy;
    private Task _initialization = Task.CompletedTask;
    private string _loginScript = string.Empty;
    private string _loginState = "Other";
    private bool _loginProbeBusy;
    private int _navigationVersion;
    private ulong _navigationId;
    private bool _refreshing;
    private bool _manualLoginPanel;
    private int _recoveryVersion;

    public MainWindow()
    {
        InitializeComponent();
        DatabasePathInput.Text = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "FingVibe", "device-inventory.sqlite");
        _loginTimer.Tick += LoginTimer_Tick;
    }

    private void Window_Loaded(object sender, RoutedEventArgs e) =>
        _initialization = InitializeBrowserAsync();

    private async Task InitializeBrowserAsync()
    {
        try
        {
            _loginScript = await ReadScriptAsync("RouterLogin.js");
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
                if (!IsRouter(args.Uri))
                {
                    args.Cancel = true;
                    Status.Text = "Navigation blocked: this inspector only opens 192.168.0.1.";
                    return;
                }
                InvalidatePageWork();
                _navigationId = args.NavigationId;
                _loginState = "Other";
                CaptureButton.IsEnabled = false;
                UpdateLoginControls();
            };
            core.FrameNavigationStarting += (_, args) => args.Cancel = !IsRouter(args.Uri);
            core.NewWindowRequested += (_, args) => args.Handled = true;
            core.DownloadStarting += (_, args) =>
            {
                args.Cancel = true;
                Status.Text = "Downloads are disabled in the inspector.";
            };
            core.PermissionRequested += (_, args) => args.State = CoreWebView2PermissionState.Deny;
            core.NavigationCompleted += (_, args) =>
            {
                if (args.NavigationId != _navigationId || _closing) return;
                CaptureButton.IsEnabled = args.IsSuccess && !_busy && !_refreshing;
                UpdateAutomationControls();
                Status.Text = args.IsSuccess
                    ? "Log in, open a client table, choose its source above, and capture. Router configuration controls are live; do not change settings."
                    : $"Router navigation failed ({args.WebErrorStatus}). Check the router and try Forced refresh.";
            };
            core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All);
            core.WebResourceRequested += (_, args) =>
            {
                if (IsRouter(args.Request.Uri) || args.Request.Uri.StartsWith("data:", StringComparison.OrdinalIgnoreCase))
                    return;
                args.Response = _environment.CreateWebResourceResponse(null, 403, "External request blocked", "");
            };
            _loginTimer.Start();
            RefreshButton.IsEnabled = true;
            core.Navigate("http://192.168.0.1");
            await LoadDatabaseAsync();
        }
        catch (Exception exception) when (exception is WebView2RuntimeNotFoundException
            or System.Runtime.InteropServices.COMException or ArgumentException or InvalidOperationException
            or IOException or UnauthorizedAccessException)
        {
            Status.Text = $"Browser could not start: {exception.Message}. Install Microsoft Edge WebView2 Runtime if missing, then reopen.";
        }
    }

    private static bool IsRouter(string value) =>
        Uri.TryCreate(value, UriKind.Absolute, out var uri) &&
        uri.Host == "192.168.0.1" && uri.UserInfo.Length == 0 &&
        ((uri.Scheme == "http" && uri.Port == 80) || (uri.Scheme == "https" && uri.Port == 443));

    private async void Capture_Click(object sender, RoutedEventArgs e)
    {
        if (_busy || _refreshing || _automationCancellation is not null || Browser.CoreWebView2 is not { } core) return;
        _busy = true;
        CaptureButton.IsEnabled = false;
        UpdateAutomationControls();
        var source = (ClientSource)SourcePicker.SelectedIndex;
        var version = _navigationVersion;
        Status.Text = "Reading visible client table...";
        try
        {
            var script = await ReadScriptAsync("ExtractClients.js");
            var sourceJson = JsonSerializer.Serialize(source.ToString());
            var json = await core.ExecuteScriptAsync($"(() => {{ {script}\n return extractClients(document, {sourceJson}); }})()")
                .WaitAsync(TimeSpan.FromSeconds(5));
            if (_closing || version != _navigationVersion) return;
            var result = JsonSerializer.Deserialize<Extraction>(json)
                ?? throw new InvalidDataException("The router did not return an extraction result.");
            if (result.Tables.Length != 1)
                throw new InvalidDataException(result.Tables.Length == 0
                    ? $"No table matched {SourceName(source)}. Visible titles: {string.Join(", ", result.AvailableTitles)}. Open the intended section and wait for it to load."
                    : $"Multiple tables match {SourceName(source)}. Their titles are not unique; this capture was not saved.");
            var table = result.Tables[0];
            if (table.InvalidRows > 0)
                throw new InvalidDataException($"{table.InvalidRows} rows could not be parsed. This capture was not saved.");
            _capture.Add(source, table.Clients);
            InvalidateComparison();
            if (source == ClientSource.Wired) WiredComplete.IsChecked = false;
            RefreshRows();
            Status.Text = $"Captured {table.Clients.Length} visible rows as {SourceName(source)} at {DateTime.Now:T}. " +
                "Select the next page and capture again if the router paginates. Clear captures before starting a new snapshot.";
            await CompareCurrentAsync();
        }
        catch (Exception exception) when (exception is JsonException or InvalidDataException
            or InvalidOperationException or System.Runtime.InteropServices.COMException or TimeoutException)
        {
            if (!_closing && version == _navigationVersion)
                Status.Text = $"Capture failed: {exception.Message} Try Forced refresh if the router is stuck.";
        }
        finally
        {
            if (version == _navigationVersion)
            {
                _busy = false;
                if (!_closing) UpdateAutomationControls();
            }
        }
    }

    private void Clear_Click(object sender, RoutedEventArgs e)
    {
        if (_busy || _automationCancellation is not null) return;
        _capture.Clear();
        InvalidateComparison();
        WiredComplete.IsChecked = false;
        RefreshRows();
        Status.Text = "Captures cleared. Start a new snapshot by opening Client List.";
    }

    private void WiredComplete_Changed(object sender, RoutedEventArgs e) => RefreshRows();
    private void HideSameInDb_Changed(object sender, RoutedEventArgs e) => RefreshRows();

    private void RefreshRows()
    {
        if (ClientsGrid is null) return;
        var rows = _capture.Rows(WiredComplete.IsChecked == true).Select(row =>
            _databaseMatches.TryGetValue(row.Mac, out var match)
                ? row with { DbComparison = match.Status, DbName = match.Name, DbIp = match.Ip, DbDetails = match.Details }
                : row with { DbComparison = _loadedDatabasePath is null ? "DB not loaded" : "Not compared" }).ToArray();
        ClientsGrid.ItemsSource = ClientCapture.FilterRows(rows, HideSameInDb.IsChecked == true);
        CaptureSummary.Text = string.Join(" | ", Enum.GetValues<ClientSource>().Select(source =>
            $"{SourceName(source)}: {(_capture.Has(source) ? $"{_capture.Count(source)} captured" : "not captured")}"));
    }

    private static string SourceName(ClientSource source) => source switch
    {
        ClientSource.Clients => "Client List",
        ClientSource.Wired => "Wired Clients",
        _ => "ARP"
    };

    private static async Task<string> ReadScriptAsync(string name)
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream($"Ex220Inspector.{name}")
            ?? throw new InvalidOperationException($"Inspector script {name} is missing.");
        using var reader = new StreamReader(stream);
        return await reader.ReadToEndAsync();
    }

    private async void LoginTimer_Tick(object? sender, EventArgs e)
    {
        if (_closing || _refreshing || _loginProbeBusy || _busy ||
            _automationCancellation is not null || _signInCancellation is not null ||
            Browser.CoreWebView2 is not { } core) return;
        _loginProbeBusy = true;
        var version = _navigationVersion;
        try
        {
            var json = await core.ExecuteScriptAsync($"(() => {{ {_loginScript}\n return inspectRouterLogin(document); }})()")
                .WaitAsync(TimeSpan.FromSeconds(5));
            if (_closing || version != _navigationVersion) return;
            if (_automationCancellation is not null || _signInCancellation is not null) return;
            var probe = JsonSerializer.Deserialize<LoginProbe>(json)
                ?? throw new InvalidDataException("The router login state could not be read.");
            _loginState = probe.State;
            var action = _login.Observe(probe.State, probe.Error, DateTimeOffset.UtcNow);
            switch (action)
            {
                case LoginAction.Prompt:
                    if (!_manualLoginPanel)
                        ShowLoginPanel("The router is logged out. Enter its local password.");
                    break;
                case LoginAction.AutoLogin:
                    ShowLoginPanel("The session expired. Signing in with the password remembered for this run...");
                    await SubmitLoginAsync(null);
                    if (_closing || version != _navigationVersion) return;
                    break;
                case LoginAction.Failed:
                    ShowLoginPanel("Login was rejected or did not complete within 15 seconds. The remembered password was cleared. Check the router message and enter the password again.");
                    Status.Text = "Sign-in did not complete. No automatic retry will be made.";
                    break;
                case LoginAction.Authenticated:
                    if (!_manualLoginPanel)
                    {
                        LoginPanel.Visibility = Visibility.Collapsed;
                        LoginPassword.Clear();
                    }
                    Status.Text = _login.HasPassword
                        ? "Signed in. Password remembered in memory until you forget it or close the inspector."
                        : "Signed in. No password remembered.";
                    break;
            }
            UpdateLoginControls();
            UpdateAutomationControls();
            if (probe.State == "Locked")
            {
                LoginMessage.Text = "The router's login controls are locked or busy. Wait for the router before trying again.";
            }
            else if (probe.State == "UsernameRequired")
            {
                LoginMessage.Text = "This router requires a username. Use the router's own login form; password-only automatic login is unavailable.";
            }
        }
        catch (Exception exception) when (exception is JsonException or InvalidDataException
            or InvalidOperationException or System.Runtime.InteropServices.COMException or TimeoutException)
        {
            if (!_closing && version == _navigationVersion)
            {
                _loginTimer.Stop();
                Status.Text = "Login monitoring failed. Use Forced refresh to restore monitoring, or use the router's own login form.";
            }
        }
        finally
        {
            if (version == _navigationVersion) _loginProbeBusy = false;
        }
    }

    private void ShowLoginPanel(string message)
    {
        LoginMessage.Text = message;
        LoginPanel.Visibility = Visibility.Visible;
        UpdateLoginControls();
        if (IsActive && !_login.IsPending) LoginPassword.Focus();
    }

    private void PasswordPanel_Click(object sender, RoutedEventArgs e)
    {
        _manualLoginPanel = true;
        ShowLoginPanel(_loginState == "Login"
            ? "Enter the router password. It can be remembered for this run only."
            : "The router's local login form is not ready. Use Forced refresh if it is stuck.");
    }

    private async void SignIn_Click(object sender, RoutedEventArgs e) => await SignInAsync();

    private async void LoginPassword_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        e.Handled = true;
        await SignInAsync();
    }

    private async Task SignInAsync()
    {
        if (_closing || _refreshing || _login.IsPending) return;
        if (_loginState is not ("Login" or "Authenticated"))
        {
            LoginMessage.Text = "The local login form is not ready. Try Forced refresh or use the router's own login form.";
            return;
        }
        if (_loginState == "Login" && _automationCancellation is null && _signInCancellation is null && !ApplyClickDelay()) return;
        var password = LoginPassword.Password;
        if (password.Length == 0)
        {
            LoginMessage.Text = "Enter the router password before signing in.";
            return;
        }
        _login.Remember(RememberPassword.IsChecked == true ? password : null);
        LoginPassword.Clear();
        _manualLoginPanel = false;
        if (_loginState == "Authenticated")
        {
            LoginPanel.Visibility = Visibility.Collapsed;
            Status.Text = _login.HasPassword
                ? "Password remembered in memory for the next expired session. No login request was sent."
                : "No password remembered. The current router session is unchanged.";
            return;
        }
        var token = _automationCancellation?.Token ?? _signInCancellation?.Token ?? CancellationToken.None;
        var recovery = _recoveryVersion;
        try { await SubmitLoginAsync(password, token); }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            if (!_closing && recovery == _recoveryVersion) Status.Text = "Sign-in cancelled.";
        }
    }

    private async Task SubmitLoginAsync(string? enteredPassword, CancellationToken token = default)
    {
        if (_closing || _refreshing || _login.IsPending || Browser.CoreWebView2 is not { } core) return;
        var password = enteredPassword ?? _login.PasswordForLogin;
        if (password is null) return;
        var version = _navigationVersion;
        _login.Submitted(DateTimeOffset.UtcNow);
        _loginSubmissionFailure = null;
        SignInButton.IsEnabled = false;
        LoginMessage.Text = "Signing in...";
        Status.Text = $"{AttemptPrefix}submitting one local sign-in attempt...";
        UpdateAutomationControls();
        try
        {
            await _clickPacer.WaitAsync(token);
            if (_closing || version != _navigationVersion) return;
            token.ThrowIfCancellationRequested();
            _login.Submitted(DateTimeOffset.UtcNow);
            if (!IsRouter(core.Source))
                throw new InvalidOperationException("Router login is not on the allowed origin.");
            var jsonPassword = JsonSerializer.Serialize(password);
            var json = await core.ExecuteScriptAsync($"(() => {{ {_loginScript}\n return submitRouterLogin(document, {jsonPassword}); }})()")
                .WaitAsync(TimeSpan.FromSeconds(5), token);
            if (_closing || version != _navigationVersion) return;
            if (!JsonSerializer.Deserialize<bool>(json))
                throw new InvalidOperationException("The local password form is not available.");
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            if (!_closing && version == _navigationVersion) _login.FailSubmission(retainPassword: true);
            throw;
        }
        catch (Exception exception) when (exception is JsonException or InvalidOperationException
            or System.Runtime.InteropServices.COMException or TimeoutException)
        {
            if (_closing || version != _navigationVersion) return;
            _loginSubmissionFailure = exception;
            var retaining = exception is TimeoutException &&
                (_automationCancellation is not null || _signInCancellation is not null);
            _login.FailSubmission(retainPassword: retaining);
            if (!_closing)
            {
                ShowLoginPanel(retaining
                    ? "Sign-in submission timed out. The capture can retry with this run's remembered password."
                    : "Sign-in could not be submitted. The remembered password was cleared. Use the router page or try again when its local login form is ready.");
                Status.Text = retaining
                    ? "Local sign-in submission timed out. The bounded capture retry policy applies."
                    : "Local sign-in submission failed. No automatic retry will be made.";
            }
        }
        finally
        {
            if (!_closing)
            {
                UpdateLoginControls();
                UpdateAutomationControls();
            }
        }
    }

    private void DismissLogin_Click(object sender, RoutedEventArgs e)
    {
        _login.DismissPrompt();
        CancelCapture_Click(sender, e);
        _manualLoginPanel = false;
        LoginPassword.Clear();
        LoginPanel.Visibility = Visibility.Collapsed;
    }

    private void ForgetPassword_Click(object sender, RoutedEventArgs e)
    {
        _login.Forget();
        LoginPassword.Clear();
        Status.Text = "Remembered password cleared from this inspector. The current router session remains signed in.";
    }

    private void RememberPassword_Changed(object sender, RoutedEventArgs e)
    {
        if (RememberPassword?.IsChecked == false) _login.Forget();
        UpdateLoginControls();
    }

    private void UpdateLoginControls()
    {
        if (SignInButton is null) return;
        var authenticated = _loginState == "Authenticated";
        SignInButton.Content = authenticated ? "Remember password" : "Sign in";
        SignInButton.IsEnabled = !_refreshing && !_login.IsPending &&
            (_loginState == "Login" || authenticated && RememberPassword.IsChecked == true);
        if (authenticated && _manualLoginPanel)
            LoginMessage.Text = "Already signed in. Enter a password to remember for the next expired session; it will not be sent now.";
    }

    private void InvalidatePageWork()
    {
        _navigationVersion++;
        _busy = false;
        _loginProbeBusy = false;
    }

    private async void ForcedRefresh_Click(object sender, RoutedEventArgs e)
    {
        if (_closing || _refreshing || Browser.CoreWebView2 is not { } core) return;
        _refreshing = true;
        _recoveryVersion++;
        CancelCapture_Click(sender, e);
        RefreshButton.IsEnabled = false;
        CaptureButton.IsEnabled = false;
        _loginTimer.Stop();
        InvalidatePageWork();
        _navigationId = 0;
        _login.ResetForRefresh();
        _loginState = "Other";
        _manualLoginPanel = false;
        LoginPassword.Clear();
        LoginPanel.Visibility = Visibility.Collapsed;
        UpdateLoginControls();
        Status.Text = "Stopping pending work and clearing cached router resources. Captures and remembered password are kept...";
        try
        {
            core.Stop();
            await core.CallDevToolsProtocolMethodAsync("Network.clearBrowserCache", "{}")
                .WaitAsync(TimeSpan.FromSeconds(5));
            if (_closing) return;
            core.Navigate("http://192.168.0.1");
            _loginTimer.Start();
            Status.Text = "Forced refresh requested. Reopening the router start page; return to the desired table after it loads.";
        }
        catch (Exception exception) when (exception is InvalidOperationException
            or System.Runtime.InteropServices.COMException or TimeoutException)
        {
            if (!_closing)
                Status.Text = "Forced refresh failed. The browser did not reset successfully; try again or close and reopen the inspector.";
        }
        finally
        {
            _refreshing = false;
            if (!_closing) RefreshButton.IsEnabled = true;
            if (!_closing) UpdateAutomationControls();
        }
    }

    private async void Window_Closing(object? sender, CancelEventArgs e)
    {
        if (_closed) return;
        e.Cancel = true;
        if (_closing) return;
        _closing = true;
        _automationCancellation?.Cancel();
        _signInCancellation?.Cancel();
        _databaseCancellation?.Cancel();
        _loginTimer.Stop();
        _login.Forget();
        LoginPassword.Clear();
        CaptureButton.IsEnabled = false;
        RefreshButton.IsEnabled = false;
        Status.Text = "Closing browser and removing its temporary login profile...";
        await _initialization;
        var exited = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (_environment is not null)
            _environment.BrowserProcessExited += (_, _) => exited.TrySetResult();
        var hadBrowser = Browser.CoreWebView2 is not null;
        Browser.Dispose();
        if (hadBrowser)
            await Task.WhenAny(exited.Task, Task.Delay(TimeSpan.FromSeconds(10)));
        try
        {
            if (Directory.Exists(_profile)) Directory.Delete(_profile, recursive: true);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            MessageBox.Show($"The temporary browser profile could not be removed. It may contain login cookies. " +
                $"Remove this specific folder after the browser exits:\n{_profile}\n\n{exception.Message}",
                "Profile cleanup failed", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        _closed = true;
        Close();
    }

    private sealed record Extraction(ExtractedTable[] Tables, string[] AvailableTitles);
    private sealed record ExtractedTable(string Title, RouterClient[] Clients, int InvalidRows, int PageNumber, int PageCount);
    private sealed record LoginProbe(string State, bool Error);
}
