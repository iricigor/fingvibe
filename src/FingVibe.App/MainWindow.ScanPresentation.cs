using System.Diagnostics;
using Microsoft.UI.Xaml;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private readonly DispatcherTimer _scanPulseTimer = new() { Interval = TimeSpan.FromMilliseconds(33) };
    private readonly Stopwatch _scanPulseClock = new();
    private bool _scanPulseInitialized;

    private void InitializeScanAction()
    {
        ScanButton.IsEnabledChanged += (_, _) => UpdateScanActionIcon();
        UpdateScanActionIcon();
    }

    // A fixed accent foreground cannot dim with the disabled label, so disabled actions use the inherited icon.
    private void UpdateScanActionIcon()
    {
        ScanButtonAccentIcon.Visibility = ScanButton.IsEnabled ? Visibility.Visible : Visibility.Collapsed;
        ScanButtonIcon.Visibility = ScanButton.IsEnabled ? Visibility.Collapsed : Visibility.Visible;
    }

    private void UpdateScanActionLayout()
    {
        var compact = RootGrid.ActualWidth < 480 + 280 * _uiSettings.TextScaleFactor;
        // Both actions stretch to their shared cell; the invisible sizer reserves the widest Stop scan label,
        // so the slot keeps one width across states and timer ticks. Compact actions shrink to their icons.
        ScanButtonLabel.Visibility = CancelButtonLabel.Visibility = ScanActionSizer.Visibility =
            compact ? Visibility.Collapsed : Visibility.Visible;
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
