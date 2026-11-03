using System.Text.Json;
using FingVibe.Core.Storage;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private readonly DeviceTableSettingsStore _deviceTableStore = new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FingVibe", "device-table.json"));
    private bool _deviceTableLoadFailed;

    private void InitializeDeviceTableSettings()
    {
        var columns = DeviceColumnLayout.Current;
        if (!IsUiReview)
        {
            try
            {
                if (_deviceTableStore.Load() is { } settings) columns.Restore(settings);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
            {
                _deviceTableLoadFailed = true;
                SettingsPage.ColumnSaveStatus = "Saved table settings could not be loaded. Defaults are shown; the file will not be overwritten.";
            }
        }
        columns.SettingsChanged += DeviceTableSettings_Changed;
        Closed += (_, _) => columns.SettingsChanged -= DeviceTableSettings_Changed;
    }

    private void DeviceTableSettings_Changed(object? sender, EventArgs e)
    {
        if (IsUiReview || _deviceTableLoadFailed) return;
        try
        {
            _deviceTableStore.Save(DeviceColumnLayout.Current.Capture());
            SettingsPage.ColumnSaveStatus = "Column visibility, combinations and widths are saved automatically.";
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            SettingsPage.ColumnSaveStatus = "Table changes are applied, but could not be saved for the next launch.";
        }
    }
}
