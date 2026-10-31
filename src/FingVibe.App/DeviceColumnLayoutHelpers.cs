using Microsoft.UI.Xaml;

namespace FingVibe.App;

public static class DeviceColumnLayoutHelpers
{
    private const double TableHorizontalPadding = 24;

    public static GridLength ToGridLength(double width) => new(width);

    public static Visibility ToVisibility(bool visible) => visible ? Visibility.Visible : Visibility.Collapsed;

    public static double ToTableWidth(double totalColumnWidth) => totalColumnWidth + TableHorizontalPadding;
}
