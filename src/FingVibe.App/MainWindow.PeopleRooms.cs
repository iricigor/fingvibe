using System.Globalization;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using FingVibe.Core.Storage;
using FingVibe.App.Views;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private readonly PeopleRoomsStore _peopleRoomsStore = new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "FingVibe",
        "people-rooms.json"));
    private PeopleRoomsData _peopleRooms = new();
    private ManagedPerson? _selectedPerson;
    private ManagedRoom? _selectedRoom;
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
        if (row.MacAddress is { } macAddress
            && _peopleRooms.Assignments.TryGetValue(macAddress.ToString(), out var assignment))
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

        var peopleSearch = PeoplePage.SearchText.Trim();
        var peopleRows = _peopleRooms.People
            .Where(person => MatchesSearch(person.ShortName, person.Name, peopleSearch))
            .Select(person =>
            {
                var assignedCount = _peopleRooms.Assignments.Count(pair => pair.Value.PersonId == person.Id);
                var respondedCount = GetAssignedDeviceRows(person.Id, null)
                    .Count(row => row.ScanResult?.IsCurrentScanResponse == true);
                return new ManagedPersonListRow(
                    person,
                    $"{assignedCount} {(assignedCount == 1 ? "device" : "devices")}",
                    LastScanResponseCount(respondedCount));
            })
            .ToArray();
        var canEdit = _peopleRoomsReady && !_peopleRoomsUnavailable && _inventoryReady && !_inventoryUnavailable;
        PeoplePage.ShowRows(peopleRows,
            _peopleRooms.People.Count == 0 ? "No people yet" : "No people match your search.", canEdit);
        PersonDetailPage.SetActionsEnabled(canEdit);

        var roomsSearch = RoomsPage.SearchText.Trim();
        var roomRows = _peopleRooms.Rooms
            .Where(room => MatchesSearch(room.ShortName, room.Name, roomsSearch))
            .Select(room =>
            {
                var assignedCount = _peopleRooms.Assignments.Count(pair => pair.Value.RoomId == room.Id);
                var respondedCount = GetAssignedDeviceRows(null, room.Id)
                    .Count(row => row.ScanResult?.IsCurrentScanResponse == true);
                return new ManagedRoomListRow(
                    room,
                    $"{assignedCount} {(assignedCount == 1 ? "device" : "devices")}",
                    LastScanResponseCount(respondedCount));
            })
            .ToArray();
        RoomsPage.ShowRows(roomRows,
            _peopleRooms.Rooms.Count == 0 ? "No rooms yet" : "No rooms match your search.", canEdit);
        RoomDetailPage.SetActionsEnabled(canEdit);

        UpdatePersonDetails();
        UpdateRoomDetails();
    }

    private static bool MatchesSearch(string shortName, string name, string search) =>
        shortName.Contains(search, StringComparison.OrdinalIgnoreCase)
        || name.Contains(search, StringComparison.OrdinalIgnoreCase);

    private IReadOnlyList<AssignedDeviceListRow> GetAssignedDeviceRows(Guid? personId, Guid? roomId)
    {
        return _peopleRooms.Assignments
            .Where(pair => (personId is null || pair.Value.PersonId == personId)
                && (roomId is null || pair.Value.RoomId == roomId))
            .OrderBy(pair => pair.Key, StringComparer.OrdinalIgnoreCase)
            .Select(pair => new AssignedDeviceListRow(
                pair.Key,
                _allResults.FirstOrDefault(row => row.MacAddress?.ToString() == pair.Key)))
            .ToArray();
    }

    private string LastScanResponseCount(int respondedCount) =>
        _liveCompletedAt is null ? "No current local scan" : $"{respondedCount} responded";

    private void UpdatePersonDetails()
    {
        if (_selectedPerson is not { } person || PersonDetailPage is null)
        {
            return;
        }

        var assignedRows = GetAssignedDeviceRows(person.Id, null);
        var assignedCount = _peopleRooms.Assignments.Count(pair => pair.Value.PersonId == person.Id);
        var responses = _liveCompletedAt is null
            ? "No current local scan. Retained device states are historical."
            : $"{assignedRows.Count(row => row.ScanResult?.IsCurrentScanResponse == true)} devices responded in the current local scan.";
        PersonDetailPage.ShowPerson(person, assignedRows,
            $"{assignedCount} {(assignedCount == 1 ? "device" : "devices")} assigned", responses, assignedCount == 0);
    }

    private void UpdateRoomDetails()
    {
        if (_selectedRoom is not { } room || RoomDetailPage is null)
        {
            return;
        }

        var assignedRows = GetAssignedDeviceRows(null, room.Id);
        var assignedCount = _peopleRooms.Assignments.Count(pair => pair.Value.RoomId == room.Id);
        var responses = _liveCompletedAt is null
            ? "No current local scan. Retained device states are historical."
            : $"{assignedRows.Count(row => row.ScanResult?.IsCurrentScanResponse == true)} devices responded in the current local scan.";
        RoomDetailPage.ShowRoom(room, assignedRows,
            $"{assignedCount} {(assignedCount == 1 ? "device" : "devices")} assigned", responses, assignedCount == 0);
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

    private void PeopleSearchBox_TextChanged(object sender, TextChangedEventArgs e) =>
        UpdatePeopleRoomsPages();

    private void RoomsSearchBox_TextChanged(object sender, TextChangedEventArgs e) =>
        UpdatePeopleRoomsPages();

    private void AddPersonButton_Click(object sender, RoutedEventArgs e) =>
        _ = ShowPersonEditorAsync(null);

    private void AddRoomButton_Click(object sender, RoutedEventArgs e) =>
        _ = ShowRoomEditorAsync(null);

    private void PersonRequested(object? sender, ManagedPerson person)
    {
        _selectedPerson = person;
        UpdatePersonDetails();
        ShowPage(PersonDetailPage);
    }

    private void RoomRequested(object? sender, ManagedRoom room)
    {
        _selectedRoom = room;
        UpdateRoomDetails();
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
        if (_selectedPerson is { } person)
        {
            await ShowPersonEditorAsync(person);
        }
    }

    private async void EditRoomButton_Click(object sender, RoutedEventArgs e)
    {
        if (_selectedRoom is { } room)
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

        var nameBox = new TextBox { Header = "Full name", Text = existing?.Name ?? string.Empty };
        var shortNameBox = new TextBox { Header = "Short name", Text = existing?.ShortName ?? string.Empty, MaxLength = 12 };
        var notesBox = new TextBox
        {
            Header = "Notes (optional)",
            Text = existing?.Notes ?? string.Empty,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 72
        };
        var validation = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var iconPicker = PeopleRoomsIconPicker.Create(PeopleRoomsIcons.People, existing?.IconId);
        var manuallyEditedShortName = existing is not null;
        var applyingSuggestion = false;
        var dialog = CreateEditorDialog(existing is null ? "Add person" : "Edit person",
            nameBox, shortNameBox, notesBox, iconPicker, validation);
        ManagedPerson? saved = null;

        void Validate()
        {
            var message = string.IsNullOrWhiteSpace(nameBox.Text) ? "A full name is required." : null;
            message ??= PeopleRoomsData.ValidateShortName(shortNameBox.Text);
            if (message is null && _peopleRooms.People.Any(person =>
                    person.Id != existing?.Id
                    && string.Equals(person.ShortName.Trim(), shortNameBox.Text.Trim(), StringComparison.OrdinalIgnoreCase)))
            {
                message = "That short name is already used by another person.";
            }

            validation.Text = message ?? string.Empty;
            dialog.IsPrimaryButtonEnabled = message is null;
        }

        nameBox.TextChanging += (_, _) =>
        {
            if (!manuallyEditedShortName && existing is null)
            {
                applyingSuggestion = true;
                shortNameBox.Text = SuggestShortName(nameBox.Text);
                applyingSuggestion = false;
            }

            Validate();
        };
        shortNameBox.TextChanging += (_, _) =>
        {
            if (!applyingSuggestion)
            {
                manuallyEditedShortName = true;
            }

            Validate();
        };
        Validate();
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            try
            {
                Validate();
                if (!dialog.IsPrimaryButtonEnabled)
                {
                    args.Cancel = true;
                    return;
                }

                var candidate = new ManagedPerson(
                    existing?.Id ?? Guid.NewGuid(), nameBox.Text.Trim(), shortNameBox.Text.Trim(),
                    string.IsNullOrWhiteSpace(notesBox.Text) ? null : notesBox.Text.Trim(),
                    iconPicker.SelectedValue as string ?? throw new ArgumentException("Choose a person icon."));
                if (await SavePeopleRoomsAsync(current => new PeopleRoomsData(
                        current.People.Where(person => person.Id != existing?.Id).Append(candidate).ToArray(),
                        current.Rooms,
                        current.Assignments)))
                {
                    saved = candidate;
                }
                else
                {
                    validation.Text = "The person could not be saved.";
                    args.Cancel = true;
                }
            }
            catch (ArgumentException exception)
            {
                validation.Text = exception.Message;
                args.Cancel = true;
            }
            finally
            {
                deferral.Complete();
            }
        };

        await dialog.ShowAsync();
        if (saved is not null && _selectedPerson?.Id == saved.Id)
        {
            _selectedPerson = saved;
            UpdatePersonDetails();
        }

        return saved;
    }

    private async Task<ManagedRoom?> ShowRoomEditorAsync(ManagedRoom? existing)
    {
        if (!_peopleRoomsReady || _peopleRoomsUnavailable)
        {
            return null;
        }

        var nameBox = new TextBox { Header = "Full name", Text = existing?.Name ?? string.Empty };
        var shortNameBox = new TextBox
        {
            Header = "Short name",
            Text = existing?.ShortName ?? string.Empty,
            MaxLength = 12,
            FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Segoe UI Emoji")
        };
        var notesBox = new TextBox
        {
            Header = "Notes (optional)",
            Text = existing?.Notes ?? string.Empty,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            MinHeight = 72
        };
        var validation = new TextBlock { TextWrapping = TextWrapping.Wrap };
        var iconPicker = PeopleRoomsIconPicker.Create(PeopleRoomsIcons.Rooms, existing?.IconId);
        var manuallyEditedShortName = existing is not null;
        var applyingSuggestion = false;
        var dialog = CreateEditorDialog(existing is null ? "Add room" : "Edit room",
            nameBox, shortNameBox, notesBox, iconPicker, validation);
        ManagedRoom? saved = null;

        void Validate()
        {
            var message = string.IsNullOrWhiteSpace(nameBox.Text) ? "A full name is required." : null;
            message ??= PeopleRoomsData.ValidateShortName(shortNameBox.Text);
            if (message is null && _peopleRooms.Rooms.Any(room =>
                    room.Id != existing?.Id
                    && string.Equals(room.ShortName.Trim(), shortNameBox.Text.Trim(), StringComparison.OrdinalIgnoreCase)))
            {
                message = "That short name is already used by another room.";
            }

            validation.Text = message ?? string.Empty;
            dialog.IsPrimaryButtonEnabled = message is null;
        }

        nameBox.TextChanging += (_, _) =>
        {
            if (!manuallyEditedShortName && existing is null)
            {
                applyingSuggestion = true;
                shortNameBox.Text = SuggestShortName(nameBox.Text);
                applyingSuggestion = false;
            }

            Validate();
        };
        shortNameBox.TextChanging += (_, _) =>
        {
            if (!applyingSuggestion)
            {
                manuallyEditedShortName = true;
            }

            Validate();
        };
        Validate();
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            try
            {
                Validate();
                if (!dialog.IsPrimaryButtonEnabled)
                {
                    args.Cancel = true;
                    return;
                }

                var candidate = new ManagedRoom(
                    existing?.Id ?? Guid.NewGuid(), nameBox.Text.Trim(), shortNameBox.Text.Trim(),
                    string.IsNullOrWhiteSpace(notesBox.Text) ? null : notesBox.Text.Trim(),
                    iconPicker.SelectedValue as string ?? throw new ArgumentException("Choose a room icon."));
                if (await SavePeopleRoomsAsync(current => new PeopleRoomsData(
                        current.People,
                        current.Rooms.Where(room => room.Id != existing?.Id).Append(candidate).ToArray(),
                        current.Assignments)))
                {
                    saved = candidate;
                }
                else
                {
                    validation.Text = "The room could not be saved.";
                    args.Cancel = true;
                }
            }
            catch (ArgumentException exception)
            {
                validation.Text = exception.Message;
                args.Cancel = true;
            }
            finally
            {
                deferral.Complete();
            }
        };

        await dialog.ShowAsync();
        if (saved is not null && _selectedRoom?.Id == saved.Id)
        {
            _selectedRoom = saved;
            UpdateRoomDetails();
        }

        return saved;
    }

    private ContentDialog CreateEditorDialog(
        string title,
        TextBox nameBox,
        TextBox shortNameBox,
        TextBox notesBox,
        ComboBox iconPicker,
        TextBlock validation)
    {
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(nameBox, "Full name");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(shortNameBox, "Short name");
        var content = new StackPanel { Spacing = 10, MinWidth = 320 };
        content.Children.Add(nameBox);
        content.Children.Add(shortNameBox);
        content.Children.Add(iconPicker);
        content.Children.Add(notesBox);
        content.Children.Add(validation);
        return new ContentDialog
        {
            XamlRoot = RootGrid.XamlRoot,
            Title = title,
            Content = content,
            PrimaryButtonText = "Save",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary
        };
    }

    private static string SuggestShortName(string name)
    {
        var initials = name.Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Select(word => StringInfo.GetNextTextElement(word))
            .Take(2)
            .Select(initial => initial.ToUpperInvariant());
        return string.Concat(initials);
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
            await PersistDeviceDataAsync(CurrentDeviceData with { PeopleRooms = updated });
            _peopleRooms = updated;
            foreach (var row in _allResults)
            {
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
        if (_selectedPerson is { } person)
        {
            await DeletePersonAsync(person);
        }
    }

    private async Task DeletePersonAsync(ManagedPerson person)
    {
        if (!_peopleRoomsReady || _peopleRoomsUnavailable || !await ConfirmDeleteAsync(person.Name, "person"))
        {
            return;
        }

        if (await SavePeopleRoomsAsync(data => data.DeletePerson(person.Id)))
        {
            _selectedPerson = null;
            ShowPage(PeoplePage);
        }
    }

    private async void DeleteRoomButton_Click(object sender, RoutedEventArgs e)
    {
        if (_selectedRoom is { } room)
        {
            await DeleteRoomAsync(room);
        }
    }

    private async Task DeleteRoomAsync(ManagedRoom room)
    {
        if (!_peopleRoomsReady || _peopleRoomsUnavailable || !await ConfirmDeleteAsync(room.Name, "room"))
        {
            return;
        }

        if (await SavePeopleRoomsAsync(data => data.DeleteRoom(room.Id)))
        {
            _selectedRoom = null;
            ShowPage(RoomsPage);
        }
    }

    private async Task<bool> ConfirmDeleteAsync(string name, string category)
    {
        var dialog = new ContentDialog
        {
            XamlRoot = RootGrid.XamlRoot,
            Title = $"Delete {category}?",
            Content = $"Delete {name}? Device assignments will be cleared; devices and scan history will remain.",
            PrimaryButtonText = "Delete",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
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
            .DistinctBy(row => row.MacAddress!.ToString())
            .OrderBy(row => row.NameText, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        if (available.Length == 0)
        {
            SetDetailStatus(personCategory, "No devices with a discovered MAC address are available to assign.");
            return;
        }

        var picker = new ComboBox { MinWidth = 300 };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(picker, "Choose a device");
        foreach (var row in available)
        {
            var item = new ComboBoxItem { Content = $"{row.NameText} · {row.AddressText} · {row.StatusLabel}", Tag = row };
            picker.Items.Add(item);
        }

        picker.SelectedIndex = 0;
        var content = new StackPanel { Spacing = 8 };
        content.Children.Add(picker);
        content.Children.Add(new TextBlock
        {
            Text = "Devices are associated by MAC address. A private or randomized MAC may change.",
            TextWrapping = TextWrapping.Wrap
        });
        var dialog = new ContentDialog
        {
            XamlRoot = RootGrid.XamlRoot,
            Title = "Assign device",
            Content = content,
            PrimaryButtonText = "Assign",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary
            || (picker.SelectedItem as ComboBoxItem)?.Tag is not ScanResultRow selected
            || selected.MacAddress is not { } macAddress)
        {
            return;
        }

        var personId = _selectedPerson?.Id;
        var roomId = _selectedRoom?.Id;
        var saved = await SavePeopleRoomsAsync(data => personCategory
            ? data.AssignPerson(macAddress.ToString(), personId)
            : data.AssignRoom(macAddress.ToString(), roomId));
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
        if (!_peopleRoomsReady || _peopleRoomsUnavailable || _selectedPerson is null)
        {
            return;
        }

        try
        {
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
        if (!_peopleRoomsReady || _peopleRoomsUnavailable || _selectedRoom is null)
        {
            return;
        }

        try
        {
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
            if (person is not null && _selectedDeviceRow?.MacAddress is { } mac)
            {
                await SavePeopleRoomsAsync(data => data.AssignPerson(mac.ToString(), person.Id));
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
            if (room is not null && _selectedDeviceRow?.MacAddress is { } mac)
            {
                await SavePeopleRoomsAsync(data => data.AssignRoom(mac.ToString(), room.Id));
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
            if (await SavePeopleRoomsAsync(data => data.AssignPerson(mac.ToString(), personId)))
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
            if (await SavePeopleRoomsAsync(data => data.AssignRoom(mac.ToString(), roomId)))
            {
                DevicePage.AssignmentStatus = "Room assignment saved.";
            }
        }
        catch (Exception exception) when (exception is ArgumentException or FormatException)
        {
            DevicePage.AssignmentStatus = "The room assignment could not be saved.";
        }
    }
}
