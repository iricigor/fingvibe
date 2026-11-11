using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;
using Microsoft.Windows.AppNotifications;

namespace FingVibe.App;

public partial class App : Application
{
    private MainWindow? _window;
    private readonly Microsoft.UI.Dispatching.DispatcherQueue _dispatcher;
    private string? _pendingDiscoveryActivation;
    internal WindowsDiscoveryNotifications DiscoveryNotifications { get; }

    public App()
    {
        UnhandledException += (_, args) => LogUiReviewFailure(args.Exception, args.Message);
        InitializeComponent();
        _dispatcher = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        DiscoveryNotifications = new(argument =>
        {
            if (!_dispatcher.TryEnqueue(() => ActivateDiscovery(argument)))
                System.Diagnostics.Trace.TraceError("Unable to queue Windows discovery notification activation.");
        });
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            _window = new MainWindow();
            _window.Activate();
            _window.AppWindow.Resize(new Windows.Graphics.SizeInt32(1280, 800));
            _window.Closed += (_, _) => DiscoveryNotifications.Close();
            try
            {
                var activation = AppInstance.GetCurrent().GetActivatedEventArgs();
                if (activation.Kind == ExtendedActivationKind.AppNotification
                    && activation.Data is AppNotificationActivatedEventArgs notification)
                    ActivateDiscovery(notification.Argument);
                else if (Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW") == "1"
                    && Environment.GetCommandLineArgs().FirstOrDefault(argument =>
                        argument.StartsWith("--review-discovery=", StringComparison.Ordinal)) is { } reviewArgument)
                    ActivateDiscovery("discovery=" + reviewArgument["--review-discovery=".Length..]);
                else if (_pendingDiscoveryActivation is { } pending)
                    ActivateDiscovery(pending);
            }
            catch (Exception exception) when (WindowsDiscoveryNotifications.IsIntegrationFailure(exception))
            {
                _window.ReportDiscoveryNotificationFailure($"Unable to read Windows notification activation: {exception.Message}");
            }
        }

        catch (Exception exception)
        {
            LogUiReviewFailure(exception, "Application launch failed.");
            throw;
        }
    }

    private void ActivateDiscovery(string argument)
    {
        if (_window is null)
        {
            _pendingDiscoveryActivation = argument;
            return;
        }
        _pendingDiscoveryActivation = null;
        _window.ActivateDiscoveryNotification(argument);
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
