using System.Diagnostics;
using FingVibe.Core.Formatting;
using FingVibe.Core.Storage;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App;

public sealed partial class DatabaseBackupsPage : UserControl
{
    private readonly AsyncSurfaceSession _surface = new();
    private InventoryBackupStore? _store;
    private InventoryBackupScheduler? _scheduler;
    private Action<string?>? _report;
    private bool _visible;
    private IReadOnlyList<InventoryBackup> _copies = [];
    private readonly DispatcherTimer _ageTimer = new() { Interval = TimeSpan.FromMinutes(1) };
    private readonly Style _normalButtonStyle;
    private sealed record BackupRow(string Created, string Name, string Size, bool IsAlternateRow,
        string Daily, string DailyDescription);

    public DatabaseBackupsPage()
    {
        InitializeComponent();
        _normalButtonStyle = BackUpNowButton.Style;
        _surface.StateChanged += (_, _) => AutomationProperties.SetItemStatus(BackupsScroll, _surface.Status);
        _ageTimer.Tick += (_, _) => UpdateBackupSummary();
        Unloaded += (_, _) => Close();
        SizeChanged += (_, args) => BackupActions.Orientation = args.NewSize.Width < 540
            ? Orientation.Vertical : Orientation.Horizontal;
    }

    public event EventHandler? BackRequested;

    internal void Configure(InventoryBackupStore? store, InventoryBackupScheduler? scheduler, Action<string?> report)
    {
        _store = store;
        _scheduler = scheduler;
        _report = report;
        BackUpNowButton.IsEnabled = scheduler is not null;
        BackupFolderText.Text = store is null ? "Backup storage is unavailable in this isolated review."
            : $"Backup folder: {store.DirectoryPath}";
    }

    internal void Open()
    {
        _visible = true;
        CompletedBackupsExpander.IsExpanded = false;
        BackupPolicyExpander.IsExpanded = false;
        _ageTimer.Start();
        ShowStatus();
        (BackUpNowButton.IsEnabled ? BackUpNowButton : OpenBackupFolderButton).Focus(FocusState.Programmatic);
        Refresh();
    }

    internal void Close()
    {
        _visible = false;
        _ageTimer.Stop();
        _surface.Cancel();
    }

    internal void Refresh()
    {
        if (_visible) _ = RefreshAsync();
    }

    private async Task RefreshAsync()
    {
        var request = _surface.Start("Database backups");
        if (request is null) return;
        ShowStatus();
        try
        {
            if (_store is null) throw new InvalidOperationException("Supply an isolated inventory fixture to use backups in UI review.");
            var copies = await _store.ListAsync(request.CancellationToken);
            if (!_surface.IsCurrent(request)) return;
            var status = _scheduler?.Status ?? new InventoryBackupStatus(Error: "Backup scheduling is unavailable.");
            _copies = copies;
            BackupRows.ItemsSource = copies.Select((item, index) => new BackupRow(
                item.CreatedUtc.ToLocalTime().ToString("g"), Path.GetFileName(item.Path),
                $"{item.Size / 1024d:N1} KiB", index % 2 == 1, item.IsDaily ? "Yes" : "No",
                item.IsDaily ? "Daily recovery point: newest copy for this local backup day."
                    : "Recent backup only: not a daily recovery point.")).ToArray();
            UpdateBackupSummary();
            BackupLastSuccess.Text = copies.FirstOrDefault() is { } last
                ? $"Last successful backup: {last.CreatedUtc.ToLocalTime():G}" : "No successful backup yet.";
            ShowStatus();
            BackupsScroll.UpdateLayout();
            _surface.Complete(request, status.Error is not null ? AsyncSurfaceState.Error
                : copies.Count == 0 ? AsyncSurfaceState.Empty : AsyncSurfaceState.Ready, () => { });
        }

        catch (OperationCanceledException) when (request.CancellationToken.IsCancellationRequested) { }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            _surface.Complete(request, AsyncSurfaceState.Error, () =>
            {
                BackupError.Message = $"Could not list backups: {exception.Message}";
                BackupError.IsOpen = true;
                BackUpNowButton.IsEnabled = _scheduler is not null && !_scheduler.Status.Running
                    && !_scheduler.Status.ManualCooldown;
                BackupsScroll.UpdateLayout();
            });
            _report?.Invoke($"Could not list database backups: {exception.Message}");
        }
    }

    private void UpdateBackupSummary()
    {
        var now = DateTimeOffset.UtcNow;
        BackupCount.Text = _copies.Count == 0 ? "No completed backups."
            : $"{_copies.Count} {(_copies.Count == 1 ? "backup" : "backups")} - "
                + $"newest {Age(_copies[0].CreatedUtc)} - oldest {Age(_copies[^1].CreatedUtc)}";

        string Age(DateTimeOffset created) => created > now
            ? $"at {created.ToLocalTime():G}" : $"{ScanAgeFormatter.FormatAge(now - created)} ago";
    }

    private void ShowStatus()
    {
        var status = _scheduler?.Status;
        BackupProgress.Visibility = status?.Running == true ? Visibility.Visible : Visibility.Collapsed;
        BackUpNowButton.IsEnabled = status is { Running: false, ManualCooldown: false };
        var action = status?.Running == true ? "Creating backup..."
            : status?.ManualCooldown == true ? status.ManualFailed ? "Backup failed" : "Backed up"
            : status?.Pending == true ? "Backup pending"
            : status?.Missing == true ? "No database to back up" : "Back up now";
        BackUpNowButton.Style = status is { Running: false, ManualCooldown: true }
            ? (Style)Resources[status.ManualFailed ? "BackupFailureButtonStyle" : "BackupSuccessButtonStyle"]
            : _normalButtonStyle;
        BackUpNowButton.Content = action;
        AutomationProperties.SetName(BackUpNowButton, action);
        AutomationProperties.SetHelpText(BackUpNowButton, status?.ManualCooldown == true
            ? "Available one minute after this manual attempt finished."
            : status?.Missing == true ? "Waiting for the first successful saved scan."
            : "Create a consistent backup now, without the automatic delay.");
        BackupError.Message = status?.Error ?? "";
        BackupError.IsOpen = status?.Error is not null;
    }

    private void BackUpNow_Click(object sender, RoutedEventArgs e)
    {
        if (_scheduler is null) return;
        _scheduler.BackUpNow();
        Refresh();
    }

    private async void OpenFolder_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            if (_store is null) throw new InvalidOperationException("Backup storage is unavailable.");
            var folder = await Windows.Storage.StorageFolder.GetFolderFromPathAsync(_store.DirectoryPath);
            if (!await Windows.System.Launcher.LaunchFolderAsync(folder))
                throw new IOException("Windows could not open the backup folder.");
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
            or InvalidOperationException or System.Runtime.InteropServices.COMException or ArgumentException)
        {
            var error = $"Could not open backup folder: {exception.Message} Create a successful backup first, then check folder access.";
            BackupError.Message = error;
            BackupError.IsOpen = true;
            _report?.Invoke(error);
            Debug.WriteLine(error);
        }
    }

    private void Back_Click(object sender, RoutedEventArgs e) => BackRequested?.Invoke(this, EventArgs.Empty);
}
