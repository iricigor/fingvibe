using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private void ShowDiscoveryPopup(IReadOnlyList<DeviceDiscovery> discoveries)
    {
        var content = new StackPanel { Spacing = 8, MaxWidth = 400 };
        var title = new TextBlock
        {
            Text = "New devices discovered", Style = (Style)Application.Current.Resources["SubtitleTextBlockStyle"]
        };
        AutomationProperties.SetAutomationId(title, "DiscoveryPopup");
        content.Children.Add(title);
        content.Children.Add(new TextBlock
        {
            Text = $"{discoveries.Count} newly observed devices on this network. Saved locally.",
            TextWrapping = TextWrapping.Wrap
        });
        var entries = new StackPanel { Spacing = 4 };
        var popup = new Flyout { Content = content };
        foreach (var discovery in discoveries)
        {
            var row = _allResults.First(item => item.IdentityKey == discovery.IdentityKey);
            var mac = string.Join("-", Enumerable.Range(0, 6).Select(i => discovery.Mac.Substring(i * 2, 2)));
            var link = new HyperlinkButton
            {
                Content = new TextBlock { Text = $"{mac} - {row.NameText}", TextWrapping = TextWrapping.Wrap },
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left
            };
            AutomationProperties.SetAutomationId(link, $"Discovery-{discovery.Mac}");
            AutomationProperties.SetName(link, $"Open details for {mac}");
            link.Click += (_, _) => { popup.Hide(); ShowDeviceDetails(row); };
            entries.Children.Add(link);
        }
        content.Children.Add(new ScrollViewer
        {
            Content = entries, MaxHeight = 300,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto
        });
        var close = new Button { Content = "Close" };
        AutomationProperties.SetAutomationId(close, "CloseDiscoveryPopup");
        close.Click += (_, _) => popup.Hide();
        content.Children.Add(close);
        popup.ShowAt(ScanFreshnessText, new FlyoutShowOptions { Placement = FlyoutPlacementMode.Bottom });
    }
}
