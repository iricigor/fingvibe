using FingVibe.App.Views;
using FingVibe.Core.Models;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private async void DeviceLinkRequested(object? sender, DeviceLinkRequest request)
    {
        var row = _selectedDeviceRow;
        if (row?.MacAddress?.ToString() is not { } mac) return;
        await _deviceDataSaveLock.WaitAsync();
        try
        {
            await PersistDeviceDataAsync(CurrentDeviceData.LinkDevices(mac, request.OtherMac, request.Choices, DateTimeOffset.UtcNow));
            ApplyLinkedDevice(CurrentDeviceData.FindLinkedDevice(mac)
                ?? throw new InvalidOperationException("The saved inventory does not contain the new linked device."));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
                                              or InvalidOperationException or InvalidDataException or ArgumentException)
        {
            if (ReferenceEquals(_selectedDeviceRow, row)) DevicePage.ShowLinkError(exception.Message);
            return;
        }
        finally { _deviceDataSaveLock.Release(); }

        ApplyUsageCategories();
        if (!ReferenceEquals(_selectedDeviceRow, row)) return;
        DevicePage.NameInput = row.NameText;
        UpdateDeviceNameActions();
        UpdateClassificationDetails();
        UpdateDeviceAssignmentPickers();
        ShowSelectedMatchSuggestions(opening: false);
    }

    /// <summary>Saves a shared-value edit; callers hold the device-data save lock.</summary>
    private async Task SaveLinkedDeviceAsync(Guid id, Func<LinkedDevice, LinkedDevice> update)
    {
        await PersistDeviceDataAsync(CurrentDeviceData.UpdateLinkedDevice(id, update));
        ApplyLinkedDevice(CurrentDeviceData.LinkedDevices.First(device => device.Id == id));
    }

    /// <summary>Shows the linked device's shared values on every member row.</summary>
    private void ApplyLinkedDevice(LinkedDevice linked)
    {
        foreach (var row in _allResults.Concat(_selectedDeviceRow is { } selected ? [selected] : []).Distinct()
                     .Where(row => row.VirtualDevice is null && row.MacAddress?.ToString() is { } mac && linked.HasMember(mac)))
        {
            row.UpdateLinkedDevice(linked);
            ApplyPeopleRoomAssignments(row);
        }
        RefreshVisibleResults();
        UpdatePeopleRoomsPages();
    }
}
