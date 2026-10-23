using Microsoft.UI.Input;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.System;
using Windows.UI.Core;

namespace FingVibe.App;

public sealed class ColumnResizeGrip : Control
{
    private const double KeyboardStep = 8;
    private const double LargeKeyboardStep = 32;

    private double? _dragStartX;
    private double _dragStartWidth;

    public ColumnResizeGrip()
    {
        DefaultStyleKey = typeof(ColumnResizeGrip);
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeWestEast);
        IsTabStop = true;
    }

    public DeviceColumn? Column { get; set; }

    protected override AutomationPeer OnCreateAutomationPeer() => new ColumnResizeGripAutomationPeer(this);

    private sealed class ColumnResizeGripAutomationPeer(ColumnResizeGrip owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Thumb;

        protected override string GetClassNameCore() => nameof(ColumnResizeGrip);

        protected override bool IsKeyboardFocusableCore() => true;
    }

    protected override void OnPointerPressed(PointerRoutedEventArgs e)
    {
        if (Column is null)
        {
            return;
        }

        _dragStartX = e.GetCurrentPoint(null).Position.X;
        _dragStartWidth = Column.Width;
        CapturePointer(e.Pointer);
        e.Handled = true;
    }

    protected override void OnPointerMoved(PointerRoutedEventArgs e)
    {
        if (_dragStartX is not double startX || Column is null)
        {
            return;
        }

        Column.Width = _dragStartWidth + (e.GetCurrentPoint(null).Position.X - startX);
        e.Handled = true;
    }

    protected override void OnPointerReleased(PointerRoutedEventArgs e)
    {
        if (_dragStartX is null)
        {
            return;
        }

        _dragStartX = null;
        ReleasePointerCapture(e.Pointer);
        e.Handled = true;
    }

    protected override void OnPointerCaptureLost(PointerRoutedEventArgs e)
    {
        _dragStartX = null;
    }

    protected override void OnKeyDown(KeyRoutedEventArgs e)
    {
        if (Column is not null && e.Key is VirtualKey.Left or VirtualKey.Right)
        {
            var step = InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Shift)
                .HasFlag(CoreVirtualKeyStates.Down)
                ? LargeKeyboardStep
                : KeyboardStep;
            Column.Width += e.Key == VirtualKey.Left ? -step : step;
            e.Handled = true;
            return;
        }

        base.OnKeyDown(e);
    }
}
