using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private readonly DispatcherTimer _scanPulseTimer = new() { Interval = TimeSpan.FromMilliseconds(33) };
    private readonly Stopwatch _scanPulseClock = new();
    private bool _scanPulseInitialized;

    private void ScanActions_SizeChanged(object sender, SizeChangedEventArgs e) => UpdateScanPulseWidth();

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
        UpdateScanPulseWidth();
        ScanPulse_Tick(null, EventArgs.Empty);
    }

    private void ScanPulse_Tick(object? sender, object e)
    {
        ScanPulse.Visibility = _uiSettings.AnimationsEnabled && !_accessibilitySettings.HighContrast
            ? Visibility.Visible : Visibility.Collapsed;
        var perimeter = ScanBorderLength();
        if (perimeter <= 0) return;
        ScanPulse.StrokeDashArray = new DoubleCollection { perimeter * 0.15 / 2, perimeter * 0.85 / 2 };
        ScanPulse.StrokeDashOffset = -perimeter / 2 * (_scanPulseClock.Elapsed.TotalSeconds % 1.8 / 1.8);
    }

    private void ScanProgressArea_SizeChanged(object sender, SizeChangedEventArgs e) => UpdateScanPulseWidth();

    private void UpdateScanPulseWidth()
    {
        var perimeter = ScanBorderLength();
        if (perimeter <= 0) return;
        var filled = ScanProgressPresentation.FilledWidth(ScanProgressBar.Value, ScanProgressBar.Maximum, perimeter);
        ScanBorderProgress.Visibility = filled > 0 ? Visibility.Visible : Visibility.Collapsed;
        ScanBorderProgress.StrokeDashArray = new DoubleCollection { filled / 2, (perimeter - filled) / 2 };
    }

    // Rectangle centerline: one-DIP margin, half the two-DIP stroke, four-DIP corner radii.
    private double ScanBorderLength() => ScanProgressPresentation.BorderLength(
        ScanProgressArea.ActualWidth, ScanProgressArea.ActualHeight);

    private void StopScanPulse()
    {
        _scanPulseTimer.Stop();
        _scanPulseClock.Stop();
        ScanPulse.Visibility = Visibility.Collapsed;
    }
}
