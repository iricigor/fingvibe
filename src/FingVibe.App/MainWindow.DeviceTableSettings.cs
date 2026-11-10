using System.Text.Json;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private readonly DeviceTableSettingsStore _deviceTableStore = new(
        IsUiReview && Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW_DEVICE_TABLE") is { Length: > 0 } fixture
            ? fixture : Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FingVibe", "device-table.json"));
    private readonly bool _deviceTableSettingsEnabled = !IsUiReview
        || Environment.GetEnvironmentVariable("FINGVIBE_UI_REVIEW_DEVICE_TABLE") is { Length: > 0 };
    private bool _deviceTableLoadFailed;
    private bool _deviceTableSettingsReady;
    private InventoryDeviceStatus[] _savedStatusFilters = [];
    private bool _savedStatusAnyKnown;

    private void InitializeDeviceTableSettings()
    {
        var columns = DeviceColumnLayout.Current;
        var migrateDensity = false;
        if (_deviceTableSettingsEnabled)
        {
            try
            {
                if (_deviceTableStore.Load() is { } settings)
                {
                    columns.Restore(settings);
                    DevicesPage.RestoreStatusFilters(settings.StatusFilters ?? [], settings.StatusAnyKnown);
                    migrateDensity = settings.DensityVersion == 0;
                }
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or JsonException)
            {
                _deviceTableLoadFailed = true;
                SettingsPage.ColumnSaveStatus = "Saved table settings could not be loaded. Defaults are shown; the file will not be overwritten.";
            }
        }
        _savedStatusFilters = DevicesPage.StatusFilters.Order().ToArray();
        _savedStatusAnyKnown = DevicesPage.StatusAnyKnown;
        _deviceTableSettingsReady = true;
        columns.SettingsChanged += DeviceTableSettings_Changed;
        Closed += (_, _) => columns.SettingsChanged -= DeviceTableSettings_Changed;
        if (migrateDensity) DeviceTableSettings_Changed(this, EventArgs.Empty);
    }

    private void DeviceTableSettings_Changed(object? sender, EventArgs e)
    {
        if (!_deviceTableSettingsEnabled || !_deviceTableSettingsReady || _deviceTableLoadFailed) return;
        try
        {
            var statuses = DevicesPage.StatusFilters.Order().ToArray();
            _deviceTableStore.Save(DeviceColumnLayout.Current.Capture() with
            {
                StatusFilters = statuses,
                StatusAnyKnown = DevicesPage.StatusAnyKnown
            });
            _savedStatusFilters = statuses;
            _savedStatusAnyKnown = DevicesPage.StatusAnyKnown;
            SettingsPage.ColumnSaveStatus = "Table preferences are saved automatically.";
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            SettingsPage.ColumnSaveStatus = "Table changes are applied, but could not be saved for the next launch.";
        }
    }

    private void SaveStatusFilterSettings()
    {
        if (!_deviceTableSettingsReady) return;
        if (DevicesPage.StatusAnyKnown != _savedStatusAnyKnown
            || !DevicesPage.StatusFilters.Order().SequenceEqual(_savedStatusFilters))
            DeviceTableSettings_Changed(this, EventArgs.Empty);
    }
}
