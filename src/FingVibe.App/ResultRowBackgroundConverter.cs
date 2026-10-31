using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace FingVibe.App;

public sealed class ResultRowBackgroundConverter : IValueConverter
{
    private readonly SolidColorBrush _transparent = new(Color.FromArgb(0, 0, 0, 0));
    public SolidColorBrush AlternateBackground { get; } = new();

    public object Convert(object value, Type targetType, object parameter, string language) =>
        (bool)value ? AlternateBackground : _transparent;

    public object ConvertBack(object value, Type targetType, object parameter, string language) =>
        throw new NotSupportedException();
}
