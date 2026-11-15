using System.IO;
using System.Text.Json;
using System.Windows;

namespace Ex220Inspector;

public partial class MainWindow : IInspectorCaptureBrowser
{
    private CancellationTokenSource? _automationCancellation;
    private CancellationTokenSource? _signInCancellation;
    private string _captureScripts = "";
    private bool _capturePagesActive;
    private string? _captureFailure;

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
        var probe = await BrowserValueAsync<LoginProbe>("inspectRouterLogin(document)", token);
        if (probe.State == "Authenticated")
        {
            _loginState = probe.State;
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
        if (probe.State == "Authenticated") return;
        if (probe.State == "UsernameRequired")
            throw new InvalidOperationException("Use the router's own username/password form before automatic capture.");
        _loginState = probe.State;
        _login.ResetForRefresh();
        _loginTimer.Start();
        if (_login.HasPassword && probe.State == "Login")
            await SubmitLoginAsync(null);
        else
            ShowLoginPanel("Sign in to continue. Enter the local password; Cancel or Forced refresh stops the pending operation.");
        await WaitForAsync(async () =>
        {
            probe = await BrowserValueAsync<LoginProbe>("inspectRouterLogin(document)", token);
            return probe.State == "Authenticated";
        }, TimeSpan.FromMinutes(2), token);
        _loginState = "Authenticated";
        LoginPanel.Visibility = Visibility.Collapsed;
    }

    public async Task NavigateAsync(ClientSource source, CancellationToken token)
    {
        _capturePagesActive = true;
        var path = source switch
        {
            ClientSource.Clients => new[] { "Advanced", "Network", "LAN Settings" },
            ClientSource.Wired => new[] { "Basic", "Network Map", "Wired Clients" },
            _ => new[] { "Advanced", "Security", "IP and MAC Binding" }
        };
        var sourceJson = JsonSerializer.Serialize(source.ToString());
        var state = await BrowserValueAsync<RouterCaptureState>($"routerCaptureState(document,{sourceJson},null)", token);
        if (state.Ready) return;
        for (var index = 0; index < path.Length; index++)
        {
            var label = JsonSerializer.Serialize(path[index]);
            var next = index + 1 < path.Length ? JsonSerializer.Serialize(path[index + 1]) : "null";
            Status.Text = $"Opening {SourceName(source)}: {string.Join(" / ", path.Take(index + 1))}...";
            _ = await BrowserValueAsync<bool>($"clickRouterMenu(document,{label},{next})", token);
            await WaitForAsync(async () =>
            {
                var login = await BrowserValueAsync<LoginProbe>("inspectRouterLogin(document)", token);
                if (login.State is "Login" or "Locked")
                    throw new InvalidOperationException("The router logged out during capture. Sign in and retry; the previous capture was kept.");
                state = await BrowserValueAsync<RouterCaptureState>($"routerCaptureState(document,{sourceJson},{next})", token);
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
        await WaitForAsync(async () =>
        {
            state = await BrowserValueAsync<RouterCaptureState>($"routerCaptureState(document,{sourceJson},null)", token);
            return state.Ready;
        }, TimeSpan.FromSeconds(15), token);
        var table = state?.Table ?? throw new InvalidDataException("The client table is missing.");
        return new(table.Clients, table.PageNumber, table.PageCount, table.Title);
    }

    public async Task GoToPageAsync(ClientSource source, int page, CancellationToken token)
    {
        var sourceJson = JsonSerializer.Serialize(source.ToString());
        _ = await BrowserValueAsync<bool>($"clickClientPage(document,{sourceJson},{page})", token);
        await WaitForAsync(async () =>
        {
            var state = await BrowserValueAsync<RouterCaptureState>($"routerCaptureState(document,{sourceJson},null)", token);
            return state.Ready && state.Table?.PageNumber == page;
        }, TimeSpan.FromSeconds(15), token);
    }

    private async void CaptureAll_Click(object sender, RoutedEventArgs e) => await CaptureAutomaticAsync(null);

    private async void CaptureClients_Click(object sender, RoutedEventArgs e) => await CaptureAutomaticAsync(ClientSource.Clients);

    private async void CaptureWired_Click(object sender, RoutedEventArgs e) => await CaptureAutomaticAsync(ClientSource.Wired);

    private async void CaptureArp_Click(object sender, RoutedEventArgs e) => await CaptureAutomaticAsync(ClientSource.Arp);

    private async Task CaptureAutomaticAsync(ClientSource? source)
    {
        if (_automationCancellation is not null || _signInCancellation is not null || _busy || _refreshing) return;
        using var cancellation = new CancellationTokenSource();
        _automationCancellation = cancellation;
        _captureFailure = null;
        var recovery = _recoveryVersion;
        UpdateAutomationControls();
        Status.Text = source is { } selected
            ? $"Starting {SourceName(selected)} capture. Previous captures are kept until every page succeeds."
            : "Starting complete capture. The previous snapshot is kept until all sources and pages succeed.";
        var progress = new Progress<InspectorCaptureProgress>(item =>
        {
            if (ReferenceEquals(_automationCancellation, cancellation) && !cancellation.IsCancellationRequested)
                Status.Text = $"{SourceName(item.Source)}: captured page {item.Page}/{item.Pages}.";
        });
        try
        {
            var capture = source is { } single
                ? await InspectorCaptureRunner.CaptureSourceAsync(this, single, progress, cancellation.Token)
                : await InspectorCaptureRunner.CaptureAsync(this, progress, cancellation.Token);
            cancellation.Token.ThrowIfCancellationRequested();
            _capturePagesActive = false;
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
                Status.Text = _captureFailure is null
                    ? "Automatic capture cancelled. The previous snapshot was kept."
                    : $"Automatic capture stopped: {_captureFailure} The previous snapshot was kept.";
        }
        catch (Exception exception) when (exception is InvalidDataException or InvalidOperationException
            or JsonException or TimeoutException or System.Runtime.InteropServices.COMException)
        {
            if (!_closing && ReferenceEquals(_automationCancellation, cancellation))
                Status.Text = $"Automatic capture failed: {exception.Message} The previous snapshot was kept. Use Forced refresh if needed.";
        }
        finally
        {
            if (ReferenceEquals(_automationCancellation, cancellation))
            {
                _capturePagesActive = false;
                _automationCancellation = null;
                if (!_closing) UpdateAutomationControls();
            }
        }
    }

    private async void ShowLogin_Click(object sender, RoutedEventArgs e)
    {
        if (_signInCancellation is not null || _automationCancellation is not null || _refreshing) return;
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
        var canCapture = !running && !_busy && !_refreshing && Browser.CoreWebView2 is not null;
        CaptureAllButton.IsEnabled = canCapture;
        CaptureClientsButton.IsEnabled = canCapture;
        CaptureWiredButton.IsEnabled = canCapture;
        CaptureArpButton.IsEnabled = canCapture;
        CaptureButton.IsEnabled = !running && !_refreshing && !_busy && Browser.CoreWebView2 is not null;
        ClearButton.IsEnabled = !running;
        SourcePicker.IsEnabled = !running;
        WiredComplete.IsEnabled = !running;
        LoginEntryButton.IsEnabled = !running && !_refreshing;
        CancelCaptureButton.IsEnabled = running;
    }

    private sealed record RouterCaptureState(bool Ready, ExtractedTable? Table, bool NextLabelVisible);
    private sealed record BrowserScriptResult<T>(bool Ok, T? Value, string? Error);
}
