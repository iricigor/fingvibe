using System.ComponentModel;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;

namespace FingVibe.App.Views;

public sealed partial class DevicesPageView
{
    public static readonly DependencyProperty PreviewTextProperty = DependencyProperty.RegisterAttached(
        "PreviewText", typeof(string), typeof(DevicesPageView), new PropertyMetadata(null, PreviewTextChanged));

    public static string? GetPreviewText(DependencyObject element) => (string?)element.GetValue(PreviewTextProperty);
    public static void SetPreviewText(DependencyObject element, string value) => element.SetValue(PreviewTextProperty, value);
    public static string VendorPreviewText(string value, string description) =>
        value == description ? value : $"{value}\n{description}";

    private readonly DispatcherTimer _previewTimer = new() { Interval = TimeSpan.FromMilliseconds(500) };
    private FrameworkElement? _previewAnchor;
    private object? _previewData;
    private Rect _anchorBounds;
    private Rect _previewBounds;
    private bool _keyboardPreview;

    private static void PreviewTextChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args)
    {
        if (sender is not FrameworkElement element) return;
        UpdateCellTooltip(element);
        element.Loaded -= PreviewCell_Loaded;
        element.Loaded += PreviewCell_Loaded;
        FindAncestor<DevicesPageView>(element)?.DismissCellPreview();
    }

    private static void PreviewCell_Loaded(object sender, RoutedEventArgs args) =>
        UpdateCellTooltip((FrameworkElement)sender);

    private static void UpdateCellTooltip(FrameworkElement element)
    {
        var text = GetPreviewText(element);
        ToolTipService.SetToolTip(element, DeviceColumnLayout.Current.EnlargedCellPreviews ? null : text);
        AutomationProperties.SetName(element, text ?? string.Empty);
    }

    private void InitializeCellPreviews()
    {
        _previewTimer.Tick += (_, _) => ShowCellPreview();
        Loaded += (_, _) =>
        {
            Columns.PropertyChanged += PreviewSettingsChanged;
            UpdateCellTooltips(this);
        };
        Unloaded += (_, _) =>
        {
            Columns.PropertyChanged -= PreviewSettingsChanged;
            DismissCellPreview();
        };
        IsEnabledChanged += (_, _) => DismissCellPreview();
        SizeChanged += (_, _) => DismissCellPreview();
        ActualThemeChanged += (_, _) => DismissCellPreview();
        RegisterPropertyChangedCallback(VisibilityProperty, (_, _) => DismissCellPreview());
        EffectiveViewportChanged += (_, args) =>
        {
            if (args.EffectiveViewport.Width <= 0 || args.EffectiveViewport.Height <= 0) DismissCellPreview();
        };
        TableViewport.AddHandler(PointerMovedEvent, new PointerEventHandler(Preview_PointerMoved), true);
        TableViewport.AddHandler(PointerPressedEvent, new PointerEventHandler(Preview_PointerPressed), true);
        TableViewport.AddHandler(PointerWheelChangedEvent, new PointerEventHandler(Preview_PointerPressed), true);
        TableViewport.PointerExited += Preview_PointerExited;
        ResultsList.GotFocus += Preview_GotFocus;
        ResultsList.LostFocus += (_, _) => DismissCellPreview();
        ResultsList.LayoutUpdated += (_, _) => ValidateCellPreviewLayout();
    }

    private void PreviewSettingsChanged(object? sender, PropertyChangedEventArgs args)
    {
        DismissCellPreview();
        if (args.PropertyName == nameof(DeviceColumnLayout.EnlargedCellPreviews))
            UpdateCellTooltips(this);
    }

    private static void UpdateCellTooltips(DependencyObject root)
    {
        if (root is FrameworkElement element && GetPreviewText(element) is not null)
            UpdateCellTooltip(element);
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(root); index++)
            UpdateCellTooltips(VisualTreeHelper.GetChild(root, index));
    }

    private static T? FindAncestor<T>(DependencyObject? element) where T : DependencyObject
    {
        while (element is not null)
        {
            if (element is T match) return match;
            element = VisualTreeHelper.GetParent(element);
        }
        return null;
    }

    private Rect BoundsInPreviewLayer(FrameworkElement element) =>
        element.TransformToVisual(PreviewLayer).TransformBounds(new Rect(0, 0, element.ActualWidth, element.ActualHeight));

    private bool IsCurrentPreviewAnchor(FrameworkElement anchor) =>
        // Initially collapsed virtualized descendants can render while IsLoaded remains false.
        FindAncestor<DevicesPageView>(anchor) == this
        && FindAncestor<ListViewItem>(anchor) is { } container
        && ReferenceEquals(ResultsList.ItemFromContainer(container), _previewData)
        && ReferenceEquals(anchor.DataContext, _previewData);

    private void ValidateCellPreviewLayout()
    {
        if (_previewAnchor is not { } anchor) return;
        if (!IsCurrentPreviewAnchor(anchor))
        {
            DismissCellPreview();
            return;
        }
        var bounds = BoundsInPreviewLayer(anchor);
        if (bounds.Equals(_anchorBounds)) return;
        if (_keyboardPreview && _previewTimer.IsEnabled)
        {
            // Keyboard focus can scroll its row into view before the preview is shown.
            _anchorBounds = bounds;
            _previewTimer.Stop();
            _previewTimer.Start();
        }
        else
        {
            DismissCellPreview();
        }
    }

    private void Preview_PointerMoved(object sender, PointerRoutedEventArgs args)
    {
        if (!Columns.EnlargedCellPreviews || args.Pointer.PointerDeviceType != Microsoft.UI.Input.PointerDeviceType.Mouse)
            return;
        var point = args.GetCurrentPoint(PreviewLayer).Position;
        if (!_keyboardPreview && CellPreview.Visibility == Visibility.Visible
            && (_previewBounds.Contains(point) || _anchorBounds.Contains(point)))
            return;

        var candidate = args.OriginalSource as DependencyObject;
        while (candidate is not null && candidate != ResultsList && GetPreviewText(candidate) is null)
            candidate = VisualTreeHelper.GetParent(candidate);
        var anchor = candidate is FrameworkElement element && GetPreviewText(element) is not null
            && FindAncestor<ListViewItem>(element) is not null ? element : null;
        if (ReferenceEquals(anchor, _previewAnchor) && !_keyboardPreview) return;
        DismissCellPreview();
        if (anchor is null) return;
        _previewAnchor = anchor;
        _previewData = anchor.DataContext;
        _anchorBounds = BoundsInPreviewLayer(anchor);
        _previewTimer.Start();
    }

    private void Preview_PointerExited(object sender, PointerRoutedEventArgs args)
    {
        var point = args.GetCurrentPoint(PreviewLayer).Position;
        if (point.X < 0 || point.Y < 0 || point.X >= PreviewLayer.ActualWidth || point.Y >= PreviewLayer.ActualHeight)
            DismissCellPreview();
    }

    private void Preview_PointerPressed(object sender, PointerRoutedEventArgs args) => DismissCellPreview();
    private void TableViewport_ViewChanged(object sender, ScrollViewerViewChangedEventArgs args) => ValidateCellPreviewLayout();

    private void Preview_GotFocus(object sender, RoutedEventArgs args)
    {
        DismissCellPreview();
        var focused = FocusManager.GetFocusedElement(XamlRoot) as Control;
        if (!Columns.EnlargedCellPreviews || focused?.FocusState != FocusState.Keyboard
            || FindAncestor<ListViewItem>(focused) is not { } row
            || ResultsList.ItemFromContainer(row) is not ScanResultRow)
            return;
        _previewAnchor = row;
        _previewData = row.DataContext;
        _anchorBounds = BoundsInPreviewLayer(row);
        _keyboardPreview = true;
        _previewTimer.Start();
    }

    private static string FullRowValues(ScanResultRow row) =>
        $"{row.NameText}\nIP address: {row.AddressText}\nMAC address: {row.MacAddressText}\nVendor: {row.VendorDescription}"
        + $"\n{row.PersonAssignmentDescription}\n{row.RoomAssignmentDescription}";

    private void ShowCellPreview()
    {
        _previewTimer.Stop();
        if (!Columns.EnlargedCellPreviews || _previewAnchor is not { } anchor
            || !IsCurrentPreviewAnchor(anchor) || !IsLoaded || !IsEnabled
            || Visibility != Visibility.Visible || PreviewLayer.ActualWidth <= 2 || PreviewLayer.ActualHeight <= 2)
        {
            DismissCellPreview();
            return;
        }
        var bounds = BoundsInPreviewLayer(anchor);
        if (!bounds.Equals(_anchorBounds) || bounds.Bottom <= 0 || bounds.Top >= PreviewLayer.ActualHeight
            || bounds.Right <= 0 || bounds.Left >= PreviewLayer.ActualWidth)
        {
            DismissCellPreview();
            return;
        }
        var text = _keyboardPreview && ResultsList.ItemFromContainer(anchor) is ScanResultRow row
            ? FullRowValues(row) : GetPreviewText(anchor);
        CellPreviewText.Text = text ?? string.Empty;
        var sourceText = FindText(anchor);
        CellPreviewText.FontSize = (sourceText?.FontSize ?? (anchor as Control)?.FontSize ?? 12) * 1.25;
        CellPreviewText.FontFamily = sourceText?.FontFamily ?? (anchor as Control)?.FontFamily ?? new FontFamily("Segoe UI");
        CellPreviewText.FontWeight = sourceText?.FontWeight ?? Microsoft.UI.Text.FontWeights.Normal;
        CellPreview.MinWidth = 0;
        CellPreview.MaxWidth = PreviewLayer.ActualWidth;
        CellPreview.MaxHeight = PreviewLayer.ActualHeight;
        CellPreview.MinWidth = Math.Min(bounds.Width + 24, CellPreview.MaxWidth);
        CellPreview.Visibility = Visibility.Visible;
        CellPreview.Measure(new Size(CellPreview.MaxWidth, CellPreview.MaxHeight));
        var size = CellPreview.DesiredSize;
        var left = Math.Clamp(bounds.Left - 12, 0, Math.Max(0, PreviewLayer.ActualWidth - size.Width));
        var top = Math.Clamp(bounds.Top + (bounds.Height - size.Height) / 2, 0,
            Math.Max(0, PreviewLayer.ActualHeight - size.Height));
        Canvas.SetLeft(CellPreview, left);
        Canvas.SetTop(CellPreview, top);
        _previewBounds = new Rect(left, top, size.Width, size.Height);
    }

    private static TextBlock? FindText(DependencyObject element)
    {
        if (element is TextBlock text) return text;
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(element); index++)
            if (FindText(VisualTreeHelper.GetChild(element, index)) is { } child) return child;
        return null;
    }

    private void DismissCellPreview()
    {
        _previewTimer.Stop();
        _previewAnchor = null;
        _previewData = null;
        _keyboardPreview = false;
        CellPreview.Visibility = Visibility.Collapsed;
    }
}
