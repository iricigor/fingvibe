using System.Net;
using System.Net.NetworkInformation;
using FingVibe.App;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Microsoft.Data.Sqlite;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class LinkedDeviceTests : IDisposable
{
    private const string A = "001122AA0001";
    private const string B = "001122AA0002";
    private const string C = "001122AA0003";
    private const string Private = "D0C907000001";
    private static readonly DateTimeOffset Start = new(2026, 11, 1, 12, 0, 0, TimeSpan.Zero);
    private static readonly ManagedPerson Person = new(Guid.NewGuid(), "Ada", "AD");
    private static readonly ManagedRoom Room = new(Guid.NewGuid(), "Office", "OF");
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"fingvibe-linked-{Guid.NewGuid():N}");

    private static ScanResult Result(string mac, string address, string vendor = "Example") =>
        new(IPAddress.Parse(address), HostStatus.Alive, 1, TimeSpan.FromMilliseconds(1), null, PhysicalAddress.Parse(mac), vendor);

    private static DeviceInventoryData Scan(DeviceInventoryData data, int minute, params ScanResult[] results) =>
        data.ObserveCompletedScan("home", new("192.0.2.0/24", Start.AddMinutes(minute), results));

    private static DeviceInventoryData Inventory()
    {
        var data = Scan(DeviceInventoryData.Empty, 0, Result(A, "192.0.2.10"), Result(B, "192.0.2.11"), Result(C, "192.0.2.12"));
        return data with
        {
            Names = new Dictionary<string, string> { [A] = "Laptop Wi-Fi", [B] = "Laptop dock" },
            Classifications = new Dictionary<string, DeviceClassificationOverride> { [A] = new(Type: DeviceType.Phone) },
            PeopleRooms = new PeopleRoomsData([Person], [Room]).AssignRoom(B, Room.Id),
            Devices = data.Devices.ToDictionary(pair => pair.Key, pair => pair.Key == B
                ? pair.Value with { UsageCategoryOverride = DeviceUsageCategory.Guest } : pair.Value)
        };
    }

    private static LinkedDeviceChoices Choices(string name = "Work laptop") =>
        new(name, new(DeviceOperatingSystem.Windows, DeviceType.Computer, null, "Contoso", null, null),
            new(Person.Id, Room.Id), DeviceUsageCategory.Personal);

    [Fact]
    public void LinkingSavesSharedValuesAndKeepsEachMembersOwnValues()
    {
        var data = Inventory();

        var linked = data.LinkDevices(B, A, Choices(" Work laptop "), Start);
        var device = Assert.Single(linked.LinkedDevices);

        Assert.Equal([B, A], device.Members.Select(member => member.Mac));
        Assert.All(device.Members, member => Assert.Equal(Start, member.LinkedAt));
        Assert.Equal("Work laptop", device.Name);
        Assert.Equal(new LinkedDeviceConfirmation("Work laptop", Choices().Identification), device.Confirmed);
        Assert.Same(device, linked.FindLinkedDevice(A));
        Assert.Equal(new DeviceAssignment(Person.Id, Room.Id), linked.GetAssignment(A));
        Assert.Equal(DeviceUsageCategory.Personal, linked.GetUsageCategoryOverride(LogicalDeviceId.Mac(B)));
        Assert.Null(linked.FindLinkedDevice(C));
        Assert.Null(linked.GetAssignment(C));
        // Member-specific values remain unchanged for the later Unlink restore.
        Assert.Equal(data.Names, linked.Names);
        Assert.Equal(data.Classifications, linked.Classifications);
        Assert.Equal(data.PeopleRooms.Assignments, linked.PeopleRooms.Assignments);
        Assert.Equal(DeviceUsageCategory.Guest, linked.Devices[B].UsageCategoryOverride);
    }

    [Fact]
    public void SharedEditsChangeTheLinkedDeviceButNotMembersOrConfirmedValues()
    {
        var linked = Inventory().LinkDevices(A, B, Choices(), Start);
        var id = linked.LinkedDevices[0].Id;

        var edited = linked.UpdateLinkedDevice(id, device => device with { Name = "Renamed", Assignment = null })
            .SetUsageCategoryOverride(LogicalDeviceId.Mac(A), DeviceUsageCategory.Permanent);

        var device = Assert.Single(edited.LinkedDevices);
        Assert.Equal("Renamed", device.Name);
        Assert.Equal("Work laptop", device.Confirmed.Name);
        Assert.Null(edited.GetAssignment(B));
        Assert.Equal(DeviceUsageCategory.Permanent, edited.GetUsageCategoryOverride(LogicalDeviceId.Mac(B)));
        Assert.Equal(DeviceUsageCategory.Guest, edited.Devices[B].UsageCategoryOverride);
        Assert.Null(edited.Devices[A].UsageCategoryOverride);
        Assert.Throws<InvalidOperationException>(() => linked.UpdateLinkedDevice(id, item => item with { Members = [item.Members[0], new(C, Start)] }));
        Assert.Throws<InvalidOperationException>(() => linked.UpdateLinkedDevice(id, item => item with { Confirmed = item.Confirmed with { Name = "Other" } }));
        Assert.Throws<ArgumentException>(() => linked.UpdateLinkedDevice(id, item => item with { Name = " " }));
    }

    [Fact]
    public void UnlinkTransfersSharedValuesToTheRemainingMacAndRestoresTheDetachedValues()
    {
        var original = Inventory() with
        {
            Classifications = new Dictionary<string, DeviceClassificationOverride>
            {
                [A] = new(Type: DeviceType.Phone),
                [B] = new(Type: DeviceType.Router)
            }
        };
        var linked = original.LinkDevices(A, B, Choices(), Start);
        var id = linked.LinkedDevices[0].Id;
        var edited = linked.UpdateLinkedDevice(id, device => device with
        {
            Name = "Shared edit",
            Identification = device.Identification with { Type = DeviceType.Computer },
            Assignment = new(Person.Id, Room.Id)
        }).SetUsageCategoryOverride(LogicalDeviceId.Mac(A), DeviceUsageCategory.Permanent);

        var unlinked = edited.UnlinkDevice(B);

        Assert.Empty(unlinked.LinkedDevices);
        Assert.Equal("Shared edit", unlinked.Names[A]);
        Assert.Equal("Laptop dock", unlinked.Names[B]);
        Assert.Equal(DeviceType.Computer, unlinked.Classifications[A].Type);
        Assert.Equal(DeviceType.Router, unlinked.Classifications[B].Type);
        Assert.Equal(new DeviceAssignment(Person.Id, Room.Id), unlinked.PeopleRooms.Assignments[A]);
        Assert.Equal(new DeviceAssignment(null, Room.Id), unlinked.PeopleRooms.Assignments[B]);
        Assert.Equal(DeviceUsageCategory.Permanent, unlinked.Devices[A].UsageCategoryOverride);
        Assert.Equal(DeviceUsageCategory.Guest, unlinked.Devices[B].UsageCategoryOverride);
        Assert.Equal(original.Devices[A].Observations, unlinked.Devices[A].Observations);
        Assert.Equal(original.Devices[B].ScanHistory, unlinked.Devices[B].ScanHistory);
        var declined = Assert.Single(unlinked.DeclinedMatches);
        Assert.Equal(DeclinedDeviceMatch.Create(A, B).Key, declined.Key);
        Assert.Null(unlinked.FindLinkedDevice(A));
        Assert.Null(unlinked.FindLinkedDevice(B));
        Assert.Equal("Shared edit", ScanResultRow.CreateInventoryRows(unlinked).Single(row => row.IdentityKey == A).NameText);
        Assert.Equal("Laptop dock", ScanResultRow.CreateInventoryRows(unlinked).Single(row => row.IdentityKey == B).NameText);
        var rows = ScanResultRow.CreateInventoryRows(unlinked).ToArray();
        var manual = LinkedDevicePresentation.Candidates(rows.Single(row => row.IdentityKey == A), rows, unlinked)
            .Single(candidate => candidate.Mac == B);
        Assert.True(manual.Declined);

        var opposite = edited.UnlinkDevice(A);
        Assert.Equal("Laptop Wi-Fi", opposite.Names[A]);
        Assert.Equal("Shared edit", opposite.Names[B]);
        Assert.Equal(DeviceType.Phone, opposite.Classifications[A].Type);
        Assert.Equal(DeviceType.Computer, opposite.Classifications[B].Type);
        Assert.False(opposite.PeopleRooms.Assignments.ContainsKey(A));
        Assert.Equal(new DeviceAssignment(Person.Id, Room.Id), opposite.PeopleRooms.Assignments[B]);
        Assert.Null(opposite.Devices[A].UsageCategoryOverride);
        Assert.Equal(DeviceUsageCategory.Permanent, opposite.Devices[B].UsageCategoryOverride);
    }

    [Fact]
    public void UnlinkRejectsUnknownMacs()
    {
        Assert.Throws<ArgumentException>(() => Inventory().UnlinkDevice(A));
    }

    [Fact]
    public void AddingARecordKeepsTheLinkedIdentityDatesAndEveryMembersOwnValues()
    {
        var linked = Inventory().LinkDevices(A, B, Choices(), Start);
        var id = linked.LinkedDevices[0].Id;
        var later = Start.AddDays(1);
        var choices = Choices("Desk") with { Assignment = null, UsageCategoryOverride = null };

        var added = linked.LinkDevices(B, C, choices, later);

        var device = Assert.Single(added.LinkedDevices);
        Assert.Equal(id, device.Id);
        Assert.Equal([(A, Start), (B, Start), (C, later)], device.Members.Select(member => (member.Mac, member.LinkedAt)));
        Assert.Equal(new LinkedDeviceConfirmation("Desk", choices.Identification), device.Confirmed);
        Assert.Null(device.Assignment);
        Assert.Equal("Laptop Wi-Fi", added.Names[A]);
        Assert.Equal(DeviceType.Phone, added.Classifications[A].Type);
        Assert.Equal(Room.Id, added.PeopleRooms.Assignments[B].RoomId);
        Assert.Equal(DeviceUsageCategory.Guest, added.Devices[B].UsageCategoryOverride);
        Assert.Single(ScanResultRow.CreateInventoryRows(added));

        // Opened from the single record, the existing linked device's identity still survives.
        var fromRecord = Assert.Single(linked.LinkDevices(C, A, choices, later).LinkedDevices);
        Assert.Equal(id, fromRecord.Id);
        Assert.Equal([A, B, C], fromRecord.Members.Select(member => member.Mac));
        Assert.Throws<InvalidOperationException>(() => added.LinkDevices(A, C, choices, later));
    }

    [Fact]
    public void CombiningLinkedDevicesKeepsTheOpenDevicesIdentityAndEveryLinkedDate()
    {
        const string D = "001122AA0004";
        var data = Scan(Inventory(), 1, Result(A, "192.0.2.10"), Result(B, "192.0.2.11"), Result(C, "192.0.2.12"),
            Result(D, "192.0.2.13"));
        var first = data.LinkDevices(A, B, Choices(), Start);
        var both = Scan(first.LinkDevices(C, D, Choices("Dock pair"), Start.AddDays(1)), 2, Result(A, "192.0.2.10"),
            Result(B, "192.0.2.11"), Result(C, "192.0.2.12"), Result(D, "192.0.2.13"));
        var openId = both.FindLinkedDevice(C)!.Id;

        var combined = both.LinkDevices(C, A, Choices("Desk"), Start.AddDays(2));

        var device = Assert.Single(combined.LinkedDevices);
        Assert.Equal(openId, device.Id);
        Assert.Equal([(C, Start.AddDays(1)), (D, Start.AddDays(1)), (A, Start), (B, Start)],
            device.Members.Select(member => (member.Mac, member.LinkedAt)));
        Assert.Equal("Desk", device.Name);
        Assert.Single(device.Representatives);
        Assert.Equal("Laptop Wi-Fi", combined.Names[A]);
        Assert.Equal(DeviceUsageCategory.Guest, combined.Devices[B].UsageCategoryOverride);
        Assert.Same(device, combined.FindLinkedDevice(B));
        Assert.True(device.IsValid(combined));
    }

    [Fact]
    public void UnlinkingFromThreeKeepsTheLinkedValuesAndDeclinesTheDetachedMacAgainstEveryMember()
    {
        var linked = Scan(Inventory().LinkDevices(A, B, Choices(), Start).LinkDevices(A, C, Choices(), Start.AddDays(1)),
            1, Result(C, "192.0.2.12"));
        var id = linked.LinkedDevices[0].Id;
        Assert.Equal(C, Assert.Single(linked.LinkedDevices[0].Representatives).Mac);

        var smaller = linked.UnlinkDevice(C);

        var device = Assert.Single(smaller.LinkedDevices);
        Assert.Equal(id, device.Id);
        Assert.Equal([A, B], device.Members.Select(member => member.Mac));
        Assert.Equal("Work laptop", device.Name);
        Assert.Equal(new DeviceAssignment(Person.Id, Room.Id), device.Assignment);
        Assert.Empty(device.Representatives);
        Assert.False(smaller.Names.ContainsKey(C));
        Assert.Equal([DeclinedDeviceMatch.Create(A, C).Key, DeclinedDeviceMatch.Create(B, C).Key],
            smaller.DeclinedMatches.Select(item => item.Key));
        Assert.Equal(2, ScanResultRow.CreateInventoryRows(smaller).Count());

        var separate = smaller.UnlinkDevice(B);
        Assert.Empty(separate.LinkedDevices);
        Assert.Equal("Work laptop", separate.Names[A]);
        Assert.Equal(3, separate.DeclinedMatches.Count);
    }

    [Fact]
    public async Task AddingAndUnlinkingFromLargerLinkedDevicesSurviveRestart()
    {
        var path = Path.Combine(_directory, "device-inventory.json");
        var store = new DeviceInventoryStore(path);
        var saved = await store.SaveAsync(Inventory(), Guid.Empty);
        var linked = await store.SaveAsync(saved.LinkDevices(A, B, Choices(), Start), saved.Revision);
        await store.SaveAsync(linked.LinkDevices(A, C, Choices("Desk"), Start.AddDays(1)), linked.Revision);

        var reopened = new DeviceInventoryStore(path);
        var restarted = (await reopened.LoadAsync())!;
        var device = Assert.Single(restarted.LinkedDevices);
        Assert.Equal(linked.LinkedDevices[0].Id, device.Id);
        Assert.Equal([(A, Start), (B, Start), (C, Start.AddDays(1))], device.Members.Select(member => (member.Mac, member.LinkedAt)));
        Assert.Equal("Desk", device.Name);

        await reopened.SaveAsync(restarted.UnlinkDevice(A), restarted.Revision);
        var final = (await new DeviceInventoryStore(path).LoadAsync())!;
        Assert.Equal([B, C], Assert.Single(final.LinkedDevices).Members.Select(member => member.Mac));
        Assert.Equal("Laptop Wi-Fi", final.Names[A]);
        Assert.Equal(2L, Scalar(path, "SELECT COUNT(*) FROM declined_matches"));
    }

    [Fact]
    public void GroupSuggestionsAppearOncePerLinkedDeviceAndDeclinesCoverEveryCurrentPair()
    {
        const string D = "001122AA0004";
        const string E = "001122AA0005";
        var data = Scan(Inventory(), 1, Result(A, "192.0.2.10"), Result(B, "192.0.2.11"), Result(C, "192.0.2.12"),
            Result(D, "192.0.2.13"), Result(E, "192.0.2.14"));
        data = (data with
        {
            Names = new Dictionary<string, string> { [A] = "desk.local", [B] = "desk.local", [C] = "desk.local", [D] = "Work laptop",
                [E] = "desk.local" },
            Classifications = new Dictionary<string, DeviceClassificationOverride>()
        }).LinkDevices(A, B, Choices(), Start);
        IReadOnlyDictionary<string, IReadOnlyList<DeviceMatchSuggestion>> Find(DeviceInventoryData inventory) =>
            DeviceMatchSuggestions.Find(inventory, new HashSet<string>());

        var found = Find(data);
        // C and E each match the linked device once (and each other); members are never suggested to each other,
        // and the shared name "Work laptop" is not evidence for D.
        Assert.Equal([A, E], found[C].Select(item => item.OtherMac).Order());
        Assert.Equal([C, E], found[A].Select(item => item.OtherMac).Order());
        Assert.Same(found[A], found[B]);
        Assert.False(found.ContainsKey(D));

        // One declined cross pair leaves the other matching member; declining the group covers every current pair.
        var partly = data with { DeclinedMatches = [DeclinedDeviceMatch.Create(A, C)] };
        Assert.Equal([B, E], Find(partly)[C].Select(item => item.OtherMac).Order());
        var declined = data.DeclineMatch(C, B);
        Assert.Equal([DeclinedDeviceMatch.Create(A, C).Key, DeclinedDeviceMatch.Create(B, C).Key],
            declined.DeclinedMatches.Select(item => item.Key));
        Assert.Equal([E], Find(declined)[C].Select(item => item.OtherMac));
        Assert.Equal([E], Find(declined)[A].Select(item => item.OtherMac));
        Assert.Throws<ArgumentException>(() => data.DeclineMatch(A, B));

        // A later member creates fresh pairs, so the linked device is suggested to C again through E.
        var grown = declined.LinkDevices(A, E, Choices(), Start.AddDays(1));
        Assert.Equal(E, Assert.Single(Find(grown)[C]).OtherMac);
        Assert.Equal([C], Find(grown)[A].Select(item => item.OtherMac));
    }

    [Fact]
    public async Task UnlinkPersistsAllChangesTogetherAndSurvivesRestart()
    {
        var path = Path.Combine(_directory, "device-inventory.json");
        var store = new DeviceInventoryStore(path);
        var saved = await store.SaveAsync(Inventory(), Guid.Empty);
        var linked = await store.SaveAsync(saved.LinkDevices(A, B, Choices(), Start), saved.Revision);

        await store.SaveAsync(linked.UnlinkDevice(B), linked.Revision);

        var restarted = (await new DeviceInventoryStore(path).LoadAsync())!;
        Assert.Empty(restarted.LinkedDevices);
        Assert.Single(restarted.DeclinedMatches);
        Assert.Equal("Work laptop", restarted.Names[A]);
        Assert.Equal("Laptop dock", restarted.Names[B]);
        Assert.Equal(Choices().Identification, restarted.Classifications[A]);
        Assert.Equal(DeviceUsageCategory.Personal, restarted.Devices[A].UsageCategoryOverride);
        Assert.Equal(DeviceUsageCategory.Guest, restarted.Devices[B].UsageCategoryOverride);
        Assert.Equal(new DeviceAssignment(Person.Id, Room.Id), restarted.PeopleRooms.Assignments[A]);
        Assert.Equal(new DeviceAssignment(null, Room.Id), restarted.PeopleRooms.Assignments[B]);
        Assert.Equal(0L, Scalar(path, "SELECT COUNT(*) FROM linked_devices"));
        Assert.Equal(1L, Scalar(path, "SELECT COUNT(*) FROM declined_matches"));
    }

    [Fact]
    public async Task AStaleUnlinkSaveChangesNothing()
    {
        var path = Path.Combine(_directory, "device-inventory.json");
        var store = new DeviceInventoryStore(path);
        var saved = await store.SaveAsync(Inventory(), Guid.Empty);
        var linked = await store.SaveAsync(saved.LinkDevices(A, B, Choices(), Start), saved.Revision);
        Execute(path, $"UPDATE inventory SET revision='{Guid.NewGuid()}'");

        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            store.SaveAsync(linked.UnlinkDevice(B), linked.Revision));

        var unchanged = (await new DeviceInventoryStore(path).LoadAsync())!;
        Assert.Single(unchanged.LinkedDevices);
        Assert.Empty(unchanged.DeclinedMatches);
        Assert.Equal("Laptop Wi-Fi", unchanged.Names[A]);
        Assert.Equal(DeviceType.Phone, unchanged.Classifications[A].Type);
        Assert.Null(unchanged.Devices[A].UsageCategoryOverride);
    }

    [Fact]
    public void LinkingRejectsInvalidPairsTheSameLinkedDeviceAndVirtualRecords()
    {
        var data = Inventory();
        var linked = data.LinkDevices(A, B, Choices(), Start);

        Assert.Throws<ArgumentException>(() => data.LinkDevices(A, A, Choices(), Start));
        Assert.Throws<ArgumentException>(() => data.LinkDevices(A, "001122AA00FF", Choices(), Start));
        Assert.Throws<ArgumentException>(() => data.LinkDevices(A, C, Choices(" "), Start));
        Assert.Throws<InvalidOperationException>(() => linked.LinkDevices(B, A, Choices(), Start));
        var virtualData = Scan(data, 1, Result(Private, "192.0.2.20", "Private"));
        Assert.Contains(Private, virtualData.VirtualGroupedMacs());
        Assert.Throws<InvalidOperationException>(() => virtualData.LinkDevices(C, Private, Choices(), Start));
        Assert.Throws<ArgumentException>(() => data.LinkDevices(A, C,
            Choices() with { Assignment = new(Guid.NewGuid(), null) }, Start));
    }

    [Fact]
    public void LinkedMacsNeverJoinVirtualDevicesAndAreSuggestedAsOneDevice()
    {
        var data = Scan(DeviceInventoryData.Empty, 0, Result(A, "192.0.2.10"));
        data = data with { Devices = new Dictionary<string, InventoryDevice>(data.Devices)
            { [Private] = new(Private, new(), []) }, PeopleRooms = new([Person], [Room]) };
        var linked = data.LinkDevices(A, Private, Choices(), Start);

        var scanned = Scan(linked, 5, Result(A, "192.0.2.10"), Result(Private, "192.0.2.20", "Private"));

        Assert.Empty(scanned.VirtualDevices);
        Assert.False(PrivateVirtualDeviceAllocator.IsEligible(scanned, scanned.Devices[Private]));
        Assert.Single(ScanResultRow.CreateInventoryRows(scanned), row => row.IsLinkedDeviceRow);
        var named = linked with { Names = new Dictionary<string, string> { [A] = "same.local", [C] = "same.local" },
            Devices = new Dictionary<string, InventoryDevice>(linked.Devices) { [C] = scanned.Devices[A] with { Mac = C } } };
        var found = DeviceMatchSuggestions.Find(named, new HashSet<string>());
        Assert.Equal(A, Assert.Single(found[C]).OtherMac);
        Assert.Same(found[A], found[Private]);
    }

    [Fact]
    public async Task LinksPersistAtomicallyAcrossRestartsAndExistingInventoriesGainTheirTable()
    {
        var path = Path.Combine(_directory, "device-inventory.json");
        var saved = await new DeviceInventoryStore(path).SaveAsync(Inventory(), Guid.Empty);
        Execute(path, "DROP TABLE linked_devices");

        var reopened = new DeviceInventoryStore(path);
        var loaded = (await reopened.LoadAsync())!;
        Assert.Empty(loaded.LinkedDevices);
        await reopened.SaveAsync(loaded.LinkDevices(A, B, Choices(), Start), loaded.Revision);

        var restarted = (await new DeviceInventoryStore(path).LoadAsync())!;
        var device = Assert.Single(restarted.LinkedDevices);
        Assert.Equal([A, B], device.Members.Select(member => member.Mac));
        Assert.Equal(Choices().Identification, device.Identification);
        Assert.Equal(new DeviceAssignment(Person.Id, Room.Id), device.Assignment);
        Assert.Equal("Laptop Wi-Fi", restarted.Names[A]);
        Assert.Equal(Room.Id, restarted.PeopleRooms.Assignments[B].RoomId);
        Assert.Equal(1L, Scalar(path, "SELECT COUNT(*) FROM linked_devices"));
        Assert.NotEqual(saved.Revision, restarted.Revision);
    }

    [Fact]
    public async Task AStaleLinkSaveChangesNothing()
    {
        var path = Path.Combine(_directory, "device-inventory.json");
        var store = new DeviceInventoryStore(path);
        var saved = await store.SaveAsync(Inventory(), Guid.Empty);
        Execute(path, $"UPDATE inventory SET revision='{Guid.NewGuid()}'");

        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            store.SaveAsync(saved.LinkDevices(A, B, Choices(), Start), saved.Revision));

        Assert.Equal(0L, Scalar(path, "SELECT COUNT(*) FROM linked_devices"));
    }

    [Theory]
    [InlineData("""{"id":"ID","members":[{"mac":"001122AA0001","linkedAt":"2026-11-01T12:00:00+00:00"}],"name":"X","identification":{},"confirmed":{"name":"X","identification":{}}}""")]
    [InlineData("""{"id":"ID","members":[{"mac":"001122AA0001","linkedAt":"2026-11-01T12:00:00+00:00"},{"mac":"001122AA0002","linkedAt":"2026-11-01T12:00:00+00:00"}],"name":"X","identification":{}}""")]
    [InlineData("""{"id":"ID","members":[{"mac":"001122AA0001","linkedAt":"2026-11-01T12:00:00+00:00"},{"mac":"001122AA00FF","linkedAt":"2026-11-01T12:00:00+00:00"}],"name":"X","identification":{},"confirmed":{"name":"X","identification":{}}}""")]
    [InlineData("""{"id":"ID","members":[{"mac":"001122AA0001","linkedAt":"2026-11-01T12:00:00+00:00"},{"mac":"001122AA0002","linkedAt":"2026-11-01T12:00:00+00:00"}],"name":" ","identification":{},"confirmed":{"name":"X","identification":{}}}""")]
    [InlineData("""{"id":"ID","members":[{"mac":"001122AA0001","linkedAt":"2026-11-01T12:00:00+00:00"},{"mac":"001122AA0002","linkedAt":"2026-11-01T12:00:00+00:00"}],"name":"X","identification":{},"confirmed":{"name":"X","identification":{}},"usageCategoryOverride":9}""")]
    [InlineData("""{"id":"ID","members":[""")]
    public async Task MalformedLinkedDevicesAreRejected(string json)
    {
        var path = Path.Combine(_directory, "device-inventory.json");
        await new DeviceInventoryStore(path).SaveAsync(Inventory(), Guid.Empty);
        var id = Guid.NewGuid().ToString("D");
        Execute(path, "INSERT INTO linked_devices(id,data) VALUES($id,$data)", ("$id", id), ("$data", json.Replace("ID", id)));

        await Assert.ThrowsAsync<InvalidDataException>(() => new DeviceInventoryStore(path).LoadAsync());
    }

    [Fact]
    public async Task AMacInTwoLinkedDevicesIsRejected()
    {
        var path = Path.Combine(_directory, "device-inventory.json");
        var store = new DeviceInventoryStore(path);
        var saved = await store.SaveAsync(Inventory(), Guid.Empty);
        var first = saved.LinkDevices(A, B, Choices(), Start).LinkedDevices[0];
        var duplicate = first with { Id = Guid.NewGuid(), Members = [new(A, Start), new(C, Start)] };

        await Assert.ThrowsAsync<InvalidDataException>(() =>
            store.SaveAsync(saved with { LinkedDevices = [first, duplicate] }, saved.Revision));
    }

    [Fact]
    public void LinkedRowsShowSharedValuesWithoutFallingBackToMemberData()
    {
        var data = Inventory() with
        {
            Devices = Inventory().Devices.ToDictionary(pair => pair.Key, pair => pair.Key == B
                ? pair.Value with { Imported = new(Brand: "Imported brand", Family: "Imported family") } : pair.Value)
        };
        var linked = data.LinkDevices(A, B, Choices() with
        {
            Identification = new(DeviceOperatingSystem.Windows, DeviceType.Computer, null, null, null, null)
        }, Start);

        var rows = new[] { A, B }.Select(mac => ScanResultRow.ForDevice(linked.Devices[mac], linked)).ToArray();

        Assert.Equal(2, rows.Length);
        Assert.All(rows, row =>
        {
            Assert.Equal("Work laptop", row.NameText);
            Assert.Equal(DeviceType.Computer, row.Type);
            Assert.Equal("-", row.BrandText);
            Assert.Equal("-", row.FamilyText);
            Assert.Equal(DeviceUsageCategory.Personal, row.UsageCategoryOverride);
            Assert.Equal("Linked device value", row.IdentificationSourceLabel);
        });
        Assert.False(ScanResultRow.CreateInventoryRows(linked).Single(row => row.IdentityKey == C).IsLinked);
        Assert.Single(ScanResultRow.CreateInventoryRows(linked), row => row.IsLinked);
    }

    [Fact]
    public void RoomMapShowsSharedValuesAndNeverAMembersHiddenType()
    {
        var linked = Inventory().LinkDevices(A, B, Choices(), Start);
        var automatic = linked.UpdateLinkedDevice(linked.LinkedDevices[0].Id,
            device => device with { Identification = device.Identification with { Type = null } });
        var network = new LanNetwork("Ethernet", IPAddress.Parse("192.0.2.5"), IPAddress.Parse("192.0.2.0"), 24,
            true, IPAddress.Parse("192.0.2.1"), "ethernet-test");

        var id = linked.LinkedDevices[0].Id.ToString("D");
        var devices = RoomMapProjection.Create(automatic, network, "home").Devices
            .Where(device => device.IdentityKey is A or B || device.IdentityKey == id).ToArray();

        Assert.Equal(id, Assert.Single(devices).IdentityKey);
        Assert.All(devices, device =>
        {
            Assert.Equal("Work laptop", device.Name);
            Assert.Equal(DeviceType.Unknown, device.Type);
            Assert.Equal(Room.Id, device.RoomId);
            Assert.Equal("192.0.2.10", device.Address);
        });
    }

    [Fact]
    public void DifferencesNeedExplicitChoicesAndMatchingValuesAreKept()
    {
        var (device, other) = Rows(Inventory());
        var draft = LinkedDeviceDraft.Create(device, other);

        Assert.Equal(["Name", "Device type", "Operating system", "Vendor / manufacturer", "Person", "Room", "Usage category"],
            draft.Fields.Select(field => field.Label));
        Assert.True(draft[LinkedField.Name]!.Differs);
        Assert.True(draft[LinkedField.DeviceType]!.Differs);
        Assert.False(draft[LinkedField.OperatingSystem]!.Differs);
        Assert.True(draft[LinkedField.Room]!.Differs);
        Assert.Equal(4, draft.UnresolvedCount);
        Assert.False(draft.CanMerge);
        Assert.Equal("Choose a value", draft[LinkedField.Name]!.ResultText);
        Assert.Throws<InvalidOperationException>(() => draft.ToChoices());
        Assert.Throws<InvalidOperationException>(() => draft[LinkedField.OperatingSystem]!.Choose(LinkedFieldChoice.OtherDevice));

        draft[LinkedField.Name]!.TypeName("  Typed laptop ");
        draft[LinkedField.DeviceType]!.Choose(LinkedFieldChoice.OtherDevice);
        draft[LinkedField.Room]!.Choose(LinkedFieldChoice.OtherDevice);
        Assert.False(draft.CanMerge);
        draft[LinkedField.UsageCategory]!.Choose(LinkedFieldChoice.OtherDevice);

        var choices = draft.ToChoices();
        Assert.Equal("Typed laptop", choices.Name);
        Assert.Equal(other.Type, choices.Identification.Type);
        Assert.Equal(device.OperatingSystem, choices.Identification.OperatingSystem);
        Assert.Equal(new DeviceAssignment(null, Room.Id), choices.Assignment);
        Assert.Equal(DeviceUsageCategory.Guest, choices.UsageCategoryOverride);
        draft[LinkedField.Name]!.TypeName("");
        Assert.False(draft.CanMerge);
    }

    [Fact]
    public void IdentificationCanStaySeparateWithoutResolvingOtherDifferences()
    {
        var (device, other) = Rows(Inventory());
        device.SetClassificationOverride(new(Brand: "Wi-Fi vendor", Family: "Adapter", Model: "Wi-Fi model"));
        other.SetClassificationOverride(new(Brand: "Board vendor", Family: "Motherboard", Model: "Board model"));
        var draft = LinkedDeviceDraft.Create(device, other);

        foreach (var field in new[] { LinkedField.Vendor, LinkedField.Family, LinkedField.Model })
        {
            var value = draft[field]!;
            Assert.False(value.IsResolved);
            value.Choose(LinkedFieldChoice.ThisDevice);
            Assert.Equal(value.ThisText, value.Result);
            value.Choose(LinkedFieldChoice.KeepSeparate);
            Assert.True(value.IsResolved);
            Assert.Equal("No shared value", value.ResultText);
            Assert.Null(value.Result);
            value.Choose(LinkedFieldChoice.OtherDevice);
            Assert.Equal(value.OtherText, value.Result);
            value.Choose(LinkedFieldChoice.None);
            Assert.False(value.IsResolved);
            value.Choose(LinkedFieldChoice.KeepSeparate);
        }

        Assert.False(draft.CanMerge);
        Assert.Throws<InvalidOperationException>(() => draft.ToChoices());
        foreach (var field in draft.Fields.Where(field => !field.CanKeepSeparate))
            Assert.Throws<InvalidOperationException>(() => field.Choose(LinkedFieldChoice.KeepSeparate));
        foreach (var field in draft.Fields.Where(field => !field.IsResolved))
            field.Choose(LinkedFieldChoice.ThisDevice);

        var choices = draft.ToChoices();
        Assert.Null(choices.Identification.Brand);
        Assert.Null(choices.Identification.Family);
        Assert.Null(choices.Identification.Model);
    }

    [Fact]
    public void MatchingIdentificationStaysSharedByDefaultButCanBeKeptSeparate()
    {
        var (device, other) = Rows(Inventory());
        var identification = new DeviceClassificationOverride(Brand: "Same vendor", Family: "Same family", Model: "Same model");
        device.SetClassificationOverride(identification);
        other.SetClassificationOverride(identification);
        var draft = LinkedDeviceDraft.Create(device, other);
        foreach (var field in draft.Fields.Where(field => field.Differs))
            field.Choose(LinkedFieldChoice.ThisDevice);

        Assert.Equal("Same vendor", draft.ToChoices().Identification.Brand);
        Assert.Equal("Same family", draft.ToChoices().Identification.Family);
        Assert.Equal("Same model", draft.ToChoices().Identification.Model);
        foreach (var field in draft.Fields.Where(field => field.CanKeepSeparate))
        {
            field.Choose(LinkedFieldChoice.KeepSeparate);
            Assert.Null(field.Result);
            field.Choose(LinkedFieldChoice.OtherDevice);
            Assert.Equal(field.OtherText, field.Result);
            field.Choose(LinkedFieldChoice.KeepSeparate);
        }
        Assert.Null(draft.ToChoices().Identification.Brand);
        Assert.Null(draft.ToChoices().Identification.Family);
        Assert.Null(draft.ToChoices().Identification.Model);
    }

    [Theory]
    [InlineData(2, LinkedFieldChoice.KeepSeparate)]
    [InlineData(3, LinkedFieldChoice.KeepSeparate)]
    [InlineData(4, LinkedFieldChoice.KeepSeparate)]
    [InlineData(2, LinkedFieldChoice.ThisDevice)]
    [InlineData(2, LinkedFieldChoice.OtherDevice)]
    public async Task IdentificationChoicesPersistWithoutChangingMembers(int memberCount, LinkedFieldChoice choice)
    {
        const string fourth = "001122AA0004";
        var original = Scan(Inventory(), 1, Result(fourth, "192.0.2.13"));
        original = original with
        {
            Classifications = original.Devices.Keys.ToDictionary(mac => mac,
                mac => new DeviceClassificationOverride(Brand: $"Vendor {mac}", Family: $"Family {mac}", Model: $"Model {mac}")),
            Devices = original.Devices.ToDictionary(pair => pair.Key,
                pair => pair.Value with { Imported = new(Brand: "Imported vendor", Family: "Imported family", Model: "Imported model") })
        };
        var data = memberCount == 2 ? original : original.LinkDevices(A, B, Choices(), Start);
        if (memberCount == 4) data = data.LinkDevices(C, fourth, Choices("Other group") with
        {
            Identification = new(Brand: "Other group vendor", Family: "Other group family", Model: "Other group model")
        }, Start);
        var target = memberCount == 2 ? B : C;
        var device = ScanResultRow.ForDevice(data.Devices[A], data);
        var other = ScanResultRow.ForDevice(data.Devices[target], data);
        var draft = LinkedDeviceDraft.Create(device, other);
        foreach (var field in draft.Fields)
        {
            if (field.CanKeepSeparate) field.Choose(choice);
            else if (field.Differs) field.Choose(LinkedFieldChoice.ThisDevice);
        }
        var expected = draft.ToChoices().Identification;
        var linked = data.LinkDevices(A, target, draft.ToChoices(), Start.AddDays(1));
        var path = Path.Combine(_directory, "device-inventory.json");
        await new DeviceInventoryStore(path).SaveAsync(linked, Guid.Empty);
        var loaded = await new DeviceInventoryStore(path).LoadAsync();

        Assert.NotNull(loaded);
        var group = Assert.Single(loaded.LinkedDevices);
        Assert.Equal(memberCount, group.Members.Count);
        Assert.Equal(expected, group.Identification);
        Assert.Equal(expected, group.Confirmed.Identification);
        if (choice == LinkedFieldChoice.KeepSeparate)
            Assert.All(group.Members, member =>
            {
                var row = ScanResultRow.ForDevice(loaded.Devices[member.Mac], loaded);
                Assert.Equal("-", row.BrandText);
                Assert.Equal("-", row.FamilyText);
                Assert.Equal("-", row.ModelText);
            });
        else
        {
            var source = choice == LinkedFieldChoice.ThisDevice ? device : other;
            Assert.Equal(source.BrandText, expected.Brand);
            Assert.Equal(source.FamilyText, expected.Family);
            Assert.Equal(source.ModelText, expected.Model);
        }
        foreach (var mac in original.Devices.Keys)
        {
            Assert.Equal(original.Classifications[mac], loaded.Classifications[mac]);
            Assert.Equal(original.Devices[mac].Imported, loaded.Devices[mac].Imported);
        }
        var unlinked = loaded.UnlinkDevice(B);
        Assert.Equal(original.Classifications[B], unlinked.Classifications[B]);
        var detached = ScanResultRow.ForDevice(unlinked.Devices[B], unlinked);
        Assert.Equal(original.Classifications[B].Brand, detached.BrandText);
        Assert.Equal(original.Classifications[B].Family, detached.FamilyText);
        Assert.Equal(original.Classifications[B].Model, detached.ModelText);
        if (memberCount == 2 && choice == LinkedFieldChoice.KeepSeparate)
        {
            var remaining = ScanResultRow.ForDevice(unlinked.Devices[A], unlinked);
            Assert.Equal(original.Classifications[A].Brand, remaining.BrandText);
            Assert.Equal(original.Classifications[A].Family, remaining.FamilyText);
            Assert.Equal(original.Classifications[A].Model, remaining.ModelText);
        }
    }

    [Fact]
    public void MatchingAutomaticUsageStaysAutomaticButMatchingManualCategoriesAreKept()
    {
        var data = Inventory() with { Names = new Dictionary<string, string>(), Classifications = new Dictionary<string, DeviceClassificationOverride>(),
            PeopleRooms = new PeopleRoomsData([Person], [Room]) };
        var (device, other) = Rows(data with { Devices = data.Devices.ToDictionary(pair => pair.Key, pair => pair.Value with { UsageCategoryOverride = null }) });
        device.SetUsageCategory(null, Inference(device, DeviceUsageCategory.Permanent), "ready");
        other.SetUsageCategory(null, Inference(other, DeviceUsageCategory.Permanent), "ready");

        var automatic = LinkedDeviceDraft.Create(device, other);
        automatic[LinkedField.Name]!.Choose(LinkedFieldChoice.ThisDevice);
        Assert.Null(automatic.ToChoices().UsageCategoryOverride);

        other.SetUsageCategory(DeviceUsageCategory.Permanent, other.UsageInference, "ready");
        var manual = LinkedDeviceDraft.Create(device, other);
        manual[LinkedField.Name]!.Choose(LinkedFieldChoice.ThisDevice);
        Assert.False(manual[LinkedField.UsageCategory]!.Differs);
        Assert.Equal(DeviceUsageCategory.Permanent, manual.ToChoices().UsageCategoryOverride);
    }

    [Fact]
    public void PickerListsSuggestionsFirstThenOtherRecordsAndLinkedDevicesAndTagsDeclinedPairs()
    {
        var data = Scan(Inventory(), 1, Result(A, "192.0.2.10"), Result(B, "192.0.2.11"), Result(C, "192.0.2.12"),
            Result("001122AA0004", "192.0.2.13"), Result("001122AA0005", "192.0.2.14"), Result(Private, "192.0.2.20", "Private"));
        data = data with { Names = new Dictionary<string, string> { [A] = "Alpha", [B] = "Bravo", [C] = "Charlie",
            ["001122AA0004"] = "Delta", ["001122AA0005"] = "Echo" } };
        data = data.DeclineMatch(A, C).LinkDevices("001122AA0004", "001122AA0005", Choices(), Start);
        var rows = ScanResultRow.CreateInventoryRows(data).ToArray();
        var alpha = rows.Single(row => row.IdentityKey == A);
        alpha.SetMatchSuggestions([new(A, B, DeviceMatchReason.SameName, string.Empty)], string.Empty);

        var candidates = LinkedDevicePresentation.Candidates(alpha, rows, data);

        Assert.Equal([B, C, "001122AA0004"], candidates.Select(item => item.Mac));
        Assert.True(candidates[0].IsSuggested);
        Assert.False(candidates[0].Declined);
        Assert.True(candidates[1].Declined);
        Assert.EndsWith("· Declined", LinkedDevicePresentation.CandidateText(candidates[1]));
        Assert.Equal(2, candidates[2].MacCount);
        Assert.EndsWith("· 2 MAC addresses", LinkedDevicePresentation.CandidateText(candidates[2]));
        Assert.Equal([C], LinkedDevicePresentation.Candidates(alpha, rows, data, "char").Select(item => item.Mac));
        Assert.Equal([C], LinkedDevicePresentation.Candidates(alpha, rows, data, "00:11:22:AA:00:03").Select(item => item.Mac));
        Assert.Equal(["001122AA0004"], LinkedDevicePresentation.Candidates(alpha, rows, data, "00-11-22-AA-00-05")
            .Select(item => item.Mac));

        // A linked device is offered every other record, never its own members; a suggestion via any member counts once.
        var group = rows.Single(row => row.IsLinkedDeviceRow);
        group.SetMatchSuggestions([new("001122AA0005", C, DeviceMatchReason.SameName, string.Empty)], string.Empty);
        Assert.Equal([C, A, B], LinkedDevicePresentation.Candidates(group, rows, data).Select(item => item.Mac));
        alpha.SetMatchSuggestions([new(A, "001122AA0005", DeviceMatchReason.SameName, string.Empty)], string.Empty);
        var suggestedGroup = LinkedDevicePresentation.Candidates(alpha, rows, data)[0];
        Assert.Equal(("001122AA0005", true, 2), (suggestedGroup.Mac, suggestedGroup.IsSuggested, suggestedGroup.MacCount));
        Assert.Single(LinkedDevicePresentation.Candidates(alpha, rows, data), item => item.MacCount == 2);
    }

    [Fact]
    public void SectionHeadersDescribeEachState()
    {
        var data = Scan(Inventory(), 1, Result(A, "192.0.2.10"), Result(B, "192.0.2.11"), Result(Private, "192.0.2.20", "Private"))
            .LinkDevices(A, B, Choices(), Start);
        var rows = ScanResultRow.CreateInventoryRows(data).ToArray();
        var plain = rows.Single(row => row.IdentityKey == C);

        Assert.Equal(new MergeSectionHeader(MergeSectionState.Linked, "2 MAC addresses", LinkedDevicePresentation.LinkedExplanation),
            LinkedDevicePresentation.Header(rows.Single(row => row.IsLinkedDeviceRow), data));
        Assert.Equal(MergeSectionState.Unavailable, LinkedDevicePresentation.Header(rows.Single(row => row.IsVirtualIdentity), data).State);
        Assert.Equal(LinkedDevicePresentation.VirtualExplanation, LinkedDevicePresentation.Header(rows.Single(row => row.IsVirtualIdentity), data).Explanation);
        Assert.Equal("No suggestions", LinkedDevicePresentation.Header(plain, data).Text);
        plain.SetMatchSuggestions([new(C, A, DeviceMatchReason.SameName, ""), new(C, B, DeviceMatchReason.SameName, "")], "");
        Assert.Equal(new MergeSectionHeader(MergeSectionState.PossibleMatches, "2 possible matches", string.Empty),
            LinkedDevicePresentation.Header(plain, data));
        var linkedRow = rows.Single(row => row.IsLinkedDeviceRow);
        linkedRow.SetMatchSuggestions([new(A, C, DeviceMatchReason.SameName, "")], "");
        var mixed = LinkedDevicePresentation.Header(linkedRow, data);
        Assert.Equal((MergeSectionState.LinkedWithMatches, "2 MAC addresses", "1 possible match", "2 MAC addresses · 1 possible match"),
            (mixed.State, mixed.CountText, mixed.MatchText, mixed.Text));
    }

    private static (ScanResultRow Device, ScanResultRow Other) Rows(DeviceInventoryData data)
    {
        var rows = ScanResultRow.CreateInventoryRows(data).ToDictionary(row => row.IdentityKey);
        foreach (var row in rows.Values)
        {
            var assignment = data.GetAssignment(row.IdentityKey);
            row.SetPeopleRoomAssignments(assignment?.PersonId, assignment?.PersonId is null ? null : Person.ShortName,
                assignment?.PersonId is null ? null : Person.Name, assignment?.RoomId,
                assignment?.RoomId is null ? null : Room.ShortName, assignment?.RoomId is null ? null : Room.Name);
        }
        return (rows[A], rows[B]);
    }

    private static DeviceUsageInference Inference(ScanResultRow row, DeviceUsageCategory category) =>
        new(row.UsageIdentity!, category, new(1, 1), new(1, 1), new(0, 0), 7, false,
            DateOnly.FromDateTime(Start.Date), DateOnly.FromDateTime(Start.Date), "home", "192.0.2.0/24", "UTC");

    private static void Execute(string jsonPath, string sql, params (string Name, object Value)[] parameters)
    {
        using var connection = new SqliteConnection($"Data Source={Path.ChangeExtension(jsonPath, ".sqlite")};Pooling=False");
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        foreach (var (name, value) in parameters) command.Parameters.AddWithValue(name, value);
        command.ExecuteNonQuery();
    }

    private static object? Scalar(string jsonPath, string sql)
    {
        using var connection = new SqliteConnection($"Data Source={Path.ChangeExtension(jsonPath, ".sqlite")};Pooling=False");
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        return command.ExecuteScalar();
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }
}
