using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Graphics;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private bool _titleBarActive = true;
    private bool _titleBarClosed;
    private RectInt32? _titleBarPassthrough;

    private void InitializeTitleBar()
    {
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(TitleBarDragArea);
        AppWindow.TitleBar.IconShowOptions = IconShowOptions.HideIconAndSystemMenu;
        AppWindow.Changed += TitleBar_WindowChanged;
        Activated += TitleBar_Activated;
        RootGrid.ActualThemeChanged += TitleBar_ActualThemeChanged;
        AppTitleBar.Loaded += (_, _) =>
        {
            AppTitleBar.XamlRoot.Changed += TitleBar_XamlRootChanged;
            UpdateTitleBarLayout();
        };
        Closed += (_, _) =>
        {
            _titleBarClosed = true;
            AppWindow.Changed -= TitleBar_WindowChanged;
            Activated -= TitleBar_Activated;
            RootGrid.ActualThemeChanged -= TitleBar_ActualThemeChanged;
            if (AppTitleBar.XamlRoot is { } root)
            {
                root.Changed -= TitleBar_XamlRootChanged;
            }
        };
    }

    private void TitleBar_Activated(object sender, WindowActivatedEventArgs args)
    {
        _titleBarActive = args.WindowActivationState != WindowActivationState.Deactivated;
        UpdateTitleBarColors();
    }

    private void TitleBar_ActualThemeChanged(FrameworkElement sender, object args) => UpdateTitleBarColors();

    private void TitleBar_WindowChanged(AppWindow sender, AppWindowChangedEventArgs args) => UpdateTitleBarLayout();

    private void TitleBar_XamlRootChanged(XamlRoot sender, XamlRootChangedEventArgs args) => UpdateTitleBarLayout();

    private void AppTitleBar_LayoutUpdated(object? sender, object args) => UpdateTitleBarLayout();

    private void UpdateTitleBarLayout()
    {
        if (_titleBarClosed || AppTitleBar.XamlRoot is not { } root)
        {
            return;
        }

        var scale = root.RasterizationScale;
        TitleBarLeftInset.Width = new GridLength(AppWindow.TitleBar.LeftInset / scale);
        TitleBarRightInset.Width = new GridLength(AppWindow.TitleBar.RightInset / scale);
        AppTitleBar.MinHeight = Math.Max(40, AppWindow.TitleBar.Height / scale);
        var bounds = TitleBarAppearanceButton.TransformToVisual(RootGrid).TransformBounds(
            new Windows.Foundation.Rect(0, 0, TitleBarAppearanceButton.ActualWidth, TitleBarAppearanceButton.ActualHeight));
        if (bounds.Width <= 0 || bounds.Height <= 0)
        {
            return;
        }

        // Nonclient regions use physical client pixels, not XAML DIPs.
        var left = (int)Math.Floor(bounds.Left * scale);
        var top = (int)Math.Floor(bounds.Top * scale);
        var right = (int)Math.Ceiling(bounds.Right * scale);
        var bottom = (int)Math.Ceiling(bounds.Bottom * scale);
        var region = new RectInt32(left, top, right - left, bottom - top);
        if (_titleBarPassthrough != region)
        {
            InputNonClientPointerSource.GetForWindowId(AppWindow.Id).SetRegionRects(
                NonClientRegionKind.Passthrough, [region]);
            _titleBarPassthrough = region;
        }
    }

    private void TitleBarAppearanceButton_Click(object sender, RoutedEventArgs args) =>
        AppearanceShortcutFlyout.ShowAt(TitleBarAppearanceButton);
}
