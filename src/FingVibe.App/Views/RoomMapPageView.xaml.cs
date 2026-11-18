using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
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
    private readonly Windows.UI.ViewManagement.UISettings _uiSettings = new();

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

    private void RoomMapPage_SizeChanged(object sender, SizeChangedEventArgs e) =>
        Render();

    private void Render()
    {
        if (!IsLoaded)
        {
            return;
        }

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
            return;
        }

        var availableWidth = Math.Max(720, RoomMapScroll.ActualWidth - 16);
        if (Math.Abs(availableWidth - _renderWidth) < 1 && RoomMapCanvas.Children.Count > 0)
        {
            return;
        }
        _renderWidth = availableWidth;

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
        var roomName = new TextBlock
        {
            Text = room.Name,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap,
            MaxLines = 2,
            TextTrimming = TextTrimming.CharacterEllipsis
        };
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
        AutomationProperties.SetAutomationId(card,
            room.Id is { } id ? $"RoomMapRoom-{id:D}" : "RoomMapRootPlaceholder");
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

        var tile = new ListViewItem
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
        AutomationProperties.SetAutomationId(tile, $"RoomMapDevice-{device.IdentityKey}");
        AutomationProperties.SetName(tile, device.AccessibleName + (device.IsLocal ? ", your device" : string.Empty));
        AutomationProperties.SetHelpText(tile, $"{device.Type.Label()} · {device.Address}");
        AutomationProperties.SetLocalizedControlType(tile, "device");
        ToolTipService.SetToolTip(tile, $"{device.Name}\n{device.Type.Label()} · {device.Address}\n{device.StatusText}");
        Canvas.SetLeft(tile, placement.Bounds.X);
        Canvas.SetTop(tile, placement.Bounds.Y);
        RoomMapCanvas.Children.Add(tile);
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

    private static Brush Brush(string key) =>
        Application.Current.Resources[key] as Brush
        ?? throw new InvalidOperationException($"Required Room map brush '{key}' is unavailable.");
}
