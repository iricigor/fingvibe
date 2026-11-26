using System.Text.Json;
using System.Text;
using FingVibe.App;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class PeopleRoomsIconsTests
{
    [Fact]
    public void Palettes_PreserveExistingIdsAndGlyphsAlongsideEmojiPortraits()
    {
        Assert.Equal(new[] { "person", "profile", "person-filled" }, PeopleRoomsIcons.People.Take(3).Select(item => item.Id));
        Assert.Equal(new[] { "room", "home", "bedroom", "kitchen", "living-room", "office", "garage", "garden" },
            PeopleRoomsIcons.Rooms.Take(8).Select(item => item.Id));
        foreach (var palette in new[] { PeopleRoomsIcons.People, PeopleRoomsIcons.Rooms })
        {
            Assert.Equal(palette.Count, palette.Select(item => item.Id).Distinct().Count());
            Assert.Equal(palette.Count, palette.Select(item => (item.IsFontAwesome, item.Glyph)).Distinct().Count());
            foreach (var choice in palette)
            {
                Assert.False(string.IsNullOrWhiteSpace(choice.Label));
                if (!choice.IsEmoji)
                {
                    Assert.Single(choice.Glyph);
                    Assert.InRange(choice.Glyph[0], '\uE000', '\uF8FF');
                }
                Assert.Same(choice, PeopleRoomsIcons.Resolve(palette, choice.Id));
            }
        }
        Assert.Equal("\uEA8C", PeopleRoomsIcons.Resolve(PeopleRoomsIcons.People, "person-filled").Glyph);
        Assert.Equal("\uEC32", PeopleRoomsIcons.Resolve(PeopleRoomsIcons.Rooms, "kitchen").Glyph);
        Assert.Equal("\uE7F4", PeopleRoomsIcons.Resolve(PeopleRoomsIcons.Rooms, "living-room").Glyph);
    }

    [Fact]
    public void RoomCatalog_SearchesSuggestedRoomsAndAliasesWithoutChangingTheSelectedChoice()
    {
        var bedroom = Assert.Single(PeopleRoomsIcons.Filter(PeopleRoomsIcons.Rooms, "master bedroom", "All"));
        Assert.Equal("fa-solid:bed", bedroom.Id);
        Assert.Equal("Bed, suggested room: Master bedroom", bedroom.AccessibleName);
        Assert.Equal("fa-solid:jug-detergent",
            Assert.Single(PeopleRoomsIcons.Filter(PeopleRoomsIcons.Rooms, "LAUNDRY", "Utility")).Id);
        Assert.Contains(PeopleRoomsIcons.Filter(PeopleRoomsIcons.Rooms, "lounge", "All"), item => item.Id == "fa-solid:couch");
        Assert.Empty(PeopleRoomsIcons.Filter(PeopleRoomsIcons.Rooms, "master bedroom", "Kitchen"));
        Assert.Empty(PeopleRoomsIcons.Filter(PeopleRoomsIcons.Rooms, "no-such-room-icon", "All"));
        Assert.Equal(8, PeopleRoomsIcons.Filter(PeopleRoomsIcons.Rooms, null, "Existing icons").Count);
        Assert.Same(bedroom, PeopleRoomsIcons.Resolve(PeopleRoomsIcons.Rooms, bedroom.Id));
        Assert.All(RoomIconCatalog.Choices, choice =>
        {
            Assert.StartsWith("fa-solid:", choice.Id);
            Assert.True(choice.IsFontAwesome);
            Assert.False(choice.IsEmoji);
            Assert.False(string.IsNullOrWhiteSpace(choice.SuggestedRoom));
            Assert.Contains(choice.Category, RoomIconCatalog.Categories);
        });
        Assert.DoesNotContain(RoomIconCatalog.Choices, choice => choice.Id is "fa-solid:user-group" or "fa-solid:bed-front");
    }

    [Fact]
    public void RoomAssignments_NotifyIconChangesAndClearUnassignedArtwork()
    {
        var row = new ScanResultRow(result: null, prefixLength: 24);
        var changed = new List<string?>();
        row.PropertyChanged += (_, e) => changed.Add(e.PropertyName);
        var roomId = Guid.NewGuid();
        row.SetPeopleRoomAssignments(null, null, null, roomId, "III", "Custom room name", roomIconId: "fa-solid:bed");
        Assert.Equal("fa-solid:bed", row.RoomIconId);
        Assert.Equal("III", row.RoomShortName);
        Assert.Equal("Custom room name", row.RoomFullName);
        Assert.Contains(nameof(ScanResultRow.RoomIconId), changed);
        row.SetPeopleRoomAssignments(null, null, null, null, "III", "Stale room", roomIconId: "fa-solid:bed");
        Assert.Null(row.RoomIconId);
        Assert.False(row.HasRoomAssignment);
        Assert.Equal("-", row.RoomShortName);
    }

    [Fact]
    public void PortraitVariants_FilterWithoutMutatingChoicesOrTheSelectedId()
    {
        var all = PeopleRoomsIcons.People;
        var primary = Assert.Single(PersonEmojiCatalog.Filter(all, "manager", "Professions", false));
        var variants = PersonEmojiCatalog.Filter(all, "manager", "Professions", true);
        Assert.Equal(4, variants.Count);
        Assert.Equal(new[] { "Man 1", "Man 2", "Woman 1", "Woman 2" }, variants.Select(item => item.Variant));
        Assert.Same(primary, variants[0]);
        var selected = variants[3].Id;
        Assert.DoesNotContain(PersonEmojiCatalog.Filter(all, "manager", "Professions", false), item => item.Id == selected);
        Assert.Equal(selected, Assert.Single(PersonEmojiCatalog.Filter(all, "MANAGER woman 2", "All", true)).Id);
        Assert.Equal(selected, Assert.Single(PersonEmojiCatalog.Filter(all, "  manager\twoman\n2  ", "All", true)).Id);
        Assert.Empty(PersonEmojiCatalog.Filter(all, "manager", "Hair", true));
        Assert.Empty(PersonEmojiCatalog.Filter(all, "not-a-person-icon", "All", true));
        Assert.Equal(3, PersonEmojiCatalog.Filter(all, null, "Existing icons", false).Count);
        Assert.Same(variants[3], PeopleRoomsIcons.Resolve(all, selected));
    }

    [Fact]
    public void PortraitCatalog_CoversPortraitCategoriesAndOnlyTheTwoApprovedTones()
    {
        foreach (var category in new[] { "People", "Hair", "Professions", "Fantasy" })
            Assert.Contains(PersonEmojiCatalog.Choices, item => item.Category == category);
        foreach (var choice in PersonEmojiCatalog.Choices)
        {
            var runes = choice.Glyph.EnumerateRunes().Select(rune => rune.Value).ToArray();
            Assert.StartsWith("emoji:", choice.Id);
            Assert.True(choice.IsEmoji);
            Assert.Single(runes, rune => rune is >= 0x1F3FB and <= 0x1F3FF);
            Assert.Contains(runes, rune => rune is 0x1F3FB or 0x1F3FC);
            Assert.DoesNotContain(runes, rune => rune is >= 0x1F3FD and <= 0x1F3FF);
            Assert.Equal("emoji:" + string.Join("-", runes.Select(rune => rune.ToString("x"))), choice.Id);
        }
        Assert.Contains(PersonEmojiCatalog.Choices, choice => choice.Label == "Bearded woman");
        Assert.Contains(PersonEmojiCatalog.Choices, choice => choice.Label == "White hair person");
        Assert.Contains(PersonEmojiCatalog.Choices, choice => choice.Label == "Astronaut");
        Assert.Contains(PersonEmojiCatalog.Choices, choice => choice.Label == "Supervillain");
    }

    [Fact]
    public void DeviceAssignments_NotifyEmojiChangesAndPreserveCompleteShortNames()
    {
        var row = new ScanResultRow(result: null, prefixLength: 24);
        var changed = new List<string?>();
        row.PropertyChanged += (_, e) => changed.Add(e.PropertyName);
        var id = PersonEmojiCatalog.Choices.First(choice => choice.Label == "Manager" && choice.Variant == "Woman 2").Id;
        var person = Guid.NewGuid();
        row.SetPeopleRoomAssignments(person, "III", "Example person", null, null, null, id);
        Assert.Equal(id, row.PersonIconId);
        Assert.Equal("III", row.PersonShortName);
        Assert.Equal("Example person", row.PersonFullName);
        Assert.Contains(nameof(ScanResultRow.PersonIconId), changed);
        row.SetPeopleRoomAssignments(null, null, null, null, null, null, id);
        Assert.Null(row.PersonIconId);
        Assert.False(row.HasPersonAssignment);
    }

    [Fact]
    public void OlderWindows_ExcludesNewerSequencesWithoutChangingTheirSavedIds()
    {
        var newer = PersonEmojiCatalog.Choices.First(choice => choice.Label == "Person with a crown");
        Assert.False(PersonEmojiCatalog.IsAvailable(newer, 19041));
        Assert.False(PersonEmojiCatalog.IsAvailable(newer, 22000));
        Assert.True(PersonEmojiCatalog.IsAvailable(newer, 22621));
        var beard = PersonEmojiCatalog.Choices.First(choice => choice.Label == "Bearded woman");
        Assert.False(PersonEmojiCatalog.IsAvailable(beard, 19041));
        Assert.True(PersonEmojiCatalog.IsAvailable(beard, 22000));
        Assert.Same(newer, PeopleRoomsIcons.Resolve(PeopleRoomsIcons.People, newer.Id));
        Assert.Contains(PersonEmojiCatalog.Choices, choice =>
            choice.Label == "Manager" && PersonEmojiCatalog.IsAvailable(choice, 17763));
    }

    [Fact]
    public void Rows_UseSelectedIconsWithoutChangingNamesOrActionLabels()
    {
        var person = new ManagedPerson(Guid.NewGuid(), "Alex", "AL", IconId: "profile");
        var room = new ManagedRoom(Guid.NewGuid(), "Office", "OF", IconId: "office");
        var personRow = new ManagedPersonListRow(person, "2 devices", "1 responded");
        var roomRow = new ManagedRoomListRow(room, "2 devices", "1 responded");
        Assert.Equal(PeopleRoomsIcons.Resolve(PeopleRoomsIcons.People, "profile").Glyph, personRow.IconGlyph);
        Assert.Equal(PeopleRoomsIcons.Resolve(PeopleRoomsIcons.Rooms, "office").Glyph, roomRow.IconGlyph);
        Assert.Equal(person, personRow.Person);
        Assert.Equal(room, roomRow.Room);
        Assert.Equal("Actions for Alex", personRow.ActionsLabel);
        Assert.Equal("Actions for Office", roomRow.ActionsLabel);
    }

    [Fact]
    public void MissingAndUnavailableIds_UseGenericIconsWithoutDiscardingSavedIds()
    {
        Assert.Same(PeopleRoomsIcons.People[0], PeopleRoomsIcons.Resolve(PeopleRoomsIcons.People, null));
        Assert.Same(PeopleRoomsIcons.Rooms[0], PeopleRoomsIcons.Resolve(PeopleRoomsIcons.Rooms, null));
        var person = new ManagedPerson(Guid.NewGuid(), "Alex", "AL", IconId: "future-icon");
        var row = new ManagedPersonListRow(person, "0 devices", "No scan");
        Assert.Equal(PeopleRoomsIcons.People[0].Glyph, row.IconGlyph);
        Assert.Equal("future-icon", row.Person.IconId);
        Assert.Throws<ArgumentException>(() => PeopleRoomsIcons.Resolve([], null));
    }

    [Theory]
    [InlineData(false, "person-filled", "garden")]
    [InlineData(true, "person-filled", "garden")]
    [InlineData(false, "future-person", "future-room")]
    [InlineData(true, "future-person", "future-room")]
    [InlineData(true, "emoji:1f469-1f3fc-200d-1f4bc", "garden")]
    [InlineData(true, null, null)]
    [InlineData(true, "person", "fa-solid:bed")]
    [InlineData(true, "person", "fa-solid:jug-detergent")]
    public async Task Storage_OldEntriesLoadAndChoicesSurviveInventoryUpdates(bool inventory, string? personIcon, string? roomIcon)
    {
        var directory = Path.Combine(Path.GetTempPath(), $"fingvibe-icons-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, inventory ? "device-inventory.json" : "people-rooms.json");
        var personId = Guid.NewGuid();
        var roomId = Guid.NewGuid();
        var entries = $$$$"""
            {"people":[{"id":"{{{{personId}}}}","name":"Alex","shortName":"AL"}],
             "rooms":[{"id":"{{{{roomId}}}}","name":"Office","shortName":"OF"}],
             "assignments":{"AABBCCDDEEFF":{"personId":"{{{{personId}}}}","roomId":"{{{{roomId}}}}"}}}
            """;
        var json = inventory
            ? $$$$"""{"version":1,"data":{"revision":"{{{{Guid.NewGuid()}}}}","devices":{},"names":{},"classifications":{},"peopleRooms":{{{{entries}}}}}}"""
            : entries;
        try
        {
            await File.WriteAllTextAsync(path, json);
            var inventoryStore = new DeviceInventoryStore(path);
            var legacyStore = new PeopleRoomsStore(path);
            var savedInventory = inventory ? await inventoryStore.LoadAsync() : null;
            var old = inventory ? savedInventory!.PeopleRooms : await legacyStore.LoadAsync();
            Assert.Null(Assert.Single(old.People).IconId);
            Assert.Null(Assert.Single(old.Rooms).IconId);
            var changed = new PeopleRoomsData(
                [old.People[0] with { IconId = personIcon }],
                [old.Rooms[0] with { IconId = roomIcon }], old.Assignments);
            if (inventory)
            {
                var saved = await inventoryStore.SaveAsync(savedInventory! with { PeopleRooms = changed }, savedInventory!.Revision);
                await inventoryStore.SaveAsync(saved with { Names = new Dictionary<string, string> { ["AABBCCDDEEFF"] = "Device" } }, saved.Revision);
                var rejected = saved with
                {
                    PeopleRooms = new PeopleRoomsData(
                        [changed.People[0] with { IconId = "person" }], changed.Rooms, changed.Assignments)
                };
                await Assert.ThrowsAsync<InvalidOperationException>(() =>
                    inventoryStore.SaveAsync(rejected, saved.Revision));
            }
            else
            {
                await legacyStore.SaveAsync(changed);
            }

            var loaded = inventory
                ? (await inventoryStore.LoadAsync())!.PeopleRooms
                : await legacyStore.LoadAsync();
            Assert.Equal(changed.People[0], Assert.Single(loaded.People));
            Assert.Equal(changed.Rooms[0], Assert.Single(loaded.Rooms));
            Assert.Equal(new DeviceAssignment(personId, roomId), Assert.Single(loaded.Assignments).Value);
            Assert.Equal(roomIcon, Assert.Single(loaded.DeletePerson(personId).Rooms).IconId);
            Assert.Equal(personIcon, Assert.Single(loaded.DeleteRoom(roomId).People).IconId);
            Assert.Equal(roomIcon, Assert.Single(loaded.AssignPerson("AABBCCDDEEFF", null).Rooms).IconId);
            if (inventory) Assert.Equal(json, await File.ReadAllTextAsync(path));
            using var document = JsonDocument.Parse(inventory
                ? JsonSerializer.Serialize(loaded, new JsonSerializerOptions(JsonSerializerDefaults.Web))
                : await File.ReadAllTextAsync(path));
            var root = document.RootElement;
            Assert.Equal(personIcon, root.GetProperty("people")[0].GetProperty("iconId").GetString());
            Assert.Equal(roomIcon, root.GetProperty("rooms")[0].GetProperty("iconId").GetString());
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }
}
