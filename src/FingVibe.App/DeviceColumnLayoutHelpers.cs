using Microsoft.UI.Xaml;

namespace FingVibe.App;

public static class DeviceColumnLayoutHelpers
{
    private const double TableHorizontalPadding = 24;

    public static GridLength ToGridLength(double width) => new(width);

    public static GridLength ToVisibleStarWidth(bool visible) => visible
        ? new GridLength(1, GridUnitType.Star) : new GridLength(0);

    public static string MetadataText(string? value) =>
        string.IsNullOrWhiteSpace(value) || value is "Unknown" or "-" ? "\u2014" : value;

    public static string AssignmentText(Guid? id, string? value) =>
        id is null || string.IsNullOrWhiteSpace(value) ? "\u2014" : value;

    public static Visibility ToVisibility(bool visible) => visible ? Visibility.Visible : Visibility.Collapsed;

    public static double ToTableWidth(double totalColumnWidth) => totalColumnWidth + TableHorizontalPadding;
}
