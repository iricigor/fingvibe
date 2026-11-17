using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;

namespace FingVibe.App;

public sealed partial class PageHeaderIcon : UserControl
{
    public static readonly DependencyProperty IconProperty = DependencyProperty.Register(
        nameof(Icon), typeof(string), typeof(PageHeaderIcon), new PropertyMetadata(null, OnIconChanged));

    public PageHeaderIcon() => InitializeComponent();

    /// <summary>Family asset name under Assets/PageIcons, for example "speed-test".</summary>
    public string? Icon
    {
        get => (string?)GetValue(IconProperty);
        set => SetValue(IconProperty, value);
    }

    private static void OnIconChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args)
    {
        if (sender is PageHeaderIcon control && args.NewValue is string { Length: > 0 } icon)
        {
            control.ColorIcon.Source = new BitmapImage(new Uri($"ms-appx:///Assets/PageIcons/{icon}-color.png"));
            control.MonochromeIcon.UriSource = new Uri($"ms-appx:///Assets/PageIcons/{icon}-mono.png");
        }
    }
}
