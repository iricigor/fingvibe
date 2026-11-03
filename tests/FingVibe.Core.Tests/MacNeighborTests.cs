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
}
