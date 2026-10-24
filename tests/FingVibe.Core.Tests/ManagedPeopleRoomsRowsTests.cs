using FingVibe.App;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class ManagedPeopleRoomsRowsTests
{
    [Fact]
    public void AssignedDeviceWithoutCurrentScan_IsShownByMacAndCanBeUnassigned()
    {
        var row = new AssignedDeviceListRow("AABBCCDDEEFF", null);

        Assert.Equal("Not observed in the last scan", row.NameText);
        Assert.Equal("-", row.AddressText);
        Assert.Equal("AA-BB-CC-DD-EE-FF", row.MacAddressText);
    }
}
