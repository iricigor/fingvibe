using System.IO;
using System.Text.Json;
using System.Windows;

namespace Ex220Inspector;

public partial class MainWindow : IInspectorCaptureBrowser
{
    private CancellationTokenSource? _automationCancellation;
    private CancellationTokenSource? _signInCancellation;
    private string _captureScripts = "";
    private readonly InspectorClickPacer _clickPacer = new();
    private static readonly InspectorCaptureRetryPolicy RetryPolicy = new(5, TimeSpan.FromSeconds(2));
    private Exception? _loginSubmissionFailure;
    private InspectorCaptureProgress? _captureProgress;

    private string AttemptPrefix => _captureProgress is { } item
        ? $"{SourceName(item.Source)} attempt {item.Attempt}/{item.MaximumAttempts}: " : "";

    private bool ApplyClickDelay()
    {
        if (!int.TryParse(ClickDelayInput.Text, out var milliseconds) || milliseconds is < 0 or > 10_000)
        {
            Status.Text = "Enter a click delay from 0 to 10000 milliseconds.";
            ClickDelayInput.Focus();
            return false;
        }
        _clickPacer.Delay = TimeSpan.FromMilliseconds(milliseconds);
        return true;
    }

    private async Task<T> BrowserValueAsync<T>(string expression, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var core = Browser.CoreWebView2 ?? throw new InvalidOperationException("The router browser is not ready.");
        if (!IsRouter(core.Source)) throw new InvalidOperationException("The browser is not on the allowed router origin.");
        if (_captureScripts.Length == 0)
            _captureScripts = await ReadScriptAsync("ExtractClients.js") + "\n" +
                await ReadScriptAsync("RouterNavigation.js") + "\n" + _loginScript;
        token.ThrowIfCancellationRequested();
        var json = await core.ExecuteScriptAsync($"(() => {{ {_captureScripts}\n try {{ return {{ Ok: true, Value: {expression} }}; }} catch (error) {{ return {{ Ok: false, Error: error.message }}; }} }})()")
            .WaitAsync(TimeSpan.FromSeconds(5), token);
        token.ThrowIfCancellationRequested();
        var result = JsonSerializer.Deserialize<BrowserScriptResult<T>>(json)
            ?? throw new InvalidDataException("The router script did not return an inspection result.");
        if (!result.Ok)
            throw new InvalidDataException(result.Error ?? "The required router controls could not be identified.");
        return result.Value ?? throw new InvalidDataException("The router returned an empty inspection result.");
    }

    private async Task WaitForAsync(Func<Task<bool>> ready, TimeSpan timeout, CancellationToken token)
    {
        var deadline = DateTimeOffset.UtcNow + timeout;
        while (true)
        {
            token.ThrowIfCancellationRequested();
            if (await ready()) return;
            if (DateTimeOffset.UtcNow >= deadline)
                throw new TimeoutException("The expected router page or login state did not become ready.");
            await Task.Delay(150, token);
        }
    }

    public async Task EnsureSignedInAsync(CancellationToken token)
    {
        _loginSubmissionFailure = null;
        var probe = await BrowserValueAsync<LoginProbe>("inspectRouterLogin(document)", token);
        if (probe.State == "Authenticated")
        {
            _loginState = probe.State;
            _login.Observe(probe.State, probe.Error, DateTimeOffset.UtcNow);
            UpdateLoginControls();
            return;
        }
        if (probe.State == "Other")
        {
            Browser.CoreWebView2.Navigate("http://192.168.0.1");
            await WaitForAsync(async () =>
            {
                probe = await BrowserValueAsync<LoginProbe>("inspectRouterLogin(document)", token);
                return probe.State != "Other";
            }, TimeSpan.FromSeconds(15), token);
        }
        if (probe.State == "Authenticated")
        {
            _loginState = probe.State;
            _login.Observe(probe.State, probe.Error, DateTimeOffset.UtcNow);
            UpdateLoginControls();
            return;
        }
        CheckLoginBlocked(probe);
        _loginState = probe.State;
        _login.ResetForRefresh();
        _loginTimer.Start();
        if (_login.HasPassword && probe.State == "Login")
            await SubmitLoginAsync(null, token);
        else
            ShowLoginPanel("Sign in to continue. Enter the local password; Cancel or Forced refresh stops the pending operation.");
        await WaitForAsync(async () =>
        {
            probe = await BrowserValueAsync<LoginProbe>("inspectRouterLogin(document)", token);
            _loginState = probe.State;
            if (_loginSubmissionFailure is { } failure)
            {
                if (failure is TimeoutException) throw new TimeoutException("Local login submission timed out.", failure);
                throw new InvalidOperationException("The local login could not be submitted; automatic retries stopped.", failure);
            }
            CheckLoginBlocked(probe);
            var action = _login.Observe(probe.State, probe.Error, DateTimeOffset.UtcNow, retainPasswordOnTimeout: true);
            if (action == LoginAction.Failed)
            {
                UpdateLoginControls();
                if (probe.Error || probe.State == "Locked")
                {
                    _login.Forget();
                    ShowLoginPanel("Login was rejected or locked. Automatic retries stopped; check the router before entering a password again.");
                    throw new InvalidOperationException("Login was rejected or locked; automatic retries stopped.");
                }
                ShowLoginPanel("Login timed out. A capture retry can reuse the password remembered for this run.");
                throw new TimeoutException("Local login did not complete within 15 seconds.");
            }
            UpdateLoginControls();
            return probe.State == "Authenticated";
        }, TimeSpan.FromMinutes(2), token);
        _loginState = "Authenticated";
        LoginPanel.Visibility = Visibility.Collapsed;
        LoginPassword.Clear();
        _manualLoginPanel = false;
    }

    private void CheckLoginBlocked(LoginProbe probe)
    {
        if (probe.State == "UsernameRequired")
            throw new InvalidOperationException("Use the router's own username/password form; automatic retries stopped.");
        if (!_login.IsPending && (probe.State == "Locked" || probe.State == "Login" && probe.Error))
        {
            _login.FailSubmission();
            ShowLoginPanel("The router rejected login or locked its controls. Automatic retries stopped.");
            throw new InvalidOperationException("The router rejected login or locked its controls; automatic retries stopped.");
        }
    }

    private async Task CheckCaptureSessionAsync(CancellationToken token)
    {
        var probe = await BrowserValueAsync<LoginProbe>("inspectRouterLogin(document)", token);
        _loginState = probe.State;
        CheckLoginBlocked(probe);
        if (probe.State == "Login")
            throw new InspectorTransientCaptureException("The router session expired; sign-in and this list will be restarted.");
    }

    private async Task<T> CaptureValueAsync<T>(string expression, CancellationToken token)
    {
        await CheckCaptureSessionAsync(token);
        try { return await BrowserValueAsync<T>(expression, token); }
        catch (InvalidDataException)
        {
            await CheckCaptureSessionAsync(token);
            throw;
        }
    }

    public async Task NavigateAsync(ClientSource source, CancellationToken token)
    {
        var path = source switch
        {
            ClientSource.Clients => new[] { "Advanced", "Network", "LAN Settings" },
            ClientSource.Wired => new[] { "Basic", "Network Map", "Wired Clients" },
            _ => new[] { "Advanced", "Security", "IP and MAC Binding" }
        };
        var sourceJson = JsonSerializer.Serialize(source.ToString());
        var state = await CaptureValueAsync<RouterCaptureState>($"routerCaptureState(document,{sourceJson},null)", token);
        if (state.Ready) return;
        for (var index = 0; index < path.Length; index++)
        {
            var label = JsonSerializer.Serialize(path[index]);
            var next = index + 1 < path.Length ? JsonSerializer.Serialize(path[index + 1]) : "null";
            Status.Text = $"{AttemptPrefix}opening {string.Join(" / ", path.Take(index + 1))}...";
            await _clickPacer.WaitAsync(token);
            _ = await CaptureValueAsync<bool>($"clickRouterMenu(document,{label},{next})", token);
            await WaitForAsync(async () =>
            {
                state = await CaptureValueAsync<RouterCaptureState>($"routerCaptureState(document,{sourceJson},{next})", token);
                return state.Ready || state.NextLabelVisible;
            }, TimeSpan.FromSeconds(15), token);
            if (state.Ready) return;
        }
        throw new InvalidDataException($"The titled {SourceName(source)} table was not found.");
    }

    public async Task<RouterTablePage> ReadPageAsync(ClientSource source, CancellationToken token)
    {
        var sourceJson = JsonSerializer.Serialize(source.ToString());
        RouterCaptureState? state = null;
        string? previous = null;
        await WaitForAsync(async () =>
        {
            state = await CaptureValueAsync<RouterCaptureState>($"routerCaptureState(document,{sourceJson},null)", token);
            if (!state.Ready || state.Table is null)
            {
                previous = null;
                return false;
            }
            var current = JsonSerializer.Serialize(state.Table);
            var stable = current == previous;
            previous = current;
            return stable;
        }, TimeSpan.FromSeconds(15), token);
        var table = state?.Table ?? throw new InvalidDataException("The client table is missing.");
        return new(table.Clients, table.PageNumber, table.PageCount, table.Title);
    }

    public async Task GoToPageAsync(ClientSource source, int page, CancellationToken token)
    {
        var sourceJson = JsonSerializer.Serialize(source.ToString());
        var before = await CaptureValueAsync<RouterCaptureState>($"routerCaptureState(document,{sourceJson},null)", token);
        var priorRows = JsonSerializer.Serialize(before.Table?.Clients);
        if (before.Table?.PageNumber != page) await _clickPacer.WaitAsync(token);
        _ = await CaptureValueAsync<bool>($"clickClientPage(document,{sourceJson},{page})", token);
        await WaitForAsync(async () =>
        {
            var state = await CaptureValueAsync<RouterCaptureState>($"routerCaptureState(document,{sourceJson},null)", token);
            var table = state.Table;
            return state.Ready && table is not null && table.PageNumber == page &&
                (before.Table?.PageNumber == page || JsonSerializer.Serialize(table.Clients) != priorRows);
        }, TimeSpan.FromSeconds(15), token);
    }

    private async void CaptureAll_Click(object sender, RoutedEventArgs e) => await CaptureAutomaticAsync(null);

    private async void CaptureClients_Click(object sender, RoutedEventArgs e) => await CaptureAutomaticAsync(ClientSource.Clients);

    private async void CaptureWired_Click(object sender, RoutedEventArgs e) => await CaptureAutomaticAsync(ClientSource.Wired);

    private async void CaptureArp_Click(object sender, RoutedEventArgs e) => await CaptureAutomaticAsync(ClientSource.Arp);

    private async Task CaptureAutomaticAsync(ClientSource? source)
    {
        if (_automationCancellation is not null || _signInCancellation is not null || _login.IsPending || _busy || _refreshing) return;
        if (!ApplyClickDelay()) return;
        using var cancellation = new CancellationTokenSource();
        _automationCancellation = cancellation;
        _captureProgress = null;
        var recovery = _recoveryVersion;
        UpdateAutomationControls();
        Status.Text = source is { } selected
            ? $"Starting {SourceName(selected)} capture. Previous captures are kept until every page succeeds."
            : "Starting complete capture. The previous snapshot is kept until all sources and pages succeed.";
        var progress = new Progress<InspectorCaptureProgress>(item =>
        {
            if (ReferenceEquals(_automationCancellation, cancellation) && !cancellation.IsCancellationRequested)
            {
                _captureProgress = item;
                Status.Text = item.Failure is { } failure
                    ? $"{AttemptPrefix}failed: {failure} Retrying in 2 seconds; Cancel stops retries."
                    : item.Page == 0 ? $"{AttemptPrefix}sign-in and navigation..."
                    : $"{AttemptPrefix}captured page {item.Page}/{item.Pages}.";
            }
        });
        try
        {
            var capture = source is { } single
                ? await InspectorCaptureRunner.CaptureSourceAsync(this, single, progress, cancellation.Token, RetryPolicy)
                : await InspectorCaptureRunner.CaptureAsync(this, progress, cancellation.Token, RetryPolicy);
            cancellation.Token.ThrowIfCancellationRequested();
            if (source is { } replacement) _capture.ReplaceSource(replacement, capture);
            else _capture = capture;
            InvalidateComparison();
            if (source is null or ClientSource.Wired) WiredComplete.IsChecked = true;
            RefreshRows();
            Status.Text = source is { } completed
                ? $"{SourceName(completed)}: all pages captured. Other source captures were kept."
                : "All three lists and all pagination pages captured. Wired list completeness verified automatically.";
            await CompareCurrentAsync();
        }
        catch (OperationCanceledException)
        {
            if (!_closing && ReferenceEquals(_automationCancellation, cancellation) && recovery == _recoveryVersion)
                Status.Text = "Automatic capture cancelled. The previous snapshot was kept.";
        }
        catch (Exception exception) when (exception is InvalidDataException or InvalidOperationException
            or InspectorTransientCaptureException or JsonException or TimeoutException or System.Runtime.InteropServices.COMException)
        {
            if (!_closing && ReferenceEquals(_automationCancellation, cancellation))
                Status.Text = $"{AttemptPrefix}automatic capture failed: {exception.Message} The previous snapshot was kept. Use Forced refresh if needed.";
        }
        finally
        {
            if (ReferenceEquals(_automationCancellation, cancellation))
            {
                _captureProgress = null;
                _automationCancellation = null;
                if (!_closing) UpdateAutomationControls();
            }
        }
    }

    private async void ShowLogin_Click(object sender, RoutedEventArgs e)
    {
        if (_signInCancellation is not null || _automationCancellation is not null || _login.IsPending || _refreshing) return;
        if (!ApplyClickDelay()) return;
        using var cancellation = new CancellationTokenSource();
        _signInCancellation = cancellation;
        var recovery = _recoveryVersion;
        UpdateAutomationControls();
        try
        {
            Status.Text = "Ensuring a signed-in router session...";
            await EnsureSignedInAsync(cancellation.Token);
            if (!_closing) Status.Text = "Router session is signed in. An already-valid session was kept.";
        }
        catch (OperationCanceledException)
        {
            if (!_closing && recovery == _recoveryVersion) Status.Text = "Sign-in operation cancelled.";
        }
        catch (Exception exception) when (exception is InvalidOperationException or InvalidDataException
            or JsonException or TimeoutException or System.Runtime.InteropServices.COMException)
        {
            if (!_closing) Status.Text = $"Sign-in did not complete: {exception.Message} Use Forced refresh if needed.";
        }
        finally
        {
            if (ReferenceEquals(_signInCancellation, cancellation)) _signInCancellation = null;
            if (!_closing) UpdateAutomationControls();
        }
    }

    private void CancelCapture_Click(object sender, RoutedEventArgs e)
    {
        _automationCancellation?.Cancel();
        _signInCancellation?.Cancel();
    }

    private void UpdateAutomationControls()
    {
        var running = _automationCancellation is not null || _signInCancellation is not null;
        var canCapture = !running && !_login.IsPending && !_busy && !_refreshing && Browser.CoreWebView2 is not null;
        CaptureAllButton.IsEnabled = canCapture;
        CaptureClientsButton.IsEnabled = canCapture;
        CaptureWiredButton.IsEnabled = canCapture;
        CaptureArpButton.IsEnabled = canCapture;
        CaptureButton.IsEnabled = canCapture;
        ClearButton.IsEnabled = !running;
        SourcePicker.IsEnabled = !running;
        WiredComplete.IsEnabled = !running;
        LoginEntryButton.IsEnabled = !running && !_login.IsPending && !_refreshing;
        CancelCaptureButton.IsEnabled = running;
        ClickDelayInput.IsEnabled = !running && !_login.IsPending && !_busy && !_refreshing;
    }

    private sealed record RouterCaptureState(bool Ready, ExtractedTable? Table, bool NextLabelVisible);
    private sealed record BrowserScriptResult<T>(bool Ok, T? Value, string? Error);
}
