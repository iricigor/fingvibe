using System.Numerics;
using System.Runtime.InteropServices;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private readonly AppearanceSettingsStore _appearanceStore = new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "FingVibe",
        "appearance.json"));
    private readonly AccessibilitySettings _accessibilitySettings = new();
    private readonly UISettings _uiSettings = new();
    private AppearanceSettings _appearance = new();
    private bool _appearanceReady;
    private bool _appearanceClosed;

    private void InitializeAppearance()
    {
        _appearance = IsUiReview
            ? new AppearanceSettings(Theme: ThemeVariant.StandardDark)
            : _appearanceStore.Load(Application.Current.RequestedTheme == ApplicationTheme.Dark
                ? ThemeVariant.StandardDark
                : ThemeVariant.StandardLight);
        SettingsPage.SetAppearance(_appearance);
        ApplyAppearance();
        MainNavigation.PaneOpening += (_, _) => UpdateNavigationPaneBackground(isPaneOpen: true);
        MainNavigation.PaneClosing += (_, _) => UpdateNavigationPaneBackground(isPaneOpen: false);
        MainNavigation.DisplayModeChanged += (_, _) => UpdateNavigationPaneBackground(MainNavigation.IsPaneOpen);
        _appearanceReady = true;
        // HighContrastChanged requires a CoreWindow, which WinUI desktop windows do not have.
        _uiSettings.ColorValuesChanged += Appearance_ColorValuesChanged;
        _uiSettings.AdvancedEffectsEnabledChanged += Appearance_AdvancedEffectsEnabledChanged;
        Closed += (_, _) =>
        {
            _appearanceClosed = true;
            _uiSettings.ColorValuesChanged -= Appearance_ColorValuesChanged;
            _uiSettings.AdvancedEffectsEnabledChanged -= Appearance_AdvancedEffectsEnabledChanged;
        };
    }

    private void Appearance_AdvancedEffectsEnabledChanged(UISettings sender, object args) =>
        Appearance_ColorValuesChanged(sender, args);

    private void Appearance_ColorValuesChanged(UISettings sender, object args)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (!_appearanceClosed)
            {
                ApplyAppearance();
            }
        });
    }

    private void AppearancePicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_appearanceReady || SettingsPage.SelectedAppearance is not { } appearance)
        {
            return;
        }

        _appearance = appearance;
        ApplyAppearance();
        if (IsUiReview)
        {
            return;
        }
        try
        {
            _appearanceStore.Save(_appearance);
            SettingsPage.SaveStatus = "Appearance saved automatically.";
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            SettingsPage.SaveStatus = "Appearance applied, but could not be saved for the next launch.";
        }
    }

    private void ApplyAppearance()
    {
        var palette = AppearancePalette.For(_appearance.Theme);
        var resources = (ResourceDictionary)Application.Current.Resources.ThemeDictionaries[
            palette.IsDark ? "Dark" : "Light"];
        var glass = _appearance.Style == VisualStyle.Glass
            && !_accessibilitySettings.HighContrast && _uiSettings.AdvancedEffectsEnabled;
        var surface = SurfacePalette.For(palette, _appearance.Style, card: true);
        var fillAlpha = glass ? surface.FillAlpha : (byte)255;
        SetAppearanceBrush(resources, "ScannerHeaderBackgroundBrush", palette.Header, glass ? (byte)80 : (byte)255);
        SetAppearanceBrush(resources, "ScannerCardBorderBrush",
            glass ? surface.BorderTop : palette.Border, glass ? surface.BorderAlpha : (byte)255);
        SetAppearanceBrush(resources, "CardBackgroundFillColorDefaultBrush", palette.Card, fillAlpha);
        SetAppearanceBrush(resources, "ControlFillColorDefaultBrush", palette.Control, fillAlpha);
        SetAppearanceBrush(resources, "ControlFillColorSecondaryBrush", palette.Hover, glass ? (byte)200 : (byte)255);
        SetAppearanceBrush(resources, "ControlFillColorTertiaryBrush", palette.Pressed, glass ? (byte)220 : (byte)255);
        RootGrid.RequestedTheme = palette.IsDark ? ElementTheme.Dark : ElementTheme.Light;
        var rowBackground = (ResultRowBackgroundConverter)Application.Current.Resources["ResultRowBackgroundConverter"];
        rowBackground.AlternateBackground.Color = _accessibilitySettings.HighContrast
            ? Color.FromArgb(0, 0, 0, 0)
            : Color.FromArgb(glass ? (byte)80 : (byte)255, (byte)(palette.AlternateRow >> 16),
                (byte)(palette.AlternateRow >> 8), (byte)palette.AlternateRow);
        UpdateBuildRibbonColors();

        var hasBackdrop = ApplyWindowBackdrop();
        UpdateGlassBackdrop(glass && hasBackdrop, palette.IsDark);
        UpdateNavigationPaneBackground(MainNavigation.IsPaneOpen);
        SurfaceTreatment.Apply(_appearance, _accessibilitySettings.HighContrast, _uiSettings.AdvancedEffectsEnabled);
        SettingsPage.MaterialStatus = _accessibilitySettings.HighContrast
            ? "High contrast is active; Windows system colors are used instead of materials."
            : !_uiSettings.AdvancedEffectsEnabled
                && (_appearance.Style == VisualStyle.Glass || _appearance.Backdrop != WindowBackdrop.Solid)
                ? "Windows transparency effects are off; opaque surfaces are used. Your choices are kept."
            : _appearance.Backdrop != WindowBackdrop.Solid && !hasBackdrop
                ? "This material is unavailable. A solid background is used; your choice is kept."
                : "Changes are previewed immediately. Material effects also depend on Windows transparency settings.";
    }

    private void UpdateNavigationPaneBackground(bool isPaneOpen)
    {
        var isOverlay = isPaneOpen && MainNavigation.DisplayMode != NavigationViewDisplayMode.Expanded;
        var glass = _appearance.Style == VisualStyle.Glass
            && !_accessibilitySettings.HighContrast && _uiSettings.AdvancedEffectsEnabled;
        GlassPaneOutline.Visibility = glass
            && (isPaneOpen || MainNavigation.DisplayMode != NavigationViewDisplayMode.Minimal)
            ? Visibility.Visible : Visibility.Collapsed;
        GlassPaneOutline.Width = isPaneOpen ? MainNavigation.OpenPaneLength : MainNavigation.CompactPaneLength;
        if (_accessibilitySettings.HighContrast)
        {
            SetNavigationPaneBrush("NavigationViewDefaultPaneBackground",
                isOverlay ? _uiSettings.GetColorValue(UIColorType.Background) : Color.FromArgb(0, 0, 0, 0), false);
            SetNavigationPaneBrush("NavigationViewExpandedPaneBackground", Color.FromArgb(0, 0, 0, 0), false);
        }
        else
        {
            var palette = AppearancePalette.For(_appearance.Theme);
            var resources = (ResourceDictionary)Application.Current.Resources.ThemeDictionaries[
                palette.IsDark ? "Dark" : "Light"];
            SetAppearanceBrush(resources, "ScannerPageBackgroundBrush", palette.Page,
                isOverlay || SystemBackdrop is null ? (byte)255 : (byte)0);
            var paneAlpha = glass ? (byte)160 : isOverlay ? (byte)255 : (byte)0;
            var color = Color.FromArgb(paneAlpha, (byte)(palette.Page >> 16),
                (byte)(palette.Page >> 8), (byte)palette.Page);
            SetNavigationPaneBrush("NavigationViewDefaultPaneBackground", color, glass && isOverlay);
            SetNavigationPaneBrush("NavigationViewExpandedPaneBackground", color, false);
        }
    }

    private void SetNavigationPaneBrush(string key, Color color, bool frosted)
    {
        var brush = (AcrylicBrush)MainNavigation.Resources[key];
        brush.FallbackColor = color;
        brush.TintColor = Color.FromArgb(255, color.R, color.G, color.B);
        brush.TintOpacity = 0.65;
        // Overlay menus need in-app blur to prevent page text showing through their labels.
        brush.AlwaysUseFallback = !frosted;
    }

    private void UpdateGlassBackdrop(bool visible, bool dark)
    {
        GlassBackdrop.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        ElementCompositionPreview.SetElementChildVisual(GlassBackdrop, null);
        if (!visible)
        {
            return;
        }

        var compositor = ElementCompositionPreview.GetElementVisual(GlassBackdrop).Compositor;
        var layer = compositor.CreateContainerVisual();
        layer.RelativeSizeAdjustment = Vector2.One;
        layer.Clip = compositor.CreateInsetClip();
        var alpha = dark ? (byte)90 : (byte)150;
        AddGlow(0x8B6CE8, new Vector2(1.2f, 1.4f), new Vector3(-0.4f, -0.5f, 0));
        AddGlow(0x29B8CF, new Vector2(1.1f, 1.5f), new Vector3(0.35f, -0.25f, 0));
        AddGlow(0xECAB78, new Vector2(1.4f, 1.3f), new Vector3(-0.05f, 0.3f, 0));
        ElementCompositionPreview.SetElementChildVisual(GlassBackdrop, layer);

        void AddGlow(uint rgb, Vector2 size, Vector3 offset)
        {
            var brush = compositor.CreateRadialGradientBrush();
            brush.CenterPoint = new Vector2(0.5f);
            brush.EllipseRadius = new Vector2(0.5f);
            brush.ColorStops.Add(compositor.CreateColorGradientStop(0, GlowColor(alpha)));
            brush.ColorStops.Add(compositor.CreateColorGradientStop(0.5f, GlowColor((byte)(alpha / 2))));
            brush.ColorStops.Add(compositor.CreateColorGradientStop(1, GlowColor(0)));
            var glow = compositor.CreateSpriteVisual();
            glow.RelativeSizeAdjustment = size;
            glow.RelativeOffsetAdjustment = offset;
            glow.Brush = brush;
            layer.Children.InsertAtTop(glow);

            Color GlowColor(byte opacity) =>
                Color.FromArgb(opacity, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);
        }
    }

    private bool ApplyWindowBackdrop()
    {
        try
        {
            // Disconnect the old composition target before connecting a different material.
            SystemBackdrop = null;
            if (_accessibilitySettings.HighContrast || !_uiSettings.AdvancedEffectsEnabled)
            {
                return false;
            }

            SystemBackdrop = _appearance.Backdrop switch
            {
                WindowBackdrop.Mica when MicaController.IsSupported() =>
                    new MicaBackdrop { Kind = MicaKind.Base },
                WindowBackdrop.MicaAlt when MicaController.IsSupported() =>
                    new MicaBackdrop { Kind = MicaKind.BaseAlt },
                WindowBackdrop.Acrylic when DesktopAcrylicController.IsSupported() =>
                    new DesktopAcrylicBackdrop(),
                _ => null
            };
            return SystemBackdrop is not null;
        }
        catch (Exception exception) when (exception is COMException or ArgumentException
                                        or InvalidOperationException or NotSupportedException)
        {
            SystemBackdrop = null;
            return false;
        }
    }

    private static void SetAppearanceBrush(ResourceDictionary resources, string key, uint rgb, byte alpha = 255)
    {
        ((SolidColorBrush)resources[key]).Color = Color.FromArgb(
            alpha, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);
    }
}
