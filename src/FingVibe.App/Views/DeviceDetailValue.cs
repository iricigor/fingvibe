using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Windows.ApplicationModel.DataTransfer;

namespace FingVibe.App.Views;

public sealed class DeviceDetailValue : Grid
{
    public static readonly DependencyProperty LabelProperty = DependencyProperty.Register(
        nameof(Label), typeof(string), typeof(DeviceDetailValue), new PropertyMetadata("", Changed));
    public static readonly DependencyProperty ValueProperty = DependencyProperty.Register(
        nameof(Value), typeof(string), typeof(DeviceDetailValue), new PropertyMetadata("", Changed));
    public static readonly DependencyProperty SourceProperty = DependencyProperty.Register(
        nameof(Source), typeof(string), typeof(DeviceDetailValue), new PropertyMetadata("", Changed));

    private readonly TextBlock _label = new() { FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock _value = new() { FontSize = 16, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
    private readonly TextBlock _source = new() { TextWrapping = TextWrapping.Wrap, Opacity = 0.75 };
    private readonly Button _copy = new()
    {
        Content = new FontIcon { Glyph = "\uE8C8", FontSize = 14 },
        Width = 32, Height = 32, Padding = new Thickness(4),
        VerticalAlignment = VerticalAlignment.Top, Opacity = 0
    };
    private bool _pointerOver;

    public DeviceDetailValue()
    {
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(36) });
        var content = new StackPanel { Spacing = 2 };
        content.Children.Add(_label);
        content.Children.Add(_value);
        content.Children.Add(_source);
        Children.Add(content);
        SetColumn(_copy, 1);
        Children.Add(_copy);
        _copy.Click += Copy_Click;
        PointerEntered += (_, _) => { _pointerOver = true; UpdateCopyOpacity(); };
        PointerExited += (_, _) => { _pointerOver = false; UpdateCopyOpacity(); };
        _copy.GotFocus += (_, _) => UpdateCopyOpacity();
        _copy.LostFocus += (_, _) => UpdateCopyOpacity();
        Refresh();
    }

    public string Label { get => (string)GetValue(LabelProperty); set => SetValue(LabelProperty, value); }
    public string Value { get => (string)GetValue(ValueProperty); set => SetValue(ValueProperty, value); }
    public string Source { get => (string)GetValue(SourceProperty); set => SetValue(SourceProperty, value); }
    public double ValueFontSize { get => _value.FontSize; set => _value.FontSize = value; }

    private static void Changed(DependencyObject sender, DependencyPropertyChangedEventArgs args) =>
        ((DeviceDetailValue)sender).Refresh();

    private void Refresh()
    {
        _label.Text = Label;
        _label.Visibility = string.IsNullOrWhiteSpace(Label) ? Visibility.Collapsed : Visibility.Visible;
        _value.Text = string.IsNullOrWhiteSpace(Value) ? "-" : Value;
        _source.Text = Source;
        _source.Visibility = string.IsNullOrWhiteSpace(Source) ? Visibility.Collapsed : Visibility.Visible;
        _copy.Visibility = DeviceDetailsPresentation.CanCopy(Value) ? Visibility.Visible : Visibility.Collapsed;
        AutomationProperties.SetName(_copy, $"Copy {Label}");
        ToolTipService.SetToolTip(_copy, $"Copy {Label}");
    }

    private void UpdateCopyOpacity() =>
        _copy.Opacity = _pointerOver || _copy.FocusState != FocusState.Unfocused ? 1 : 0;

    private void Copy_Click(object sender, RoutedEventArgs e)
    {
        var message = new TextBlock { TextWrapping = TextWrapping.Wrap, MaxWidth = 320 };
        AutomationProperties.SetLiveSetting(message, AutomationLiveSetting.Polite);
        try
        {
            var data = new DataPackage();
            data.SetText(Value);
            Clipboard.SetContent(data);
            Clipboard.Flush();
            message.Text = $"{Label} copied.";
        }
        catch (Exception exception) when (exception is System.Runtime.InteropServices.COMException
            or UnauthorizedAccessException or InvalidOperationException)
        {
            message.Text = $"Could not copy {Label}: {exception.Message}";
        }
        new Flyout { Content = message }.ShowAt(_copy);
    }
}
