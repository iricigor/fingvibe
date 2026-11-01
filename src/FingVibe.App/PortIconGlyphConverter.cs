using Microsoft.UI.Xaml.Data;
using FingVibe.Core.Models;

namespace FingVibe.App;

public sealed class PortIconGlyphConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        return value is OpenPort endpoint ? PortServiceIcons.Glyph(endpoint) : "\uE9CE";
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotSupportedException();
    }
}
