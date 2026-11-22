using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Windows.Graphics;
using WinRT.Interop;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private bool _titleBarActive = true;
    private bool _titleBarClosed;
    private RectInt32[] _titleBarPassthrough = [];
    private RectInt32 _maximizeRegion;
    private InputNonClientPointerSource? _titleBarPointerSource;
    private WindowSubclassProcedure? _titleBarSubclass;
    private IntPtr _titleBarWindowHandle;
    private bool _titleBarSubclassInstalled;
    private bool _maximizeHovered;
    private bool _maximizePressed;
    private static readonly UIntPtr TitleBarSubclassId = new(719);

    private void InitializeTitleBar()
    {
        ExtendsContentIntoTitleBar = true;
        AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Collapsed;
        SetTitleBar(TitleBarDragArea);
        _titleBarWindowHandle = WindowNative.GetWindowHandle(this);
        _titleBarPointerSource = InputNonClientPointerSource.GetForWindowId(AppWindow.Id);
        _titleBarSubclass = TitleBar_WindowProcedure;
        if (!SetWindowSubclass(_titleBarWindowHandle, _titleBarSubclass, TitleBarSubclassId, UIntPtr.Zero))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not initialize custom caption controls.");
        }
        _titleBarSubclassInstalled = true;
        UpdateTitleBarPresenter();
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
            if (_titleBarSubclassInstalled)
            {
                if (!RemoveWindowSubclass(_titleBarWindowHandle, _titleBarSubclass!, TitleBarSubclassId))
                {
                    Trace.TraceError("Could not remove the custom title-bar window subclass.");
                }
                _titleBarSubclassInstalled = false;
            }
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

    private void TitleBar_WindowChanged(AppWindow sender, AppWindowChangedEventArgs args)
    {
        UpdateTitleBarPresenter();
        UpdateTitleBarLayout();
    }

    private void TitleBar_XamlRootChanged(XamlRoot sender, XamlRootChangedEventArgs args) => UpdateTitleBarLayout();

    private void AppTitleBar_LayoutUpdated(object? sender, object args) => UpdateTitleBarLayout();

    private void UpdateTitleBarLayout()
    {
        if (_titleBarClosed || AppTitleBar.XamlRoot is not { } root || _titleBarPointerSource is not { } source)
        {
            return;
        }

        var scale = root.RasterizationScale;
        var regions = new[] { TitleBarAppearanceButton, TitleBarMinimizeButton, TitleBarMaximizeButton, TitleBarCloseButton }
            .Select(button => GetTitleBarRegion(button, scale)).ToArray();
        if (regions.Any(region => region.Width <= 0 || region.Height <= 0))
        {
            return;
        }

        _maximizeRegion = regions[2];
        if (!_titleBarPassthrough.SequenceEqual(regions))
        {
            source.SetRegionRects(NonClientRegionKind.Passthrough, regions);
            _titleBarPassthrough = regions;
        }
    }

    private RectInt32 GetTitleBarRegion(FrameworkElement element, double scale)
    {
        var bounds = element.TransformToVisual(RootGrid).TransformBounds(
            new Windows.Foundation.Rect(0, 0, element.ActualWidth, element.ActualHeight));
        // Nonclient hit testing uses physical client pixels, not XAML DIPs.
        var left = (int)Math.Floor(bounds.Left * scale);
        var top = (int)Math.Floor(bounds.Top * scale);
        var right = (int)Math.Ceiling(bounds.Right * scale);
        var bottom = (int)Math.Ceiling(bounds.Bottom * scale);
        return new RectInt32(left, top, right - left, bottom - top);
    }

    private void TitleBarMinimizeButton_Click(object sender, RoutedEventArgs args)
    {
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.Minimize();
        }
        else
        {
            Trace.TraceError("Minimize is unavailable for the current window presenter.");
        }
    }

    private void TitleBarMaximizeButton_Click(object sender, RoutedEventArgs args) => ToggleWindowMaximized();

    private void TitleBarCloseButton_Click(object sender, RoutedEventArgs args) => Close();

    private void ToggleWindowMaximized()
    {
        if (AppWindow.Presenter is not OverlappedPresenter presenter)
        {
            Trace.TraceError("Maximize/restore is unavailable for the current window presenter.");
            return;
        }
        if (presenter.State == OverlappedPresenterState.Maximized) presenter.Restore();
        else presenter.Maximize();
    }

    private void UpdateTitleBarPresenter()
    {
        if (_titleBarClosed) return;
        var maximized = AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Maximized };
        TitleBarMaximizeIcon.Glyph = maximized ? "\uE923" : "\uE922";
        var name = maximized ? "Restore" : "Maximize";
        AutomationProperties.SetName(TitleBarMaximizeButton, name);
        AutomationProperties.SetHelpText(TitleBarMaximizeButton, "Hover for Windows Snap Layouts, or activate to " + name.ToLowerInvariant() + ".");
        ToolTipService.SetToolTip(TitleBarMaximizeButton, name);
    }

    private bool IsInMaximizeRegion(NativePoint point) =>
        point.X >= _maximizeRegion.X && point.X < _maximizeRegion.X + _maximizeRegion.Width
        && point.Y >= _maximizeRegion.Y && point.Y < _maximizeRegion.Y + _maximizeRegion.Height;

    private static NativePoint DecodeTitleBarPoint(IntPtr value)
    {
        var packed = value.ToInt64();
        return new NativePoint { X = (short)(packed & 0xffff), Y = (short)((packed >> 16) & 0xffff) };
    }

    private void UpdateMaximizeVisualState() =>
        VisualStateManager.GoToState(TitleBarMaximizeButton,
            _maximizeHovered ? _maximizePressed ? "Pressed" : "PointerOver" : "Normal", false);

    private void TrackMaximizeMouseLeave()
    {
        var tracking = new NativeMouseTracking
        {
            Size = (uint)Marshal.SizeOf<NativeMouseTracking>(),
            Flags = 0x12, // TME_LEAVE | TME_NONCLIENT
            Window = _titleBarWindowHandle
        };
        if (!TrackMouseEvent(ref tracking))
        {
            Trace.TraceError("Could not track custom caption hover exit: {0}.", Marshal.GetLastWin32Error());
        }
    }

    private IntPtr TitleBar_WindowProcedure(IntPtr window, uint message, UIntPtr parameter, IntPtr value,
        UIntPtr subclassId, UIntPtr referenceData)
    {
        const int maximizeHit = 9;
        if (message == 0x0082) // WM_NCDESTROY
        {
            if (!RemoveWindowSubclass(window, _titleBarSubclass!, TitleBarSubclassId))
            {
                Trace.TraceError("Could not remove the custom title-bar subclass on window destruction.");
            }
            _titleBarSubclassInstalled = false;
        }
        if (_titleBarClosed) return DefSubclassProc(window, message, parameter, value);

        // HTMAXBUTTON preserves the Windows 11 Snap flyout for the app-drawn button.
        if (message == 0x0084)
        {
            var point = DecodeTitleBarPoint(value);
            if (!ScreenToClient(window, ref point))
            {
                Trace.TraceError("Could not translate caption hit-test coordinates: {0}.", Marshal.GetLastWin32Error());
            }
            else if (IsInMaximizeRegion(point))
            {
                return new IntPtr(maximizeHit);
            }
        }
        else if (message == 0x00a0) // WM_NCMOUSEMOVE
        {
            var hovered = parameter.ToUInt64() == maximizeHit;
            if (hovered && !_maximizeHovered) TrackMaximizeMouseLeave();
            _maximizeHovered = hovered;
            UpdateMaximizeVisualState();
        }
        else if (message == 0x02a2 && !_maximizePressed) // WM_NCMOUSELEAVE
        {
            _maximizeHovered = false;
            UpdateMaximizeVisualState();
        }
        else if (message is 0x00a1 or 0x00a3 && parameter.ToUInt64() == maximizeHit)
        {
            TitleBarMaximizeButton.Focus(FocusState.Pointer);
            _maximizePressed = true;
            _maximizeHovered = true;
            SetCapture(window);
            if (GetCapture() != window)
            {
                _maximizePressed = false;
                Trace.TraceError("Could not capture the custom maximize button press.");
            }
            UpdateMaximizeVisualState();
            return IntPtr.Zero;
        }
        else if (message == 0x0200 && _maximizePressed) // Captured WM_MOUSEMOVE
        {
            _maximizeHovered = IsInMaximizeRegion(DecodeTitleBarPoint(value));
            UpdateMaximizeVisualState();
            return IntPtr.Zero;
        }
        else if (message == 0x0202 && _maximizePressed) // Captured WM_LBUTTONUP
        {
            var activate = IsInMaximizeRegion(DecodeTitleBarPoint(value));
            _maximizePressed = false;
            if (!ReleaseCapture()) Trace.TraceError("Could not release the custom maximize button capture.");
            _maximizeHovered = activate;
            if (activate) TrackMaximizeMouseLeave();
            UpdateMaximizeVisualState();
            if (activate && !DispatcherQueue.TryEnqueue(ToggleWindowMaximized))
            {
                Trace.TraceError("Could not dispatch the custom maximize/restore action.");
            }
            return IntPtr.Zero;
        }
        else if (message == 0x00a2 && parameter.ToUInt64() == maximizeHit)
        {
            return IntPtr.Zero;
        }
        else if (message is 0x0215 or 0x001f && _maximizePressed) // Capture loss / WM_CANCELMODE
        {
            _maximizePressed = false;
            _maximizeHovered = false;
            if (GetCapture() == window && !ReleaseCapture()) Trace.TraceError("Could not cancel caption capture.");
            UpdateMaximizeVisualState();
        }
        return DefSubclassProc(window, message, parameter, value);
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate IntPtr WindowSubclassProcedure(IntPtr window, uint message, UIntPtr parameter, IntPtr value,
        UIntPtr subclassId, UIntPtr referenceData);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint { public int X; public int Y; }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeMouseTracking { public uint Size; public uint Flags; public IntPtr Window; public uint HoverTime; }

    [DllImport("comctl32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowSubclass(IntPtr window, WindowSubclassProcedure callback, UIntPtr id, UIntPtr data);

    [DllImport("comctl32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RemoveWindowSubclass(IntPtr window, WindowSubclassProcedure callback, UIntPtr id);

    [DllImport("comctl32.dll")]
    private static extern IntPtr DefSubclassProc(IntPtr window, uint message, UIntPtr parameter, IntPtr value);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ScreenToClient(IntPtr window, ref NativePoint point);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TrackMouseEvent(ref NativeMouseTracking tracking);

    [DllImport("user32.dll")]
    private static extern IntPtr SetCapture(IntPtr window);

    [DllImport("user32.dll")]
    private static extern IntPtr GetCapture();

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ReleaseCapture();
}
