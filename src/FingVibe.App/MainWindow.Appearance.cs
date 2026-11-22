using System.Runtime.InteropServices;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private const string AppearanceSaveFailure = "Appearance applied, but could not be saved for the next launch.";
    // UI review keeps appearance in memory unless a check supplies an isolated store to cover persistence.
    private static string? ReviewAppearancePath => IsUiReview
        && Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW_APPEARANCE") is { Length: > 0 } path ? path : null;
    private static bool PersistAppearance => !IsUiReview || ReviewAppearancePath is not null;
    private readonly AppearanceSettingsStore _appearanceStore = new(ReviewAppearancePath ?? Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "FingVibe",
        "appearance.json"));
    private readonly AccessibilitySettings _accessibilitySettings = new();
    private readonly UISettings _uiSettings = new();
    private AppearanceSettings _appearance = new();
    private bool _appearanceReady;
    private bool _appearanceClosed;
    private string? _appearanceSaveError;
    private bool _updatingAppearanceShortcut;

    private void InitializeAppearance()
    {
        _appearance = !PersistAppearance
            ? new AppearanceSettings(Theme: ThemeVariant.StandardDark)
            : _appearanceStore.Load(IsUiReview || Application.Current.RequestedTheme == ApplicationTheme.Dark
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
        Closed += (_, _) =>
        {
            _appearanceClosed = true;
            _uiSettings.ColorValuesChanged -= Appearance_ColorValuesChanged;
        };
    }

    private void Appearance_ColorValuesChanged(UISettings sender, object args)
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            if (!_appearanceClosed)
            {
                ApplyAppearance();
                RefreshVisibleResults();
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
        SaveAppearance(fromShortcut: false);
    }

    private void AppearanceShortcutModes_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingAppearanceShortcut || !_appearanceReady || AppearanceShortcutModes.SelectedIndex < 0)
        {
            return;
        }

        var updated = AppearanceModes.WithMode(_appearance, dark: AppearanceShortcutModes.SelectedIndex == 1);
        if (updated == _appearance)
        {
            return;
        }

        _appearance = updated;
        SettingsPage.SetAppearance(_appearance);
        ApplyAppearance();
        SaveAppearance(fromShortcut: true);
    }

    private void SaveAppearance(bool fromShortcut)
    {
        if (!PersistAppearance)
        {
            return;
        }

        try
        {
            _appearanceStore.Save(_appearance);
            _appearanceSaveError = null;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            _appearanceSaveError = AppearanceSaveFailure;
        }

        SettingsPage.SaveError = _appearanceSaveError;
        UpdateAppearanceShortcut();
        if (fromShortcut && _appearanceSaveError is { } error)
        {
            // The status text is inside the open flyout; also announce it while focus stays on a mode choice.
            FrameworkElementAutomationPeer.CreatePeerForElement(AppearanceShortcutSaveStatus)?.RaiseNotificationEvent(
                AutomationNotificationKind.Other, AutomationNotificationProcessing.ImportantMostRecent,
                error, "AppearanceSaveError");
        }
    }

    private void UpdateAppearanceShortcut()
    {
        var dark = AppearanceModes.IsDark(_appearance.Theme);
        var mode = dark ? "Dark" : "Light";
        _updatingAppearanceShortcut = true;
        try
        {
            AppearanceShortcutModes.SelectedIndex = dark ? 1 : 0;
        }
        finally
        {
            _updatingAppearanceShortcut = false;
        }

        AppearanceShortcutNavItem.Content = $"{mode} mode";
        AppearanceShortcutIcon.Glyph = dark ? "\uE708" : "\uE706";
        var highContrast = _accessibilitySettings.HighContrast;
        AppearanceShortcutHighContrastNote.Visibility = highContrast ? Visibility.Visible : Visibility.Collapsed;
        AppearanceShortcutSaveStatus.Text = _appearanceSaveError ?? string.Empty;
        AppearanceShortcutSaveStatus.Visibility = _appearanceSaveError is null ? Visibility.Collapsed : Visibility.Visible;
        AppearanceShortcutBadge.Visibility = AppearanceShortcutSaveStatus.Visibility;
        TitleBarAppearanceIcon.Glyph = AppearanceShortcutIcon.Glyph;
        TitleBarAppearanceBadge.Visibility = AppearanceShortcutSaveStatus.Visibility;
        var name = $"Appearance mode: {mode}";
        var help = "Choose Light or Dark mode."
            + (highContrast ? $" {AppearanceShortcutHighContrastNote.Text}" : string.Empty)
            + (_appearanceSaveError is { } error ? $" {error}" : string.Empty);
        AutomationProperties.SetName(AppearanceShortcutNavItem, name);
        AutomationProperties.SetHelpText(AppearanceShortcutNavItem, help);
        ToolTipService.SetToolTip(AppearanceShortcutNavItem, $"{name}. {help}");
        AutomationProperties.SetName(TitleBarAppearanceButton, name);
        AutomationProperties.SetHelpText(TitleBarAppearanceButton, help);
        ToolTipService.SetToolTip(TitleBarAppearanceButton, $"{name}. {help}");
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
        var rowBackground = (ResultRowBackgroundConverter)Application.Current.Resources["ResultRowBackgroundConverter"];
        rowBackground.AlternateBackground.Color = _accessibilitySettings.HighContrast
            ? Color.FromArgb(0, 0, 0, 0)
            : Color.FromArgb(255, (byte)(palette.AlternateRow >> 16),
                (byte)(palette.AlternateRow >> 8), (byte)palette.AlternateRow);
        UpdateBuildRibbonColors();
        RoomMapPage.RefreshAppearance();

        var hasBackdrop = ApplyWindowBackdrop();
        UpdateNavigationPaneBackground(MainNavigation.IsPaneOpen);
        SettingsPage.MaterialStatus = _accessibilitySettings.HighContrast
            ? "High contrast is active; Windows system colors are used instead of materials."
            : _appearance.Backdrop != WindowBackdrop.Solid && !hasBackdrop
                ? "This material is unavailable. A solid background is used; your choice is kept."
                : null;
        UpdateAppearanceShortcut();
        UpdateTitleBarColors();
    }

    private void UpdateTitleBarColors()
    {
        if (_titleBarClosed)
        {
            return;
        }

        var highContrast = _accessibilitySettings.HighContrast;
        var palette = AppearancePalette.For(_appearance.Theme);
        var background = highContrast ? _uiSettings.GetColorValue(UIColorType.Background)
            : Color.FromArgb(255, (byte)(palette.Header >> 16), (byte)(palette.Header >> 8), (byte)palette.Header);
        var foreground = highContrast ? _uiSettings.GetColorValue(UIColorType.Foreground)
            : CompositeTitleBarColor(((SolidColorBrush)AppTitleBar.Resources["TitleBarForegroundBrush"]).Color, background);
        var inactive = highContrast ? foreground
            : CompositeTitleBarColor(((SolidColorBrush)AppTitleBar.Resources["TitleBarSecondaryBrush"]).Color, background);
        var hover = highContrast ? foreground
            : Color.FromArgb(255, (byte)(palette.Hover >> 16), (byte)(palette.Hover >> 8), (byte)palette.Hover);
        var pressed = highContrast ? foreground
            : Color.FromArgb(255, (byte)(palette.Pressed >> 16), (byte)(palette.Pressed >> 8), (byte)palette.Pressed);
        AppTitleBar.Background = new SolidColorBrush(background);
        TitleBarAppName.Foreground = new SolidColorBrush(_titleBarActive ? foreground : inactive);
        TitleBarBuildText.Foreground = new SolidColorBrush(inactive);
        TitleBarAppearanceButton.Foreground = new SolidColorBrush(_titleBarActive ? foreground : inactive);
        var titleBar = AppWindow.TitleBar;
        titleBar.ButtonBackgroundColor = background;
        titleBar.ButtonInactiveBackgroundColor = background;
        titleBar.ButtonForegroundColor = foreground;
        titleBar.ButtonInactiveForegroundColor = inactive;
        titleBar.ButtonHoverBackgroundColor = hover;
        titleBar.ButtonHoverForegroundColor = highContrast ? background : foreground;
        titleBar.ButtonPressedBackgroundColor = pressed;
        titleBar.ButtonPressedForegroundColor = highContrast ? background : foreground;
    }

    private static Color CompositeTitleBarColor(Color foreground, Color background) =>
        Color.FromArgb(255,
            (byte)((foreground.R * foreground.A + background.R * (255 - foreground.A)) / 255),
            (byte)((foreground.G * foreground.A + background.G * (255 - foreground.A)) / 255),
            (byte)((foreground.B * foreground.A + background.B * (255 - foreground.A)) / 255));

    private void UpdateNavigationPaneBackground(bool isPaneOpen)
    {
        var brush = (SolidColorBrush)MainNavigation.Resources["NavigationViewDefaultPaneBackground"];
        var isOverlay = isPaneOpen && MainNavigation.DisplayMode != NavigationViewDisplayMode.Expanded;
        // Only overlay panes need an opaque surface so page content cannot bleed through the menu.
        if (_accessibilitySettings.HighContrast)
        {
            brush.Color = isOverlay ? _uiSettings.GetColorValue(UIColorType.Background) : Color.FromArgb(0, 0, 0, 0);
        }
        else
        {
            var palette = AppearancePalette.For(_appearance.Theme);
            var resources = (ResourceDictionary)Application.Current.Resources.ThemeDictionaries[
                palette.IsDark ? "Dark" : "Light"];
            SetAppearanceBrush(resources, "ScannerPageBackgroundBrush", palette.Page,
                isOverlay || SystemBackdrop is null ? (byte)255 : (byte)0);
            SetAppearanceBrush(MainNavigation.Resources, "NavigationViewDefaultPaneBackground",
                palette.Page, isOverlay ? (byte)255 : (byte)0);
        }
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
