using System.Numerics;
using System.Runtime.CompilerServices;
using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.UI;

namespace FingVibe.App;

public enum SurfaceKind
{
    None,
    Card,
    Control
}

public sealed class SurfaceTreatment : DependencyObject
{
    private static readonly HashSet<FrameworkElement> LoadedSurfaces = [];
    private static readonly ConditionalWeakTable<FrameworkElement, OriginalSurface> Originals = new();
    private static AppearanceSettings _settings = new();
    private static bool _highContrast;
    private static bool _transparencyEnabled = true;

    public static readonly DependencyProperty KindProperty = DependencyProperty.RegisterAttached(
        "Kind", typeof(SurfaceKind), typeof(SurfaceTreatment),
        new PropertyMetadata(SurfaceKind.None, KindChanged));

    private sealed record OriginalSurface(CornerRadius Corner, bool CanSetBackground, bool CanSetStroke);

    public static SurfaceKind GetKind(DependencyObject target) => (SurfaceKind)target.GetValue(KindProperty);
    public static void SetKind(DependencyObject target, SurfaceKind value) => target.SetValue(KindProperty, value);

    internal static void Apply(AppearanceSettings settings, bool highContrast, bool transparencyEnabled)
    {
        _settings = settings;
        _highContrast = highContrast;
        _transparencyEnabled = transparencyEnabled;
        foreach (var surface in LoadedSurfaces)
        {
            ApplySurface(surface);
        }
    }

    private static void KindChanged(DependencyObject sender, DependencyPropertyChangedEventArgs args)
    {
        if (sender is not Border && sender is not Control)
        {
            throw new ArgumentException("Surface treatments require a Border or Control.", nameof(sender));
        }
        var element = (FrameworkElement)sender;
        element.Loaded -= SurfaceLoaded;
        element.Unloaded -= SurfaceUnloaded;
        LoadedSurfaces.Remove(element);
        if ((SurfaceKind)args.NewValue != SurfaceKind.None)
        {
            element.Loaded += SurfaceLoaded;
            element.Unloaded += SurfaceUnloaded;
            if (element.IsLoaded)
            {
                SurfaceLoaded(element, new RoutedEventArgs());
            }
        }
    }

    private static void SurfaceLoaded(object sender, RoutedEventArgs args)
    {
        var element = (FrameworkElement)sender;
        Originals.GetValue(element, surface =>
        {
            var background = surface is Border ? Border.BackgroundProperty : Control.BackgroundProperty;
            var stroke = surface is Border ? Border.BorderBrushProperty : Control.BorderBrushProperty;
            return new OriginalSurface(
                surface is Border border ? border.CornerRadius : ((Control)surface).CornerRadius,
                surface.ReadLocalValue(background) == DependencyProperty.UnsetValue,
                surface.ReadLocalValue(stroke) == DependencyProperty.UnsetValue);
        });
        LoadedSurfaces.Add(element);
        ApplySurface(element);
    }

    private static void SurfaceUnloaded(object sender, RoutedEventArgs args) =>
        LoadedSurfaces.Remove((FrameworkElement)sender);

    private static void ApplySurface(FrameworkElement element)
    {
        var palette = AppearancePalette.For(_settings.Theme);
        var resources = (ResourceDictionary)Application.Current.Resources.ThemeDictionaries[
            _highContrast ? "HighContrast" : palette.IsDark ? "Dark" : "Light"];
        var card = GetKind(element) == SurfaceKind.Card;
        var backgroundProperty = element is Border ? Border.BackgroundProperty : Control.BackgroundProperty;
        var borderProperty = element is Border ? Border.BorderBrushProperty : Control.BorderBrushProperty;
        var cornerProperty = element is Border ? Border.CornerRadiusProperty : Control.CornerRadiusProperty;
        element.Shadow = null;
        ElementCompositionPreview.SetIsTranslationEnabled(element, true);
        element.Translation = Vector3.Zero;
        var original = Originals.GetValue(element, _ => throw new InvalidOperationException("Surface was not initialized."));
        element.SetValue(cornerProperty, original.Corner);

        if (_highContrast || _settings.Style == VisualStyle.Standard)
        {
            if (card)
            {
                element.SetValue(backgroundProperty, _highContrast
                    ? resources["ScannerPageBackgroundBrush"]
                    : resources["CardBackgroundFillColorDefaultBrush"]);
                element.SetValue(borderProperty, resources["ScannerCardBorderBrush"]);
            }
            else
            {
                if (original.CanSetBackground) { element.ClearValue(backgroundProperty); }
                if (original.CanSetStroke) { element.ClearValue(borderProperty); }
            }
            return;
        }

        var treatment = SurfacePalette.For(palette, _settings.Style, card);
        var color = ColorFromRgb(treatment.Top);
        Brush background = treatment.Acrylic && _transparencyEnabled
            ? new AcrylicBrush
            {
                TintColor = color,
                TintOpacity = palette.IsDark ? 0.72 : 0.82,
                FallbackColor = color
            }
            : Gradient(color, ColorFromRgb(treatment.Bottom));
        var stroke = Gradient(ColorFromRgb(treatment.BorderTop), ColorFromRgb(treatment.BorderBottom));
        if (card || original.CanSetBackground) { element.SetValue(backgroundProperty, background); }
        if (card || original.CanSetStroke) { element.SetValue(borderProperty, stroke); }
        element.SetValue(cornerProperty, new CornerRadius(treatment.Radius));
        if (treatment.Elevation > 0)
        {
            element.Shadow = new ThemeShadow();
            element.Translation = new Vector3(0, 0, treatment.Elevation);
        }
    }

    private static Color ColorFromRgb(uint value) =>
        Color.FromArgb(255, (byte)(value >> 16), (byte)(value >> 8), (byte)value);

    private static LinearGradientBrush Gradient(Color start, Color end) => new()
    {
        StartPoint = new Point(0, 0),
        EndPoint = new Point(1, 1),
        GradientStops =
        {
            new GradientStop { Color = start, Offset = 0 },
            new GradientStop { Color = end, Offset = 1 }
        }
    };
}
