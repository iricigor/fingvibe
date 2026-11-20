using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Shapes;

namespace FingVibe.App;

/// <summary>Shared monitor visuals for the header dot, Network health and the Network summary.</summary>
internal static class NetworkMonitorDots
{
    public static void Apply(Ellipse dot, NetworkMonitorIndicatorKind kind) =>
        dot.Style = (Style)Application.Current.Resources[kind switch
        {
            NetworkMonitorIndicatorKind.Paused => "NetworkMonitorDotPausedStyle",
            NetworkMonitorIndicatorKind.NoResult => "NetworkMonitorDotNoResultStyle",
            NetworkMonitorIndicatorKind.Checking or NetworkMonitorIndicatorKind.Observed => "NetworkMonitorDotActiveStyle",
            NetworkMonitorIndicatorKind.Stale => "NetworkMonitorDotStaleStyle",
            NetworkMonitorIndicatorKind.Learning => "NetworkMonitorDotLearningStyle",
            NetworkMonitorIndicatorKind.Healthy => "NetworkMonitorDotHealthyStyle",
            NetworkMonitorIndicatorKind.Verifying => "NetworkMonitorDotVerifyingStyle",
            NetworkMonitorIndicatorKind.Problem => "NetworkMonitorDotProblemStyle",
            NetworkMonitorIndicatorKind.Uncertain => "NetworkMonitorDotUncertainStyle",
            _ => "NetworkMonitorDotOffStyle"
        }];

    public static void RenderRows(Panel host, Panel rows, IReadOnlyList<NetworkMonitorRawRow> items, string automationPrefix)
    {
        rows.Children.Clear();
        host.Visibility = items.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
        for (var index = 0; index < items.Count; index++)
        {
            var item = items[index];
            var row = new Grid { ColumnSpacing = 12 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star), MinWidth = 120 });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1.4, GridUnitType.Star) });
            row.Children.Add(new TextBlock { Text = item.Label, TextWrapping = TextWrapping.Wrap });
            var result = new TextBlock { Text = item.Result, TextWrapping = TextWrapping.Wrap };
            AutomationProperties.SetAutomationId(result, $"{automationPrefix}{index}");
            AutomationProperties.SetName(result, $"{item.Label}: {item.Result}");
            Grid.SetColumn(result, 1);
            row.Children.Add(result);
            rows.Children.Add(row);
        }
    }
}
