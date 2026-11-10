using FingVibe.Core.Models;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private DiscoveryNotificationState _discoveryNotifications = null!;
    private readonly AsyncSurfaceSession _discoveryActivation = new();
    private bool _discoveryNotificationsClosed;
    private string? _pendingDiscoveryActivation;
    private Flyout? _discoveryPopup;
    private string? _windowsNotificationMessage;
    private bool _windowWasMinimized;
    private bool _openingDiscoveryNotification;
    private bool _renderingDiscoveryActivation;

    private bool IsMinimized => AppWindow.IsMinimized();
    private WindowsDiscoveryNotifications WindowsNotifications => ((App)Application.Current).DiscoveryNotifications;

    private void InitializeDiscoveryNotifications()
    {
        _discoveryNotifications = new(ShowDiscoveryPopup, RequestWindowsDiscoveryNotification);
        _windowsNotificationMessage = WindowsNotifications.RegistrationError;
        _discoveryActivation.StateChanged += (_, _) =>
            AutomationProperties.SetItemStatus(ScanFreshnessText, _discoveryActivation.Status);
        AppWindow.Changed += DiscoveryWindow_Changed;
        Activated += DiscoveryWindow_Activated;
        Closed += (_, _) =>
        {
            _discoveryNotificationsClosed = true;
            _discoveryActivation.Dispose();
        };
    }

    private void PresentDiscoveries(IReadOnlyList<DeviceDiscovery> discoveries)
    {
        if (_discoveryNotificationsClosed) return;
        var devices = discoveries.Select(discovery => DiscoveryDevice.Capture(discovery,
            _allResults.FirstOrDefault(row => row.IdentityKey == discovery.IdentityKey))).ToArray();
        _discoveryNotifications.CompleteScan(devices, IsMinimized);
    }

    private async void RequestWindowsDiscoveryNotification(DiscoveryNotificationBatch batch)
    {
        var message = await WindowsNotifications.SendAsync(batch);
        if (_discoveryNotificationsClosed) return;
        _windowsNotificationMessage = message;
        UpdateScanStatus();
    }

    private void DiscoveryWindow_Changed(AppWindow sender, AppWindowChangedEventArgs args)
    {
        var restored = _windowWasMinimized && !IsMinimized;
        _windowWasMinimized = IsMinimized;
        if (restored) QueueDeferredDiscoveries();
    }

    private void DiscoveryWindow_Activated(object sender, WindowActivatedEventArgs args)
    {
        if (args.WindowActivationState != WindowActivationState.Deactivated && _windowWasMinimized && !IsMinimized)
        {
            _windowWasMinimized = false;
            QueueDeferredDiscoveries();
        }
    }

    private void QueueDeferredDiscoveries()
    {
        if (!_discoveryNotificationsClosed && !IsMinimized && AppWindow.IsVisible)
            DispatcherQueue.TryEnqueue(() =>
            {
                if (!_discoveryNotificationsClosed && !IsMinimized && !_openingDiscoveryNotification)
                    _discoveryNotifications.Restore();
            });
    }

    internal void ActivateDiscoveryNotification(string argument)
    {
        if (_discoveryNotificationsClosed) return;
        _pendingDiscoveryActivation = argument;
        _openingDiscoveryNotification = true;
        if (!WindowsDiscoveryNotifications.RestoreAndFocus(this))
        {
            _windowsNotificationMessage = "Windows did not allow FingVibe to take foreground focus. The discovery list is still available in this window.";
            UpdateScanStatus();
        }
        OpenPendingDiscoveryNotification();
    }

    private async void OpenPendingDiscoveryNotification()
    {
        if (!_inventoryReady || _pendingDiscoveryActivation is not { } argument) return;
        _pendingDiscoveryActivation = null;
        var request = _discoveryActivation.Start("Discovery notification");
        if (request is null) return;
        try
        {
            var batch = await WindowsNotifications.LoadAsync(argument);
            if (_discoveryActivation.IsCurrent(request))
            {
                _renderingDiscoveryActivation = true;
                try { _discoveryNotifications.Activate(batch.Devices); }
                finally { _renderingDiscoveryActivation = false; }
            }
        }
        catch (Exception exception) when (WindowsDiscoveryNotifications.IsIntegrationFailure(exception))
        {
            _discoveryActivation.Complete(request, AsyncSurfaceState.Error, () =>
            {
                _windowsNotificationMessage = $"Unable to open the discovery notification: {exception.Message}";
                UpdateScanStatus();
            });
            if (_discoveryActivation.Number == request.Number)
                _openingDiscoveryNotification = false;
        }
    }

    private void ShowDiscoveryPopup(IReadOnlyList<DiscoveryDevice> discoveries, bool deferred)
    {
        _discoveryPopup?.Hide();
        var content = new DiscoveryPopup
        {
            Width = Math.Max(180, Math.Min(480, RootGrid.ActualWidth - 80)),
            MaxHeight = Math.Max(180, Math.Min(620, RootGrid.ActualHeight - 100)),
            RequestedTheme = RootGrid.ActualTheme
        };
        content.SetDiscoveries(discoveries.Select(device =>
            new DiscoveryPopupItem(device, _allResults.Any(row => row.IdentityKey == device.IdentityKey))).ToArray(), deferred);
        var activationRequest = _renderingDiscoveryActivation ? _discoveryActivation.Current : null;
        content.Loaded += (_, _) =>
        {
            content.UpdateLayout();
            if (activationRequest is not null)
            {
                _discoveryActivation.Complete(activationRequest, AsyncSurfaceState.Ready, () => { });
                if (_discoveryActivation.Number == activationRequest.Number)
                    _openingDiscoveryNotification = false;
            }
        };
        var popup = new Flyout { Content = content };
        _discoveryPopup = popup;
        content.DismissRequested += (_, _) => popup.Hide();
        content.DetailsRequested += (_, identity) =>
        {
            var row = _allResults.FirstOrDefault(item => item.IdentityKey == identity);
            if (row is null)
            {
                _windowsNotificationMessage = "Discovery details are unavailable: the device is not in the displayed results.";
                UpdateScanStatus();
                return;
            }
            popup.Hide();
            ShowDeviceDetails(row);
        };
        popup.ShowAt(ScanFreshnessText, new FlyoutShowOptions { Placement = FlyoutPlacementMode.Bottom });
    }
}
