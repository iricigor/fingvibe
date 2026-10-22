using Microsoft.UI.Xaml.Data;
using Windows.UI;

namespace FingVibe.App;

public sealed class LatencyColorConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        var fraction = Math.Clamp((double)value, 0, 1);
        var green = Color.FromArgb(255, 34, 197, 94);
        var amber = Color.FromArgb(255, 245, 158, 11);
        var red = Color.FromArgb(255, 239, 68, 68);
        var start = fraction <= 0.5 ? green : amber;
        var end = fraction <= 0.5 ? amber : red;
        var blend = fraction <= 0.5 ? fraction * 2 : (fraction - 0.5) * 2;

        return Color.FromArgb(
            255,
            (byte)Math.Round(start.R + ((end.R - start.R) * blend)),
            (byte)Math.Round(start.G + ((end.G - start.G) * blend)),
            (byte)Math.Round(start.B + ((end.B - start.B) * blend)));
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}
