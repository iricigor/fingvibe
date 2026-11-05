using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;
using Windows.UI.Core;

namespace FingVibe.App;

public sealed class ResizeRequestedEventArgs(double width, bool isKeyboard) : EventArgs
{
    public double Width { get; } = width;
    public bool IsKeyboard { get; } = isKeyboard;
}

public sealed class ColumnResizeGrip : Control
{
    private const double KeyboardStep = 8;
    private const double LargeKeyboardStep = 32;

    private double? _dragStartX;
    private double _dragStartWidth;
    private bool _isPointerOver;

    public ColumnResizeGrip()
    {
        DefaultStyleKey = typeof(ColumnResizeGrip);
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeWestEast);
        IsTabStop = true;
    }

    public DeviceColumn? Column { get; set; }

    public double ResizeWidth { get; set; }
    public event EventHandler<ResizeRequestedEventArgs>? ResizeRequested;
    public event EventHandler? ResizeCompleted;
    public bool IsResizing => _dragStartX is not null;
    public bool RevealSeparatorOnInteraction { get; set; }

    public static readonly DependencyProperty SeparatorVisibilityProperty = DependencyProperty.Register(
        nameof(SeparatorVisibility), typeof(Visibility), typeof(ColumnResizeGrip),
        new PropertyMetadata(Visibility.Visible));

    public Visibility SeparatorVisibility
    {
        get => (Visibility)GetValue(SeparatorVisibilityProperty);
        set => SetValue(SeparatorVisibilityProperty, value);
    }

    protected override void OnApplyTemplate()
    {
        base.OnApplyTemplate();
        UpdateSeparatorVisibility();
    }

    protected override void OnPointerEntered(PointerRoutedEventArgs e)
    {
        base.OnPointerEntered(e);
        _isPointerOver = true;
        UpdateSeparatorVisibility();
    }

    protected override void OnPointerExited(PointerRoutedEventArgs e)
    {
        base.OnPointerExited(e);
        _isPointerOver = false;
        UpdateSeparatorVisibility();
    }

    protected override void OnGotFocus(RoutedEventArgs e)
    {
        base.OnGotFocus(e);
        UpdateSeparatorVisibility();
    }

    protected override void OnLostFocus(RoutedEventArgs e)
    {
        base.OnLostFocus(e);
        UpdateSeparatorVisibility();
    }

    private void UpdateSeparatorVisibility()
    {
        if (RevealSeparatorOnInteraction)
        {
            SeparatorVisibility = _isPointerOver || IsResizing || FocusState == FocusState.Keyboard
                ? Visibility.Visible
                : Visibility.Collapsed;
        }
    }

    protected override AutomationPeer OnCreateAutomationPeer() => new ColumnResizeGripAutomationPeer(this);

    private sealed class ColumnResizeGripAutomationPeer(ColumnResizeGrip owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Thumb;

        protected override string GetClassNameCore() => nameof(ColumnResizeGrip);

        protected override bool IsKeyboardFocusableCore() => true;
    }

    protected override void OnPointerPressed(PointerRoutedEventArgs e)
    {
        if (Column is null && ResizeRequested is null)
        {
            return;
        }

        var point = e.GetCurrentPoint(null);
        if (!point.Properties.IsLeftButtonPressed || !CapturePointer(e.Pointer))
        {
            return;
        }

        _dragStartX = point.Position.X;
        _dragStartWidth = Column?.Width ?? ResizeWidth;
        if (Column is null)
        {
            Focus(FocusState.Pointer);
        }
        UpdateSeparatorVisibility();
        e.Handled = true;
    }

    protected override void OnPointerMoved(PointerRoutedEventArgs e)
    {
        if (_dragStartX is not double startX)
        {
            return;
        }

        RequestResize(_dragStartWidth + (e.GetCurrentPoint(null).Position.X - startX));
        e.Handled = true;
    }

    protected override void OnPointerReleased(PointerRoutedEventArgs e)
    {
        if (_dragStartX is null)
        {
            return;
        }

        CompleteResize();
        ReleasePointerCapture(e.Pointer);
        e.Handled = true;
    }

    protected override void OnPointerCaptureLost(PointerRoutedEventArgs e)
    {
        CompleteResize();
    }

    protected override void OnPointerCanceled(PointerRoutedEventArgs e)
    {
        CompleteResize();
        ReleasePointerCapture(e.Pointer);
    }

    private void CompleteResize()
    {
        if (!IsResizing)
        {
            return;
        }

        _dragStartX = null;
        UpdateSeparatorVisibility();
        ResizeCompleted?.Invoke(this, EventArgs.Empty);
    }

    protected override void OnKeyDown(KeyRoutedEventArgs e)
    {
        if ((Column is not null || ResizeRequested is not null) && e.Key is VirtualKey.Left or VirtualKey.Right)
        {
            var step = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift)
                .HasFlag(CoreVirtualKeyStates.Down)
                ? LargeKeyboardStep
                : KeyboardStep;
            RequestResize((Column?.Width ?? ResizeWidth) + (e.Key == VirtualKey.Left ? -step : step), isKeyboard: true);
            e.Handled = true;
            return;
        }

        base.OnKeyDown(e);
    }

    private void RequestResize(double width, bool isKeyboard = false)
    {
        if (Column is not null)
        {
            Column.Width = width;
        }
        else
        {
            ResizeRequested?.Invoke(this, new ResizeRequestedEventArgs(width, isKeyboard));
        }
    }
}
