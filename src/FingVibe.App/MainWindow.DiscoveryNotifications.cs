using FingVibe.Core.Models;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private IReadOnlyList<DeviceDiscovery> _deferredDiscoveries = [];

    private bool IsMinimized => AppWindow.IsMinimized();

    private void InitializeDiscoveryNotifications()
    {
        AppWindow.Changed += DiscoveryWindow_Changed;
        Activated += DiscoveryWindow_Activated;
        Closed += (_, _) =>
        {
            AppWindow.Changed -= DiscoveryWindow_Changed;
            Activated -= DiscoveryWindow_Activated;
        };
    }

    // Discoveries found while minimized, for example by scheduled scans, wait until the window is restored.
    private void PresentDiscoveries(IReadOnlyList<DeviceDiscovery> discoveries)
    {
        if (IsMinimized)
        {
            _deferredDiscoveries = PeriodicScanPresentation.MergeDiscoveries(_deferredDiscoveries, discoveries);
            return;
        }

        ShowDiscoveryPopup(discoveries, deferred: false);
    }

    private void DiscoveryWindow_Changed(AppWindow sender, AppWindowChangedEventArgs args) => QueueDeferredDiscoveries();

    private void DiscoveryWindow_Activated(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState != WindowActivationState.Deactivated)
        {
            QueueDeferredDiscoveries();
        }
    }

    private void QueueDeferredDiscoveries()
    {
        if (_deferredDiscoveries.Count > 0)
        {
            // Let restoration finish before anchoring the popup to the header.
            DispatcherQueue.TryEnqueue(ShowDeferredDiscoveries);
        }
    }

    private void ShowDeferredDiscoveries()
    {
        if (_deferredDiscoveries.Count == 0 || IsMinimized || !AppWindow.IsVisible)
        {
            return;
        }

        var discoveries = _deferredDiscoveries;
        _deferredDiscoveries = [];
        ShowDiscoveryPopup(discoveries, deferred: true);
    }

    private void ShowDiscoveryPopup(IReadOnlyList<DeviceDiscovery> discoveries, bool deferred)
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
            Text = deferred
                ? $"{discoveries.Count} newly observed devices while FingVibe was minimized. Saved locally."
                : $"{discoveries.Count} newly observed devices on this network. Saved locally.",
            TextWrapping = TextWrapping.Wrap
        });
        var entries = new StackPanel { Spacing = 4 };
        var popup = new Flyout { Content = content };
        foreach (var discovery in discoveries)
        {
            var row = _allResults.FirstOrDefault(item => item.IdentityKey == discovery.IdentityKey);
            var mac = string.Join("-", Enumerable.Range(0, 6).Select(i => discovery.Mac.Substring(i * 2, 2)));
            if (row is null)
            {
                // A later scan can replace the displayed results before a deferred popup is shown.
                var unavailable = new TextBlock
                {
                    Text = $"{mac} - not in the displayed results", TextWrapping = TextWrapping.Wrap
                };
                AutomationProperties.SetAutomationId(unavailable, $"Discovery-{discovery.Mac}");
                entries.Children.Add(unavailable);
                continue;
            }

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
