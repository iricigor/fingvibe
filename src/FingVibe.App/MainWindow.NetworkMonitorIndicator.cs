using System.Globalization;
using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Shapes;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    // Re-renders time-dependent text (stale results, "today") between monitor status changes.
    private readonly DispatcherTimer _networkMonitorViewTimer = new() { Interval = TimeSpan.FromSeconds(30) };
    private NetworkMonitorState? _indicatorState;
    private bool _networkMonitorPulsing;
    private string? _networkMonitorViewSignature;

    private void InitializeNetworkMonitorIndicator()
    {
        NetworkMonitorStateChanged += (_, snapshot) => ShowNetworkMonitor(snapshot);
        _networkMonitorViewTimer.Tick += (_, _) => ShowNetworkMonitor(CurrentNetworkMonitorSnapshot);
        _networkMonitorViewTimer.Start();
        Closed += (_, _) => _networkMonitorViewTimer.Stop();
        ShowNetworkMonitor(CurrentNetworkMonitorSnapshot);
    }

    private void NetworkMonitorIndicator_Click(object sender, RoutedEventArgs e) => NetworkHealthRequested(sender, EventArgs.Empty);

    private void ShowNetworkMonitor(NetworkMonitorSnapshot snapshot)
    {
        var view = NetworkMonitorViewPresentation.Create(
            snapshot, DateTimeOffset.UtcNow, TimeZoneInfo.Local, CultureInfo.CurrentCulture);
        if (snapshot.State == NetworkMonitorState.Checking && _indicatorState != NetworkMonitorState.Checking)
            PulseNetworkMonitorIndicator();
        _indicatorState = snapshot.State;
        // Status changes can arrive several times a second (scaled review clocks, skipped checks); only
        // re-render the dot and both result projections when their visible content actually changed.
        var signature = string.Join("\n", new[] { view.Kind.ToString(), view.Title, view.Detail, view.LastCheck }
            .Concat(view.Rows.Select(row => $"{row.Label}\t{row.Result}")));
        if (signature == _networkMonitorViewSignature) return;
        _networkMonitorViewSignature = signature;
        NetworkMonitorDots.Apply(NetworkMonitorDot, view.Kind);
        AutomationProperties.SetName(NetworkMonitorIndicator, view.IndicatorName);
        ToolTipService.SetToolTip(NetworkMonitorIndicator, $"{view.Title}\n{view.LastCheck}");
        NetworkPage.ShowNetworkMonitor(view);
        ToolsPage.ShowNetworkMonitor(view);
    }

    private void PulseNetworkMonitorIndicator()
    {
        // One pulse at a time: checks starting during a pulse do not restart or queue another animation.
        if (_networkMonitorPulsing) return;
        if (!_uiSettings.AnimationsEnabled)
        {
            // The check start stays observable to assistive technology and tests without motion.
            AutomationProperties.SetItemStatus(NetworkMonitorIndicator, "Check started; pulse skipped for reduced motion");
            return;
        }

        var duration = new Duration(TimeSpan.FromSeconds(1.5));
        var pulse = new Storyboard();
        Add(pulse, new DoubleAnimation { From = 0.9, To = 0, Duration = duration }, NetworkMonitorPulse, "Opacity");
        Add(pulse, new DoubleAnimation { From = 1, To = 2.2, Duration = duration }, NetworkMonitorPulseScale, "ScaleX");
        Add(pulse, new DoubleAnimation { From = 1, To = 2.2, Duration = duration }, NetworkMonitorPulseScale, "ScaleY");
        pulse.Completed += (_, _) =>
        {
            _networkMonitorPulsing = false;
            AutomationProperties.SetItemStatus(NetworkMonitorIndicator, "");
        };
        AutomationProperties.SetItemStatus(NetworkMonitorIndicator, "Check started; pulsing");
        _networkMonitorPulsing = true;
        pulse.Begin();

        static void Add(Storyboard storyboard, DoubleAnimation animation, DependencyObject target, string property)
        {
            Storyboard.SetTarget(animation, target);
            Storyboard.SetTargetProperty(animation, property);
            storyboard.Children.Add(animation);
        }
    }
}
