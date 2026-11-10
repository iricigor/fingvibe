using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Windows.AppNotifications;

namespace FingVibe.App;

internal sealed class WindowsDiscoveryNotifications
{
    private readonly DiscoveryNotificationStore _store;
    private readonly Action<string> _activate;
    private AppNotificationManager? _manager;
    private bool _registered;
    internal bool IsEnabled { get; }
    internal string? RegistrationError { get; private set; }

    internal WindowsDiscoveryNotifications(Action<string> activate)
    {
        _activate = activate;
        var review = Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW") == "1";
        IsEnabled = !review || Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW_NOTIFICATIONS") == "1";
        var reviewInventory = Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW_INVENTORY");
        var directory = review
            ? Path.Combine(Path.GetDirectoryName(reviewInventory ?? Path.Combine(Path.GetTempPath(), "FingVibe-review", "inventory.json"))!,
                "discovery-notifications")
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "FingVibe", "discovery-notifications");
        _store = new(directory);
        if (!IsEnabled) return;
        try
        {
            // Subscribe before registration so clicks on a running unpackaged app stay in this process.
            _manager = AppNotificationManager.Default;
            _manager.NotificationInvoked += NotificationInvoked;
            _manager.Register("FingVibe",
                new Uri(Path.Combine(AppContext.BaseDirectory, "Assets", "Scanner.ico")));
            _registered = true;
        }
        catch (Exception exception) when (IsIntegrationFailure(exception))
        {
            RegistrationError = $"Windows notification registration failed: {exception.Message}";
        }
    }

    internal async Task<string?> SendAsync(DiscoveryNotificationBatch batch)
    {
        if (!IsEnabled) return null;
        if (!_registered) return RegistrationError ?? "Windows notifications are unavailable because FingVibe is closing.";
        try
        {
            await _store.SaveAsync(batch);
            if (!_registered || _manager is not { } manager)
                return "Windows notifications are unavailable because FingVibe is closing.";
            var setting = manager.Setting;
            var notification = new AppNotification(DiscoveryNotificationPresentation.ToastXml(batch,
                Path.Combine(AppContext.BaseDirectory, "Assets", "DiscoveryCaution.png")))
            {
                Tag = batch.Id.ToString("N"),
                Group = "discovery",
                Expiration = batch.ExpiresAt
            };
            manager.Show(notification);
            if (setting != AppNotificationSetting.Enabled)
                return $"Windows notifications are unavailable ({setting}). Discoveries remain available in FingVibe.";
            if (notification.Id == 0)
                throw new InvalidOperationException("Windows did not accept the notification.");
            // Acceptance is not evidence that Windows displayed a banner (settings/DND still apply).
            return null;
        }
        catch (Exception exception) when (IsIntegrationFailure(exception))
        {
            return $"Unable to request a Windows discovery notification: {exception.Message}";
        }
    }

    internal Task<DiscoveryNotificationBatch> LoadAsync(string argument) =>
        _store.LoadAsync(DiscoveryNotificationPresentation.ParseArgument(argument));

    internal static bool RestoreAndFocus(Microsoft.UI.Xaml.Window window)
    {
        if (window.AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter) presenter.Restore();
        window.AppWindow.Show();
        window.Activate();
        return SetForegroundWindow(WinRT.Interop.WindowNative.GetWindowHandle(window));
    }

    internal void Close()
    {
        if (_manager is not { } manager) return;
        try
        {
            manager.NotificationInvoked -= NotificationInvoked;
            if (_registered) manager.Unregister();
        }
        catch (Exception exception) when (IsIntegrationFailure(exception))
        {
            System.Diagnostics.Trace.TraceError($"Windows notification cleanup failed: {exception}");
        }
        finally
        {
            _registered = false;
            _manager = null;
        }
    }

    private void NotificationInvoked(AppNotificationManager sender, AppNotificationActivatedEventArgs args) =>
        _activate(args.Argument);

    internal static bool IsIntegrationFailure(Exception exception) =>
        exception is COMException or InvalidOperationException or IOException or InvalidDataException or UnauthorizedAccessException
            or ArgumentException or JsonException or NotSupportedException;

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr window);
}
