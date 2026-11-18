using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace FingVibe.App.Views;

public sealed partial class RoomMapPageView : UserControl
{
    private DeviceInventoryData _data = DeviceInventoryData.Empty;
    private LanNetwork? _network;
    private string? _networkId;
    private string? _networkError;
    private double _renderWidth;
    private RoomMapNavigationState? _returnState;
    private readonly Dictionary<string, RoomMapNavigationTarget> _navigationTargets =
        new(StringComparer.Ordinal);
    private readonly Windows.UI.ViewManagement.UISettings _uiSettings = new();
    private string[] _brushThemes = ["Light"];

    public RoomMapPageView()
    {
        InitializeComponent();
        ActualThemeChanged += (_, _) =>
        {
            _renderWidth = 0;
            Render();
        };
        // Text scale changes arrive off the UI thread; relayout so enlarged labels keep their room space.
        _uiSettings.TextScaleFactorChanged += (_, _) => DispatcherQueue.TryEnqueue(() =>
        {
            _renderWidth = 0;
            Render();
        });
        Loaded += (_, _) => Render();
    }

    public event RoutedEventHandler? ManageRoomsRequested;
    public event EventHandler<string>? DeviceRequested;
    public event EventHandler<Guid>? RoomRequested;

    // Panels have no automation peer, so expose the page itself as the RoomMapPage pane.
    protected override AutomationPeer OnCreateAutomationPeer() => new RoomMapPagePeer(this);

    private sealed class RoomMapPagePeer(RoomMapPageView owner) : FrameworkElementAutomationPeer(owner)
    {
        protected override AutomationControlType GetAutomationControlTypeCore() => AutomationControlType.Pane;
        protected override string GetClassNameCore() => nameof(RoomMapPageView);
    }

    internal void Show(
        DeviceInventoryData data,
        LanNetwork? network,
        string? networkId,
        string? networkError)
    {
        _data = data;
        _network = network;
        _networkId = networkId;
        _networkError = networkError;
        _renderWidth = 0;
        Render();
    }

    internal void ResetScroll()
    {
        _returnState = null;
        RoomMapScroll.ChangeView(0, 0, null);
        _renderWidth = 0;
        Render();
    }

    internal void RefreshAppearance()
    {
        _renderWidth = 0;
        Render();
    }

    private void ManageRoomsButton_Click(object sender, RoutedEventArgs e) =>
        ManageRoomsRequested?.Invoke(this, e);

    internal void RestoreNavigation()
    {
        if (_returnState is not { } state)
        {
            return;
        }

        DispatcherQueue.TryEnqueue(() =>
        {
            RoomMapCanvas.UpdateLayout();
            RoomMapScroll.ChangeView(state.HorizontalOffset, state.VerticalOffset, null, disableAnimation: true);
            var target = NavigationTarget(state);
            target?.Control.Focus(FocusState.Programmatic);
            target?.Control.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false });
        });
    }

    internal void SetNavigationError(string message)
    {
        RoomMapErrorText.Text = message;
        RoomMapErrorText.Visibility = Visibility.Visible;
    }

    private void RoomMapPage_SizeChanged(object sender, SizeChangedEventArgs e) =>
        Render();

    private void Render()
    {
        if (!IsLoaded)
        {
            return;
        }

        _brushThemes = new Windows.UI.ViewManagement.AccessibilitySettings().HighContrast
            ? ["HighContrast"]
            : ActualTheme == ElementTheme.Dark ? ["Dark", "Default"] : ["Light"];
        if (_network is null)
        {
            RoomMapNetworkText.Text = "No active IPv4 network";
            RoomMapSummaryText.Text = "Select a network to show its saved room assignments and scan evidence.";
            RoomMapUnassignedSummaryText.Text = "No room assigned · unavailable";
            AutomationProperties.SetName(RoomMapUnassignedSummaryText, "No room assigned, unavailable");
            RoomMapErrorText.Visibility = Visibility.Collapsed;
            RoomMapScroll.Visibility = Visibility.Collapsed;
            RoomMapEmptyState.Visibility = Visibility.Visible;
            RoomMapEmptyText.Text = "No network to map";
            RoomMapCanvas.Children.Clear();
            _navigationTargets.Clear();
            return;
        }

        var availableWidth = Math.Max(720, RoomMapScroll.ActualWidth - 16);
        if (Math.Abs(availableWidth - _renderWidth) < 1 && RoomMapCanvas.Children.Count > 0)
        {
            return;
        }
        _renderWidth = availableWidth;
        var previousViewport = new RoomMapViewportState(
            RoomMapScroll.HorizontalOffset,
            RoomMapScroll.VerticalOffset,
            FocusedNavigationId());
        var preserveViewport = _navigationTargets.Count > 0;

        var projection = RoomMapProjection.Create(_data, _network, _networkId);
        var layout = RoomMapLayout.Create(projection, availableWidth, _uiSettings.TextScaleFactor);
        var deviceCount = projection.Devices.Count;
        var roomCount = projection.Rooms.Count(room => room.Id is not null);
        var onlineCount = projection.Devices.Count(device => device.Status == RoomMapDeviceStatus.Online);
        RoomMapNetworkText.Text = projection.NetworkLabel;
        RoomMapSummaryText.Text =
            $"{roomCount} {(roomCount == 1 ? "saved room" : "saved rooms")} · "
            + $"{deviceCount} {(deviceCount == 1 ? "device" : "devices")} · {onlineCount} online";
        RoomMapUnassignedSummaryText.Text =
            $"No room assigned · {projection.UnassignedDevices.Count} "
            + $"{(projection.UnassignedDevices.Count == 1 ? "device" : "devices")}";
        AutomationProperties.SetName(
            RoomMapUnassignedSummaryText,
            $"No room assigned, {projection.UnassignedDevices.Count} devices");
        RoomMapErrorText.Text = _networkError ?? string.Empty;
        RoomMapErrorText.Visibility = string.IsNullOrWhiteSpace(_networkError)
            ? Visibility.Collapsed
            : Visibility.Visible;
        RoomMapEmptyState.Visibility = Visibility.Collapsed;
        RoomMapScroll.Visibility = Visibility.Visible;
        RoomMapCanvas.Width = layout.Width;
        RoomMapCanvas.Height = layout.Height;
        RoomMapCanvas.Children.Clear();
        _navigationTargets.Clear();

        AddConnections(layout.Connections);
        foreach (var room in layout.Rooms)
        {
            AddRoom(room);
            foreach (var device in room.Devices)
            {
                AddDevice(device);
            }
            foreach (var anchor in room.Anchors)
            {
                AddAnchor(anchor);
            }
        }

        AddRootLink(layout);
        AddGlobe(layout.GlobeBounds);
        AddUnassignedStrip(layout);
        if (preserveViewport)
        {
            RestoreViewport(previousViewport);
        }
    }

    private void AddRoom(RoomMapRoomPlacement room)
    {
        var header = new StackPanel { Spacing = 2, Padding = new Thickness(12, 9, 12, 7) };
        var titleRow = new Grid { ColumnSpacing = 7 };
        titleRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        titleRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        titleRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var roomIcon = new FontIcon
        {
            Glyph = PeopleRoomsIcons.Resolve(PeopleRoomsIcons.Rooms, room.IconId).Glyph,
            FontFamily = new FontFamily("Segoe Fluent Icons"),
            FontSize = 16,
            IsHitTestVisible = false
        };
        titleRow.Children.Add(roomIcon);
        FrameworkElement roomName;
        if (room.Id is { } roomId)
        {
            var openRoom = new HyperlinkButton
            {
                Padding = new Thickness(0),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
                Content = new TextBlock
                {
                    Text = room.Name,
                    FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                    TextWrapping = TextWrapping.Wrap,
                    MaxLines = 2,
                    TextTrimming = TextTrimming.CharacterEllipsis
                }
            };
            AutomationProperties.SetAutomationId(openRoom, $"RoomMapOpenRoom-{roomId:D}");
            AutomationProperties.SetName(openRoom, $"Open {room.Name} room details");
            openRoom.Click += (_, _) =>
            {
                CaptureNavigationState($"RoomMapOpenRoom-{roomId:D}", roomId);
                RoomRequested?.Invoke(this, roomId);
            };
            roomName = openRoom;
        }
        else
        {
            roomName = new TextBlock
            {
                Text = room.Name,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                TextWrapping = TextWrapping.Wrap,
                MaxLines = 2,
                TextTrimming = TextTrimming.CharacterEllipsis
            };
        }
        Grid.SetColumn(roomName, 1);
        titleRow.Children.Add(roomName);
        if (room.IsRoot)
        {
            var root = new TextBlock
            {
                Text = "Root",
                FontSize = 11,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                Foreground = Brush("AccentTextFillColorPrimaryBrush"),
                VerticalAlignment = VerticalAlignment.Center
            };
            Grid.SetColumn(root, 2);
            titleRow.Children.Add(root);
        }
        header.Children.Add(titleRow);
        header.Children.Add(new TextBlock
        {
            Text = room.IsPlaceholder
                ? room.PlaceholderText
                : $"{room.ShortName} · {room.DeviceCount} "
                    + $"{(room.DeviceCount == 1 ? "device" : "devices")} · {room.OnlineCount} online",
            FontSize = 11,
            TextWrapping = TextWrapping.Wrap,
            Foreground = Brush("TextFillColorSecondaryBrush")
        });
        if (room.IsLocalRoom)
        {
            header.Children.Add(new TextBlock
            {
                Text = "Your device is here",
                FontSize = 11,
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
                Foreground = Brush("AccentTextFillColorPrimaryBrush")
            });
        }

        var card = new ListViewItem
        {
            Content = header,
            Width = room.Bounds.Width,
            Height = room.Bounds.Height,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Top,
            Padding = new Thickness(0),
            Background = Brush("CardBackgroundFillColorDefaultBrush"),
            BorderBrush = room.IsLocalRoom || room.IsRoot
                ? Brush("AccentFillColorDefaultBrush")
                : Brush("ScannerCardBorderBrush"),
            BorderThickness = new Thickness(room.IsRoot ? 2 : room.IsLocalRoom ? 1.5 : 1),
            CornerRadius = new CornerRadius(10),
            UseSystemFocusVisuals = true,
            IsTabStop = true
        };
        var roomAutomationId = room.Id is { } roomCardId
            ? $"RoomMapRoom-{roomCardId:D}"
            : "RoomMapRootPlaceholder";
        AutomationProperties.SetAutomationId(card, roomAutomationId);
        AutomationProperties.SetName(card,
            room.IsPlaceholder
                ? $"{room.Name}. {room.PlaceholderText}"
                : $"{room.Name}, {room.DeviceCount} devices, {room.OnlineCount} online"
                    + (room.IsRoot ? ", root room" : string.Empty)
                    + (room.IsLocalRoom ? ", your device is here" : string.Empty));
        AutomationProperties.SetLocalizedControlType(card, "room");
        Canvas.SetLeft(card, room.Bounds.X);
        Canvas.SetTop(card, room.Bounds.Y);
        RoomMapCanvas.Children.Add(card);
        RegisterNavigationTarget(roomAutomationId, card, room.Id, room.Bounds);
        if (roomName is Control roomNameControl && room.Id is not null)
        {
            RegisterNavigationTarget(
                AutomationProperties.GetAutomationId(roomNameControl),
                roomNameControl,
                room.Id,
                room.Bounds);
        }
    }

    private void AddDevice(RoomMapDevicePlacement placement)
    {
        var device = placement.Device;
        var foreground = device.Status switch
        {
            RoomMapDeviceStatus.Online => Brush("ScannerOnlineForegroundBrush"),
            RoomMapDeviceStatus.Offline => Brush("ScannerOfflineForegroundBrush"),
            _ => Brush("ScannerImportedForegroundBrush")
        };
        var tileContent = new Grid
        {
            ColumnSpacing = 6,
            RowSpacing = 0
        };
        tileContent.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        tileContent.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var icon = new FontIcon
        {
            Glyph = ScanResultRow.GetIconGlyph(device.Icon),
            FontFamily = new FontFamily("Segoe Fluent Icons"),
            FontSize = 18,
            Foreground = foreground,
            VerticalAlignment = VerticalAlignment.Center
        };
        AutomationProperties.SetAccessibilityView(icon, AccessibilityView.Raw);
        Grid.SetColumn(icon, 0);
        var text = new StackPanel { Spacing = 0, VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock
        {
            Text = device.Name,
            FontSize = 11,
            FontWeight = device.Status == RoomMapDeviceStatus.Online
                ? Microsoft.UI.Text.FontWeights.SemiBold
                : Microsoft.UI.Text.FontWeights.Normal,
            TextWrapping = TextWrapping.NoWrap,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Foreground = foreground
        });
        text.Children.Add(new TextBlock
        {
            Text = device.CompactStatusText,
            FontSize = 10,
            TextWrapping = TextWrapping.NoWrap,
            TextTrimming = TextTrimming.CharacterEllipsis,
            Foreground = foreground
        });
        Grid.SetColumn(text, 1);
        tileContent.Children.Add(icon);
        tileContent.Children.Add(text);

        var tile = new Button
        {
            Content = tileContent,
            Width = placement.Bounds.Width,
            Height = placement.Bounds.Height,
            Padding = new Thickness(7, 4, 7, 4),
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Center,
            Background = device.Status switch
            {
                RoomMapDeviceStatus.Online => Brush("ScannerOnlineBackgroundBrush"),
                RoomMapDeviceStatus.Offline => Brush("ScannerOfflineBackgroundBrush"),
                _ => Brush("ScannerImportedBackgroundBrush")
            },
            BorderBrush = device.IsLocal
                ? Brush("AccentFillColorDefaultBrush")
                : Brush("ScannerCardBorderBrush"),
            BorderThickness = new Thickness(device.IsLocal ? 2 : 1),
            CornerRadius = new CornerRadius(7),
            UseSystemFocusVisuals = true,
            IsTabStop = true
        };
        var automationId = $"RoomMapDevice-{device.IdentityKey}";
        AutomationProperties.SetAutomationId(tile, automationId);
        AutomationProperties.SetName(tile, device.AccessibleName + (device.IsLocal ? ", your device" : string.Empty));
        AutomationProperties.SetHelpText(tile, $"{device.Type.Label()} · {device.Address}");
        AutomationProperties.SetLocalizedControlType(tile, "device");
        ToolTipService.SetToolTip(tile, $"{device.Name}\n{device.Type.Label()} · {device.Address}\n{device.StatusText}");
        tile.Click += (_, _) =>
        {
            CaptureNavigationState(automationId, device.RoomId);
            DeviceRequested?.Invoke(this, device.IdentityKey);
        };
        Canvas.SetLeft(tile, placement.Bounds.X);
        Canvas.SetTop(tile, placement.Bounds.Y);
        RoomMapCanvas.Children.Add(tile);
        RegisterNavigationTarget(automationId, tile, device.RoomId, placement.Bounds);
    }

    private void AddAnchor(RoomMapAnchorPlacement anchor)
    {
        var marker = new Ellipse
        {
            Width = anchor.Bounds.Width,
            Height = anchor.Bounds.Height,
            Fill = Brush("CardBackgroundFillColorDefaultBrush"),
            Stroke = Brush("AccentFillColorDefaultBrush"),
            StrokeThickness = 2,
            IsHitTestVisible = false
        };
        AutomationProperties.SetAccessibilityView(marker, AccessibilityView.Raw);
        Canvas.SetLeft(marker, anchor.Bounds.X);
        Canvas.SetTop(marker, anchor.Bounds.Y);
        RoomMapCanvas.Children.Add(marker);
    }

    private void AddConnections(IEnumerable<RoomMapConnection> connections)
    {
        foreach (var (connection, index) in connections.Select((connection, index) => (connection, index)))
        {
            if (connection.Points.Count < 2)
            {
                continue;
            }

            var figure = new PathFigure
            {
                StartPoint = new Windows.Foundation.Point(connection.Points[0].X, connection.Points[0].Y)
            };
            foreach (var point in connection.Points.Skip(1))
            {
                figure.Segments.Add(new LineSegment
                {
                    Point = new Windows.Foundation.Point(point.X, point.Y)
                });
            }
            var geometry = new PathGeometry();
            geometry.Figures.Add(figure);
            var path = new Microsoft.UI.Xaml.Shapes.Path
            {
                Data = geometry,
                Stroke = Brush("TextFillColorSecondaryBrush"),
                StrokeThickness = 2,
                IsHitTestVisible = false
            };
            if (connection.IsDashed)
            {
                path.StrokeDashArray = new DoubleCollection { 5, 4 };
                path.Opacity = 0.75;
            }
            AutomationProperties.SetAutomationId(
                path, $"RoomMapConnection-{connection.Kind}-{index}");
            AutomationProperties.SetAccessibilityView(path, AccessibilityView.Raw);
            RoomMapCanvas.Children.Add(path);
        }
    }

    private void AddRootLink(RoomMapLayout layout)
    {
        RoomMapCanvas.Children.Add(new Line
        {
            X1 = layout.RootLinkX,
            X2 = layout.RootLinkX,
            Y1 = layout.RootLinkStartY,
            Y2 = layout.RootLinkEndY,
            Stroke = Brush("TextFillColorSecondaryBrush"),
            StrokeThickness = 2,
            IsHitTestVisible = false
        });
    }

    private void AddGlobe(RoomMapBounds bounds)
    {
        var content = new StackPanel { Spacing = 3, HorizontalAlignment = HorizontalAlignment.Center };
        var globeIcon = new FontIcon
        {
            Glyph = "\uE774",
            FontSize = 34,
            HorizontalAlignment = HorizontalAlignment.Center
        };
        AutomationProperties.SetAccessibilityView(globeIcon, AccessibilityView.Raw);
        content.Children.Add(globeIcon);
        content.Children.Add(new TextBlock
        {
            Text = "Internet",
            FontSize = 11,
            TextAlignment = TextAlignment.Center
        });
        var globe = new ListViewItem
        {
            Content = content,
            Width = bounds.Width,
            Height = bounds.Height,
            Padding = new Thickness(6),
            HorizontalContentAlignment = HorizontalAlignment.Center,
            VerticalContentAlignment = VerticalAlignment.Center,
            Background = Brush("CardBackgroundFillColorDefaultBrush"),
            BorderBrush = Brush("ScannerCardBorderBrush"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(36),
            UseSystemFocusVisuals = true,
            IsTabStop = true
        };
        AutomationProperties.SetAutomationId(globe, "RoomMapInternet");
        AutomationProperties.SetName(globe, "Internet connection anchor");
        AutomationProperties.SetHelpText(globe, "Conceptual anchor; this does not verify Internet access.");
        Canvas.SetLeft(globe, bounds.X);
        Canvas.SetTop(globe, bounds.Y);
        RoomMapCanvas.Children.Add(globe);
    }

    private void AddUnassignedStrip(RoomMapLayout layout)
    {
        var strip = new ListViewItem
        {
            Width = layout.UnassignedBounds.Width,
            Height = layout.UnassignedBounds.Height,
            Padding = new Thickness(0),
            Background = Brush("ControlFillColorSecondaryBrush"),
            BorderBrush = Brush("ScannerCardBorderBrush"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            VerticalContentAlignment = VerticalAlignment.Top,
            UseSystemFocusVisuals = true,
            IsTabStop = true
        };
        var header = new StackPanel { Padding = new Thickness(14, 8, 14, 6), Spacing = 2 };
        header.Children.Add(new TextBlock
        {
            Text = "No room assigned",
            FontSize = 16,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold
        });
        header.Children.Add(new TextBlock
        {
            Text = layout.UnassignedDevices.Count == 0
                ? "Every mapped device has a saved room."
                : "These devices remain on the selected network but have no saved room assignment.",
            FontSize = 11,
            TextWrapping = TextWrapping.Wrap,
            Foreground = Brush("TextFillColorSecondaryBrush")
        });
        strip.Content = header;
        AutomationProperties.SetAutomationId(strip, "RoomMapUnassigned");
        AutomationProperties.SetName(strip,
            $"No room assigned, {layout.UnassignedDevices.Count} devices");
        AutomationProperties.SetLocalizedControlType(strip, "unassigned devices");
        Canvas.SetLeft(strip, layout.UnassignedBounds.X);
        Canvas.SetTop(strip, layout.UnassignedBounds.Y);
        RoomMapCanvas.Children.Add(strip);
        foreach (var device in layout.UnassignedDevices)
        {
            AddDevice(device);
        }
    }

    // Application.Resources[key] resolves the application's theme, but the user's theme is applied as a
    // RequestedTheme on the window content, so code-built map elements look up this page's actual theme.
    private Brush Brush(string key) =>
        ThemeBrush(Application.Current.Resources, key, _brushThemes)
            ?? Application.Current.Resources[key] as Brush
            ?? throw new InvalidOperationException($"Required Room map brush '{key}' is unavailable.");

    private static Brush? ThemeBrush(ResourceDictionary dictionary, string key, string[] themes)
    {
        foreach (var theme in themes)
        {
            if (dictionary.ThemeDictionaries.TryGetValue(theme, out var themed) &&
                themed is ResourceDictionary resources &&
                resources.TryGetValue(key, out var value) &&
                value is Brush brush)
            {
                return brush;
            }
        }
        foreach (var merged in dictionary.MergedDictionaries)
        {
            if (ThemeBrush(merged, key, themes) is { } brush)
            {
                return brush;
            }
        }
        return null;
    }

    private void CaptureNavigationState(string focusId, Guid? roomId)
    {
        var target = _navigationTargets.GetValueOrDefault(focusId);
        _returnState = new(
            focusId,
            roomId,
            RoomMapScroll.HorizontalOffset,
            RoomMapScroll.VerticalOffset,
            target?.X ?? 0,
            target?.Y ?? 0);
    }

    private void RegisterNavigationTarget(
        string automationId,
        Control control,
        Guid? roomId,
        RoomMapBounds bounds)
    {
        _navigationTargets[automationId] = new(
            control,
            roomId,
            bounds.CenterX,
            bounds.CenterY);
    }

    private string? FocusedNavigationId()
    {
        if (Visibility != Visibility.Visible || FocusManager.GetFocusedElement(XamlRoot) is not FrameworkElement focused)
        {
            return null;
        }

        var automationId = AutomationProperties.GetAutomationId(focused);
        return automationId is not null && _navigationTargets.ContainsKey(automationId)
            ? automationId
            : null;
    }

    private void RestoreViewport(RoomMapViewportState viewport)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            RoomMapCanvas.UpdateLayout();
            RoomMapScroll.ChangeView(
                viewport.HorizontalOffset, viewport.VerticalOffset, null, disableAnimation: true);
            if (viewport.FocusId is not null &&
                _navigationTargets.GetValueOrDefault(viewport.FocusId) is { } target)
            {
                target.Control.Focus(FocusState.Programmatic);
                target.Control.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false });
            }
        });
    }

    private RoomMapNavigationTarget? NavigationTarget(RoomMapNavigationState state)
    {
        if (_navigationTargets.GetValueOrDefault(state.FocusId) is { } exact)
        {
            return exact;
        }

        var candidates = _navigationTargets.Values.Where(target =>
            state.RoomId is not null && target.RoomId == state.RoomId);
        return (candidates.Any() ? candidates : _navigationTargets.Values)
            .OrderBy(target => Math.Pow(target.X - state.X, 2) + Math.Pow(target.Y - state.Y, 2))
            .FirstOrDefault();
    }

    private sealed record RoomMapViewportState(
        double HorizontalOffset,
        double VerticalOffset,
        string? FocusId);

    private sealed record RoomMapNavigationState(
        string FocusId,
        Guid? RoomId,
        double HorizontalOffset,
        double VerticalOffset,
        double X,
        double Y);

    private sealed record RoomMapNavigationTarget(
        Control Control,
        Guid? RoomId,
        double X,
        double Y);
}
