using Microsoft.UI.Xaml.Data;

namespace FingVibe.App;

public sealed class PortIconGlyphConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
    {
        return value is int port
            ? port switch
            {
                22 => "\uE756",
                53 => "\uE968",
                80 or 8080 => "\uE774",
                443 => "\uE72E",
                445 => "\uE8B7",
                554 => "\uE714",
                8008 or 8009 => "\uE7F4",
                9100 => "\uE749",
                _ => "\uE9CE"
            }
            : "\uE9CE";
    }

    public object ConvertBack(object value, Type targetType, object parameter, string language)
    {
        throw new NotSupportedException();
    }
}
