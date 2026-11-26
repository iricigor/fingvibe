using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Media;

namespace FingVibe.App;

public sealed class RoomIcon : ContentControl
{
    private readonly TextBlock _text = new()
    {
        LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
        VerticalAlignment = VerticalAlignment.Center
    };

    public static readonly DependencyProperty IconIdProperty = DependencyProperty.Register(
        nameof(IconId), typeof(string), typeof(RoomIcon), new PropertyMetadata(null, OnIconChanged));

    public string? IconId
    {
        get => (string?)GetValue(IconIdProperty);
        set => SetValue(IconIdProperty, value);
    }

    public RoomIcon()
    {
        VerticalAlignment = VerticalAlignment.Center;
        HorizontalContentAlignment = HorizontalAlignment.Center;
        VerticalContentAlignment = VerticalAlignment.Center;
        IsHitTestVisible = false;
        Content = _text;
        foreach (var (property, path) in new[]
        {
            (TextBlock.FontSizeProperty, nameof(FontSize)),
            (TextBlock.LineHeightProperty, nameof(FontSize)),
            (TextBlock.ForegroundProperty, nameof(Foreground)),
            (TextBlock.IsTextScaleFactorEnabledProperty, nameof(IsTextScaleFactorEnabled))
        })
            _text.SetBinding(property, new Binding { Source = this, Path = new PropertyPath(path) });
        AutomationProperties.SetAccessibilityView(this, AccessibilityView.Raw);
        AutomationProperties.SetAccessibilityView(_text, AccessibilityView.Raw);
        UpdateIcon();
    }

    private static void OnIconChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args) =>
        ((RoomIcon)sender).UpdateIcon();

    private void UpdateIcon()
    {
        var choice = PeopleRoomsIcons.Resolve(PeopleRoomsIcons.Rooms, IconId);
        _text.Text = choice.Glyph;
        _text.FontFamily = new FontFamily(choice.IsFontAwesome ? RoomIconCatalog.FontFamily : "Segoe Fluent Icons");
        _text.FontWeight = choice.IsFontAwesome ? FontWeights.Black : FontWeights.Normal;
    }
}
