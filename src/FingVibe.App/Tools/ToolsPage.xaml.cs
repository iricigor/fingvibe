using FingVibe.Core.Models;
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
        set
        {
            SpeedTestView.ActivityCoordinator = value;
            TroubleshootingView.ActivityCoordinator = value;
        }
    }

    public bool HasActiveTest => SpeedTestView.HasActiveTest || TroubleshootingView.HasActiveTest;

    public void SetNetworkContext(LanNetwork? network) => TroubleshootingView.SetNetworkContext(network);

    public async Task StopForNavigationAsync()
    {
        SpeedTestView.Visibility = Visibility.Collapsed;
        AboutView.Visibility = Visibility.Collapsed;
        TroubleshootingView.Visibility = Visibility.Collapsed;
        ToolsLanding.Visibility = Visibility.Visible;
        await Task.WhenAll(SpeedTestView.StopForNavigationAsync(), TroubleshootingView.StopForNavigationAsync());
        SpeedTestView.ResetForNavigation();
    }

    public Task StopForWindowCloseAsync() => Task.WhenAll(
        SpeedTestView.StopForWindowCloseAsync(), TroubleshootingView.StopForWindowCloseAsync());

    private async void TroubleshootingCard_Click(object sender, RoutedEventArgs e)
    {
        ToolsLanding.Visibility = Visibility.Collapsed;
        TroubleshootingView.Visibility = Visibility.Visible;
        await TroubleshootingView.OpenAsync();
    }

    private async void TroubleshootingView_BackRequested(object? sender, EventArgs e)
    {
        await StopForNavigationAsync();
        TroubleshootingCard.Focus(FocusState.Programmatic);
    }

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
