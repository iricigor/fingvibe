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
}
