using Microsoft.UI.Xaml;

namespace FingVibe.App;

public partial class App : Application
{
    private Window? _window;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        _window = new MainWindow();
        _window.Activate();
        _window.AppWindow.Resize(new Windows.Graphics.SizeInt32(1100, 720));
    }
}
