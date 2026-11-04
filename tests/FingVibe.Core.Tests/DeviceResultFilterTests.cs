using System.Net;
using FingVibe.App;
using FingVibe.Core.Models;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class DeviceResultFilterTests
{
    private static ScanResultRow Row(HostStatus status, bool hasPorts) => new(
        new ScanResult(
            IPAddress.Parse("192.168.0.1"), status, null, TimeSpan.Zero,
            DeviceName: "router.local",
            OpenPorts: hasPorts ? [new OpenPort(443, "HTTPS")] : []),
        24, "Kitchen router");

    [Theory]
    [InlineData(false, false, HostStatus.Alive, false, true)]
    [InlineData(false, false, HostStatus.Unreachable, false, true)]
    [InlineData(true, false, HostStatus.Unreachable, false, false)]
    [InlineData(true, false, HostStatus.Alive, false, true)]
    [InlineData(false, true, HostStatus.Alive, false, false)]
    [InlineData(false, true, HostStatus.Alive, true, true)]
    [InlineData(false, true, HostStatus.Unreachable, true, true)]
    [InlineData(true, true, HostStatus.Unreachable, true, false)]
    public void StatusAndPortFilters_Combine(
        bool alive, bool ports, HostStatus status, bool hasPorts, bool expected) =>
        Assert.Equal(expected, new DeviceResultFilter(alive, ports, "").Matches(Row(status, hasPorts)));

    [Theory]
    [InlineData(" kitchen ", true)]
    [InlineData("HTTPS", true)]
    [InlineData("router.local", true)]
    [InlineData("192.168.0.1", true)]
    [InlineData("missing", false)]
    public void TextFilter_PreservesCustomNamesAndServiceSearch(string text, bool expected) =>
        Assert.Equal(expected, new DeviceResultFilter(true, true, text).Matches(Row(HostStatus.Alive, true)));

    [Fact]
    public void AdditionalPortDiscovery_UpdatesFilterMembership()
    {
        var row = Row(HostStatus.Alive, false);
        var filter = new DeviceResultFilter(false, true, "");
        Assert.False(filter.Matches(row));

        row.UpdateOpenPorts([new OpenPort(443, "HTTPS")]);

        Assert.True(filter.Matches(row));
    }

    [Theory]
    [InlineData("Android")]
    [InlineData("Phone")]
    public void ClassificationOverrides_RemainSearchableWithPortFilter(string search)
    {
        var row = Row(HostStatus.Alive, true);
        row.SetClassificationOverride(new DeviceClassificationOverride(
            DeviceOperatingSystem.Android, DeviceType.Phone));

        Assert.True(new DeviceResultFilter(true, true, search).Matches(row));
        Assert.False(new DeviceResultFilter(true, true, search).Matches(Row(HostStatus.Alive, false)));
    }

    [Fact]
    public void PeopleAndRoomAssignments_AreSearchableAndFilterIndependently()
    {
        var personId = Guid.NewGuid();
        var roomId = Guid.NewGuid();
        var row = Row(HostStatus.Alive, true);
        row.SetPeopleRoomAssignments(personId, "AL", "Alex", roomId, "LR", "Living room");

        Assert.True(new DeviceResultFilter(false, false, "AL").Matches(row));
        Assert.True(new DeviceResultFilter(false, false, "Living room").Matches(row));
        Assert.True(new DeviceResultFilter(false, false, "", PersonId: personId).Matches(row));
        Assert.True(new DeviceResultFilter(false, false, "", RoomId: roomId).Matches(row));
        Assert.False(new DeviceResultFilter(false, false, "", PersonId: Guid.NewGuid()).Matches(row));
        Assert.False(new DeviceResultFilter(false, false, "", UnassignedPersonOnly: true).Matches(row));
    }

    [Theory]
    [InlineData(HostStatus.Alive, DeviceType.Phone, true)]
    [InlineData(HostStatus.Unreachable, DeviceType.Tablet, true)]
    [InlineData(HostStatus.Alive, DeviceType.Computer, false)]
    [InlineData(HostStatus.Unreachable, DeviceType.Router, false)]
    public void MultiSelect_UsesOrWithinAndBetweenCategories(HostStatus status, DeviceType type, bool expected)
    {
        var row = Row(status, true);
        row.SetClassificationOverride(new(DeviceOperatingSystem.Android, type));
        var filter = new DeviceResultFilter(false, true, "router")
        {
            Statuses = new HashSet<InventoryDeviceStatus> { InventoryDeviceStatus.Online, InventoryDeviceStatus.Offline },
            Types = new HashSet<DeviceType> { DeviceType.Phone, DeviceType.Tablet },
            OperatingSystems = new HashSet<DeviceOperatingSystem> { DeviceOperatingSystem.Android, DeviceOperatingSystem.IOS }
        };
        Assert.Equal(expected, filter.Matches(row));
        Assert.False((filter with { SearchText = "missing" }).Matches(row));
        Assert.False((filter with { OperatingSystems = new HashSet<DeviceOperatingSystem> { DeviceOperatingSystem.Windows } }).Matches(row));
        Assert.False(filter.Matches(Row(status, false)));
    }

    [Fact]
    public void MultiSelect_UnknownAndUnassignedCanCombineWithConcreteValues()
    {
        var person = Guid.NewGuid();
        var room = Guid.NewGuid();
        var filter = new DeviceResultFilter(false, false, "")
        {
            Types = new HashSet<DeviceType> { DeviceType.Unknown, DeviceType.Phone },
            OperatingSystems = new HashSet<DeviceOperatingSystem> { DeviceOperatingSystem.Unknown, DeviceOperatingSystem.Android },
            People = new HashSet<Guid?> { null, person },
            Rooms = new HashSet<Guid?> { null, room }
        };
        var row = Row(HostStatus.Alive, false);
        Assert.True(filter.Matches(row));
        row.SetClassificationOverride(new(DeviceOperatingSystem.Android, DeviceType.Phone));
        row.SetPeopleRoomAssignments(person, "A", "Alex", room, "K", "Kitchen");
        Assert.True(filter.Matches(row));
        row.SetPeopleRoomAssignments(Guid.NewGuid(), "B", "Blair", room, "K", "Kitchen");
        Assert.False(filter.Matches(row));
        row.SetPeopleRoomAssignments(person, "A", "Alex", Guid.NewGuid(), "L", "Living room");
        Assert.False(filter.Matches(row));
    }

    [Fact]
    public void ClassificationAndVendorFilters_UseEffectiveImportedAndOverriddenValues()
    {
        var row = new ScanResultRow(new InventoryDevice("001122334455",
            new ImportedDeviceMetadata(Type: "Phone", OperatingSystem: "Android", Brand: "Imported vendor"), []), 24);
        var imported = new DeviceResultFilter(false, false, "")
        {
            Statuses = new HashSet<InventoryDeviceStatus> { InventoryDeviceStatus.FingOnly, InventoryDeviceStatus.Unknown },
            Types = new HashSet<DeviceType> { DeviceType.Phone },
            OperatingSystems = new HashSet<DeviceOperatingSystem> { DeviceOperatingSystem.Android },
            Vendors = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "IMPORTED VENDOR", "Other vendor" }
        };
        Assert.True(imported.Matches(row));
        row.SetClassificationOverride(new(DeviceOperatingSystem.IOS, DeviceType.Tablet, Brand: "Corrected vendor"));
        Assert.False(imported.Matches(row));
        Assert.True((imported with
        {
            Types = new HashSet<DeviceType> { DeviceType.Tablet },
            OperatingSystems = new HashSet<DeviceOperatingSystem> { DeviceOperatingSystem.IOS },
            Vendors = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "Corrected vendor" }
        }).Matches(row));
    }

    [Fact]
    public void EmptyCategories_AreUnrestrictedAndCountOnlyActiveSecondaryCategories()
    {
        var row = Row(HostStatus.Alive, true);
        var unrestricted = new DeviceResultFilter(false, false, "");
        Assert.True(unrestricted.Matches(row));
        Assert.False(unrestricted.HasRestrictions);
        Assert.Equal(0, unrestricted.ActiveSecondaryCategoryCount);
        var primaryOnly = unrestricted with
        {
            SearchText = "router",
            Statuses = new HashSet<InventoryDeviceStatus> { InventoryDeviceStatus.Online, InventoryDeviceStatus.Offline }
        };
        Assert.True(primaryOnly.HasRestrictions);
        Assert.Equal(0, primaryOnly.ActiveSecondaryCategoryCount);
        var all = primaryOnly with
        {
            Types = new HashSet<DeviceType> { DeviceType.Unknown, DeviceType.Phone },
            OperatingSystems = new HashSet<DeviceOperatingSystem> { DeviceOperatingSystem.Unknown },
            Vendors = new HashSet<string> { "Unknown" },
            People = new HashSet<Guid?> { null },
            Rooms = new HashSet<Guid?> { null },
            OpenPortsOnly = true
        };
        Assert.True(all.Matches(row));
        Assert.Equal(6, all.ActiveSecondaryCategoryCount);
        Assert.False((all with { Statuses = new HashSet<InventoryDeviceStatus> { InventoryDeviceStatus.FingOnly } }).Matches(row));
        Assert.True((all with { Statuses = new HashSet<InventoryDeviceStatus>() }).Matches(row));
    }
}
