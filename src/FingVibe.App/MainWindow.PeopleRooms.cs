using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using FingVibe.Core.Storage;
using FingVibe.App.Views;
using Microsoft.UI.Xaml;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private readonly PeopleRoomsStore _peopleRoomsStore = new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "FingVibe",
        "people-rooms.json"));
    private PeopleRoomsData _peopleRooms = new();
    private bool _peopleRoomsReady;
    private bool _peopleRoomsUnavailable;

    private async Task RestorePeopleRoomsAsync()
    {
        try
        {
            _peopleRooms = IsUiReview
                ? new PeopleRoomsData(
                    [new ManagedPerson(Guid.Parse("db958652-55aa-409f-afca-d60c68081574"), "UI review person", "UI", IconId: "person-filled")],
                    [new ManagedRoom(Guid.Parse("db958652-55aa-409f-afca-d60c68081575"), "UI review room", "UI", IconId: "garden")])
                : await _peopleRoomsStore.LoadAsync();
            SetPeopleRoomsStatus("People and rooms are saved locally.");
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidDataException)
        {
            _peopleRoomsUnavailable = true;
            SetPeopleRoomsStatus("Saved people and rooms could not be loaded. Changes are disabled to protect the saved data.");
        }

        _peopleRoomsReady = true;
        UpdatePeopleRoomsPages();
        UpdatePeopleRoomFilters();
    }

    private void InitializePeopleRoomsViews()
    {
        UpdatePeopleRoomsPages();
        UpdatePeopleRoomFilters();
    }

    private void ApplyPeopleRoomAssignments(ScanResultRow row)
    {
        Guid? personId = null;
        string? personShortName = null;
        string? personName = null;
        Guid? roomId = null;
        string? roomShortName = null;
        string? roomName = null;
        var assignment = row.VirtualDevice is { } virtualDevice ? virtualDevice.Assignment
            : row.MacAddress is { } macAddress ? _peopleRooms.Assignments.GetValueOrDefault(macAddress.ToString()) : null;
        if (assignment is not null)
        {
            if (assignment.PersonId is { } assignedPersonId
                && _peopleRooms.People.FirstOrDefault(person => person.Id == assignedPersonId) is { } person)
            {
                personId = person.Id;
                personShortName = person.ShortName;
                personName = person.Name;
            }

            if (assignment.RoomId is { } assignedRoomId
                && _peopleRooms.Rooms.FirstOrDefault(room => room.Id == assignedRoomId) is { } room)
            {
                roomId = room.Id;
                roomShortName = room.ShortName;
                roomName = room.Name;
            }
        }

        row.SetPeopleRoomAssignments(personId, personShortName, personName, roomId, roomShortName, roomName);
    }

    private void UpdatePeopleRoomsPages()
    {
        if (PeoplePage is null || RoomsPage is null || PersonDetailPage is null || RoomDetailPage is null)
        {
            return;
        }

        var canEdit = _peopleRoomsReady && !_peopleRoomsUnavailable && _inventoryReady && !_inventoryUnavailable;
        var devices = GetAssignedDeviceRows();
        var hasCurrentScan = _currentScanSnapshot is not null || _allResults.Any(row => !row.IsFingOnly);
        PeoplePage.ShowPeople(_peopleRooms, devices, hasCurrentScan, canEdit);
        RoomsPage.ShowRooms(_peopleRooms, devices, hasCurrentScan, canEdit);
        PersonDetailPage.Refresh(_peopleRooms, devices, hasCurrentScan, canEdit);
        RoomDetailPage.Refresh(_peopleRooms, devices, hasCurrentScan, canEdit);
        UpdateEquipmentActivity();
    }

    private IReadOnlyList<AssignedDeviceListRow> GetAssignedDeviceRows()
    {
        return _peopleRooms.Assignments
            .OrderBy(pair => pair.Key, StringComparer.OrdinalIgnoreCase)
            .Select(pair => new AssignedDeviceListRow(
                pair.Key,
                _allResults.FirstOrDefault(row => row.VirtualDevice is null && row.MacAddress?.ToString() == pair.Key)
                    ?? (CurrentDeviceData.Devices.TryGetValue(pair.Key, out var device)
                        ? new ScanResultRow(device, 0, _deviceNameOverrides.GetValueOrDefault(pair.Key),
                            _classificationOverrides.GetValueOrDefault(pair.Key),
                            historical: true) : null)))
            .Concat(_allResults.Where(row => row.VirtualDevice?.Assignment is not null)
                .Select(row => new AssignedDeviceListRow(row.IdentityKey, row)))
            .ToArray();
    }

    private void UpdatePeopleRoomFilters()
    {
        if (DevicesPage is null)
        {
            return;
        }

        DevicesPage.SetPeopleRoomFilters(
            _peopleRooms.People.OrderBy(item => item.ShortName, StringComparer.OrdinalIgnoreCase)
                .Select(person => (person.Id, $"{person.ShortName} · {person.Name}")),
            _peopleRooms.Rooms.OrderBy(item => item.ShortName, StringComparer.OrdinalIgnoreCase)
                .Select(room => (room.Id, $"{room.ShortName} · {room.Name}")));
    }

    private void AddPersonButton_Click(object sender, RoutedEventArgs e) =>
        _ = ShowPersonEditorAsync(null);

    private void AddRoomButton_Click(object sender, RoutedEventArgs e) =>
        _ = ShowRoomEditorAsync(null);

    private void PersonRequested(object? sender, ManagedPerson person)
    {
        PersonDetailPage.SelectedPerson = person;
        UpdatePeopleRoomsPages();
        ShowPage(PersonDetailPage);
    }

    private void RoomRequested(object? sender, ManagedRoom room)
    {
        RoomDetailPage.SelectedRoom = room;
        UpdatePeopleRoomsPages();
        ShowPage(RoomDetailPage);
    }

    private async void PersonEditRequested(object? sender, Guid id)
    {
        if (_peopleRooms.People.FirstOrDefault(person => person.Id == id) is { } person)
        {
            await ShowPersonEditorAsync(person);
        }
    }

    private async void PersonDeleteRequested(object? sender, Guid id)
    {
        if (_peopleRooms.People.FirstOrDefault(person => person.Id == id) is { } person)
        {
            await DeletePersonAsync(person);
        }
    }

    private async void RoomEditRequested(object? sender, Guid id)
    {
        if (_peopleRooms.Rooms.FirstOrDefault(room => room.Id == id) is { } room)
        {
            await ShowRoomEditorAsync(room);
        }
    }

    private async void RoomDeleteRequested(object? sender, Guid id)
    {
        if (_peopleRooms.Rooms.FirstOrDefault(room => room.Id == id) is { } room)
        {
            await DeleteRoomAsync(room);
        }
    }

    private async void EditPersonButton_Click(object sender, RoutedEventArgs e)
    {
        if (PersonDetailPage.SelectedPerson is { } person)
        {
            await ShowPersonEditorAsync(person);
        }
    }

    private async void EditRoomButton_Click(object sender, RoutedEventArgs e)
    {
        if (RoomDetailPage.SelectedRoom is { } room)
        {
            await ShowRoomEditorAsync(room);
        }
    }

    private async Task<ManagedPerson?> ShowPersonEditorAsync(ManagedPerson? existing)
    {
        if (!_peopleRoomsReady || _peopleRoomsUnavailable)
        {
            return null;
        }

        return await PeopleRoomsDialogs.ShowPersonEditorAsync(RootGrid.XamlRoot, existing, () => _peopleRooms,
            candidate => SavePeopleRoomsAsync(current => new PeopleRoomsData(
                current.People.Where(person => person.Id != existing?.Id).Append(candidate).ToArray(),
                current.Rooms, current.Assignments)));
    }

    private async Task<ManagedRoom?> ShowRoomEditorAsync(ManagedRoom? existing)
    {
        if (!_peopleRoomsReady || _peopleRoomsUnavailable)
        {
            return null;
        }

        return await PeopleRoomsDialogs.ShowRoomEditorAsync(RootGrid.XamlRoot, existing, () => _peopleRooms,
            candidate => SavePeopleRoomsAsync(current => new PeopleRoomsData(
                current.People,
                current.Rooms.Where(room => room.Id != existing?.Id).Append(candidate).ToArray(),
                current.Assignments)));
    }

    private async Task<bool> SavePeopleRoomsAsync(Func<PeopleRoomsData, PeopleRoomsData> update)
    {
        if (!_peopleRoomsReady || _peopleRoomsUnavailable)
        {
            return false;
        }

        await _deviceDataSaveLock.WaitAsync();
        try
        {
            var updated = update(_peopleRooms);
            await PersistDeviceDataAsync(CurrentDeviceData with
            {
                PeopleRooms = updated,
                VirtualDevices = CurrentDeviceData.VirtualDevices.Select(device => device with
                {
                    Assignment = device.Assignment is not { } assignment ? null : assignment with
                    {
                        PersonId = updated.People.Any(person => person.Id == assignment.PersonId) ? assignment.PersonId : null,
                        RoomId = updated.Rooms.Any(room => room.Id == assignment.RoomId) ? assignment.RoomId : null
                    }
                }).ToArray()
            });
            _peopleRooms = updated;
            foreach (var row in _allResults)
            {
                if (row.VirtualDevice is { } virtualDevice)
                    row.UpdateVirtualDevice(CurrentDeviceData.VirtualDevices.First(device => device.Id == virtualDevice.Id));
                ApplyPeopleRoomAssignments(row);
            }

            UpdatePeopleRoomFilters();
            RefreshVisibleResults();
            UpdatePeopleRoomsPages();
            if (_selectedDeviceRow is not null)
            {
                UpdateDeviceAssignmentPickers();
            }

            SetPeopleRoomsStatus("People and rooms saved.");
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
                                          or InvalidDataException or ArgumentException or FormatException or InvalidOperationException)
        {
            SetPeopleRoomsStatus($"People and rooms could not be saved. Your previous saved data is unchanged: {exception.Message}");
            return false;
        }
        finally
        {
            _deviceDataSaveLock.Release();
        }
    }

    private void SetPeopleRoomsStatus(string message)
    {
        if (PeoplePage is not null)
        {
            PeoplePage.Status = message;
        }

        if (RoomsPage is not null)
        {
            RoomsPage.Status = message;
        }

        if (DevicePage is not null)
        {
            DevicePage.AssignmentStatus = message;
        }

        if (PersonDetailPage is not null)
        {
            PersonDetailPage.Status = message;
        }

        if (RoomDetailPage is not null)
        {
            RoomDetailPage.Status = message;
        }
    }

    private async void DeletePersonButton_Click(object sender, RoutedEventArgs e)
    {
        if (PersonDetailPage.SelectedPerson is { } person)
        {
            await DeletePersonAsync(person);
        }
    }

    private async Task DeletePersonAsync(ManagedPerson person)
    {
        if (!_peopleRoomsReady || _peopleRoomsUnavailable
            || !await PeopleRoomsDialogs.ConfirmDeleteAsync(RootGrid.XamlRoot, person.Name, "person"))
        {
            return;
        }

        if (await SavePeopleRoomsAsync(data => data.DeletePerson(person.Id)))
        {
            PersonDetailPage.SelectedPerson = null;
            ShowPage(PeoplePage);
        }
    }

    private async void DeleteRoomButton_Click(object sender, RoutedEventArgs e)
    {
        if (RoomDetailPage.SelectedRoom is { } room)
        {
            await DeleteRoomAsync(room);
        }
    }

    private async Task DeleteRoomAsync(ManagedRoom room)
    {
        if (!_peopleRoomsReady || _peopleRoomsUnavailable
            || !await PeopleRoomsDialogs.ConfirmDeleteAsync(RootGrid.XamlRoot, room.Name, "room"))
        {
            return;
        }

        if (await SavePeopleRoomsAsync(data => data.DeleteRoom(room.Id)))
        {
            RoomDetailPage.SelectedRoom = null;
            ShowPage(RoomsPage);
        }
    }

    private async void AssignPersonDeviceButton_Click(object sender, RoutedEventArgs e) =>
        await AssignDeviceFromDetailsAsync(personCategory: true);

    private async void AssignRoomDeviceButton_Click(object sender, RoutedEventArgs e) =>
        await AssignDeviceFromDetailsAsync(personCategory: false);

    private async Task AssignDeviceFromDetailsAsync(bool personCategory)
    {
        if (!_peopleRoomsReady || _peopleRoomsUnavailable)
        {
            SetDetailStatus(personCategory, "People and rooms are unavailable until saved data has finished loading.");
            return;
        }

        var available = _allResults.Where(row => row.MacAddress?.GetAddressBytes().Length == 6)
            .DistinctBy(row => row.IdentityKey)
            .OrderBy(row => row.NameText, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        if (available.Length == 0)
        {
            SetDetailStatus(personCategory, "No devices with a discovered MAC address are available to assign.");
            return;
        }

        var selected = await PeopleRoomsDialogs.ChooseDeviceAsync(RootGrid.XamlRoot, available);
        if (selected?.MacAddress is null)
        {
            return;
        }

        var personId = PersonDetailPage.SelectedPerson?.Id;
        var roomId = RoomDetailPage.SelectedRoom?.Id;
        var saved = await SaveRowAssignmentAsync(selected, personCategory, personCategory ? personId : roomId);
        if (saved)
        {
            SetDetailStatus(personCategory, "Device assignment saved.");
        }
    }

    private void SetDetailStatus(bool personCategory, string message)
    {
        if (personCategory)
        {
            PersonDetailPage.Status = message;
        }
        else
        {
            RoomDetailPage.Status = message;
        }
    }

    private async void PersonUnassignRequested(object? sender, string macAddress)
    {
        if (!_peopleRoomsReady || _peopleRoomsUnavailable || PersonDetailPage.SelectedPerson is null)
        {
            return;
        }

        try
        {
            if (_allResults.FirstOrDefault(row => row.VirtualDevice is not null && row.IdentityKey == macAddress) is { } virtualRow)
            {
                if (await SaveRowAssignmentAsync(virtualRow, true, null)) PersonDetailPage.Status = "Device unassigned.";
                return;
            }
            if (await SavePeopleRoomsAsync(data => data.AssignPerson(macAddress, null)))
            {
                PersonDetailPage.Status = "Device unassigned.";
            }
        }
        catch (FormatException)
        {
            PersonDetailPage.Status = "The device MAC address is invalid.";
        }
    }

    private async void RoomUnassignRequested(object? sender, string macAddress)
    {
        if (!_peopleRoomsReady || _peopleRoomsUnavailable || RoomDetailPage.SelectedRoom is null)
        {
            return;
        }

        try
        {
            if (_allResults.FirstOrDefault(row => row.VirtualDevice is not null && row.IdentityKey == macAddress) is { } virtualRow)
            {
                if (await SaveRowAssignmentAsync(virtualRow, false, null)) RoomDetailPage.Status = "Device unassigned.";
                return;
            }
            if (await SavePeopleRoomsAsync(data => data.AssignRoom(macAddress, null)))
            {
                RoomDetailPage.Status = "Device unassigned.";
            }
        }
        catch (FormatException)
        {
            RoomDetailPage.Status = "The device MAC address is invalid.";
        }
    }

    private void BackToPeopleButton_Click(object sender, RoutedEventArgs e) => ShowPage(PeoplePage);

    private void BackToRoomsButton_Click(object sender, RoutedEventArgs e) => ShowPage(RoomsPage);

    private void UpdateDeviceAssignmentPickers()
    {
        if (DevicePage is null || _selectedDeviceRow is null)
        {
            return;
        }

        var macAddress = _selectedDeviceRow.MacAddress;
        var canAssign = macAddress?.GetAddressBytes().Length == 6
            && _peopleRoomsReady && !_peopleRoomsUnavailable && _inventoryReady && !_inventoryUnavailable;
        DevicePage.SetAssignments(
            _peopleRooms.People.Select(person => (person.Id, $"{person.ShortName} · {person.Name}")),
            _peopleRooms.Rooms.Select(room => (room.Id, $"{room.ShortName} · {room.Name}")),
            _selectedDeviceRow.PersonId, _selectedDeviceRow.RoomId, canAssign);
        DevicePage.AssignmentStatus = !_peopleRoomsReady
            ? "People and rooms are still loading; assignments are unavailable."
            : _peopleRoomsUnavailable
            ? "Saved people and rooms could not be loaded; assignments are disabled."
            : _selectedDeviceRow.VirtualDevice is not null
                ? "Assignments belong to this virtual device and follow its inferred MAC associations."
            : macAddress is null
                ? "A valid six-byte MAC address is required to save assignments; IP addresses can change."
                : macAddress.GetAddressBytes().Length != 6
                    ? "A valid six-byte MAC address is required to save assignments."
                : MacAddressResolver.IsPrivateOrRandomized(macAddress)
                    ? "This private/randomized MAC may change; its assignments will not transfer to another MAC."
                    : "Assignments are saved by MAC address and do not depend on scan snapshots.";
    }

    private async void DevicePersonAssignmentRequested(object? sender, DeviceAssignmentChoice choice)
    {
        if (choice.AddNew)
        {
            UpdateDeviceAssignmentPickers();
            var person = await ShowPersonEditorAsync(null);
            if (person is not null)
            {
                await SaveDevicePersonAssignmentAsync(person.Id);
            }

            return;
        }

        await SaveDevicePersonAssignmentAsync(choice.Id);
    }

    private async void DeviceRoomAssignmentRequested(object? sender, DeviceAssignmentChoice choice)
    {
        if (choice.AddNew)
        {
            UpdateDeviceAssignmentPickers();
            var room = await ShowRoomEditorAsync(null);
            if (room is not null)
            {
                await SaveDeviceRoomAssignmentAsync(room.Id);
            }

            return;
        }

        await SaveDeviceRoomAssignmentAsync(choice.Id);
    }

    private async Task SaveDevicePersonAssignmentAsync(Guid? personId)
    {
        if (!_peopleRoomsReady || _peopleRoomsUnavailable || _selectedDeviceRow?.MacAddress is not { } mac
            || mac.GetAddressBytes().Length != 6)
        {
            return;
        }

        try
        {
            if (await SaveRowAssignmentAsync(_selectedDeviceRow, true, personId))
            {
                DevicePage.AssignmentStatus = "Person assignment saved.";
            }
        }
        catch (Exception exception) when (exception is ArgumentException or FormatException)
        {
            DevicePage.AssignmentStatus = "The person assignment could not be saved.";
        }
    }

    private async Task SaveDeviceRoomAssignmentAsync(Guid? roomId)
    {
        if (!_peopleRoomsReady || _peopleRoomsUnavailable || _selectedDeviceRow?.MacAddress is not { } mac
            || mac.GetAddressBytes().Length != 6)
        {
            return;
        }

        try
        {
            if (await SaveRowAssignmentAsync(_selectedDeviceRow, false, roomId))
            {
                DevicePage.AssignmentStatus = "Room assignment saved.";
            }

        }
        catch (Exception exception) when (exception is ArgumentException or FormatException)
        {
            DevicePage.AssignmentStatus = "The room assignment could not be saved.";
        }
    }

    private async Task<bool> SaveRowAssignmentAsync(ScanResultRow row, bool person, Guid? id)
    {
        if (row.VirtualDevice is null)
            return await SavePeopleRoomsAsync(data => person
                ? data.AssignPerson(row.IdentityKey, id) : data.AssignRoom(row.IdentityKey, id));
        await _deviceDataSaveLock.WaitAsync();
        try
        {
            await SaveVirtualDeviceAsync(row, device => device with
            {
                Assignment = person
                    ? (device.Assignment ?? new()) with { PersonId = id }
                    : (device.Assignment ?? new()) with { RoomId = id }
            });
            UpdateDeviceAssignmentPickers();
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or ArgumentException or InvalidOperationException)
        {
            SetPeopleRoomsStatus($"The virtual-device assignment could not be saved: {exception.Message}");
            return false;
        }
        finally { _deviceDataSaveLock.Release(); }
    }
}
