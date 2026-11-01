using System.Text.Json;
using FingVibe.App;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class PeopleRoomsIconsTests
{
    [Fact]
    public void Palettes_HaveStableUniqueIdsAndNativeMonochromeGlyphs()
    {
        Assert.Equal(new[] { "person", "profile", "person-filled" }, PeopleRoomsIcons.People.Select(item => item.Id));
        Assert.Equal(new[] { "room", "home", "bedroom", "kitchen", "living-room", "office", "garage", "garden" },
            PeopleRoomsIcons.Rooms.Select(item => item.Id));
        foreach (var palette in new[] { PeopleRoomsIcons.People, PeopleRoomsIcons.Rooms })
        {
            Assert.Equal(palette.Count, palette.Select(item => item.Id).Distinct().Count());
            Assert.Equal(palette.Count, palette.Select(item => item.Glyph).Distinct().Count());
            foreach (var choice in palette)
            {
                Assert.False(string.IsNullOrWhiteSpace(choice.Label));
                Assert.Single(choice.Glyph);
                Assert.InRange(choice.Glyph[0], '\uE000', '\uF8FF');
                Assert.Same(choice, PeopleRoomsIcons.Resolve(palette, choice.Id));
            }
        }
        Assert.Equal("\uEA8C", PeopleRoomsIcons.Resolve(PeopleRoomsIcons.People, "person-filled").Glyph);
        Assert.Equal("\uEC32", PeopleRoomsIcons.Resolve(PeopleRoomsIcons.Rooms, "kitchen").Glyph);
        Assert.Equal("\uE7F4", PeopleRoomsIcons.Resolve(PeopleRoomsIcons.Rooms, "living-room").Glyph);
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
    public async Task Storage_OldEntriesLoadAndChoicesSurviveInventoryUpdates(bool inventory, string personIcon, string roomIcon)
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
            using var document = JsonDocument.Parse(await File.ReadAllTextAsync(path));
            var root = inventory ? document.RootElement.GetProperty("data").GetProperty("peopleRooms") : document.RootElement;
            Assert.Equal(personIcon, root.GetProperty("people")[0].GetProperty("iconId").GetString());
            Assert.Equal(roomIcon, root.GetProperty("rooms")[0].GetProperty("iconId").GetString());
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }
}
