using System.Collections.ObjectModel;
using System.Diagnostics;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App;

public sealed partial class MainWindow : Window
{
    private readonly NetworkDiscoveryService _networkDiscovery = new();
    private readonly LanScannerService _scanner = new();
    private readonly ObservableCollection<ScanResult> _results = [];
    private CancellationTokenSource? _scanCancellation;

    public MainWindow()
    {
        InitializeComponent();
        ResultsList.ItemsSource = _results;
    }

    private void RootGrid_Loaded(object sender, RoutedEventArgs e)
    {
        var networks = _networkDiscovery.GetAvailableNetworks();
        NetworkPicker.ItemsSource = networks;
        NetworkPicker.DisplayMemberPath = nameof(LanNetwork.DisplayLabel);

        if (networks.Count == 0)
        {
            MachineAddressText.Text = "No active IPv4 interface";
            LanAddressText.Text = "Unavailable";
            ScanStatusText.Text = "Connect to a LAN to scan";
            ScanButton.IsEnabled = false;
            return;
        }

        NetworkPicker.SelectedIndex = 0;
    }

    private void NetworkPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (NetworkPicker.SelectedItem is not LanNetwork network)
        {
            return;
        }

        MachineAddressText.Text = network.LocalAddress.ToString();
        LanAddressText.Text = network.Cidr;
        ScanStatusText.Text = $"{SubnetCalculator.GetUsableHostCount(network.PrefixLength):N0} addresses ready";
    }

    private async void ScanButton_Click(object sender, RoutedEventArgs e)
    {
        if (NetworkPicker.SelectedItem is not LanNetwork network)
        {
            return;
        }

        _results.Clear();
        EmptyResultsText.Visibility = Visibility.Collapsed;
        ScanButton.IsEnabled = false;
        NetworkPicker.IsEnabled = false;
        CancelButton.IsEnabled = true;
        _scanCancellation = new CancellationTokenSource();

        var total = SubnetCalculator.GetUsableHostCount(network.PrefixLength);
        ScanProgressBar.Maximum = total;
        ScanProgressBar.Value = 0;
        ScanStatusText.Text = $"Scanning 0 of {total:N0}";
        var stopwatch = Stopwatch.StartNew();

        var resultProgress = new Progress<ScanResult>(result => _results.Add(result));
        var scanProgress = new Progress<ScanProgress>(progress =>
        {
            ScanProgressBar.Value = progress.Completed;
            ScanStatusText.Text = $"Scanning {progress.Completed:N0} of {progress.Total:N0}";
        });

        try
        {
            var summary = await _scanner.ScanAsync(
                network,
                resultProgress,
                scanProgress,
                _scanCancellation.Token);

            stopwatch.Stop();
            ScanStatusText.Text =
                $"Complete in {stopwatch.Elapsed.TotalSeconds:N1}s - {summary.Alive:N0} alive, {summary.Unreachable:N0} unreachable";
        }
        catch (OperationCanceledException)
        {
            ScanStatusText.Text = $"Cancelled after {_results.Count:N0} results";
        }
        catch (InvalidOperationException exception)
        {
            EmptyResultsText.Text = exception.Message;
            EmptyResultsText.Visibility = Visibility.Visible;
            ScanStatusText.Text = "Unable to scan this subnet";
        }
        finally
        {
            _scanCancellation.Dispose();
            _scanCancellation = null;
            ScanButton.IsEnabled = true;
            NetworkPicker.IsEnabled = true;
            CancelButton.IsEnabled = false;
        }
    }

    private void CancelButton_Click(object sender, RoutedEventArgs e)
    {
        _scanCancellation?.Cancel();
        CancelButton.IsEnabled = false;
        ScanStatusText.Text = "Cancelling...";
    }
}
