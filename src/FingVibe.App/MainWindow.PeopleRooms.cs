using System.Globalization;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using FingVibe.Core.Storage;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace FingVibe.App;

public sealed partial class MainWindow
{
    private readonly PeopleRoomsStore _peopleRoomsStore = new(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "FingVibe",
        "people-rooms.json"));
    private readonly SemaphoreSlim _peopleRoomsSaveLock = new(1, 1);
    private PeopleRoomsData _peopleRooms = new();
    private ManagedPerson? _selectedPerson;
    private ManagedRoom? _selectedRoom;
    private bool _peopleRoomsReady;
    private bool _peopleRoomsUnavailable;
    private bool _updatingDeviceAssignmentPickers;

    private sealed record FilterChoice(string Label, Guid? Id = null, bool All = false, bool Unassigned = false);

    private async Task RestorePeopleRoomsAsync()
    {
        try
        {
            _peopleRooms = IsUiReview
                ? new PeopleRoomsData(
                    [new ManagedPerson(Guid.Parse("db958652-55aa-409f-afca-d60c68081574"), "UI review person", "UI")],
                    [new ManagedRoom(Guid.Parse("db958652-55aa-409f-afca-d60c68081575"), "UI review room", "UI")])
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
        if (row.Result.MacAddress is { } macAddress
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
        if (PeopleList is null)
        {
            return;
        }

        var peopleSearch = PeopleSearchBox.Text.Trim();
        var peopleRows = _peopleRooms.People
            .Where(person => MatchesSearch(person.ShortName, person.Name, peopleSearch))
            .Select(person =>
            {
                var assignedCount = _peopleRooms.Assignments.Count(pair => pair.Value.PersonId == person.Id);
                var respondedCount = GetAssignedDeviceRows(person.Id, null)
                    .Count(row => row.ScanResult?.IsOnline == true);
                return new ManagedPersonListRow(
                    person,
                    $"{assignedCount} {(assignedCount == 1 ? "device" : "devices")}",
                    LastScanResponseCount(respondedCount));
            })
            .ToArray();
        PeopleList.ItemsSource = peopleRows;
        PeopleTableBorder.Visibility = peopleRows.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        PeopleEmptyState.Visibility = peopleRows.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        PeopleEmptyText.Text = _peopleRooms.People.Count == 0 ? "No people yet" : "No people match your search.";
        AddPersonButton.IsEnabled = _peopleRoomsReady && !_peopleRoomsUnavailable;
        EditPersonDetailButton.IsEnabled = _peopleRoomsReady && !_peopleRoomsUnavailable;
        DeletePersonDetailButton.IsEnabled = _peopleRoomsReady && !_peopleRoomsUnavailable;
        AssignPersonDevicesButton.IsEnabled = _peopleRoomsReady && !_peopleRoomsUnavailable;

        var roomsSearch = RoomsSearchBox.Text.Trim();
        var roomRows = _peopleRooms.Rooms
            .Where(room => MatchesSearch(room.ShortName, room.Name, roomsSearch))
            .Select(room =>
            {
                var assignedCount = _peopleRooms.Assignments.Count(pair => pair.Value.RoomId == room.Id);
                var respondedCount = GetAssignedDeviceRows(null, room.Id)
                    .Count(row => row.ScanResult?.IsOnline == true);
                return new ManagedRoomListRow(
                    room,
                    $"{assignedCount} {(assignedCount == 1 ? "device" : "devices")}",
                    LastScanResponseCount(respondedCount));
            })
            .ToArray();
        RoomsList.ItemsSource = roomRows;
        RoomsTableBorder.Visibility = roomRows.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        RoomsEmptyState.Visibility = roomRows.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        RoomsEmptyText.Text = _peopleRooms.Rooms.Count == 0 ? "No rooms yet" : "No rooms match your search.";
        AddRoomButton.IsEnabled = _peopleRoomsReady && !_peopleRoomsUnavailable;
        EditRoomDetailButton.IsEnabled = _peopleRoomsReady && !_peopleRoomsUnavailable;
        DeleteRoomDetailButton.IsEnabled = _peopleRoomsReady && !_peopleRoomsUnavailable;
        AssignRoomDevicesButton.IsEnabled = _peopleRoomsReady && !_peopleRoomsUnavailable;

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
                _allResults.FirstOrDefault(row => row.Result.MacAddress?.ToString() == pair.Key)))
            .ToArray();
    }

    private string LastScanResponseCount(int respondedCount) =>
        _allResults.Count == 0 ? "No scan yet" : $"{respondedCount} responded";

    private void UpdatePersonDetails()
    {
        if (_selectedPerson is not { } person || PersonDetailPage is null)
        {
            return;
        }

        var assignedRows = GetAssignedDeviceRows(person.Id, null);
        var assignedCount = _peopleRooms.Assignments.Count(pair => pair.Value.PersonId == person.Id);
        PersonDetailShortName.Text = person.ShortName;
        PersonDetailName.Text = person.Name;
        PersonDetailNotes.Text = person.Notes ?? string.Empty;
        PersonDeviceCountText.Text = $"{assignedCount} {(assignedCount == 1 ? "device" : "devices")} assigned";
        PersonRespondedCountText.Text = _allResults.Count == 0
            ? "No scan yet."
            : $"{assignedRows.Count(row => row.ScanResult?.IsOnline == true)} devices responded in the last scan.";
        PersonAssignedDevicesList.ItemsSource = assignedRows;
        PersonAssignedDevicesEmptyText.Visibility = assignedCount == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void UpdateRoomDetails()
    {
        if (_selectedRoom is not { } room || RoomDetailPage is null)
        {
            return;
        }

        var assignedRows = GetAssignedDeviceRows(null, room.Id);
        var assignedCount = _peopleRooms.Assignments.Count(pair => pair.Value.RoomId == room.Id);
        RoomDetailShortName.Text = room.ShortName;
        RoomDetailName.Text = room.Name;
        RoomDetailNotes.Text = room.Notes ?? string.Empty;
        RoomDeviceCountText.Text = $"{assignedCount} {(assignedCount == 1 ? "device" : "devices")} assigned";
        RoomRespondedCountText.Text = _allResults.Count == 0
            ? "No scan yet."
            : $"{assignedRows.Count(row => row.ScanResult?.IsOnline == true)} devices responded in the last scan.";
        RoomAssignedDevicesList.ItemsSource = assignedRows;
        RoomAssignedDevicesEmptyText.Visibility = assignedCount == 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void UpdatePeopleRoomFilters()
    {
        if (PersonFilter is null || RoomFilter is null)
        {
            return;
        }

        var selectedPerson = SelectedFilterChoice(PersonFilter);
        var selectedRoom = SelectedFilterChoice(RoomFilter);
        PersonFilter.Items.Clear();
        PersonFilter.Items.Add(CreateFilterItem(new FilterChoice("All people", All: true)));
        PersonFilter.Items.Add(CreateFilterItem(new FilterChoice("Unassigned", Unassigned: true)));
        foreach (var person in _peopleRooms.People.OrderBy(item => item.ShortName, StringComparer.OrdinalIgnoreCase))
        {
            PersonFilter.Items.Add(CreateFilterItem(new FilterChoice($"{person.ShortName} · {person.Name}", person.Id)));
        }

        RoomFilter.Items.Clear();
        RoomFilter.Items.Add(CreateFilterItem(new FilterChoice("All rooms", All: true)));
        RoomFilter.Items.Add(CreateFilterItem(new FilterChoice("Unassigned", Unassigned: true)));
        foreach (var room in _peopleRooms.Rooms.OrderBy(item => item.ShortName, StringComparer.OrdinalIgnoreCase))
        {
            RoomFilter.Items.Add(CreateFilterItem(new FilterChoice($"{room.ShortName} · {room.Name}", room.Id)));
        }

        SelectFilterChoice(PersonFilter, selectedPerson);
        SelectFilterChoice(RoomFilter, selectedRoom);
    }

    private static ComboBoxItem CreateFilterItem(FilterChoice choice) =>
        new() { Content = choice.Label, Tag = choice };

    private static void SelectFilterChoice(ComboBox picker, FilterChoice? selected)
    {
        var item = picker.Items.OfType<ComboBoxItem>().FirstOrDefault(candidate =>
        {
            if (candidate.Tag is not FilterChoice choice)
            {
                return false;
            }

            if (selected?.Unassigned == true)
            {
                return choice.Unassigned;
            }

            if (selected?.Id is { } id)
            {
                return choice.Id == id;
            }

            return choice.All;
        });
        picker.SelectedItem = item ?? picker.Items.OfType<ComboBoxItem>().First();
    }

    private void PeopleRoomFilter_SelectionChanged(object sender, SelectionChangedEventArgs e) =>
        RefreshVisibleResults();

    private void PeopleSearchBox_TextChanged(object sender, TextChangedEventArgs e) =>
        UpdatePeopleRoomsPages();

    private void RoomsSearchBox_TextChanged(object sender, TextChangedEventArgs e) =>
        UpdatePeopleRoomsPages();

    private void AddPersonButton_Click(object sender, RoutedEventArgs e) =>
        _ = ShowPersonEditorAsync(null);

    private void AddRoomButton_Click(object sender, RoutedEventArgs e) =>
        _ = ShowRoomEditorAsync(null);

    private void PeopleList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not ManagedPersonListRow row)
        {
            return;
        }

        _selectedPerson = row.Person;
        UpdatePersonDetails();
        ShowPage(PersonDetailPage);
    }

    private void RoomsList_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is not ManagedRoomListRow row)
        {
            return;
        }

        _selectedRoom = row.Room;
        UpdateRoomDetails();
        ShowPage(RoomDetailPage);
    }

    private void PersonActionsButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: Guid id } button
            || _peopleRooms.People.FirstOrDefault(person => person.Id == id) is not { } person)
        {
            return;
        }

        var menu = new MenuFlyout();
        var edit = new MenuFlyoutItem { Text = "Edit" };
        edit.IsEnabled = _peopleRoomsReady && !_peopleRoomsUnavailable;
        edit.Click += (_, _) => _ = ShowPersonEditorAsync(person);
        var delete = new MenuFlyoutItem { Text = "Delete" };
        delete.IsEnabled = _peopleRoomsReady && !_peopleRoomsUnavailable;
        delete.Click += async (_, _) => await DeletePersonAsync(person);
        menu.Items.Add(edit);
        menu.Items.Add(delete);
        menu.ShowAt(button);
    }

    private void RoomActionsButton_Click(object sender, RoutedEventArgs e)
    {
        if (sender is not Button { Tag: Guid id } button
            || _peopleRooms.Rooms.FirstOrDefault(room => room.Id == id) is not { } room)
        {
            return;
        }

        var menu = new MenuFlyout();
        var edit = new MenuFlyoutItem { Text = "Edit" };
        edit.IsEnabled = _peopleRoomsReady && !_peopleRoomsUnavailable;
        edit.Click += (_, _) => _ = ShowRoomEditorAsync(room);
        var delete = new MenuFlyoutItem { Text = "Delete" };
        delete.IsEnabled = _peopleRoomsReady && !_peopleRoomsUnavailable;
        delete.Click += async (_, _) => await DeleteRoomAsync(room);
        menu.Items.Add(edit);
        menu.Items.Add(delete);
        menu.ShowAt(button);
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
        var manuallyEditedShortName = existing is not null;
        var applyingSuggestion = false;
        var dialog = CreateEditorDialog(existing is null ? "Add person" : "Edit person",
            nameBox, shortNameBox, notesBox, validation);
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

        nameBox.TextChanged += (_, _) =>
        {
            if (!manuallyEditedShortName && existing is null)
            {
                applyingSuggestion = true;
                shortNameBox.Text = SuggestShortName(nameBox.Text);
                applyingSuggestion = false;
            }

            Validate();
        };
        shortNameBox.TextChanged += (_, _) =>
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
                    string.IsNullOrWhiteSpace(notesBox.Text) ? null : notesBox.Text.Trim());
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
        var manuallyEditedShortName = existing is not null;
        var applyingSuggestion = false;
        var dialog = CreateEditorDialog(existing is null ? "Add room" : "Edit room",
            nameBox, shortNameBox, notesBox, validation);
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

        nameBox.TextChanged += (_, _) =>
        {
            if (!manuallyEditedShortName && existing is null)
            {
                applyingSuggestion = true;
                shortNameBox.Text = SuggestShortName(nameBox.Text);
                applyingSuggestion = false;
            }

            Validate();
        };
        shortNameBox.TextChanged += (_, _) =>
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
                    string.IsNullOrWhiteSpace(notesBox.Text) ? null : notesBox.Text.Trim());
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
        TextBlock validation)
    {
        var content = new StackPanel { Spacing = 10, MinWidth = 320 };
        content.Children.Add(nameBox);
        content.Children.Add(shortNameBox);
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
            .Take(3)
            .Select(initial => initial.ToUpperInvariant());
        return string.Concat(initials);
    }

    private async Task<bool> SavePeopleRoomsAsync(Func<PeopleRoomsData, PeopleRoomsData> update)
    {
        if (!_peopleRoomsReady || _peopleRoomsUnavailable)
        {
            return false;
        }

        await _peopleRoomsSaveLock.WaitAsync();
        try
        {
            var updated = update(_peopleRooms);
            if (!IsUiReview)
            {
                await _peopleRoomsStore.SaveAsync(updated);
            }
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
                                          or InvalidDataException or ArgumentException or FormatException)
        {
            SetPeopleRoomsStatus("People and rooms could not be saved. Your previous saved data is unchanged.");
            return false;
        }
        finally
        {
            _peopleRoomsSaveLock.Release();
        }
    }

    private void SetPeopleRoomsStatus(string message)
    {
        if (PeopleStatusText is not null)
        {
            PeopleStatusText.Text = message;
        }

        if (RoomsStatusText is not null)
        {
            RoomsStatusText.Text = message;
        }

        if (DeviceAssignmentStatusText is not null)
        {
            DeviceAssignmentStatusText.Text = message;
        }

        if (PersonDetailStatusText is not null)
        {
            PersonDetailStatusText.Text = message;
        }

        if (RoomDetailStatusText is not null)
        {
            RoomDetailStatusText.Text = message;
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

        var available = _allResults.Where(row => row.Result.MacAddress?.GetAddressBytes().Length == 6)
            .DistinctBy(row => row.Result.MacAddress!.ToString())
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
            var item = new ComboBoxItem { Content = $"{row.NameText} · {row.Result.AddressText}", Tag = row };
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
            || selected.Result.MacAddress is not { } macAddress)
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
            PersonDetailStatusText.Text = message;
        }
        else
        {
            RoomDetailStatusText.Text = message;
        }
    }

    private async void UnassignPersonDeviceButton_Click(object sender, RoutedEventArgs e)
    {
        if (!_peopleRoomsReady || _peopleRoomsUnavailable || _selectedPerson is not { } person
            || sender is not Button { Tag: string macAddress })
        {
            return;
        }

        try
        {
            if (await SavePeopleRoomsAsync(data => data.AssignPerson(macAddress, null)))
            {
                PersonDetailStatusText.Text = "Device unassigned.";
            }
        }
        catch (FormatException)
        {
            PersonDetailStatusText.Text = "The device MAC address is invalid.";
        }
    }

    private async void UnassignRoomDeviceButton_Click(object sender, RoutedEventArgs e)
    {
        if (!_peopleRoomsReady || _peopleRoomsUnavailable || _selectedRoom is not { } room
            || sender is not Button { Tag: string macAddress })
        {
            return;
        }

        try
        {
            if (await SavePeopleRoomsAsync(data => data.AssignRoom(macAddress, null)))
            {
                RoomDetailStatusText.Text = "Device unassigned.";
            }
        }
        catch (FormatException)
        {
            RoomDetailStatusText.Text = "The device MAC address is invalid.";
        }
    }

    private void AssignedPersonDevice_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is AssignedDeviceListRow { ScanResult: { } row })
        {
            ShowDeviceDetails(row);
        }
    }

    private void AssignedRoomDevice_ItemClick(object sender, ItemClickEventArgs e)
    {
        if (e.ClickedItem is AssignedDeviceListRow { ScanResult: { } row })
        {
            ShowDeviceDetails(row);
        }
    }

    private void BackToPeopleButton_Click(object sender, RoutedEventArgs e) => ShowPage(PeoplePage);

    private void BackToRoomsButton_Click(object sender, RoutedEventArgs e) => ShowPage(RoomsPage);

    private void UpdateDeviceAssignmentPickers()
    {
        if (DevicePersonPicker is null || _selectedDeviceRow is null)
        {
            return;
        }

        _updatingDeviceAssignmentPickers = true;
        PopulateAssignmentPicker(DevicePersonPicker, "Add person…", _peopleRooms.People
            .Select(person => (person.Id, $"{person.ShortName} · {person.Name}")));
        PopulateAssignmentPicker(DeviceRoomPicker, "Add room…", _peopleRooms.Rooms
            .Select(room => (room.Id, $"{room.ShortName} · {room.Name}")));

        var macAddress = _selectedDeviceRow.Result.MacAddress;
        var canAssign = macAddress?.GetAddressBytes().Length == 6
            && _peopleRoomsReady && !_peopleRoomsUnavailable;
        DevicePersonPicker.IsEnabled = canAssign;
        DeviceRoomPicker.IsEnabled = canAssign;
        SelectAssignment(DevicePersonPicker, _selectedDeviceRow.PersonId);
        SelectAssignment(DeviceRoomPicker, _selectedDeviceRow.RoomId);
        DeviceAssignmentStatusText.Text = !_peopleRoomsReady
            ? "People and rooms are still loading; assignments are unavailable."
            : _peopleRoomsUnavailable
            ? "Saved people and rooms could not be loaded; assignments are disabled."
            : macAddress is null
                ? "A discovered MAC address is required to save assignments; IP addresses can change."
                : macAddress.GetAddressBytes().Length != 6
                    ? "A valid six-byte MAC address is required to save assignments."
                : MacAddressResolver.IsPrivateOrRandomized(macAddress)
                    ? "This private/randomized MAC may change; its assignments will not transfer to another MAC."
                    : "Assignments are saved by MAC address and do not depend on scan snapshots.";
        _updatingDeviceAssignmentPickers = false;
    }

    private static void PopulateAssignmentPicker(
        ComboBox picker,
        string addLabel,
        IEnumerable<(Guid Id, string Label)> values)
    {
        picker.Items.Clear();
        picker.Items.Add(new ComboBoxItem { Content = "Unassigned", Tag = "unassigned" });
        foreach (var (id, label) in values.OrderBy(item => item.Label, StringComparer.OrdinalIgnoreCase))
        {
            picker.Items.Add(new ComboBoxItem { Content = label, Tag = id });
        }

        picker.Items.Add(new ComboBoxItem { Content = addLabel, Tag = "add" });
    }

    private static void SelectAssignment(ComboBox picker, Guid? id)
    {
        picker.SelectedItem = picker.Items.OfType<ComboBoxItem>()
            .FirstOrDefault(item => id is null ? Equals(item.Tag, "unassigned") : Equals(item.Tag, id));
    }

    private async void DevicePersonPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingDeviceAssignmentPickers || sender is not ComboBox picker
            || picker.SelectedItem is not ComboBoxItem { Tag: var tag })
        {
            return;
        }

        if (tag is "add")
        {
            UpdateDeviceAssignmentPickers();
            var person = await ShowPersonEditorAsync(null);
            if (person is not null && _selectedDeviceRow?.Result.MacAddress is { } mac)
            {
                await SavePeopleRoomsAsync(data => data.AssignPerson(mac.ToString(), person.Id));
            }

            return;
        }

        await SaveDevicePersonAssignmentAsync(tag is Guid id ? id : null);
    }

    private async void DeviceRoomPicker_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_updatingDeviceAssignmentPickers || sender is not ComboBox picker
            || picker.SelectedItem is not ComboBoxItem { Tag: var tag })
        {
            return;
        }

        if (tag is "add")
        {
            UpdateDeviceAssignmentPickers();
            var room = await ShowRoomEditorAsync(null);
            if (room is not null && _selectedDeviceRow?.Result.MacAddress is { } mac)
            {
                await SavePeopleRoomsAsync(data => data.AssignRoom(mac.ToString(), room.Id));
            }

            return;
        }

        await SaveDeviceRoomAssignmentAsync(tag is Guid id ? id : null);
    }

    private async Task SaveDevicePersonAssignmentAsync(Guid? personId)
    {
        if (!_peopleRoomsReady || _peopleRoomsUnavailable || _selectedDeviceRow?.Result.MacAddress is not { } mac
            || mac.GetAddressBytes().Length != 6)
        {
            return;
        }

        try
        {
            if (await SavePeopleRoomsAsync(data => data.AssignPerson(mac.ToString(), personId)))
            {
                DeviceAssignmentStatusText.Text = "Person assignment saved.";
            }
        }
        catch (Exception exception) when (exception is ArgumentException or FormatException)
        {
            DeviceAssignmentStatusText.Text = "The person assignment could not be saved.";
        }
    }

    private async Task SaveDeviceRoomAssignmentAsync(Guid? roomId)
    {
        if (!_peopleRoomsReady || _peopleRoomsUnavailable || _selectedDeviceRow?.Result.MacAddress is not { } mac
            || mac.GetAddressBytes().Length != 6)
        {
            return;
        }

        try
        {
            if (await SavePeopleRoomsAsync(data => data.AssignRoom(mac.ToString(), roomId)))
            {
                DeviceAssignmentStatusText.Text = "Room assignment saved.";
            }
        }
        catch (Exception exception) when (exception is ArgumentException or FormatException)
        {
            DeviceAssignmentStatusText.Text = "The room assignment could not be saved.";
        }
    }
}
