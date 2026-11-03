using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App.Views;

public sealed partial class SettingsPageView : UserControl
{
    private static readonly ThemeVariant[] LightThemes =
        [ThemeVariant.StandardLight, ThemeVariant.WarmLight, ThemeVariant.ColorfulLight, ThemeVariant.VividLight];
    private static readonly ThemeVariant[] DarkThemes =
        [ThemeVariant.StandardDark, ThemeVariant.OledDark, ThemeVariant.ColorfulDark, ThemeVariant.VividDark];
    private bool _updatingAppearance;

    public SettingsPageView() => InitializeComponent();

    public DeviceColumnLayout Columns => DeviceColumnLayout.Current;
    public event SelectionChangedEventHandler? AppearanceChanged;

    private ThemeVariant[] ModeThemes => ModePicker.SelectedIndex == 1 ? DarkThemes : LightThemes;
    internal AppearanceSettings? SelectedAppearance =>
        ModePicker.SelectedIndex < 0 || ThemePicker.SelectedIndex < 0
            || VisualStylePicker.SelectedIndex < 0 || BackdropPicker.SelectedIndex < 0
            ? null
            : new AppearanceSettings((WindowBackdrop)BackdropPicker.SelectedIndex,
                ModeThemes[ThemePicker.SelectedIndex], (VisualStyle)VisualStylePicker.SelectedIndex);
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
            VisualStylePicker.SelectedIndex = (int)appearance.Style;
        }
        finally
        {
            _updatingAppearance = false;
        }
    }

    private void ModePicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        var styleIndex = ThemePicker.SelectedIndex;
        var wasUpdating = _updatingAppearance;
        _updatingAppearance = true;
        try
        {
            // Replace the item so the selected display and automation name refresh together.
            ThemePicker.Items[1] = new ComboBoxItem
            {
                Content = ModePicker.SelectedIndex == 1 ? "True Black (OLED)" : "Warm"
            };
            ThemePicker.SelectedIndex = styleIndex;
        }
        finally
        {
            _updatingAppearance = wasUpdating;
        }
        AppearancePicker_SelectionChanged(sender, e);
    }

    private void AppearancePicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_updatingAppearance && SelectedAppearance is not null)
        {
            if (ReferenceEquals(sender, VisualStylePicker)
                && VisualStylePicker.SelectedIndex == (int)VisualStyle.Glass)
            {
                _updatingAppearance = true;
                try
                {
                    BackdropPicker.SelectedIndex = (int)WindowBackdrop.MicaAlt;
                }
                finally
                {
                    _updatingAppearance = false;
                }
            }
            AppearanceChanged?.Invoke(this, e);
        }
    }

    private void AppearanceOptions_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var columns = e.NewSize.Width >= 840 ? 4 : e.NewSize.Width >= 408 ? 2 : 1;
        AppearanceOptions.RowSpacing = columns == 4 ? 0 : 12;
        var rows = 4 / columns;
        if (AppearanceOptions.RowDefinitions.Count != rows)
        {
            AppearanceOptions.RowDefinitions.Clear();
            for (var row = 0; row < rows; row++)
            {
                AppearanceOptions.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            }
        }
        FrameworkElement[] pickers = [ModePicker, ThemePicker, VisualStylePicker, BackdropPicker];
        for (var index = 0; index < pickers.Length; index++)
        {
            Grid.SetRow(pickers[index], index / columns);
            Grid.SetColumn(pickers[index], index % columns * (4 / columns));
            Grid.SetColumnSpan(pickers[index], 4 / columns);
        }
    }

    private void ColumnFooter_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        var inline = e.NewSize.Width >= 632;
        ColumnFooter.RowSpacing = inline ? 0 : 8;
        Grid.SetColumnSpan(MandatoryColumnNote, inline ? 1 : 2);
        Grid.SetRow(ResetColumnsButton, inline ? 0 : 1);
        Grid.SetColumn(ResetColumnsButton, inline ? 1 : 0);
        Grid.SetColumnSpan(ResetColumnsButton, inline ? 1 : 2);
    }

    private void ColumnChoices_Loaded(object sender, RoutedEventArgs e) => UpdateColumnChoicesLayout();

    private void ColumnChoices_SizeChanged(object sender, SizeChangedEventArgs e) => UpdateColumnChoicesLayout();

    private void UpdateColumnChoicesLayout()
    {
        if (ColumnChoices.ItemsPanelRoot is not Grid panel)
        {
            return;
        }
        const double spacing = 16;
        var columns = Math.Clamp((int)((ColumnChoices.ActualWidth + spacing) / (200 + spacing)), 1, 3);
        var rows = (Columns.All.Count + columns - 1) / columns;
        if (panel.ColumnDefinitions.Count != columns)
        {
            panel.ColumnDefinitions.Clear();
            for (var column = 0; column < columns; column++)
            {
                panel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            }
        }
        if (panel.RowDefinitions.Count != rows)
        {
            panel.RowDefinitions.Clear();
            for (var row = 0; row < rows; row++)
            {
                panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            }
        }
        for (var index = 0; index < panel.Children.Count; index++)
        {
            var container = (FrameworkElement)panel.Children[index];
            Grid.SetRow(container, index / columns);
            Grid.SetColumn(container, index % columns);
        }
    }

    private void ResetColumnsButton_Click(object sender, RoutedEventArgs e) => Columns.Reset();
}
