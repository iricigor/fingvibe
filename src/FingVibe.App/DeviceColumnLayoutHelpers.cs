using Microsoft.UI.Xaml;

namespace FingVibe.App;

public static class DeviceColumnLayoutHelpers
{
    private const double TableHorizontalPadding = 24;

    public static GridLength ToGridLength(double width) => new(width);
    public static Thickness RowPadding(double vertical) => new(12, vertical, 12, vertical);
    public static Thickness HeaderPadding(double vertical) => new(12, vertical, 12, vertical);
    public static Thickness HeaderButtonPadding(double vertical) => new(0, vertical, 0, vertical);
    public static Thickness HeaderPrimaryMargin(double top) => new(0, top, 0, 0);
    public static Thickness HeaderTextMargin(double vertical) => new(0, vertical, 12, vertical);
    public static Thickness HeaderSecondaryMargin(double vertical) => new(0, vertical, 0, vertical);
    public static string KnownMetadataText(string? value) =>
        string.IsNullOrWhiteSpace(value) || value is "Unknown" or "-" ? string.Empty : value;

    public static GridLength ToVisibleStarWidth(bool visible) => visible
        ? new GridLength(1, GridUnitType.Star) : new GridLength(0);

    public static string MetadataText(string? value) =>
        string.IsNullOrWhiteSpace(value) || value is "Unknown" or "-" ? "\u2014" : value;

    public static string AssignmentText(Guid? id, string? value) =>
        id is null || string.IsNullOrWhiteSpace(value) ? "\u2014" : value;

    public static string VisibilityChoiceLabel(string header, bool canHide) =>
        canHide ? header : $"{header} (always shown)";

    public static Visibility ToVisibility(bool visible) => visible ? Visibility.Visible : Visibility.Collapsed;
    public static Visibility SecondaryTypeVisibility(bool merged, string value) =>
        ToVisibility(merged && !string.IsNullOrWhiteSpace(value) && value is not "Unknown" and not "-");

    public static double ToTableWidth(double totalColumnWidth) => totalColumnWidth + TableHorizontalPadding;
}
