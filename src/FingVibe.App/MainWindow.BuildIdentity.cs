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
        OverviewVersionText.Text = build.Summary;
        AboutVersionText.Text = build.Summary;
        BuildRibbonText.Text = build.RibbonText;
        AutomationProperties.SetName(BuildRibbon, $"Acknowledge {build.Label}; hide ribbon until the app closes");
        BuildRibbonArea.Visibility = build.IsRibbonVisible ? Visibility.Visible : Visibility.Collapsed;
        UpdateBuildHeaderLayout();
    }

    private void BuildRibbon_Click(object sender, RoutedEventArgs e)
    {
        BuildIdentity.Current.Acknowledge();
        BuildRibbonArea.Visibility = Visibility.Collapsed;
        UpdateBuildHeaderLayout();
        MainNavigation.Focus(FocusState.Programmatic);
    }

    private void BuildHeader_SizeChanged(object sender, SizeChangedEventArgs e) => UpdateBuildHeaderLayout();

    private void UpdateBuildHeaderLayout()
    {
        var hasRibbon = BuildRibbonArea.Visibility == Visibility.Visible;
        var stackHeader = hasRibbon && BuildHeader.ActualWidth < 720;
        Grid.SetRow(ScanBar, stackHeader ? 1 : 0);
        Grid.SetColumnSpan(ScanBar, !hasRibbon || stackHeader ? 2 : 1);
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
