using FingVibe.App.Views;
using FingVibe.Core.Models;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private async void DeviceLinkRequested(object? sender, DeviceLinkRequest request)
    {
        var row = _selectedDeviceRow;
        if (row?.MacAddress?.ToString() is not { } mac) return;
        LinkedDevice linked;
        await _deviceDataSaveLock.WaitAsync();
        try
        {
            await PersistDeviceDataAsync(CurrentDeviceData.LinkDevices(mac, request.OtherMac, request.Choices, DateTimeOffset.UtcNow));
            linked = CurrentDeviceData.FindLinkedDevice(mac)
                ?? throw new InvalidOperationException("The saved inventory does not contain the new linked device.");
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
                                              or InvalidOperationException or InvalidDataException or ArgumentException)
        {
            if (ReferenceEquals(_selectedDeviceRow, row)) DevicePage.ShowLinkError(exception.Message);
            return;
        }
        finally { _deviceDataSaveLock.Release(); }

        // The two member rows become one linked-device row; reopen it with the linked section in view.
        RefreshInventoryRows();
        if (!ReferenceEquals(_selectedDeviceRow, row) && _selectedDeviceRow?.IdentityKey != row.IdentityKey) return;
        var linkedRow = _allResults.FirstOrDefault(item => item.IdentityKey == linked.Id.ToString("D"))
            ?? ScanResultRow.ForLinkedDevice(linked, CurrentDeviceData);
        ApplyPeopleRoomAssignments(linkedRow);
        ShowDeviceDetails(linkedRow, _deviceDetailsFromRoomMap);
        DevicePage.RevealMatchSuggestions();
    }

    private async void DeviceUnlinkRequested(object? sender, string mac)
    {
        var row = _selectedDeviceRow;
        var linked = CurrentDeviceData.FindLinkedDevice(mac);
        if (row is null || linked is null) return;
        var detached = PeopleRoomsData.NormalizeMacAddress(mac);
        var remaining = linked.Members.FirstOrDefault(member => member.Mac != detached)?.Mac;
        await _deviceDataSaveLock.WaitAsync();
        try
        {
            await PersistDeviceDataAsync(CurrentDeviceData.UnlinkDevice(mac));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
                                              or InvalidOperationException or InvalidDataException or ArgumentException)
        {
            if (ReferenceEquals(_selectedDeviceRow, row)) DevicePage.ShowUnlinkError(exception.Message);
            return;
        }
        finally { _deviceDataSaveLock.Release(); }

        // The detached MAC gets its own row again; reopen the remaining device, which keeps the shared values
        // (the linked device itself while two or more MACs remain).
        RefreshInventoryRows();
        if (!ReferenceEquals(_selectedDeviceRow, row) && _selectedDeviceRow?.IdentityKey != row.IdentityKey) return;
        var still = remaining is null ? null : CurrentDeviceData.FindLinkedDevice(remaining);
        var key = still?.Id.ToString("D") ?? remaining;
        var remainingRow = _allResults.FirstOrDefault(item => item.IdentityKey == key)
            ?? (still is not null ? ScanResultRow.ForLinkedDevice(still, CurrentDeviceData)
                : remaining is not null && CurrentDeviceData.Devices.TryGetValue(remaining, out var device)
                    ? ScanResultRow.ForDevice(device, CurrentDeviceData) : null);
        if (remainingRow is null) return;
        ApplyPeopleRoomAssignments(remainingRow);
        ShowDeviceDetails(remainingRow, _deviceDetailsFromRoomMap);
        DevicePage.RevealMatchSuggestions();
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
