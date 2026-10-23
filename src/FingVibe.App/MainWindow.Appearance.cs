using System.Runtime.InteropServices;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
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
    private AppearanceSettings _appearance = new();
    private bool _appearanceReady;
    private bool _appearanceClosed;

    private void InitializeAppearance()
    {
        _appearance = IsUiReview
            ? new AppearanceSettings(Theme: ThemeVariant.StandardDark)
            : _appearanceStore.Load();
        BackdropPicker.SelectedIndex = (int)_appearance.Backdrop;
        ThemePicker.SelectedIndex = (int)_appearance.Theme;
        ApplyAppearance();
        _appearanceReady = true;
        _accessibilitySettings.HighContrastChanged += Appearance_HighContrastChanged;
        Closed += (_, _) =>
        {
            _appearanceClosed = true;
            _accessibilitySettings.HighContrastChanged -= Appearance_HighContrastChanged;
        };
    }

    private void Appearance_HighContrastChanged(AccessibilitySettings sender, object args)
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
        if (!_appearanceReady || BackdropPicker.SelectedIndex < 0 || ThemePicker.SelectedIndex < 0)
        {
            return;
        }

        _appearance = new AppearanceSettings(
            (WindowBackdrop)BackdropPicker.SelectedIndex,
            (ThemeVariant)ThemePicker.SelectedIndex);
        ApplyAppearance();
        try
        {
            _appearanceStore.Save(_appearance);
            AppearanceSaveStatus.Text = "Appearance saved automatically.";
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            AppearanceSaveStatus.Text = "Appearance applied, but could not be saved for the next launch.";
        }
    }

    private void ApplyAppearance()
    {
        var palette = AppearancePalette.For(_appearance.Theme);
        var resources = (ResourceDictionary)Application.Current.Resources.ThemeDictionaries[
            palette.IsDark ? "Dark" : "Light"];
        SetAppearanceBrush(resources, "ScannerHeaderBackgroundBrush", palette.Header);
        SetAppearanceBrush(resources, "ScannerCardBorderBrush", palette.Border);
        SetAppearanceBrush(resources, "CardBackgroundFillColorDefaultBrush", palette.Card);
        SetAppearanceBrush(resources, "ControlFillColorDefaultBrush", palette.Control);
        SetAppearanceBrush(resources, "ControlFillColorSecondaryBrush", palette.Hover);
        SetAppearanceBrush(resources, "ControlFillColorTertiaryBrush", palette.Pressed);
        RootGrid.RequestedTheme = palette.IsDark ? ElementTheme.Dark : ElementTheme.Light;

        var hasBackdrop = ApplyWindowBackdrop();
        SetAppearanceBrush(resources, "ScannerPageBackgroundBrush", palette.Page, hasBackdrop ? (byte)0 : (byte)255);
        BackdropStatus.Text = _accessibilitySettings.HighContrast
            ? "High contrast is active; Windows system colors are used instead of materials."
            : _appearance.Backdrop != WindowBackdrop.Solid && !hasBackdrop
                ? "This material is unavailable. A solid background is used; your choice is kept."
                : "Changes are previewed immediately. Material effects also depend on Windows transparency settings.";
    }

    private bool ApplyWindowBackdrop()
    {
        try
        {
            // Disconnect the old composition target before connecting a different material.
            SystemBackdrop = null;
            if (_accessibilitySettings.HighContrast)
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
