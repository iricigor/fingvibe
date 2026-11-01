using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class PeopleRoomsStoreTests
{
    [Theory]
    [InlineData("LR")]
    [InlineData("\u0030\uFE0F\u20E3")]
    public async Task SaveAndLoadAsync_PreservesPeopleRoomsAndMacAssignments(string roomShortName)
    {
        var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        var store = new PeopleRoomsStore(Path.Combine(directory, "people-rooms.json"));
        var person = new ManagedPerson(Guid.NewGuid(), "Alex", "AL", IconId: "profile");
        var room = new ManagedRoom(Guid.NewGuid(), "Living room", roomShortName, IconId: "living-room");
        var data = new PeopleRoomsData([person], [room])
            .AssignPerson("aa:bb:cc:dd:ee:ff", person.Id)
            .AssignRoom("AABBCCDDEEFF", room.Id);

        try
        {
            await store.SaveAsync(data);
            var loaded = await store.LoadAsync();

            Assert.Equal(person, Assert.Single(loaded.People));
            Assert.Equal(room, Assert.Single(loaded.Rooms));
            Assert.Equal(new DeviceAssignment(person.Id, room.Id), Assert.Single(loaded.Assignments).Value);
        }
        finally
        {
            if (Directory.Exists(directory))
            {
                Directory.Delete(directory, recursive: true);
            }
        }
    }

    [Fact]
    public async Task LoadAsync_RejectsMalformedEntriesWithExplicitDataError()
    {
        var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "people-rooms.json");
        await File.WriteAllTextAsync(path, """{"people":[null],"rooms":[],"assignments":{}}""");

        try
        {
            await Assert.ThrowsAsync<InvalidDataException>(() => new PeopleRoomsStore(path).LoadAsync());
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void ShortNames_AreRequiredLimitedAndUniqueIgnoringCaseWithinCategory()
    {
        Assert.NotNull(PeopleRoomsData.ValidateShortName(" "));
        Assert.NotNull(PeopleRoomsData.ValidateShortName("LONG"));
        Assert.Null(PeopleRoomsData.ValidateShortName("😀"));
        Assert.Null(PeopleRoomsData.ValidateShortName("👨‍👩‍👧‍👦"));
        Assert.Null(PeopleRoomsData.ValidateShortName("\u0030\uFE0F\u20E3"));
        Assert.Null(PeopleRoomsData.ValidateShortName("\u0030\uFE0F\u20E3AB"));
        Assert.NotNull(PeopleRoomsData.ValidateShortName("\u0030\uFE0F\u20E3ABC"));
        Assert.Throws<ArgumentException>(() => new PeopleRoomsData(
            [new ManagedPerson(Guid.NewGuid(), "Alex", "AL"), new ManagedPerson(Guid.NewGuid(), "Avery", "al")]));
        var sharedCategoryNamesAreAllowed = new PeopleRoomsData(
            [new ManagedPerson(Guid.NewGuid(), "Alex", "AL")],
            [new ManagedRoom(Guid.NewGuid(), "Alcove", "al")]);
        Assert.Single(sharedCategoryNamesAreAllowed.Rooms);
    }

    [Fact]
    public void Assignments_AreIndependentAndDeletingEntryClearsOnlyItsAssignment()
    {
        var person = new ManagedPerson(Guid.NewGuid(), "Alex", "AL");
        var room = new ManagedRoom(Guid.NewGuid(), "Living room", "LR");
        var assigned = new PeopleRoomsData([person], [room])
            .AssignPerson("AABBCCDDEEFF", person.Id)
            .AssignRoom("AABBCCDDEEFF", room.Id);

        var withoutPerson = assigned.DeletePerson(person.Id);
        Assert.Empty(withoutPerson.People);
        Assert.Equal(room.Id, Assert.Single(withoutPerson.Assignments).Value.RoomId);

        var withoutRoom = withoutPerson.DeleteRoom(room.Id);
        Assert.Empty(withoutRoom.Rooms);
        Assert.Empty(withoutRoom.Assignments);
    }

    [Fact]
    public void AssignmentRequiresStableMacAndExistingTarget()
    {
        var person = new ManagedPerson(Guid.NewGuid(), "Alex", "AL");
        var data = new PeopleRoomsData([person]);

        Assert.Throws<FormatException>(() => data.AssignPerson("missing", person.Id));
        Assert.Throws<ArgumentException>(() => data.AssignPerson("AABBCCDDEEFF", Guid.NewGuid()));
    }
}
