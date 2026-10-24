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
        await SpeedTestView.StopForNavigationAsync();
        SpeedTestView.ResetForNavigation();
        SpeedTestView.Visibility = Visibility.Collapsed;
        ToolsLanding.Visibility = Visibility.Visible;
    }

    public Task StopForWindowCloseAsync() => SpeedTestView.StopForWindowCloseAsync();

    private void SpeedTestCard_Click(object sender, RoutedEventArgs e)
    {
        ToolsLanding.Visibility = Visibility.Collapsed;
        SpeedTestView.Visibility = Visibility.Visible;
        SpeedTestView.FocusStartButton();
    }

    private async void SpeedTestView_BackRequested(object sender, EventArgs e)
    {
        await StopForNavigationAsync();
        SpeedTestCard.Focus(FocusState.Programmatic);
    }
}
