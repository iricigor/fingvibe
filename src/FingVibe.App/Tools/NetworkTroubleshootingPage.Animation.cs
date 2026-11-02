using System.Diagnostics;
using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using Windows.UI.ViewManagement;

namespace FingVibe.App;

public sealed partial class NetworkTroubleshootingPage
{
    private readonly DiagnosticDiagramMotion _diagramMotion = new();
    private readonly DispatcherTimer _diagramTimer = new() { Interval = TimeSpan.FromMilliseconds(16) };
    private readonly Stopwatch _diagramClock = new();
    private readonly Dictionary<DiagnosticCheckpoint, Ellipse> _diagramPorts = [];
    private bool _diagramPlaybackEnabled;

    private void BeginDiagramAnimation()
    {
        _diagramPlaybackEnabled = _open && IsLoaded && _uiSettings.AnimationsEnabled;
        if (_diagramPlaybackEnabled) _diagramMotion.BeginRun(Random.Shared.Next(3, 6));
    }

    private void ObserveDiagram(DiagnosticObservation observation)
    {
        if (!_diagramPlaybackEnabled || !_open || !IsLoaded || !_uiSettings.AnimationsEnabled) return;
        _diagramMotion.Observe(observation.Checkpoint, observation.State);
        StartDiagramTimer();
    }

    private void StartDiagramTimer()
    {
        if (_diagramMotion.HasWork && !_diagramTimer.IsEnabled)
        {
            _diagramClock.Restart();
            _diagramTimer.Start();
        }
    }

    private void CompleteDiagramAnimation(NetworkDiagnosticReport report)
    {
        if (!_diagramPlaybackEnabled || !_uiSettings.AnimationsEnabled)
        {
            StopDiagramAnimation();
            return;
        }
        _diagramMotion.CompleteRun(report.Observations);
        StartDiagramTimer();
    }

    private void AnimationSettingsChanged(UISettings sender, object args) => DispatcherQueue.TryEnqueue(() =>
    {
        if (!_uiSettings.AnimationsEnabled) StopDiagramAnimation();
    });

    private void DiagramTimer_Tick(object? sender, object e)
    {
        if (!_open || !IsLoaded || !_diagramPlaybackEnabled || _cancellation is { IsCancellationRequested: true }
            || !_uiSettings.AnimationsEnabled)
        {
            StopDiagramAnimation();
            return;
        }
        _diagramMotion.Advance(_diagramClock.Elapsed.TotalSeconds);
        _diagramClock.Restart();
        if (_diagramMotion.Checkpoint is not { } checkpoint)
        {
            PauseDiagramAnimation();
            return;
        }
        var playbackText = $"Illustrative pass {_diagramMotion.PassNumber} of {_diagramMotion.TotalPasses}"
            + (_cancellation is null ? " - recorded results; no network traffic." : " - not actual packet timing.");
        if (DiagramPlaybackText.Text != playbackText) DiagramPlaybackText.Text = playbackText;
        DiagramPlaybackText.Visibility = Visibility.Visible;
        var state = _diagramMotion.State;
        Brush brush = _accessibility.HighContrast
            ? new SolidColorBrush(_uiSettings.GetColorValue(UIColorType.Foreground))
            : state == DiagnosticState.Responded ? StatusBrush(DiagnosticSummaryKind.Good)
            : state is DiagnosticState.Unanswered or DiagnosticState.Error ? StatusBrush(DiagnosticSummaryKind.Problem)
            : (Brush)Application.Current.Resources["TextFillColorPrimaryBrush"];
        DiagramDot.Fill = brush;
        DiagramEndpoint.Fill = brush;
        DiagramPulse.Stroke = brush;
        DiagramDot.Opacity = _diagramMotion.Opacity;
        DiagramDot.Visibility = Visibility.Collapsed;
        Windows.Foundation.Point? target = _diagramPorts.TryGetValue(
            checkpoint == DiagnosticCheckpoint.ConfiguredDns ? DiagnosticCheckpoint.LocalAddress : checkpoint, out var port)
            && port.ActualWidth > 0
                ? port.TransformToVisual(DiagramCanvas).TransformPoint(new(7, 7)) : null;
        if (!_diagramMotion.IsLocal && (!_diagramMotion.AtTarget || _diagramMotion.Returning))
        {
            var position = DiagnosticDiagramMotion.Position(checkpoint, _diagramMotion.Progress);
            Canvas.SetLeft(DiagramDot, position.X - DiagnosticDiagramMotion.DotSize / 2);
            Canvas.SetTop(DiagramDot, position.Y - DiagnosticDiagramMotion.DotSize / 2);
            DiagramDot.Visibility = position.Visible ? Visibility.Visible : Visibility.Collapsed;
        }
        DiagramPulse.Visibility = Visibility.Collapsed;
        DiagramEndpoint.Visibility = Visibility.Collapsed;
        if (_diagramMotion.ShowPulse && target is { } center)
        {
            var endpointSize = _diagramMotion.EndpointSize;
            DiagramEndpoint.Width = DiagramEndpoint.Height = endpointSize;
            DiagramEndpoint.Opacity = _diagramMotion.Opacity;
            Canvas.SetLeft(DiagramEndpoint, center.X - endpointSize / 2);
            Canvas.SetTop(DiagramEndpoint, center.Y - endpointSize / 2);
            DiagramEndpoint.Visibility = Visibility.Visible;
            var size = 18 + 14 * _diagramMotion.Pulse;
            DiagramPulse.Width = DiagramPulse.Height = size;
            DiagramPulse.Opacity = _diagramMotion.Opacity * (1 - 0.5 * _diagramMotion.Pulse);
            Canvas.SetLeft(DiagramPulse, center.X - size / 2);
            Canvas.SetTop(DiagramPulse, center.Y - size / 2);
            DiagramPulse.Visibility = Visibility.Visible;
        }
    }

    private void StopDiagramAnimation()
    {
        _diagramPlaybackEnabled = false;
        _diagramMotion.Reset();
        PauseDiagramAnimation();
    }

    private void PauseDiagramAnimation()
    {
        _diagramTimer.Stop();
        _diagramClock.Reset();
        DiagramDot.Visibility = DiagramEndpoint.Visibility = DiagramPulse.Visibility = Visibility.Collapsed;
        DiagramPlaybackText.Visibility = Visibility.Collapsed;
        UpdateAnimationCancelButton();
    }

    private void UpdateAnimationCancelButton()
    {
        var replay = _cancellation is null && _diagramMotion.HasWork;
        CancelRunButton.IsEnabled = _cancellation is not null || replay;
        CancelRunButton.Content = replay ? "Stop replay" : "Cancel";
        AutomationProperties.SetName(CancelRunButton, replay ? "Stop diagnostic animation" : "Cancel network troubleshooting");
    }
}
