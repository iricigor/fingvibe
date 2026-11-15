using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Data.Sqlite;
using Microsoft.Win32;

namespace Ex220Inspector;

public partial class MainWindow
{
    private IReadOnlyDictionary<string, DatabaseMatch> _databaseMatches = new Dictionary<string, DatabaseMatch>();
    private CancellationTokenSource? _databaseCancellation;
    private int _comparisonVersion;
    private string? _loadedDatabasePath;

    private void InvalidateComparison()
    {
        _comparisonVersion++;
        _databaseCancellation?.Cancel();
        _databaseMatches = new Dictionary<string, DatabaseMatch>();
    }

    private void DatabasePath_Changed(object sender, TextChangedEventArgs e)
    {
        _loadedDatabasePath = null;
        InvalidateComparison();
        if (DatabaseNetworkPicker is not null) DatabaseNetworkPicker.ItemsSource = null;
        if (DatabaseStatus is not null) DatabaseStatus.Text = "Database path changed. Load DB to choose its saved network.";
        if (ClientsGrid is not null) RefreshRows();
    }

    private void BrowseDatabase_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Filter = "SQLite inventory (*.sqlite)|*.sqlite|All files (*.*)|*.*" };
        if (dialog.ShowDialog(this) == true) DatabasePathInput.Text = dialog.FileName;
    }

    private async void LoadDatabase_Click(object sender, RoutedEventArgs e) => await LoadDatabaseAsync();

    private async Task LoadDatabaseAsync()
    {
        InvalidateComparison();
        _loadedDatabasePath = null;
        DatabaseNetworkPicker.ItemsSource = null;
        var version = _comparisonVersion;
        using var cancellation = new CancellationTokenSource();
        _databaseCancellation = cancellation;
        var path = DatabasePathInput.Text.Trim();
        DatabaseStatus.Text = "Reading saved networks from SQLite in read-only mode...";
        RefreshRows();
        try
        {
            var networks = await new FingVibeDatabaseComparison(path).NetworksAsync(cancellation.Token);
            if (_closing || version != _comparisonVersion) return;
            _loadedDatabasePath = path;
            DatabaseNetworkPicker.ItemsSource = networks;
            DatabaseNetworkPicker.SelectedIndex = networks.Count == 1 ? 0 : -1;
            DatabaseStatus.Text = networks.Count == 0
                ? "The database has no saved network-scoped observations. IP comparison is unavailable."
                : networks.Count == 1 ? $"Database loaded read-only. Selected {networks[0].Label}."
                : "Database loaded read-only. Select the router's saved network/subnet before comparing.";
            RefreshRows();
        }
        catch (OperationCanceledException)
        {
            if (!_closing && version == _comparisonVersion)
                DatabaseStatus.Text = "Database load stopped by cancellation or its five-second query limit.";
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
            or SqliteException or InvalidDataException or JsonException or ArgumentException or InvalidOperationException)
        {
            if (!_closing && version == _comparisonVersion)
            {
                _loadedDatabasePath = null;
                DatabaseStatus.Text = $"Read-only database load failed: {exception.Message}";
                RefreshRows();
            }
        }
        finally
        {
            if (ReferenceEquals(_databaseCancellation, cancellation)) _databaseCancellation = null;
        }
    }

    private void DatabaseNetwork_Changed(object sender, SelectionChangedEventArgs e)
    {
        InvalidateComparison();
        DatabaseStatus.Text = DatabaseNetworkPicker.SelectedItem is DatabaseNetwork network
            ? $"Selected {network.Label}. Compare to refresh name/IP matches."
            : "Select the router's saved network/subnet before comparing.";
        RefreshRows();
    }

    private async void CompareDatabase_Click(object sender, RoutedEventArgs e) => await CompareCurrentAsync();

    private async Task CompareCurrentAsync()
    {
        if (_loadedDatabasePath is null || DatabaseNetworkPicker.SelectedItem is not DatabaseNetwork network)
        {
            DatabaseStatus.Text = "DB comparison unavailable: load a database and select its saved router network/subnet.";
            return;
        }
        InvalidateComparison();
        var version = _comparisonVersion;
        using var cancellation = new CancellationTokenSource();
        _databaseCancellation = cancellation;
        var rows = _capture.Rows(WiredComplete.IsChecked == true);
        DatabaseStatus.Text = "Comparing captured names and IPs with a read-only database snapshot...";
        RefreshRows();
        try
        {
            var matches = await new FingVibeDatabaseComparison(_loadedDatabasePath).CompareAsync(rows, network, cancellation.Token);
            if (_closing || version != _comparisonVersion) return;
            _databaseMatches = matches;
            DatabaseStatus.Text = $"Compared {matches.Count} MAC identities read-only against {network.Label}. Names ignore case and surrounding spaces.";
            RefreshRows();
        }
        catch (OperationCanceledException)
        {
            if (!_closing && version == _comparisonVersion)
                DatabaseStatus.Text = "Database comparison stopped by cancellation or its five-second query limit.";
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
            or SqliteException or InvalidDataException or JsonException or ArgumentException or InvalidOperationException)
        {
            if (!_closing && version == _comparisonVersion)
            {
                DatabaseStatus.Text = $"Read-only database comparison failed: {exception.Message}";
                RefreshRows();
            }
        }
        finally
        {
            if (ReferenceEquals(_databaseCancellation, cancellation)) _databaseCancellation = null;
        }
    }
}
