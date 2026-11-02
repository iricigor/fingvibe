using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private void InitializeBuildIdentity()
    {
        var build = BuildIdentity.Current;
        Title = build.WindowTitle;
        OverviewPage.ShowBuild(build.Summary);
        BuildRibbonText.Text = build.RibbonText;
        BuildRibbonTimestampText.Text = build.RibbonTimestampText;
        ToolTipService.SetToolTip(BuildRibbon, build.RibbonToolTip);
        AutomationProperties.SetHelpText(BuildRibbon, build.RibbonToolTip);
        AutomationProperties.SetName(BuildRibbon, build.RibbonAccessibleName);
        BuildRibbonArea.Visibility = build.IsRibbonVisible ? Visibility.Visible : Visibility.Collapsed;
    }

    private void BuildRibbon_Click(object sender, RoutedEventArgs e)
    {
        BuildIdentity.Current.Acknowledge();
        BuildRibbonArea.Visibility = Visibility.Collapsed;
        MainNavigation.Focus(FocusState.Programmatic);
    }

    private void AboutFingVibe_Click(object sender, RoutedEventArgs e)
    {
        MainNavigation.SelectedItem = ToolsNavItem;
        ToolsPage.ShowAbout();
    }

    private void UpdateBuildRibbonColors()
    {
        BuildRibbon.Background = new SolidColorBrush(_accessibilitySettings.HighContrast
            ? _uiSettings.GetColorValue(Windows.UI.ViewManagement.UIColorType.Background)
            : Color.FromArgb(255, 255, 179, 71));
        BuildRibbon.Foreground = new SolidColorBrush(_accessibilitySettings.HighContrast
            ? _uiSettings.GetColorValue(Windows.UI.ViewManagement.UIColorType.Foreground)
            : Color.FromArgb(255, 32, 24, 0));
    }
}
