using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace FingVibe.App;

public sealed class ScanBorderProgressBar : ProgressBar
{
    private Rectangle? _progressOutline;
    private Rectangle? _activityOutline;

    public ScanBorderProgressBar()
    {
        RegisterPropertyChangedCallback(ValueProperty, (_, _) => UpdateBorder());
        RegisterPropertyChangedCallback(MaximumProperty, (_, _) => UpdateBorder());
        SizeChanged += (_, _) => UpdateBorder();
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new ProgressBarAutomationPeer(this);

    protected override void OnApplyTemplate()
    {
        base.OnApplyTemplate();
        _progressOutline = GetTemplateChild("ProgressOutline") as Rectangle
            ?? throw new InvalidOperationException("The scan border template requires ProgressOutline.");
        _activityOutline = GetTemplateChild("ActivityOutline") as Rectangle
            ?? throw new InvalidOperationException("The scan border template requires ActivityOutline.");
        UpdateBorder();
    }

    private void UpdateBorder()
    {
        if (_progressOutline is null) return;
        var perimeter = ScanProgressPresentation.BorderLength(ActualWidth, ActualHeight);
        var filled = ScanProgressPresentation.FilledWidth(Value, Maximum, perimeter);
        _progressOutline.Visibility = filled > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (perimeter <= 0) return;
        _progressOutline.StrokeDashArray = new DoubleCollection { filled / 2, (perimeter - filled) / 2 };
    }

    internal void ShowActivity(TimeSpan elapsed, bool enabled)
    {
        if (_activityOutline is null) return;
        _activityOutline.Visibility = enabled ? Visibility.Visible : Visibility.Collapsed;
        var perimeter = ScanProgressPresentation.BorderLength(ActualWidth, ActualHeight);
        if (perimeter <= 0) return;
        _activityOutline.StrokeDashArray = new DoubleCollection { perimeter * 0.15 / 2, perimeter * 0.85 / 2 };
        _activityOutline.StrokeDashOffset = -perimeter / 2 * (elapsed.TotalSeconds % 1.8 / 1.8);
    }
}
