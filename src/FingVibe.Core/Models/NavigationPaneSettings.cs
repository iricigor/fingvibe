namespace FingVibe.Core.Models;

public sealed record NavigationPaneSettings(
    double ExpandedWidth = NavigationPaneSettings.DefaultExpandedWidth,
    bool IsCollapsed = false)
{
    public const double DefaultExpandedWidth = 216;
    public const double MinimumExpandedWidth = 160;
    public const double MaximumExpandedWidth = 320;
}
