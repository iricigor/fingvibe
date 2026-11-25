using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Data;
using System.Diagnostics;

namespace FingVibe.App;

public sealed class PersonIcon : ContentControl
{
    private readonly TextBlock _text = new()
    {
        IsColorFontEnabled = true,
        LineStackingStrategy = LineStackingStrategy.BlockLineHeight,
        VerticalAlignment = VerticalAlignment.Center
    };
    public static readonly DependencyProperty IconIdProperty = DependencyProperty.Register(
        nameof(IconId), typeof(string), typeof(PersonIcon), new PropertyMetadata(null, OnIconChanged));

    public string? IconId
    {
        get => (string?)GetValue(IconIdProperty);
        set => SetValue(IconIdProperty, value);
    }

    public PersonIcon()
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
        UpdateIcon();
    }

    private static void OnIconChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args) =>
        ((PersonIcon)sender).UpdateIcon();

    private void UpdateIcon()
    {
        var choice = PeopleRoomsIcons.Resolve(PeopleRoomsIcons.People, IconId);
        if (!PersonEmojiCatalog.IsAvailable(choice, Environment.OSVersion.Version.Build))
        {
            Trace.TraceWarning("Person icon '{0}' needs Windows build {1}; displaying the generic icon without changing its saved ID.",
                choice.Id, choice.MinimumWindowsBuild);
            choice = PeopleRoomsIcons.People[0];
        }
        _text.Text = choice.Glyph;
        _text.FontFamily = new FontFamily(choice.IsEmoji ? "Segoe UI Emoji" : "Segoe Fluent Icons");
    }
}
