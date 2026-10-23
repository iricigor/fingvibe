using Microsoft.UI.Xaml;

namespace FingVibe.App;

public partial class App : Application
{
    private Window? _window;

    public App()
    {
        UnhandledException += (_, args) => LogUiReviewFailure(args.Exception, args.Message);
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            _window = new MainWindow();
            _window.Activate();
            _window.AppWindow.Resize(new Windows.Graphics.SizeInt32(1280, 800));
        }
        catch (Exception exception)
        {
            LogUiReviewFailure(exception, "Application launch failed.");
            throw;
        }
    }

    private static void LogUiReviewFailure(Exception exception, string message)
    {
        if (Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW") != "1")
        {
            return;
        }

        try
        {
            File.AppendAllText(
                Path.Combine(Path.GetTempPath(), "fingvibe-ui-review-startup.log"),
                $"{message}{Environment.NewLine}HRESULT: 0x{exception.HResult:X8}{Environment.NewLine}{exception}{Environment.NewLine}");
        }
        catch (Exception logException) when (logException is IOException or UnauthorizedAccessException)
        {
            // Diagnostics must not replace or suppress the original startup exception.
        }
    }
}
