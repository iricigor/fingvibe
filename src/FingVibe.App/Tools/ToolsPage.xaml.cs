using System.Net;
using FingVibe.Core.Models;
using FingVibe.Core.Import;
using FingVibe.Core.Storage;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App;

public sealed partial class ToolsPage : UserControl
{
    private Action<string>? _showManagement;
    private bool _resumeImport;

    public event EventHandler? RoomMapRequested;

    public ToolsPage()
    {
        InitializeComponent();
        var index = 0;
        var columns = ToolsLandingGrid.ColumnDefinitions.Count;
        foreach (var child in ToolsLandingGrid.Children)
        {
            if (child is not Button card) continue;
            var row = index / columns;
            if (row >= ToolsLandingGrid.RowDefinitions.Count)
                ToolsLandingGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid.SetRow(card, row);
            Grid.SetColumn(card, index % columns);
            index++;
        }
    }

    internal NetworkActivityCoordinator? ActivityCoordinator
    {
        get => SpeedTestView.ActivityCoordinator;
        set
        {
            SpeedTestView.ActivityCoordinator = value;
            NetworkHealthView.ActivityCoordinator = value;
        }
    }

    public bool HasActiveTest => SpeedTestView.HasActiveTest || NetworkHealthView.HasActiveTest || SqlEditorView.IsRunning;

    internal void ConfigureSqlEditor(string? databasePath) => SqlEditorView.Configure(databasePath);

    internal void ConfigureBackups(InventoryBackupStore? store, InventoryBackupScheduler? scheduler, Action<string?> report) =>
        DatabaseBackupsView.Configure(store, scheduler, report);
    internal void RefreshBackups() => DatabaseBackupsView.Refresh();

    internal void ConfigureImport(Func<DeviceInventoryData> getData, Func<bool> canEdit,
        Func<FingImportAnalysis, Task<string>> import, Action<string> showManagement, nint windowHandle)
    {
        _showManagement = showManagement;
        FingImportView.Configure(getData, canEdit, import, windowHandle);
    }

    internal void InvalidateImportAnalysis(string reason) => FingImportView.InvalidateAnalysis(reason);

    internal void Open()
    {
        if (_resumeImport)
        {
            _resumeImport = false;
            ShowImport();
        }
    }

    public void SetNetworkContext(LanNetwork? network) => NetworkHealthView.SetNetworkContext(network);

    internal void ConfigureNetworkHealth(Func<LanNetwork, Guid?, IReadOnlyList<IPAddress>> peers) =>
        NetworkHealthView.ConfigurePeerCandidates(peers);

    internal void ShowNetworkMonitor(NetworkMonitorView view) => NetworkHealthView.ShowNetworkMonitor(view);

    internal void ShowIncidentHistory(IReadOnlyList<NetworkIncidentRow> rows,
        IReadOnlyDictionary<Guid, NetworkEvidenceView> evidence, string? storageMessage) =>
        NetworkHealthView.ShowIncidentHistory(rows, evidence, storageMessage);

    public async Task StopForNavigationAsync()
    {
        SpeedTestView.Visibility = Visibility.Collapsed;
        NetworkHealthView.Visibility = Visibility.Collapsed;
        ServiceStatusView.StopForNavigation();
        ServiceStatusView.Visibility = Visibility.Collapsed;
        FingImportView.Visibility = Visibility.Collapsed;
        SqlEditorView.Visibility = Visibility.Collapsed;
        DatabaseBackupsView.Close();
        DatabaseBackupsView.Visibility = Visibility.Collapsed;
        ToolsLandingContainer.Visibility = Visibility.Visible;
        await Task.WhenAll(SpeedTestView.StopForNavigationAsync(), NetworkHealthView.StopForNavigationAsync(),
            SqlEditorView.StopAsync());
        SpeedTestView.ResetForNavigation();
    }

    public Task StopForWindowCloseAsync() => Task.WhenAll(
        SpeedTestView.StopForWindowCloseAsync(), NetworkHealthView.StopForWindowCloseAsync(), SqlEditorView.StopAsync());

    private void SqlEditorCard_Click(object sender, RoutedEventArgs e)
    {
        ToolsLandingContainer.Visibility = Visibility.Collapsed;
        SqlEditorView.Visibility = Visibility.Visible;
        SqlEditorView.Open();
    }

    private void DatabaseBackupsCard_Click(object sender, RoutedEventArgs e)
    {
        ToolsLandingContainer.Visibility = Visibility.Collapsed;
        DatabaseBackupsView.Visibility = Visibility.Visible;
        DatabaseBackupsView.Open();
    }

    private async void DatabaseBackupsView_BackRequested(object? sender, EventArgs e)
    {
        await StopForNavigationAsync();
        DatabaseBackupsCard.Focus(FocusState.Programmatic);
    }

    private async void SqlEditorView_BackRequested(object? sender, EventArgs e)
    {
        await StopForNavigationAsync();
        SqlEditorCard.Focus(FocusState.Programmatic);
    }

    private async void NetworkHealthCard_Click(object sender, RoutedEventArgs e) => await OpenNetworkHealthAsync();

    internal async Task OpenNetworkHealthAsync(bool focusServiceStatus = false)
    {
        ToolsLandingContainer.Visibility = Visibility.Collapsed;
        FingImportView.Visibility = Visibility.Collapsed;
        ServiceStatusView.StopForNavigation();
        ServiceStatusView.Visibility = Visibility.Collapsed;
        NetworkHealthView.Visibility = Visibility.Visible;
        await NetworkHealthView.OpenAsync(focusServiceStatus);
    }

    private async void NetworkHealthView_BackRequested(object? sender, EventArgs e)
    {
        await StopForNavigationAsync();
        NetworkHealthCard.Focus(FocusState.Programmatic);
    }

    private async void NetworkHealthView_ServiceStatusRequested(object? sender, EventArgs e)
    {
        await NetworkHealthView.StopForNavigationAsync();
        NetworkHealthView.Visibility = Visibility.Collapsed;
        ServiceStatusView.Visibility = Visibility.Visible;
        await ServiceStatusView.OpenAsync();
    }

    private async void ServiceStatusView_BackRequested(object? sender, EventArgs e) =>
        await OpenNetworkHealthAsync(focusServiceStatus: true);

    private void SpeedTestCard_Click(object sender, RoutedEventArgs e)
    {
        ToolsLandingContainer.Visibility = Visibility.Collapsed;
        SpeedTestView.Visibility = Visibility.Visible;
        SpeedTestView.FocusStartButton();
    }

    private async void SpeedTestView_BackRequested(object sender, EventArgs e)
    {
        await StopForNavigationAsync();
        SpeedTestCard.Focus(FocusState.Programmatic);
    }

    private void RoomMapCard_Click(object sender, RoutedEventArgs e) =>
        RoomMapRequested?.Invoke(this, EventArgs.Empty);

    private void NetworkHealthView_RoomMapRequested(object? sender, EventArgs e) =>
        RoomMapRequested?.Invoke(this, e);

    private void ShowImport()
    {
        ToolsLandingContainer.Visibility = Visibility.Collapsed;
        FingImportView.Visibility = Visibility.Visible;
        FingImportView.Open();
    }

    private void FingImportCard_Click(object sender, RoutedEventArgs e) => ShowImport();

    private async void FingImportView_BackRequested(object? sender, EventArgs e)
    {
        await StopForNavigationAsync();
        FingImportCard.Focus(FocusState.Programmatic);
    }

    private void FingImportView_ManagementRequested(object? sender, string category)
    {
        _resumeImport = true;
        _showManagement?.Invoke(category);
    }
}
