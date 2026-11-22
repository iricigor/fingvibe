using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App;

/// <summary>
/// The shared quiet Back action (#658). It owns presentation only: the back arrow, the always-visible destination,
/// and an accessible name and tooltip of "Back to {destination}". Owning pages keep their navigation target,
/// leave guards and tool cleanup in their <see cref="BackRequested"/> handlers. The look is its implicit App.xaml style.
/// </summary>
public sealed class PageBackButton : Button
{
    public static readonly DependencyProperty DestinationProperty = DependencyProperty.Register(
        nameof(Destination), typeof(string), typeof(PageBackButton),
        new PropertyMetadata(string.Empty, (owner, _) => ((PageBackButton)owner).ShowDestination()));

    public static readonly DependencyProperty AccessibleDestinationProperty = DependencyProperty.Register(
        nameof(AccessibleDestination), typeof(string), typeof(PageBackButton),
        new PropertyMetadata(null, (owner, _) => ((PageBackButton)owner).ShowDestination()));

    private readonly TextBlock _destinationText = new() { VerticalAlignment = VerticalAlignment.Center };
    private readonly ToolTip _toolTip = new();

    public PageBackButton()
    {
        var arrow = new FontIcon { Glyph = "\uE72B", FontSize = 16, VerticalAlignment = VerticalAlignment.Center };
        // The Button carries the name; its parts and the tooltip (which repeats that name) stay out of the control
        // view, so name lookups and screen readers find exactly one invokable "Back to …" element.
        AutomationProperties.SetAccessibilityView(arrow, AccessibilityView.Raw);
        AutomationProperties.SetAccessibilityView(_destinationText, AccessibilityView.Raw);
        AutomationProperties.SetAccessibilityView(_toolTip, AccessibilityView.Raw);
        Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { arrow, _destinationText } };
        ToolTipService.SetToolTip(this, _toolTip);
        Click += (_, args) => BackRequested?.Invoke(this, args);
        ShowDestination();
    }

    /// <summary>Raised when the user activates Back by pointer, keyboard (Enter/Space) or UI Automation Invoke.</summary>
    public event RoutedEventHandler? BackRequested;

    /// <summary>The visible destination, for example "Tools" or "People &amp; rooms". It may change at runtime.</summary>
    public string Destination
    {
        get => (string)GetValue(DestinationProperty);
        set => SetValue(DestinationProperty, value);
    }

    /// <summary>
    /// The spoken destination when its wording differs from <see cref="Destination"/> (for example "people and rooms");
    /// null uses <see cref="Destination"/>.
    /// </summary>
    public string? AccessibleDestination
    {
        get => (string?)GetValue(AccessibleDestinationProperty);
        set => SetValue(AccessibleDestinationProperty, value);
    }

    private void ShowDestination()
    {
        var destination = Destination ?? string.Empty;
        var name = $"Back to {(string.IsNullOrEmpty(AccessibleDestination) ? destination : AccessibleDestination)}";
        _destinationText.Text = destination;
        AutomationProperties.SetName(this, name);
        _toolTip.Content = name;
    }
}
