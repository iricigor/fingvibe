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
    public void UnlinkRejectsUnknownMacsAndMoreThanTwoMembers()
    {
        var original = Inventory();
        var linked = original.LinkDevices(A, B, Choices(), Start);
        var group = linked.LinkedDevices[0] with
        {
            Members = [.. linked.LinkedDevices[0].Members, new(C, Start)]
        };

        Assert.Throws<ArgumentException>(() => original.UnlinkDevice(A));
        Assert.Throws<InvalidOperationException>(() =>
            (linked with { LinkedDevices = [group] }).UnlinkDevice(A));
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
    public void LinkingRejectsInvalidPairsAndAlreadyLinkedOrVirtualRecords()
    {
        var data = Inventory();
        var linked = data.LinkDevices(A, B, Choices(), Start);

        Assert.Throws<ArgumentException>(() => data.LinkDevices(A, A, Choices(), Start));
        Assert.Throws<ArgumentException>(() => data.LinkDevices(A, "001122AA00FF", Choices(), Start));
        Assert.Throws<ArgumentException>(() => data.LinkDevices(A, C, Choices(" "), Start));
        Assert.Throws<InvalidOperationException>(() => linked.LinkDevices(C, B, Choices(), Start));
        var virtualData = Scan(data, 1, Result(Private, "192.0.2.20", "Private"));
        Assert.Contains(Private, virtualData.VirtualGroupedMacs());
        Assert.Throws<InvalidOperationException>(() => virtualData.LinkDevices(C, Private, Choices(), Start));
        Assert.Throws<ArgumentException>(() => data.LinkDevices(A, C,
            Choices() with { Assignment = new(Guid.NewGuid(), null) }, Start));
    }

    [Fact]
    public void LinkedMacsNeverJoinVirtualDevicesAndAreNotSuggested()
    {
        var data = Scan(DeviceInventoryData.Empty, 0, Result(A, "192.0.2.10"));
        data = data with { Devices = new Dictionary<string, InventoryDevice>(data.Devices)
            { [Private] = new(Private, new(), []) }, PeopleRooms = new([Person], [Room]) };
        var linked = data.LinkDevices(A, Private, Choices(), Start);

        var scanned = Scan(linked, 5, Result(A, "192.0.2.10"), Result(Private, "192.0.2.20", "Private"));

        Assert.Empty(scanned.VirtualDevices);
        Assert.False(PrivateVirtualDeviceAllocator.IsEligible(scanned, scanned.Devices[Private]));
        Assert.Contains(ScanResultRow.CreateInventoryRows(scanned), row => row.IdentityKey == Private);
        var named = linked with { Names = new Dictionary<string, string> { [A] = "same.local", [C] = "same.local" },
            Devices = new Dictionary<string, InventoryDevice>(linked.Devices) { [C] = scanned.Devices[A] with { Mac = C } } };
        Assert.False(DeviceMatchSuggestions.Find(named, new HashSet<string>()).ContainsKey(A));
        Assert.False(DeviceMatchSuggestions.Find(named, new HashSet<string>()).ContainsKey(C));
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

        var rows = ScanResultRow.CreateInventoryRows(linked).Where(row => row.IsLinked).ToArray();

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
    }

    [Fact]
    public void RoomMapShowsSharedValuesAndNeverAMembersHiddenType()
    {
        var linked = Inventory().LinkDevices(A, B, Choices(), Start);
        var automatic = linked.UpdateLinkedDevice(linked.LinkedDevices[0].Id,
            device => device with { Identification = device.Identification with { Type = null } });
        var network = new LanNetwork("Ethernet", IPAddress.Parse("192.0.2.5"), IPAddress.Parse("192.0.2.0"), 24,
            true, IPAddress.Parse("192.0.2.1"), "ethernet-test");

        var devices = RoomMapProjection.Create(automatic, network, "home").Devices
            .Where(device => device.IdentityKey is A or B).ToArray();

        Assert.Equal(2, devices.Length);
        Assert.All(devices, device =>
        {
            Assert.Equal("Work laptop", device.Name);
            Assert.Equal(DeviceType.Unknown, device.Type);
            Assert.Equal(Room.Id, device.RoomId);
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
    public void PickerListsSuggestionsFirstThenOtherUnlinkedRecordsAndTagsDeclinedPairs()
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

        Assert.Equal([B, C], candidates.Select(item => item.Mac));
        Assert.True(candidates[0].IsSuggested);
        Assert.False(candidates[0].Declined);
        Assert.True(candidates[1].Declined);
        Assert.EndsWith("· Declined", LinkedDevicePresentation.CandidateText(candidates[1]));
        Assert.Equal([C], LinkedDevicePresentation.Candidates(alpha, rows, data, "char").Select(item => item.Mac));
        Assert.Equal([C], LinkedDevicePresentation.Candidates(alpha, rows, data, "00:11:22:AA:00:03").Select(item => item.Mac));
    }

    [Fact]
    public void SectionHeadersDescribeEachState()
    {
        var data = Scan(Inventory(), 1, Result(A, "192.0.2.10"), Result(B, "192.0.2.11"), Result(Private, "192.0.2.20", "Private"))
            .LinkDevices(A, B, Choices(), Start);
        var rows = ScanResultRow.CreateInventoryRows(data).ToArray();
        var plain = rows.Single(row => row.IdentityKey == C);

        Assert.Equal(new MergeSectionHeader(MergeSectionState.Linked, "2 MAC addresses", LinkedDevicePresentation.LinkedExplanation),
            LinkedDevicePresentation.Header(rows.Single(row => row.IdentityKey == A), data));
        Assert.Equal(MergeSectionState.Unavailable, LinkedDevicePresentation.Header(rows.Single(row => row.IsVirtualIdentity), data).State);
        Assert.Equal(LinkedDevicePresentation.VirtualExplanation, LinkedDevicePresentation.Header(rows.Single(row => row.IsVirtualIdentity), data).Explanation);
        Assert.Equal("No suggestions", LinkedDevicePresentation.Header(plain, data).Text);
        plain.SetMatchSuggestions([new(C, A, DeviceMatchReason.SameName, ""), new(C, B, DeviceMatchReason.SameName, "")], "");
        Assert.Equal(new MergeSectionHeader(MergeSectionState.PossibleMatches, "2 possible matches", string.Empty),
            LinkedDevicePresentation.Header(plain, data));
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
