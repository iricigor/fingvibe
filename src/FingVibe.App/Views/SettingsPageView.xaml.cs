using FingVibe.Core.Models;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App.Views;

public sealed partial class SettingsPageView : UserControl
{
    public SettingsPageView() => InitializeComponent();

    public DeviceColumnLayout Columns => DeviceColumnLayout.Current;
    public event SelectionChangedEventHandler? AppearanceChanged;

    internal int BackdropIndex => BackdropPicker.SelectedIndex;
    internal int ThemeIndex => ThemePicker.SelectedIndex;
    internal string SaveStatus { set => AppearanceSaveStatus.Text = value; }
    internal string MaterialStatus { set => BackdropStatus.Text = value; }

    internal void SetAppearance(AppearanceSettings appearance)
    {
        BackdropPicker.SelectedIndex = (int)appearance.Backdrop;
        ThemePicker.SelectedIndex = (int)appearance.Theme;
    }

    private void AppearancePicker_SelectionChanged(object sender, SelectionChangedEventArgs e) =>
        AppearanceChanged?.Invoke(this, e);

    private void ResetColumnsButton_Click(object sender, RoutedEventArgs e) => Columns.Reset();
}
