using System.ComponentModel;
using System.IO;
using System.Reflection;
using System.Text.Json;
using System.Windows;
using Microsoft.Web.WebView2.Core;

namespace Ex220Inspector;

public partial class MainWindow : Window
{
    private readonly ClientCapture _capture = new();
    private readonly string _profile = Path.Combine(Path.GetTempPath(), "FingVibe-Ex220-" + Guid.NewGuid().ToString("N"));
    private CoreWebView2Environment? _environment;
    private bool _closing;
    private bool _closed;
    private bool _busy;
    private Task _initialization = Task.CompletedTask;

    public MainWindow() => InitializeComponent();

    private void Window_Loaded(object sender, RoutedEventArgs e) =>
        _initialization = InitializeBrowserAsync();

    private async Task InitializeBrowserAsync()
    {
        try
        {
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
                if (IsRouter(args.Uri)) return;
                args.Cancel = true;
                Status.Text = "Navigation blocked: this inspector only opens 192.168.0.1.";
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
                CaptureButton.IsEnabled = args.IsSuccess && !_busy;
                Status.Text = args.IsSuccess
                    ? "Log in, open a client table, choose its source above, and capture. Router configuration controls are live; do not change settings."
                    : $"Router navigation failed ({args.WebErrorStatus}). Check the router and retry by reopening the inspector.";
            };
            core.AddWebResourceRequestedFilter("*", CoreWebView2WebResourceContext.All);
            core.WebResourceRequested += (_, args) =>
            {
                if (IsRouter(args.Request.Uri) || args.Request.Uri.StartsWith("data:", StringComparison.OrdinalIgnoreCase))
                    return;
                args.Response = _environment.CreateWebResourceResponse(null, 403, "External request blocked", "");
            };
            core.Navigate("http://192.168.0.1");
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
        if (_busy || Browser.CoreWebView2 is not { } core) return;
        _busy = true;
        CaptureButton.IsEnabled = false;
        var source = (ClientSource)SourcePicker.SelectedIndex;
        Status.Text = "Reading visible client table...";
        try
        {
            using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Ex220Inspector.ExtractClients.js")
                ?? throw new InvalidOperationException("Client extraction script is missing.");
            using var reader = new StreamReader(stream);
            var script = await reader.ReadToEndAsync();
            var json = await core.ExecuteScriptAsync($"(() => {{ {script}\n return extractClients(document); }})()");
            if (_closing) return;
            var result = JsonSerializer.Deserialize<Extraction>(json)
                ?? throw new InvalidDataException("The router did not return an extraction result.");
            if (result.Tables.Length != 1)
                throw new InvalidDataException(result.Tables.Length == 0
                    ? "No visible table with MAC and IP headings was found. Open the client table and wait for it to load."
                    : "Multiple client tables are visible. Open only the intended client table before capturing.");
            var table = result.Tables[0];
            if (table.InvalidRows > 0)
                throw new InvalidDataException($"{table.InvalidRows} rows could not be parsed. This capture was not saved.");
            _capture.Add(source, table.Clients);
            if (source == ClientSource.Wired) WiredComplete.IsChecked = false;
            RefreshRows();
            Status.Text = $"Captured {table.Clients.Length} visible rows as {SourceName(source)} at {DateTime.Now:T}. " +
                "Select the next page and capture again if the router paginates. Clear captures before starting a new snapshot.";
        }
        catch (Exception exception) when (exception is JsonException or InvalidDataException
            or InvalidOperationException or System.Runtime.InteropServices.COMException)
        {
            if (!_closing) Status.Text = $"Capture failed: {exception.Message}";
        }
        finally
        {
            _busy = false;
            if (!_closing) CaptureButton.IsEnabled = true;
        }
    }

    private void Clear_Click(object sender, RoutedEventArgs e)
    {
        if (_busy) return;
        _capture.Clear();
        WiredComplete.IsChecked = false;
        RefreshRows();
        Status.Text = "Captures cleared. Start a new snapshot by opening Client List.";
    }

    private void WiredComplete_Changed(object sender, RoutedEventArgs e) => RefreshRows();

    private void RefreshRows()
    {
        if (ClientsGrid is null) return;
        ClientsGrid.ItemsSource = _capture.Rows(WiredComplete.IsChecked == true);
        CaptureSummary.Text = string.Join(" | ", Enum.GetValues<ClientSource>().Select(source =>
            $"{SourceName(source)}: {(_capture.Has(source) ? $"{_capture.Count(source)} captured" : "not captured")}"));
    }

    private static string SourceName(ClientSource source) => source switch
    {
        ClientSource.Clients => "Client List",
        ClientSource.Wired => "Wired Clients",
        _ => "ARP"
    };

    private async void Window_Closing(object? sender, CancelEventArgs e)
    {
        if (_closed) return;
        e.Cancel = true;
        if (_closing) return;
        _closing = true;
        CaptureButton.IsEnabled = false;
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

    private sealed record Extraction(ExtractedTable[] Tables);
    private sealed record ExtractedTable(RouterClient[] Clients, int InvalidRows);
}
