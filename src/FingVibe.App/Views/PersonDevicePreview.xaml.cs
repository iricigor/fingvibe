using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace FingVibe.App.Views;

public sealed partial class PersonDevicePreview : UserControl
{
    private readonly UISettings _uiSettings = new();
    private bool _room;

    public PersonDevicePreview()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            _uiSettings.ColorValuesChanged += ColorValuesChanged;
            UpdateFade();
        };
        Unloaded += (_, _) => _uiSettings.ColorValuesChanged -= ColorValuesChanged;
        ActualThemeChanged += (_, _) => UpdateFade();
    }

    private void ColorValuesChanged(UISettings sender, object args) =>
        DispatcherQueue.TryEnqueue(() => { if (IsLoaded) UpdateFade(); });

    internal void SetIcon(string? id)
    {
        if (_room) PreviewRoomIcon.IconId = id;
        else PreviewIcon.IconId = id;
        UpdateAccessibleName();
    }

    internal void SetShortName(string shortName)
    {
        PreviewShortName.Text = shortName;
        UpdateAccessibleName();
    }

    internal void UseRoom()
    {
        _room = true;
        PreviewHeading.Text = "Room";
        PreviewIcon.Visibility = Visibility.Collapsed;
        PreviewRoomIcon.Visibility = Visibility.Visible;
        AutomationProperties.SetAutomationId(this, "RoomDevicesPreview");
        UpdateAccessibleName();
    }

    private void UpdateAccessibleName() => AutomationProperties.SetName(this,
        $"Devices table preview: {PeopleRoomsIcons.Resolve(_room ? PeopleRoomsIcons.Rooms : PeopleRoomsIcons.People,
            _room ? PreviewRoomIcon.IconId : PreviewIcon.IconId).AccessibleName}, {PreviewShortName.Text}");

    private void Viewport_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        ViewportClip.Rect = new Rect(0, 0, e.NewSize.Width, e.NewSize.Height);
        UpdateFade();
    }

    private Color DialogSurfaceColor()
    {
        // The visible dialog surface includes its top overlay, not just ContentDialogBackground.
        double coverage = 0, red = 0, green = 0, blue = 0;
        for (var parent = VisualTreeHelper.GetParent(this); parent is not null;
             parent = VisualTreeHelper.GetParent(parent))
        {
            var brush = parent switch
            {
                Panel panel => panel.Background,
                Border border => border.Background,
                ContentPresenter presenter => presenter.Background,
                Control control => control.Background,
                _ => null
            };
            if (brush is not SolidColorBrush solid) continue;
            var contribution = (1 - coverage) * solid.Color.A / 255d * solid.Opacity;
            red += contribution * solid.Color.R;
            green += contribution * solid.Color.G;
            blue += contribution * solid.Color.B;
            coverage += contribution;
            if (coverage >= 1 - 1e-6)
                return Color.FromArgb(255, (byte)Math.Round(red), (byte)Math.Round(green), (byte)Math.Round(blue));
        }
        throw new InvalidOperationException("The person preview requires an opaque, solid-color dialog surface.");
    }

    private void UpdateFade()
    {
        if (!IsLoaded || Viewport.ActualWidth <= 0) return;
        var color = DialogSurfaceColor();
        var transparent = Color.FromArgb(0, color.R, color.G, color.B);
        HeaderFade.Background = new LinearGradientBrush
        {
            StartPoint = new Point(0, 0), EndPoint = new Point(0, 1),
            GradientStops =
            {
                new GradientStop { Color = color, Offset = 0 },
                new GradientStop { Color = transparent, Offset = 1 }
            }
        };
        SideFade.Background = new LinearGradientBrush
        {
            StartPoint = new Point(0, 0), EndPoint = new Point(1, 0),
            GradientStops =
            {
                new GradientStop { Color = color, Offset = 0 },
                new GradientStop { Color = transparent, Offset = Math.Max(.1, .5 - 40 / Viewport.ActualWidth) },
                new GradientStop { Color = transparent, Offset = Math.Min(.9, .5 + 25 / Viewport.ActualWidth) },
                new GradientStop { Color = color, Offset = 1 }
            }
        };
    }
}
