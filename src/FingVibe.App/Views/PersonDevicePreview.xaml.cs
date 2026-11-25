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
        PreviewIcon.IconId = id;
        UpdateAccessibleName();
    }

    internal void SetShortName(string shortName)
    {
        PreviewShortName.Text = shortName;
        UpdateAccessibleName();
    }

    private void UpdateAccessibleName() => AutomationProperties.SetName(this,
        $"Devices table preview: {PeopleRoomsIcons.Resolve(PeopleRoomsIcons.People, PreviewIcon.IconId).AccessibleName}, {PreviewShortName.Text}");

    private void Viewport_SizeChanged(object sender, SizeChangedEventArgs e) =>
        ViewportClip.Rect = new Rect(0, 0, e.NewSize.Width, e.NewSize.Height);

    private void UpdateFade()
    {
        var color = ((SolidColorBrush)PreviewSurface.Background).Color;
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
                new GradientStop { Color = transparent, Offset = .41 },
                new GradientStop { Color = transparent, Offset = .64 },
                new GradientStop { Color = color, Offset = 1 }
            }
        };
    }
}
