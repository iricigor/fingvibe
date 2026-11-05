using System.Diagnostics;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    // UI review never touches user preferences; native checks may supply an isolated review file.
    private readonly NavigationPaneSettingsStore? _navigationPaneStore = !IsUiReview
        ? new(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "FingVibe",
            "navigation.json"))
        : Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW_NAVIGATION") is { Length: > 0 } reviewPath
            ? new(reviewPath)
            : null;
    private NavigationPaneSizing _navigationPaneSizing = new();
    private NavigationPaneSettings _savedNavigationPane = new();
    private bool _navigationPaneCollapsed;
    private bool _applyingNavigationResize;

    private void InitializeNavigationPane()
    {
        _savedNavigationPane = _navigationPaneStore?.Load() ?? new NavigationPaneSettings();
        _navigationPaneSizing = new NavigationPaneSizing(_savedNavigationPane.ExpandedWidth);
        _navigationPaneCollapsed = _savedNavigationPane.IsCollapsed;
        MainNavigation.OpenPaneLength = _savedNavigationPane.ExpandedWidth;
        if (_navigationPaneCollapsed)
        {
            // An API close before layout is a forced close, so wide windows keep the icon rail.
            MainNavigation.IsPaneOpen = false;
        }

        MainNavigation.RegisterPropertyChangedCallback(
            NavigationView.IsPaneOpenProperty, (_, _) => UpdateNavigationResizeGrip());
        MainNavigation.DisplayModeChanged += (_, _) => UpdateNavigationResizeGrip();
        MainNavigation.PaneOpening += (_, _) => NavigationPane_OpenStateChanging(isCollapsed: false);
        MainNavigation.PaneClosing += (_, _) => NavigationPane_OpenStateChanging(isCollapsed: true);
        UpdateNavigationResizeGrip();
    }

    private void NavigationPane_OpenStateChanging(bool isCollapsed)
    {
        // Resizing saves once when the drag or key press completes.
        if (!_applyingNavigationResize && !NavigationResizeGrip.IsResizing)
        {
            SaveNavigationPane(isCollapsed);
        }
    }

    private void NavigationResizeGrip_ResizeRequested(object? sender, ResizeRequestedEventArgs args)
    {
        var requestedWidth = args.IsKeyboard && !MainNavigation.IsPaneOpen &&
                             args.Width > MainNavigation.CompactPaneLength
            ? Math.Max(NavigationPaneSizing.CollapseThreshold, args.Width)
            : args.Width;
        var isOpen = _navigationPaneSizing.Resize(
            requestedWidth, MainNavigation.CompactPaneLength, NavigationResizeGrip.IsResizing);
        _applyingNavigationResize = true;
        try
        {
            MainNavigation.OpenPaneLength = _navigationPaneSizing.ExpandedWidth;
            MainNavigation.IsPaneOpen = isOpen;
        }
        finally
        {
            _applyingNavigationResize = false;
        }

        UpdateNavigationResizeGrip();
        if (args.IsKeyboard)
        {
            SaveNavigationPane(!isOpen);
        }
    }

    private void NavigationResizeGrip_ResizeCompleted(object? sender, EventArgs args)
    {
        _navigationPaneSizing.CompleteDrag();
        UpdateNavigationResizeGrip();
        SaveNavigationPane(!MainNavigation.IsPaneOpen);
    }

    private void SaveNavigationPane(bool isCollapsed)
    {
        // Compact and minimal modes close the pane automatically for small windows; keep the wide-window choice.
        if (MainNavigation.DisplayMode == NavigationViewDisplayMode.Expanded)
        {
            _navigationPaneCollapsed = isCollapsed;
        }

        var settings = new NavigationPaneSettings(_navigationPaneSizing.ExpandedWidth, _navigationPaneCollapsed);
        if (_navigationPaneStore is null || settings == _savedNavigationPane)
        {
            return;
        }

        try
        {
            _navigationPaneStore.Save(settings);
            _savedNavigationPane = settings;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            // Navigation keeps working; the next change retries saving the preference.
            Debug.WriteLine(exception);
        }
    }

    private void UpdateNavigationResizeGrip()
    {
        var paneWidth = MainNavigation.IsPaneOpen
            ? MainNavigation.OpenPaneLength
            : MainNavigation.CompactPaneLength;
        NavigationResizeGrip.ResizeWidth = paneWidth;
        var dividerWidth = _navigationPaneSizing.DragWidth ?? paneWidth;
        NavigationResizeGrip.Margin = new Thickness(dividerWidth - NavigationResizeGrip.Width / 2, 0, 0, 0);
        NavigationResizeGrip.Visibility =
            MainNavigation.DisplayMode == NavigationViewDisplayMode.Minimal && !MainNavigation.IsPaneOpen &&
            !NavigationResizeGrip.IsResizing
                ? Visibility.Collapsed
                : Visibility.Visible;
    }
}
