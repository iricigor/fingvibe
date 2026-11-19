using System.Net;
using System.Net.NetworkInformation;
using FingVibe.App;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class LinkedDeviceRowTests : IDisposable
{
    private const string A = "001122AA0001";
    private const string B = "001122AA0002";
    private const string C = "001122AA0003";
    private const string Subnet = "192.0.2.0/24";
    private static readonly DateTimeOffset Start = new(2026, 11, 1, 12, 0, 0, TimeSpan.Zero);
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"fingvibe-linked-rows-{Guid.NewGuid():N}");

    private static ScanResult Result(string mac, string address, string vendor = "Example") =>
        new(IPAddress.Parse(address), HostStatus.Alive, 1, TimeSpan.FromMilliseconds(1), null, PhysicalAddress.Parse(mac), vendor);

    private static DeviceInventoryData Scan(DeviceInventoryData data, int minute, params ScanResult[] results) =>
        Scan(data, "home", minute, results);

    private static DeviceInventoryData Scan(DeviceInventoryData data, string network, int minute, params ScanResult[] results) =>
        data.ObserveCompletedScan(network, new(Subnet, Start.AddMinutes(minute), results));

    private static DeviceInventoryData Link(DeviceInventoryData data, params string[] macs)
    {
        var linked = data.LinkDevices(macs[0], macs[1], new("Work laptop",
            new(DeviceOperatingSystem.Windows, DeviceType.Computer, null, null, null, null), null, null), Start);
        if (macs.Length == 2) return linked;
        var device = linked.LinkedDevices[0];
        return linked with
        {
            LinkedDevices = [device with { Members = [.. device.Members, .. macs.Skip(2).Select(mac => new LinkedDeviceMember(mac, Start))] }]
        };
    }

    private static string? Representative(DeviceInventoryData data, string network = "home") =>
        data.LinkedDevices[0].Representatives.SingleOrDefault(item => item.NetworkId == network)?.Mac;

    [Fact]
    public void TheRepresentativeStaysWhileOnlineThenMovesToAnOnlineOrMostRecentMember()
    {
        var data = Link(Scan(DeviceInventoryData.Empty, 0, Result(A, "192.0.2.10"), Result(B, "192.0.2.11")), B, A);

        data = Scan(data, 1, Result(A, "192.0.2.10"), Result(B, "192.0.2.11"));
        Assert.Equal(A, Representative(data));
        data = Scan(data, 2, Result(B, "192.0.2.11"));
        Assert.Equal(B, Representative(data));
        data = Scan(data, 3, Result(A, "192.0.2.10"), Result(B, "192.0.2.11"));
        Assert.Equal(B, Representative(data));
        // Nobody responded: the most recently seen member, with an exact tie broken by MAC.
        data = Scan(data, 4);
        Assert.Equal(A, Representative(data));
        data = Scan(data, 5, Result(B, "192.0.2.11"));
        data = Scan(data, 6);
        Assert.Equal(B, Representative(data));
        Assert.Equal(B, LinkedDeviceRepresentatives.Select(data.LinkedDevices[0], data, "home", Subnet, null));
    }

    [Fact]
    public void EachNetworkKeepsItsOwnRepresentativeAndUnseenMembersAreNotCandidates()
    {
        var data = Link(Scan(DeviceInventoryData.Empty, 0, Result(A, "192.0.2.10"), Result(B, "192.0.2.11")), A, B);
        data = Scan(data, "office", 1, Result(B, "192.0.2.50"));
        data = Scan(data, "home", 2, Result(A, "192.0.2.10"));

        Assert.Equal(B, Representative(data, "office"));
        Assert.Equal(A, Representative(data, "home"));
        Assert.Null(LinkedDeviceRepresentatives.Select(data.LinkedDevices[0], data, "cafe", Subnet, null));
        var office = Scan(data, "office", 3);
        Assert.Equal(B, Representative(office, "office"));
    }

    [Fact]
    public async Task RepresentativesSurviveRestarts()
    {
        var path = Path.Combine(_directory, "device-inventory.json");
        var store = new DeviceInventoryStore(path);
        var data = await store.SaveAsync(Scan(DeviceInventoryData.Empty, 0, Result(A, "192.0.2.10"), Result(B, "192.0.2.11")), Guid.Empty);
        data = await store.SaveAsync(Scan(Link(data, A, B), 1, Result(B, "192.0.2.11")), data.Revision);

        var restarted = (await new DeviceInventoryStore(path).LoadAsync())!;

        Assert.Equal(new LinkedDeviceRepresentative("home", Subnet, B), Assert.Single(restarted.LinkedDevices[0].Representatives));
        Assert.Equal(B, ScanResultRow.ForLinkedDevice(restarted.LinkedDevices[0], restarted).RepresentativeMac);
    }

    [Fact]
    public void ALinkedDeviceIsOneRowWhoseNetworkValuesComeFromOneMember()
    {
        var data = Link(Scan(DeviceInventoryData.Empty, 0, Result(A, "192.0.2.10", "Adapter A"),
            Result(B, "192.0.2.11", "Adapter B"), Result(C, "192.0.2.12")), A, B);
        data = Scan(data, 1, Result(B, "192.0.2.11", "Adapter B"), Result(C, "192.0.2.12"));

        var rows = ScanResultRow.CreateInventoryRows(data).ToArray();
        var row = Assert.Single(rows, item => item.IsLinkedDeviceRow);

        Assert.Equal(2, rows.Length);
        Assert.Equal(data.LinkedDevices[0].Id.ToString("D"), row.IdentityKey);
        Assert.Equal(B, row.RepresentativeMac);
        Assert.Equal("192.0.2.11", row.AddressText);
        Assert.Equal("00-11-22-AA-00-02", row.MacAddressText);
        Assert.Equal("Adapter B", row.Result!.VendorName);
        Assert.True(row.IsOnline);
        Assert.Equal("Work laptop", row.NameText);
        Assert.False(row.UsesVirtualIcon);
        row.SetMacExpansionState(expanded: true);
        var line = Assert.Single(row.VisibleMacExpansionLines);
        Assert.Equal(("Linked MAC address", "192.0.2.10", "00-11-22-AA-00-01", "Offline"), (line.Label, line.Address, line.Mac, line.Status));
    }

    [Fact]
    public void ChevronLinesListOnlineMembersFirstAndSummarizeTheRest()
    {
        string[] macs = [A, B, C, "001122AA0004", "001122AA0005", "001122AA0006"];
        var data = Scan(DeviceInventoryData.Empty, 0, macs.Select((mac, index) => Result(mac, $"192.0.2.{10 + index}")).ToArray());
        data = Scan(Link(data, macs), 1, Result("001122AA0006", "192.0.2.15"), Result(C, "192.0.2.12"));

        var row = ScanResultRow.CreateInventoryRows(data).Single(item => item.IsLinkedDeviceRow);
        row.SetMacExpansionState(expanded: true);

        Assert.Equal(C, row.RepresentativeMac);
        Assert.Equal(5, row.EarlierMacAddressCount);
        Assert.Equal(["00-11-22-AA-00-06", "00-11-22-AA-00-01", "00-11-22-AA-00-02"], row.VisibleMacExpansionLines.Select(item => item.Mac));
        Assert.Equal("Online", row.VisibleMacExpansionLines[0].Status);
        Assert.Equal("+2 more MAC addresses · full list in Device Details", row.MoreMacAddressesText);
    }

    [Fact]
    public void SearchFindsTheRowByAnyMemberMacOrAddressAndExpandsHiddenMatches()
    {
        var data = Link(Scan(DeviceInventoryData.Empty, 0, Result(A, "192.0.2.10"), Result(B, "192.0.2.11")), A, B);
        data = Scan(data, "office", 1, Result(B, "192.0.2.77"));
        data = Scan(data, "home", 2, Result(A, "192.0.2.10"));
        var row = ScanResultRow.CreateInventoryRows(data).Single(item => item.IsLinkedDeviceRow);

        Assert.Equal(A, row.RepresentativeMac);
        foreach (var search in new[] { "00-11-22-AA-00-02", "001122AA0002", "192.0.2.77", "192.0.2.11" })
        {
            Assert.True(row.MatchesFilter(search), search);
            row.SetMacExpansionState(expanded: false, search);
            Assert.True(row.SearchExpandsMacAddresses, search);
        }
        row.SetMacExpansionState(expanded: false, "192.0.2.10");
        Assert.True(row.MatchesFilter("192.0.2.10"));
        Assert.False(row.SearchExpandsMacAddresses);
        Assert.False(row.MatchesFilter("192.0.2.99"));
    }

    [Fact]
    public void LastSeenUsesTheLatestMemberOnTheSelectedNetworkOnly()
    {
        var data = Link(Scan(DeviceInventoryData.Empty, 0, Result(A, "192.0.2.10"), Result(B, "192.0.2.11")), A, B);
        data = Scan(data, "office", 30, Result(B, "192.0.2.11"));
        data = Scan(data, "home", 10, Result(A, "192.0.2.10"));
        var row = ScanResultRow.CreateInventoryRows(data).Single(item => item.IsLinkedDeviceRow);

        Assert.Equal(Start.AddMinutes(10), row.GetHistorySummary("home", Subnet).LastSeen);
        Assert.Equal(Start, row.GetHistorySummary("home", Subnet).FirstSeen);
        Assert.Equal(Start.AddMinutes(30), row.GetHistorySummary("office", Subnet).LastSeen);
    }

    [Fact]
    public void AMemberFirstSeenLocallyIsNotAnnouncedAsNew()
    {
        var known = Scan(DeviceInventoryData.Empty, 0, Result(A, "192.0.2.10"));
        known = known with { Devices = new Dictionary<string, InventoryDevice>(known.Devices) { [B] = new(B, new(Name: "Dock"), []) } };
        var linked = Link(known, A, B);
        var scan = new ScanSnapshot(Subnet, Start.AddMinutes(1), [Result(A, "192.0.2.10"), Result(B, "192.0.2.11"), Result(C, "192.0.2.12")]);

        var discoveries = DeviceDiscovery.FindNewDevices(linked, linked.ObserveCompletedScan("home", scan), "home", scan);

        Assert.Equal([C], discoveries.Select(item => item.Mac));
        Assert.Equal([B, C], DeviceDiscovery.FindNewDevices(known, known.ObserveCompletedScan("home", scan), "home", scan)
            .Select(item => item.Mac));
    }

    [Fact]
    public void DeviceDetailsMarksTheRepresentativeShownInDevices()
    {
        var data = Link(Scan(DeviceInventoryData.Empty, 0, Result(A, "192.0.2.10"), Result(B, "192.0.2.11")), A, B);
        data = Scan(data, 1, Result(B, "192.0.2.11"));

        var lines = LinkedDevicePresentation.Members(data.LinkedDevices[0], data, B);

        Assert.False(lines[0].IsShownInDevices);
        Assert.EndsWith("· Shown in Devices", lines[1].Text);
        Assert.StartsWith("00-11-22-AA-00-02 · 192.0.2.11 · Example · Online · linked", lines[1].Text);
    }

    [Fact]
    public void PeopleAndRoomsCountALinkedDeviceOnce()
    {
        var room = new ManagedRoom(Guid.NewGuid(), "Office", "OF");
        var data = Scan(DeviceInventoryData.Empty, 0, Result(A, "192.0.2.10"), Result(B, "192.0.2.11"))
            with { PeopleRooms = new PeopleRoomsData([], [room]) };
        data = data.LinkDevices(A, B, new("Work laptop", new(), new(null, room.Id), null), Start);
        var row = ScanResultRow.CreateInventoryRows(data).Single(item => item.IsLinkedDeviceRow);

        var assigned = PeopleRoomsPresentation.AssignedTo(data.PeopleRooms, [new(row.IdentityKey, row)], null, room.Id);

        Assert.Single(assigned);
        Assert.Equal("1 device", PeopleRoomsPresentation.DeviceCount(assigned.Count));
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }
}
