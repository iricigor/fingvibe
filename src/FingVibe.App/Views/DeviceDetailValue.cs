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
    private readonly TextBlock _browserText = new() { FontSize = 16, TextWrapping = TextWrapping.Wrap };
    private readonly HyperlinkButton _browser = new()
    {
        Padding = new Thickness(0), MinWidth = 0, MinHeight = 32,
        VerticalAlignment = VerticalAlignment.Center, Visibility = Visibility.Collapsed
    };
    private readonly Grid _valueRow = new() { HorizontalAlignment = HorizontalAlignment.Left, ColumnSpacing = 4, RowSpacing = 4 };
    private readonly Button _copy = new()
    {
        Content = new FontIcon { Glyph = "\uE8C8", FontSize = 14 },
        Width = 32, Height = 32, Padding = new Thickness(4),
        VerticalAlignment = VerticalAlignment.Center, Opacity = 0
    };
    private bool _pointerOver;
    private bool _linkedValue;

    public DeviceDetailValue()
    {
        var content = new StackPanel { Spacing = 2 };
        content.Children.Add(_label);
        for (var index = 0; index < 3; index++)
            _valueRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        _valueRow.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _valueRow.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _valueRow.Children.Add(_value);
        _value.VerticalAlignment = VerticalAlignment.Center;
        SetColumn(_copy, 1);
        _valueRow.Children.Add(_copy);
        SetColumn(_browser, 2);
        _browser.Content = _browserText;
        _valueRow.Children.Add(_browser);
        content.Children.Add(_valueRow);
        content.Children.Add(_source);
        Children.Add(content);
        SizeChanged += (_, _) => ConstrainValue();
        _browser.Click += (_, args) => BrowserRequested?.Invoke(this, args);
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
    internal event RoutedEventHandler? BrowserRequested;

    internal void SetBrowserAction(bool linkedValue, string label, string tooltip)
    {
        _linkedValue = linkedValue;
        _value.Visibility = linkedValue ? Visibility.Collapsed : Visibility.Visible;
        SetColumn(_browser, linkedValue ? 0 : 2);
        _browserText.Text = (linkedValue ? Value : label) + " \u2197";
        _browser.Visibility = Visibility.Visible;
        AutomationProperties.SetName(_browser, $"{label}: {Value}");
        ToolTipService.SetToolTip(_browser, tooltip);
        ConstrainValue();
    }

    private void ConstrainValue()
    {
        if (ActualWidth <= 0) return;
        _browserText.MaxWidth = ActualWidth;
        _browser.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
        var alternate = !_linkedValue && _browser.Visibility == Visibility.Visible;
        var stacked = alternate && ActualWidth < _browser.DesiredSize.Width + 200;
        SetRow(_browser, stacked ? 1 : 0);
        SetColumn(_browser, _linkedValue || stacked ? 0 : 2);
        SetColumnSpan(_browser, stacked ? 2 : 1);
        _browser.HorizontalAlignment = HorizontalAlignment.Left;
        var actionsWidth = (_copy.Visibility == Visibility.Visible ? 36 : 0)
            + (alternate && !stacked ? _browser.DesiredSize.Width + 4 : 0);
        var available = Math.Max(0, ActualWidth - actionsWidth);
        _value.MaxWidth = available;
        _browserText.MaxWidth = _linkedValue ? available : ActualWidth;
    }

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
        ConstrainValue();
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
            var detail = string.IsNullOrWhiteSpace(exception.Message)
                ? $"Clipboard unavailable (0x{exception.HResult:X8}). Try again."
                : exception.Message;
            message.Text = $"Could not copy {Label}: {detail}";
        }
        new Flyout { Content = message }.ShowAt(_copy);
    }
}
