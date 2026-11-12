using System.Net;
using System.Net.NetworkInformation;
using FingVibe.App;
using FingVibe.Core.Models;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class PeopleRoomsPresentationTests
{
    private static readonly ManagedPerson Person = new(Guid.NewGuid(), "Alex Smith", "AS", "Person notes", "profile");
    private static readonly ManagedRoom Room = new(Guid.NewGuid(), "Living room", "LR", "Room notes", "garden");

    [Theory]
    [InlineData("", "")]
    [InlineData("  alex   smith third ", "AS")]
    [InlineData("alex", "A")]
    [InlineData("e\u0301mile \U0001F600", "E\u0301\U0001F600")]
    public void SuggestionsRetainFirstTwoGraphemes(string name, string expected) =>
        Assert.Equal(expected, PeopleRoomsPresentation.SuggestShortName(name));

    [Theory]
    [InlineData(" ", "AS", "A full name is required.")]
    [InlineData("Alex", "", "A short name is required.")]
    [InlineData("Alex", "abcd", "Short names must contain 1 to 3 characters.")]
    [InlineData("Alex", "\U0001F600e\u0301Z", null)]
    public void EditorsReuseCoreValidationAndFeedback(string name, string shortName, string? expected)
    {
        Assert.Equal(expected, PeopleRoomsPresentation.ValidatePerson(new(), null, name, shortName));
        Assert.Equal(expected, PeopleRoomsPresentation.ValidateRoom(new(), null, name, shortName));
    }

    [Fact]
    public void DuplicatesAreTrimmedCaseInsensitiveCategoryLocalAndExcludeTheEditedIdentity()
    {
        var data = new PeopleRoomsData([Person], [Room]);
        Assert.Equal("That short name is already used by another person.",
            PeopleRoomsPresentation.ValidatePerson(data, null, "Another", " as "));
        Assert.Equal("That short name is already used by another room.",
            PeopleRoomsPresentation.ValidateRoom(data, null, "Another", " lr "));
        Assert.Null(PeopleRoomsPresentation.ValidatePerson(data, Person, "Edited", "as"));
        Assert.Null(PeopleRoomsPresentation.ValidateRoom(data, Room, "Edited", "lr"));
        Assert.Null(PeopleRoomsPresentation.ValidatePerson(data, null, "Other category", "LR"));
        Assert.Null(PeopleRoomsPresentation.ValidateRoom(data, null, "Other category", "AS"));
    }

    [Theory]
    [InlineData(" as ", true)]
    [InlineData("SMITH", true)]
    [InlineData("", true)]
    [InlineData("missing", false)]
    public void SearchUsesOnlyNamesAndShortNames(string search, bool expected) =>
        Assert.Equal(expected, PeopleRoomsPresentation.MatchesSearch(Person.ShortName, Person.Name, search));

    [Fact]
    public void ListsRetainOrderIconsNotesAndHistoricalAssignmentsWithoutInventingResponses()
    {
        var second = new ManagedPerson(Guid.NewGuid(), "Other", "O");
        var data = new PeopleRoomsData([Person, second], [Room],
            new Dictionary<string, DeviceAssignment>
            {
                ["001122334455"] = new(Person.Id, Room.Id),
                ["001122334466"] = new(Person.Id)
            });
        AssignedDeviceListRow[] devices =
        [
            new("001122334455", LiveRow("001122334455")),
            new("001122334466", null)
        ];
        var people = PeopleRoomsPresentation.PeopleRows(data, devices, false);
        Assert.Equal(new[] { Person, second }, people.Select(row => row.Person));
        Assert.Equal("2 devices", people[0].DeviceCountText);
        Assert.Equal("No local scan evidence", people[0].RespondedCountText);
        Assert.Equal("0 devices", people[1].DeviceCountText);
        var room = Assert.Single(PeopleRoomsPresentation.RoomRows(data, devices, true));
        Assert.Equal(Room, room.Room);
        Assert.Equal("1 device", room.DeviceCountText);
        Assert.Equal("1 online", room.RespondedCountText);
        Assert.Equal("1 online", PeopleRoomsPresentation.PeopleRows(data, devices, true)[0].RespondedCountText);
        Assert.Equal("No local scan evidence.",
            PeopleRoomsPresentation.DetailResponses(devices, false));
        Assert.Equal("1 devices Online in their latest applicable scan evidence.",
            PeopleRoomsPresentation.DetailResponses(devices, true));
    }

    [Fact]
    public void VirtualAssignmentBelongsToTheVirtualDeviceNotItsInferredMac()
    {
        var result = new ScanResult(IPAddress.Loopback, HostStatus.Alive, 1, TimeSpan.Zero,
            MacAddress: PhysicalAddress.Parse("D0C907000001"), VendorName: "Private");
        var inventory = DeviceInventoryData.Empty.ObserveCompletedScan("test",
            new("127.0.0.1/32", DateTimeOffset.UtcNow, [result]));
        var device = Assert.Single(inventory.VirtualDevices) with { Assignment = new(Person.Id, Room.Id) };
        var row = new ScanResultRow(device, inventory, 32);
        var data = new PeopleRoomsData([Person], [Room]);
        AssignedDeviceListRow[] devices = [new(row.IdentityKey, row)];
        Assert.Same(row, Assert.Single(PeopleRoomsPresentation.AssignedTo(data, devices, Person.Id, null)).ScanResult);
        Assert.Single(PeopleRoomsPresentation.AssignedTo(data, devices, null, Room.Id));
        row.UpdateVirtualDevice(device with { Assignment = new(RoomId: Room.Id) });
        Assert.Empty(PeopleRoomsPresentation.AssignedTo(data, devices, Person.Id, null));
        Assert.Single(PeopleRoomsPresentation.AssignedTo(data, devices, null, Room.Id));
    }

    [Fact]
    public void DeletionAndUnassignmentRefreshCountsWithoutRemovingDevicesOrTheOtherCategory()
    {
        var data = new PeopleRoomsData([Person], [Room],
            new Dictionary<string, DeviceAssignment> { ["001122334455"] = new(Person.Id, Room.Id) });
        AssignedDeviceListRow[] devices = [new("001122334455", LiveRow("001122334455"))];
        var unassigned = data.AssignPerson("001122334455", null);
        Assert.Equal("0 devices", Assert.Single(PeopleRoomsPresentation.PeopleRows(unassigned, devices, true)).DeviceCountText);
        Assert.Equal("1 device", Assert.Single(PeopleRoomsPresentation.RoomRows(unassigned, devices, true)).DeviceCountText);
        var deleted = data.DeletePerson(Person.Id);
        Assert.Empty(PeopleRoomsPresentation.PeopleRows(deleted, devices, true));
        Assert.Single(PeopleRoomsPresentation.AssignedTo(deleted, devices, null, Room.Id));
        Assert.Single(devices);
        Assert.Single(data.People);
        Assert.Empty(PeopleRoomsPresentation.RoomRows(data.DeleteRoom(Room.Id), devices, true));
    }

    [Fact]
    public void SavedEvidenceCountsOnlineWithoutClaimingFreshResponsesAndEmptyDetailsRemainZero()
    {
        Assert.Empty(PeopleRoomsPresentation.PeopleRows(new(), [], true));
        Assert.Empty(PeopleRoomsPresentation.RoomRows(new(), [], false));
        var historical = new AssignedDeviceListRow("001122334455",
            new ScanResultRow(new ScanResult(IPAddress.Loopback, HostStatus.Alive, 1, TimeSpan.Zero),
                32, historical: true));
        Assert.False(historical.ScanResult!.IsCurrentScanResponse);
        Assert.Equal("1 online", PeopleRoomsPresentation.ResponseCount([historical], true));
        Assert.Equal("0 devices Online in their latest applicable scan evidence.",
            PeopleRoomsPresentation.DetailResponses([], true));
    }

    private static ScanResultRow LiveRow(string mac) => new(
        new ScanResult(IPAddress.Loopback, HostStatus.Alive, 1, TimeSpan.Zero,
            MacAddress: PhysicalAddress.Parse(mac)), 32);
}
