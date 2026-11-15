using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using Ex220Inspector;
using Microsoft.Data.Sqlite;
using Microsoft.Win32;

namespace DecoX50Inspector;

public partial class MainWindow
{
    private string? _database;
    private int _comparisonVersion;
    private CancellationTokenSource? _databaseCancellation;
    private IReadOnlyDictionary<string, DatabaseMatch> _matches = new Dictionary<string, DatabaseMatch>();

    private void InvalidateComparison()
    {
        _comparisonVersion++;
        _databaseCancellation?.Cancel();
        _matches = new Dictionary<string, DatabaseMatch>();
    }

    private void DatabasePath_Changed(object sender, TextChangedEventArgs e)
    {
        _database = null;
        InvalidateComparison();
        if (DatabaseNetworkPicker is not null) DatabaseNetworkPicker.ItemsSource = null;
        if (DatabaseStatus is not null) DatabaseStatus.Text = "Database path changed. Load DB and choose a saved network.";
        if (ClientsGrid is not null) RefreshRows();
    }

    private void BrowseDatabase_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Filter = "SQLite inventory (*.sqlite)|*.sqlite|All files (*.*)|*.*" };
        if (dialog.ShowDialog(this) == true) DatabasePath.Text = dialog.FileName;
    }

    private async void LoadDatabase_Click(object sender, RoutedEventArgs e)
    {
        InvalidateComparison();
        _database = null;
        DatabaseNetworkPicker.ItemsSource = null;
        var version = _comparisonVersion;
        var path = DatabasePath.Text.Trim();
        using var cancellation = new CancellationTokenSource();
        _databaseCancellation = cancellation;
        RefreshRows();
        DatabaseStatus.Text = "Loading saved networks read-only...";
        try
        {
            var networks = await new FingVibeDatabaseComparison(path).NetworksAsync(cancellation.Token);
            if (_closing || version != _comparisonVersion) return;
            _database = path;
            DatabaseNetworkPicker.ItemsSource = networks;
            DatabaseNetworkPicker.SelectedIndex = networks.Count == 1 ? 0 : -1;
            DatabaseStatus.Text = networks.Count == 0 ? "No saved network scopes; comparison is unavailable." :
                "Database loaded read-only. Choose the Deco's network/subnet and click Compare.";
        }
        catch (OperationCanceledException)
        {
            if (!_closing && version == _comparisonVersion)
                DatabaseStatus.Text = "Database load cancelled or exceeded its five-second query limit.";
        }
        catch (Exception exception) when (DatabaseFailure(exception))
        {
            if (!_closing && version == _comparisonVersion)
                DatabaseStatus.Text = $"Read-only database load failed: {exception.Message}";
        }
        finally
        {
            if (ReferenceEquals(_databaseCancellation, cancellation)) _databaseCancellation = null;
            if (!_closing) RefreshRows();
        }
    }

    private void DatabaseNetwork_Changed(object sender, SelectionChangedEventArgs e)
    {
        InvalidateComparison();
        if (DatabaseStatus is not null)
            DatabaseStatus.Text = "Network selection changed. Click Compare to refresh.";
        if (ClientsGrid is not null) RefreshRows();
    }

    private async void Compare_Click(object sender, RoutedEventArgs e) => await CompareAsync();

    private async Task CompareAsync()
    {
        if (_database is null || DatabaseNetworkPicker.SelectedItem is not DatabaseNetwork network ||
            _snapshot is not { } snapshot)
        {
            DatabaseStatus.Text = "Comparison unavailable: capture clients, load DB and select the saved network/subnet.";
            return;
        }
        InvalidateComparison();
        var version = _comparisonVersion;
        using var cancellation = new CancellationTokenSource();
        _databaseCancellation = cancellation;
        RefreshRows();
        DatabaseStatus.Text = "Comparing names and IPs in a read-only SQLite transaction...";
        try
        {
            var matches = await new FingVibeDatabaseComparison(_database)
                .CompareAsync(snapshot.ComparisonRows(), network, cancellation.Token);
            if (_closing || version != _comparisonVersion) return;
            _matches = matches;
            DatabaseStatus.Text = $"Compared {matches.Count} MAC identities against {network.Label}. No database writes.";
        }
        catch (OperationCanceledException)
        {
            if (!_closing && version == _comparisonVersion)
                DatabaseStatus.Text = "Comparison cancelled or exceeded its five-second query limit.";
        }
        catch (Exception exception) when (DatabaseFailure(exception))
        {
            if (!_closing && version == _comparisonVersion)
                DatabaseStatus.Text = $"Read-only comparison failed: {exception.Message}";
        }
        finally
        {
            if (ReferenceEquals(_databaseCancellation, cancellation)) _databaseCancellation = null;
            if (!_closing) RefreshRows();
        }
    }

    private static bool DatabaseFailure(Exception exception) =>
        exception is InvalidDataException or IOException or UnauthorizedAccessException or SqliteException or JsonException
            or ArgumentException or InvalidOperationException;
}
