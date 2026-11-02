using System.Diagnostics;
using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
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
    private TaskCompletionSource? _diagramDrained;

    private void ObserveDiagram(DiagnosticObservation observation)
    {
        if (!_open || !IsLoaded || !_uiSettings.AnimationsEnabled) return;
        _diagramMotion.Observe(observation.Checkpoint, observation.State);
        if (_diagramMotion.HasWork && !_diagramTimer.IsEnabled)
        {
            _diagramClock.Restart();
            _diagramTimer.Start();
        }
    }

    private async Task DrainDiagramAsync(CancellationToken cancellationToken)
    {
        if (!_diagramMotion.HasWork) return;
        ProgressText.Text = "Checks finished; completing the illustrative request/response animation.";
        _diagramDrained = new(TaskCreationOptions.RunContinuationsAsynchronously);
        try
        {
            await _diagramDrained.Task.WaitAsync(cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            StopDiagramAnimation();
        }
    }

    private void AnimationSettingsChanged(UISettings sender, object args) => DispatcherQueue.TryEnqueue(() =>
    {
        if (!_uiSettings.AnimationsEnabled) StopDiagramAnimation();
    });

    private void DiagramTimer_Tick(object? sender, object e)
    {
        if (!_open || !IsLoaded || _cancellation is null || _cancellation.IsCancellationRequested
            || !_uiSettings.AnimationsEnabled)
        {
            StopDiagramAnimation();
            return;
        }
        _diagramMotion.Advance(_diagramClock.Elapsed.TotalSeconds);
        _diagramClock.Restart();
        if (_diagramMotion.Checkpoint is not { } checkpoint)
        {
            StopDiagramAnimation();
            return;
        }
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
        _diagramTimer.Stop();
        _diagramClock.Reset();
        _diagramMotion.Reset();
        DiagramDot.Visibility = DiagramEndpoint.Visibility = DiagramPulse.Visibility = Visibility.Collapsed;
        _diagramDrained?.TrySetResult();
        _diagramDrained = null;
    }
}
