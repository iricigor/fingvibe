using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App.Views;

public sealed partial class SettingsPageView : UserControl
{
    private static readonly ThemeVariant[] LightThemes =
        [ThemeVariant.StandardLight, ThemeVariant.WarmLight, ThemeVariant.ColorfulLight];
    private static readonly ThemeVariant[] DarkThemes =
        [ThemeVariant.StandardDark, ThemeVariant.OledDark, ThemeVariant.ColorfulDark];
    private bool _updatingAppearance;

    public SettingsPageView() => InitializeComponent();

    public DeviceColumnLayout Columns => DeviceColumnLayout.Current;
    public event SelectionChangedEventHandler? AppearanceChanged;

    private ThemeVariant[] ModeThemes => ModePicker.SelectedIndex == 1 ? DarkThemes : LightThemes;
    internal AppearanceSettings? SelectedAppearance =>
        ModePicker.SelectedIndex < 0 || ThemePicker.SelectedIndex < 0 || BackdropPicker.SelectedIndex < 0
            ? null
            : new AppearanceSettings((WindowBackdrop)BackdropPicker.SelectedIndex, ModeThemes[ThemePicker.SelectedIndex]);
    internal string SaveStatus { set => AppearanceSaveStatus.Text = value; }
    internal string MaterialStatus { set => BackdropStatus.Text = value; }

    internal void SetAppearance(AppearanceSettings appearance)
    {
        _updatingAppearance = true;
        try
        {
            ModePicker.SelectedIndex = Array.IndexOf(DarkThemes, appearance.Theme) >= 0 ? 1 : 0;
            ThemePicker.SelectedIndex = Array.IndexOf(ModeThemes, appearance.Theme);
            BackdropPicker.SelectedIndex = (int)appearance.Backdrop;
        }
        finally
        {
            _updatingAppearance = false;
        }
    }

    private void AppearancePicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (ReferenceEquals(sender, ModePicker))
        {
            AlternativeTheme.Content = ModePicker.SelectedIndex == 1 ? "True Black (OLED)" : "Warm";
        }
        if (!_updatingAppearance && SelectedAppearance is not null)
        {
            AppearanceChanged?.Invoke(this, e);
        }
    }

    private void AppearanceOptions_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var inline = e.NewSize.Width >= 632;
        FrameworkElement[] pickers = [ModePicker, ThemePicker, BackdropPicker];
        for (var index = 0; index < pickers.Length; index++)
        {
            Grid.SetRow(pickers[index], inline ? 0 : index);
            Grid.SetColumn(pickers[index], inline ? index : 0);
            Grid.SetColumnSpan(pickers[index], inline ? 1 : 3);
        }
    }

    private void ColumnFooter_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var inline = e.NewSize.Width >= 632;
        Grid.SetColumnSpan(MandatoryColumnNote, inline ? 1 : 2);
        Grid.SetRow(ResetColumnsButton, inline ? 0 : 1);
        Grid.SetColumn(ResetColumnsButton, inline ? 1 : 0);
        Grid.SetColumnSpan(ResetColumnsButton, inline ? 1 : 2);
    }

    private void ResetColumnsButton_Click(object sender, RoutedEventArgs e) => Columns.Reset();
}
