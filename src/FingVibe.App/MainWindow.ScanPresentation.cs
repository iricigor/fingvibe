using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Foundation;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private readonly DispatcherTimer _scanPulseTimer = new() { Interval = TimeSpan.FromMilliseconds(33) };
    private readonly Stopwatch _scanPulseClock = new();
    private bool _scanPulseInitialized;

    private void ScanHeader_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        ScanHeader.Margin = new Thickness(
            MainNavigation.DisplayMode == NavigationViewDisplayMode.Minimal ? 72 : 24, 16, 224, 8);
        var textScale = _uiSettings.TextScaleFactor;
        var narrow = ScanHeader.ActualWidth < 480 * textScale;
        var stackedAction = ScanHeader.ActualWidth < 150 + 120 * textScale + 12;
        ScanActions.MinWidth = Math.Min(120 * textScale, ScanHeader.ActualWidth);
        ScanActions.MaxWidth = ScanHeader.ActualWidth;
        Grid.SetRow(NetworkPicker, narrow ? 1 : 0);
        Grid.SetColumn(NetworkPicker, narrow ? 0 : 1);
        Grid.SetColumnSpan(NetworkPicker, narrow && !stackedAction ? 2 : narrow ? 3 : 1);
        NetworkPicker.Margin = narrow ? new Thickness(0, 4, 0, 0) : new Thickness(0);
        Grid.SetRow(ScanFreshnessText, narrow ? 2 : 1);
        Grid.SetColumn(ScanFreshnessText, narrow ? 0 : 1);
        Grid.SetColumnSpan(ScanFreshnessText, narrow ? 3 : 2);
        Grid.SetRow(ScanActions, stackedAction ? 3 : narrow ? 1 : 0);
        Grid.SetColumn(ScanActions, stackedAction ? 0 : 2);
        Grid.SetColumnSpan(ScanActions, stackedAction ? 3 : 1);
        ScanActions.HorizontalAlignment = stackedAction ? HorizontalAlignment.Left : HorizontalAlignment.Right;
        ScanActions.Margin = stackedAction ? new Thickness(0, 4, 0, 0) : new Thickness(0);
        Grid.SetRow(ScanMessages, narrow ? 4 : 2);
        Grid.SetColumn(ScanMessages, narrow ? 0 : 1);
        Grid.SetColumnSpan(ScanMessages, narrow ? 3 : 2);
    }

    private void StartScanPulse()
    {
        if (!_scanPulseInitialized)
        {
            _scanPulseTimer.Tick += ScanPulse_Tick;
            Closed += (_, _) => StopScanPulse();
            _scanPulseInitialized = true;
        }

        _scanPulseClock.Restart();
        _scanPulseTimer.Start();
        UpdateScanPulseWidth();
        ScanPulse_Tick(null, EventArgs.Empty);
    }

    private void ScanPulse_Tick(object? sender, object e)
    {
        ScanPulse.Visibility = _uiSettings.AnimationsEnabled && !_accessibilitySettings.HighContrast
            ? Visibility.Visible : Visibility.Collapsed;
        var position = ScanProgressPresentation.PulsePosition(_scanPulseClock.Elapsed);
        ScanPulseBrush.StartPoint = new Point(position - 0.25, 0);
        ScanPulseBrush.EndPoint = new Point(position + 0.25, 0);
    }

    private void ScanProgressArea_SizeChanged(object sender, SizeChangedEventArgs e) => UpdateScanPulseWidth();

    private void UpdateScanPulseWidth()
    {
        ScanPulse.Width = ScanProgressPresentation.FilledWidth(
            ScanProgressBar.Value, ScanProgressBar.Maximum, ScanProgressArea.ActualWidth);
    }

    private void StopScanPulse()
    {
        _scanPulseTimer.Stop();
        _scanPulseClock.Stop();
        ScanPulse.Visibility = Visibility.Collapsed;
    }
}
