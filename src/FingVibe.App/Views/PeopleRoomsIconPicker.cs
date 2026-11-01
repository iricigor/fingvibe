using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace FingVibe.App.Views;

internal static class PeopleRoomsIconPicker
{
    internal static ComboBox Create(IReadOnlyList<PeopleRoomsIconChoice> choices, string? savedId)
    {
        var picker = new ComboBox
        {
            Header = "Icon",
            HorizontalAlignment = HorizontalAlignment.Stretch,
            SelectedValuePath = "Tag"
        };
        AutomationProperties.SetName(picker, "Icon");
        foreach (var choice in choices)
        {
            picker.Items.Add(CreateItem(choice));
        }

        var resolved = PeopleRoomsIcons.Resolve(choices, savedId);
        if (savedId is not null && choices.All(choice => choice.Id != savedId))
        {
            picker.Items.Add(CreateItem(new PeopleRoomsIconChoice(
                savedId, "Unavailable saved icon (generic)", resolved.Glyph)));
        }

        picker.SelectedValue = savedId ?? resolved.Id;
        return picker;
    }

    private static ComboBoxItem CreateItem(PeopleRoomsIconChoice choice)
    {
        var icon = new FontIcon
        {
            Glyph = choice.Glyph,
            FontFamily = new FontFamily("Segoe Fluent Icons"),
            FontSize = 16
        };
        AutomationProperties.SetAccessibilityView(icon, AccessibilityView.Raw);
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        content.Children.Add(icon);
        content.Children.Add(new TextBlock { Text = choice.Label });
        var item = new ComboBoxItem { Tag = choice.Id, Content = content };
        AutomationProperties.SetName(item, choice.Label);
        return item;
    }
}
