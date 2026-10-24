using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App;

public sealed partial class ToolsPage : UserControl
{
    public ToolsPage()
    {
        InitializeComponent();
    }

    internal NetworkActivityCoordinator? ActivityCoordinator
    {
        get => SpeedTestView.ActivityCoordinator;
        set => SpeedTestView.ActivityCoordinator = value;
    }

    public bool HasActiveTest => SpeedTestView.HasActiveTest;

    public async Task StopForNavigationAsync()
    {
        SpeedTestView.Visibility = Visibility.Collapsed;
        AboutView.Visibility = Visibility.Collapsed;
        ToolsLanding.Visibility = Visibility.Visible;
        await SpeedTestView.StopForNavigationAsync();
        SpeedTestView.ResetForNavigation();
    }

    public Task StopForWindowCloseAsync() => SpeedTestView.StopForWindowCloseAsync();

    private void SpeedTestCard_Click(object sender, RoutedEventArgs e)
    {
        ToolsLanding.Visibility = Visibility.Collapsed;
        SpeedTestView.Visibility = Visibility.Visible;
        SpeedTestView.FocusStartButton();
    }

    public void ShowAbout()
    {
        ToolsLanding.Visibility = Visibility.Collapsed;
        AboutView.Visibility = Visibility.Visible;
        AboutView.FocusHeading();
    }

    private void AboutCard_Click(object sender, RoutedEventArgs e) => ShowAbout();

    private void AboutView_BackRequested(object? sender, EventArgs e)
    {
        AboutView.Visibility = Visibility.Collapsed;
        ToolsLanding.Visibility = Visibility.Visible;
        AboutCard.Focus(FocusState.Programmatic);
    }

    private async void SpeedTestView_BackRequested(object sender, EventArgs e)
    {
        await StopForNavigationAsync();
        SpeedTestCard.Focus(FocusState.Programmatic);
    }
}
