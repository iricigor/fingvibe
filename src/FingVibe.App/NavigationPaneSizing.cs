using FingVibe.Core.Models;

namespace FingVibe.App;

internal sealed class NavigationPaneSizing
{
    public const double DefaultWidth = NavigationPaneSettings.DefaultExpandedWidth;
    public const double CollapseThreshold = NavigationPaneSettings.MinimumExpandedWidth;
    public const double MaximumWidth = NavigationPaneSettings.MaximumExpandedWidth;

    public NavigationPaneSizing(double expandedWidth = DefaultWidth)
    {
        if (!double.IsFinite(expandedWidth) || expandedWidth < CollapseThreshold || expandedWidth > MaximumWidth)
        {
            throw new ArgumentOutOfRangeException(nameof(expandedWidth));
        }

        ExpandedWidth = expandedWidth;
    }

    public double ExpandedWidth { get; private set; }
    public double? DragWidth { get; private set; }

    public bool Resize(double requestedWidth, double compactWidth, bool isDragging = false)
    {
        if (!double.IsFinite(requestedWidth))
        {
            throw new ArgumentOutOfRangeException(nameof(requestedWidth));
        }
        if (!double.IsFinite(compactWidth) || compactWidth < 0 || compactWidth >= CollapseThreshold)
        {
            throw new ArgumentOutOfRangeException(nameof(compactWidth));
        }

        var width = Math.Clamp(requestedWidth, compactWidth, MaximumWidth);
        DragWidth = isDragging ? width : null;
        if (width < CollapseThreshold)
        {
            return false;
        }

        ExpandedWidth = width;
        return true;
    }

    public void CompleteDrag() => DragWidth = null;
}
