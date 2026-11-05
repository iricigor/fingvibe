namespace FingVibe.App;

internal sealed class NavigationPaneSizing
{
    public const double DefaultWidth = 216;
    public const double CollapseThreshold = 160;
    public const double MaximumWidth = 320;

    public double ExpandedWidth { get; private set; } = DefaultWidth;

    public bool Resize(double requestedWidth, double compactWidth)
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
        if (width < CollapseThreshold)
        {
            return false;
        }

        ExpandedWidth = width;
        return true;
    }
}
