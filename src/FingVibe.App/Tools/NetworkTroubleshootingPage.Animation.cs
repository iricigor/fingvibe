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
        if (_diagramPlaybackEnabled)
        {
            _diagramMotion.BeginRun(_observations.Values);
            StartDiagramTimer();
        }
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
        if (!_diagramMotion.HasWork)
        {
            PauseDiagramAnimation();
            return;
        }
        var playbackText = _cancellation is null
            ? "Illustrative replay until stopped - recorded results; no network traffic."
            : "Illustrative checks - random destinations, not actual packet timing.";
        if (DiagramPlaybackText.Text != playbackText) DiagramPlaybackText.Text = playbackText;
        DiagramPlaybackText.Visibility = Visibility.Visible;
        for (var index = 0; index < _diagramMotion.Dots.Count; index++)
            RenderDiagramDot(index, _diagramMotion.Dots[index]);
    }

    private (Ellipse Dot, Ellipse Pulse) DiagramShapes(int index) => index switch
    {
        0 => (DiagramDot, DiagramPulse),
        1 => (DiagramDot2, DiagramPulse2),
        2 => (DiagramDot3, DiagramPulse3),
        _ => throw new ArgumentOutOfRangeException(nameof(index))
    };

    private void RenderDiagramDot(int index, DiagnosticDiagramMotion.Dot motion)
    {
        var (dot, pulse) = DiagramShapes(index);
        dot.Visibility = pulse.Visibility = Visibility.Collapsed;
        if (motion.Checkpoint is not { } checkpoint) return;
        var state = motion.State;
        Brush brush = _accessibility.HighContrast
            ? new SolidColorBrush(_uiSettings.GetColorValue(UIColorType.Foreground))
            : state == DiagnosticState.Responded ? StatusBrush(DiagnosticSummaryKind.Good)
            : state is DiagnosticState.Unanswered or DiagnosticState.Error ? StatusBrush(DiagnosticSummaryKind.Problem)
            : (Brush)Application.Current.Resources["TextFillColorPrimaryBrush"];
        dot.Fill = brush;
        pulse.Stroke = brush;
        dot.Opacity = motion.Opacity;
        dot.Width = dot.Height = DiagnosticDiagramMotion.DotSize;
        Windows.Foundation.Point? target = _diagramPorts.TryGetValue(
            checkpoint == DiagnosticCheckpoint.ConfiguredDns ? DiagnosticCheckpoint.LocalAddress : checkpoint, out var port)
            && port.ActualWidth > 0
                ? port.TransformToVisual(DiagramCanvas).TransformPoint(new(7, 7)) : null;
        if (!motion.IsLocal && (!motion.AtTarget || motion.Returning))
        {
            var position = DiagnosticDiagramMotion.Position(checkpoint, motion.Progress);
            Canvas.SetLeft(dot, position.X - DiagnosticDiagramMotion.DotSize / 2);
            Canvas.SetTop(dot, position.Y - DiagnosticDiagramMotion.DotSize / 2);
            dot.Visibility = position.Visible ? Visibility.Visible : Visibility.Collapsed;
        }
        if (motion.ShowPulse && target is { } center)
        {
            var endpointSize = motion.EndpointSize;
            dot.Width = dot.Height = endpointSize;
            Canvas.SetLeft(dot, center.X - endpointSize / 2);
            Canvas.SetTop(dot, center.Y - endpointSize / 2);
            dot.Visibility = Visibility.Visible;
            var size = 18 + 14 * motion.Pulse;
            pulse.Width = pulse.Height = size;
            pulse.Opacity = motion.Opacity * (1 - 0.5 * motion.Pulse);
            Canvas.SetLeft(pulse, center.X - size / 2);
            Canvas.SetTop(pulse, center.Y - size / 2);
            pulse.Visibility = Visibility.Visible;
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
        for (var index = 0; index < _diagramMotion.Dots.Count; index++)
        {
            var (dot, pulse) = DiagramShapes(index);
            dot.Visibility = pulse.Visibility = Visibility.Collapsed;
        }
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
