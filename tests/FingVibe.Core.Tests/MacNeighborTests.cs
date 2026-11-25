using System.Net;
using System.Net.NetworkInformation;
using FingVibe.Core.Networking;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class MacNeighborTests
{
    [Theory]
    [InlineData(0, false)]
    [InlineData(1, false)]
    [InlineData(2, true)]
    [InlineData(3, true)]
    [InlineData(4, true)]
    [InlineData(5, true)]
    [InlineData(6, true)]
    [InlineData(7, false)]
    public void NeighborState_MustBeUsable(int state, bool expected) =>
        Assert.Equal(expected, MacAddressResolver.IsUsableNeighbor([0x02, 0x11, 0x22, 0x33, 0x44, 0x55], state));

    [Theory]
    [InlineData(new byte[] { 0, 0, 0, 0, 0, 0 })]
    [InlineData(new byte[] { 255, 255, 255, 255, 255, 255 })]
    [InlineData(new byte[] { 1, 0, 0, 0, 0, 1 })]
    [InlineData(new byte[] { 2, 3 })]
    public void InvalidOrMulticastAddresses_AreRejected(byte[] address) =>
        Assert.False(MacAddressResolver.IsUsableNeighbor(address, 5));

    [Fact]
    public void LocalAddress_UsesExactOwningAdapterInsteadOfConflictingNeighbor()
    {
        var address = IPAddress.Parse("192.0.2.10");
        var otherMac = PhysicalAddress.Parse("001122334455");
        var localMac = PhysicalAddress.Parse("021122334466");
        var staleMac = PhysicalAddress.Parse("001122334477");
        var remoteCalls = 0;

        var result = MacAddressResolver.ResolveIPv4(address,
            [(IPAddress.Parse("192.0.2.11"), otherMac),
             (IPAddress.Parse("198.51.100.10"), otherMac),
             (address, localMac)], _ =>
            {
                remoteCalls++;
                return staleMac;
            });

        Assert.Equal(localMac, result);
        Assert.Equal(0, remoteCalls);
    }

    [Theory]
    [InlineData("")]
    [InlineData("000000000000")]
    [InlineData("FFFFFFFFFFFF")]
    [InlineData("010000000001")]
    [InlineData("0203")]
    public void LocalAddress_WithInvalidMac_DoesNotFallBackToNeighbor(string mac)
    {
        var address = IPAddress.Parse("192.0.2.10");
        var remoteCalls = 0;

        var result = MacAddressResolver.ResolveIPv4(address,
            [(address, PhysicalAddress.Parse(mac))], _ =>
            {
                remoteCalls++;
                return PhysicalAddress.Parse("001122334477");
            });

        Assert.Null(result);
        Assert.Equal(0, remoteCalls);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void RemoteAddress_PreservesRemoteResolution(bool hasMac)
    {
        var address = IPAddress.Parse("192.0.2.10");
        var remoteMac = hasMac ? PhysicalAddress.Parse("001122334477") : null;
        var remoteCalls = 0;

        var result = MacAddressResolver.ResolveIPv4(address,
            [(IPAddress.Parse("192.0.2.11"), PhysicalAddress.Parse("001122334455"))],
            destination =>
            {
                Assert.Equal(address, destination);
                remoteCalls++;
                return remoteMac;
            });

        Assert.Equal(remoteMac, result);
        Assert.Equal(1, remoteCalls);
    }

    [Fact]
    public void UnavailableAdapterMetadata_DoesNotFallBackToNeighbor()
    {
        var remoteCalls = 0;

        var result = MacAddressResolver.ResolveIPv4(IPAddress.Parse("192.0.2.10"),
            UnavailableAddresses(), _ =>
            {
                remoteCalls++;
                return PhysicalAddress.Parse("001122334477");
            });

        Assert.Null(result);
        Assert.Equal(0, remoteCalls);
    }

    private static IEnumerable<(IPAddress Address, PhysicalAddress MacAddress)> UnavailableAddresses()
    {
        yield return (IPAddress.Parse("192.0.2.11"), PhysicalAddress.Parse("001122334455"));
        throw new NetworkInformationException();
    }
}
