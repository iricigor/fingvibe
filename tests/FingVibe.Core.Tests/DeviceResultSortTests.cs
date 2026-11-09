using System.Net;
using System.Net.NetworkInformation;
using FingVibe.App;
using FingVibe.Core.Models;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class DeviceResultSortTests
{
    public static IEnumerable<object[]> ColumnsAndDirections() =>
        Enum.GetNames<ResultSortColumn>().SelectMany(column => new[] { new object[] { column, true }, [column, false] });

    [Theory]
    [MemberData(nameof(ColumnsAndDirections))]
    public void EqualPrimaryKeys_UseMacBeforeIp(string columnName, bool ascending)
    {
        var column = Enum.Parse<ResultSortColumn>(columnName);
        var lowMac = Row("10.0.0.20", "001122334401");
        var highMac = Row("10.0.0.2", "001122334402");
        if (column == ResultSortColumn.Address)
            highMac = Row(lowMac.AddressText, "001122334402");
        if (column == ResultSortColumn.MacAddress)
            highMac = Row("10.0.0.30", "001122334401");

        AssertOrder(lowMac, highMac, column, ascending);
    }

    [Theory]
    [MemberData(nameof(ColumnsAndDirections))]
    public void EqualMacs_UseNumericIp(string columnName, bool ascending)
    {
        AssertOrder(Row("10.0.0.2"), Row("10.0.0.10"), Enum.Parse<ResultSortColumn>(columnName), ascending);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void NewPrimaryKeys_SortDisplayedNamesVendorsAndNumericPortCounts(bool ascending)
    {
        var first = Row("10.0.0.20", "001122334402", "alpha", "Private/Randomized", 2);
        var second = Row("10.0.0.2", "001122334401", "Bravo", "Private Zebra", 10);
        AssertOrder(first, second, ResultSortColumn.Name, ascending);
        AssertOrder(second, first, ResultSortColumn.Vendor, ascending);
        AssertOrder(first, second, ResultSortColumn.OpenPorts, ascending);
        first.SetCustomName("Zulu");
        AssertOrder(second, first, ResultSortColumn.Name, ascending);
        AssertOrder(Row(ports: 0), first, ResultSortColumn.OpenPorts, ascending);
    }

    [Theory]
    [InlineData("Name")]
    [InlineData("Vendor")]
    [InlineData("Person")]
    [InlineData("Room")]
    public void TextKeys_AreCaseInsensitive(string columnName)
    {
        var first = Row("10.0.0.20", "001122334401", "alpha", "alpha");
        var second = Row("10.0.0.2", "001122334402", "ALPHA", "ALPHA");
        Assign(first, "alpha", "Zulu");
        Assign(second, "ALPHA", "Alpha");
        AssertOrder(first, second, Enum.Parse<ResultSortColumn>(columnName), true);
        AssertOrder(first, second, Enum.Parse<ResultSortColumn>(columnName), false);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void Assignments_UseFullNamesAndKeepUnassignedLast(bool ascending)
    {
        var first = Row("10.0.0.20", "001122334403");
        var second = Row("10.0.0.10", "001122334402");
        var unassigned = Row("10.0.0.2", "001122334401");
        Assign(first, "Alpha", "Z");
        Assign(second, "Zulu", "A");
        foreach (var column in new[] { ResultSortColumn.Person, ResultSortColumn.Room })
        {
            AssertOrder(first, second, column, ascending);
            Assert.Equal(-1, DeviceResultSort.Compare(first, unassigned, column, ascending));
            Assert.Equal(1, DeviceResultSort.Compare(unassigned, first, column, ascending));
            Assert.Equal(0, DeviceResultSort.Compare(unassigned, unassigned, column, ascending));
        }
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void ExistingKeys_RetainPrimarySemantics(bool ascending)
    {
        var first = new ScanResultRow(new ScanResult(IPAddress.Parse("10.0.0.2"), HostStatus.Alive, null,
            TimeSpan.Zero, MacAddress: PhysicalAddress.Parse("001122334401"),
            Classification: new(DeviceOperatingSystem.Android, DeviceType.Computer)), 24);
        var second = new ScanResultRow(new ScanResult(IPAddress.Parse("10.0.0.10"), HostStatus.Unreachable, 10,
            TimeSpan.Zero, MacAddress: PhysicalAddress.Parse("001122334402"),
            Classification: new(DeviceOperatingSystem.Windows, DeviceType.Router)), 24);
        foreach (var column in new[] { ResultSortColumn.Address, ResultSortColumn.Status, ResultSortColumn.Response,
            ResultSortColumn.MacAddress, ResultSortColumn.OperatingSystem, ResultSortColumn.DeviceType })
            AssertOrder(first, second, column, ascending);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void LastSeen_UsesTimestampsAndKeepsMissingValuesLastInBothDirections(bool ascending)
    {
        var start = new DateTimeOffset(2026, 11, 1, 12, 0, 0, TimeSpan.Zero);
        var older = Row("10.0.0.30", "001122334405");
        var newer = Row("10.0.0.20", "001122334404");
        var current = Row("10.0.0.10", "001122334403");
        var unavailable = Row("10.0.0.2", "001122334401");
        var imported = Row("10.0.0.1", "001122334402");
        older.SetLastSeen(new(DeviceLastSeenKind.Timestamp, start, "older", "older"));
        newer.SetLastSeen(new(DeviceLastSeenKind.Timestamp, start.AddHours(1), "newer", "newer"));
        current.SetLastSeen(new(DeviceLastSeenKind.SeenThisScan, start.AddHours(2), "Online", "current"));
        unavailable.SetLastSeen(DeviceLastSeen.Unavailable("none"));
        imported.SetLastSeen(new(DeviceLastSeenKind.NeverLocally, null, "Never", "imported"));

        AssertOrder(older, newer, ResultSortColumn.LastSeen, ascending);
        AssertOrder(newer, current, ResultSortColumn.LastSeen, ascending);
        var rows = new List<ScanResultRow> { imported, unavailable, current, older, newer };
        rows.Sort((left, right) => DeviceResultSort.Compare(left, right, ResultSortColumn.LastSeen, ascending));
        Assert.Equal(ascending ? new[] { older, newer, current, unavailable, imported }
            : new[] { current, newer, older, unavailable, imported }, rows);
        Assert.Equal(-1, DeviceResultSort.Compare(older, unavailable, ResultSortColumn.LastSeen, ascending));
        Assert.Equal(-1, DeviceResultSort.Compare(unavailable, imported, ResultSortColumn.LastSeen, ascending));
        Assert.Equal(0, DeviceResultSort.Compare(imported, imported, ResultSortColumn.LastSeen, ascending));
        var otherUnavailable = Row("10.0.0.2", "001122334400");
        otherUnavailable.SetLastSeen(DeviceLastSeen.Unavailable("other reason"));
        AssertOrder(otherUnavailable, unavailable, ResultSortColumn.LastSeen, ascending);
    }

    [Fact]
    public void MissingTextAndAddresses_KeepLexicalAndMissingAddressBehavior()
    {
        var missing = new ScanResultRow(new InventoryDevice("001122334401",
            new ImportedDeviceMetadata(Name: "-", Address: "-", Brand: "Unknown"), []), 24);
        var known = Row(name: "Alpha", vendor: "Acme");
        AssertOrder(missing, known, ResultSortColumn.Name, true);
        AssertOrder(known, missing, ResultSortColumn.Vendor, true);
        AssertOrder(missing, known, ResultSortColumn.Address, true);
        AssertOrder(Row("10.0.0.2"), Row("::1"), ResultSortColumn.Address, true);
        AssertOrder(Row("::1"), Row("::10"), ResultSortColumn.Address, true);
    }

    [Theory]
    [MemberData(nameof(ColumnsAndDirections))]
    public void MissingMacs_StillUseNumericIpAndDeterministicTies(string columnName, bool ascending)
    {
        var column = Enum.Parse<ResultSortColumn>(columnName);
        var first = Row("10.0.0.2", mac: null);
        var second = Row("10.0.0.10", mac: null);
        AssertOrder(first, second, column, ascending);
        Assert.Equal(0, DeviceResultSort.Compare(first, first, column, ascending));
        if (column != ResultSortColumn.Address)
            AssertOrder(first, Row("10.0.0.1"), column, ascending);
    }

    [Fact]
    public void FilterAndUpdatedRows_AreReorderedUsingTheSameSort()
    {
        var first = Row(name: "Bravo", ports: 1);
        var second = Row("10.0.0.2", name: "Alpha", ports: 1);
        var excluded = Row("10.0.0.3", name: "Aardvark");
        var rows = new List<ScanResultRow> { first, second, excluded };
        var filter = new DeviceResultFilter(false, true, string.Empty);
        List<ScanResultRow> Refresh()
        {
            var visible = rows.Where(filter.Matches).ToList();
            visible.Sort((left, right) => DeviceResultSort.Compare(left, right, ResultSortColumn.Name, false));
            return visible;
        }
        Assert.Equal(new[] { first, second }, Refresh());
        second.SetCustomName("Zulu");
        Assert.Equal(new[] { second, first }, Refresh());
        var added = Row("10.0.0.4", name: "Charlie", ports: 2);
        rows.Add(added);
        Assert.Equal(new[] { second, added, first }, Refresh());
        Assert.DoesNotContain(excluded, Refresh());
    }

    [Fact]
    public void UpdatedAssignmentsAndVendor_AreUsedWithoutCaching()
    {
        var first = Row(vendor: "Zulu");
        var second = Row("10.0.0.2", vendor: "Bravo");
        AssertOrder(second, first, ResultSortColumn.Vendor, true);
        first.SetClassificationOverride(new(Brand: "Alpha"));
        AssertOrder(first, second, ResultSortColumn.Vendor, true);
        Assign(first, "Zulu", "A");
        Assign(second, "Bravo", "Z");
        AssertOrder(second, first, ResultSortColumn.Person, true);
        Assign(first, "Alpha", "A");
        AssertOrder(first, second, ResultSortColumn.Person, true);
        AssertOrder(first, second, ResultSortColumn.Room, true);
    }

    private static ScanResultRow Row(string address = "10.0.0.1", string? mac = "001122334401",
        string name = "Same", string vendor = "Same", int ports = 0) =>
        new(new ScanResult(IPAddress.Parse(address), HostStatus.Alive, 10, TimeSpan.Zero,
            name, mac is null ? null : PhysicalAddress.Parse(mac), vendor,
            Enumerable.Range(1, ports).Select(port => new OpenPort(port, "Service")).ToArray()), 24);

    private static void Assign(ScanResultRow row, string fullName, string shortName) =>
        row.SetPeopleRoomAssignments(Guid.NewGuid(), shortName, fullName, Guid.NewGuid(), shortName, fullName);

    private static void AssertOrder(ScanResultRow first, ScanResultRow second, ResultSortColumn column, bool ascending)
    {
        Assert.Equal(ascending ? -1 : 1, DeviceResultSort.Compare(first, second, column, ascending));
        Assert.Equal(ascending ? 1 : -1, DeviceResultSort.Compare(second, first, column, ascending));
    }
}
