using System.Diagnostics;
using Microsoft.UI.Xaml;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private readonly DispatcherTimer _scanPulseTimer = new() { Interval = TimeSpan.FromMilliseconds(33) };
    private readonly Stopwatch _scanPulseClock = new();
    private bool _scanPulseInitialized;

    private void UpdateScanActionLayout()
    {
        var compact = RootGrid.ActualWidth < 480 + 280 * _uiSettings.TextScaleFactor;
        ScanButtonLabel.Visibility = CancelButtonLabel.Visibility = compact ? Visibility.Collapsed : Visibility.Visible;
        ScanButton.Width = CancelButton.Width = compact ? 40 : 200 * _uiSettings.TextScaleFactor;
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
        ScanPulse_Tick(null, EventArgs.Empty);
    }

    private void ScanPulse_Tick(object? sender, object e)
    {
        ScanProgressBar.ShowActivity(_scanPulseClock.Elapsed,
            _uiSettings.AnimationsEnabled && !_accessibilitySettings.HighContrast);
    }

    private void StopScanPulse()
    {
        _scanPulseTimer.Stop();
        _scanPulseClock.Stop();
        ScanProgressBar.ShowActivity(TimeSpan.Zero, false);
    }
}
