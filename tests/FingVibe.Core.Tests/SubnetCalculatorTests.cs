using System.Net;
using FingVibe.Core.Networking;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class SubnetCalculatorTests
{
    [Fact]
    public void GetNetworkAddress_ReturnsExpectedNetwork()
    {
        var network = SubnetCalculator.GetNetworkAddress(IPAddress.Parse("192.168.4.137"), 24);

        Assert.Equal(IPAddress.Parse("192.168.4.0"), network);
    }

    [Fact]
    public void GetBroadcastAddress_ReturnsExpectedBroadcast()
    {
        var broadcast = SubnetCalculator.GetBroadcastAddress(IPAddress.Parse("10.20.31.8"), 20);

        Assert.Equal(IPAddress.Parse("10.20.31.255"), broadcast);
    }

    [Fact]
    public void EnumerateUsableHosts_ExcludesNetworkAndBroadcast()
    {
        var hosts = SubnetCalculator
            .EnumerateUsableHosts(IPAddress.Parse("192.168.10.0"), 24)
            .ToArray();

        Assert.Equal(254, hosts.Length);
        Assert.Equal(IPAddress.Parse("192.168.10.1"), hosts[0]);
        Assert.Equal(IPAddress.Parse("192.168.10.254"), hosts[^1]);
    }

    [Fact]
    public void EnumerateUsableHosts_IncludesBothAddressesForPointToPointSubnet()
    {
        var hosts = SubnetCalculator
            .EnumerateUsableHosts(IPAddress.Parse("192.168.10.20"), 31)
            .ToArray();

        Assert.Equal(
            [IPAddress.Parse("192.168.10.20"), IPAddress.Parse("192.168.10.21")],
            hosts);
    }

    [Fact]
    public void EnumerateUsableHosts_RejectsUnsafeSubnetSize()
    {
        var hosts = SubnetCalculator.EnumerateUsableHosts(IPAddress.Parse("10.0.0.0"), 8);

        var exception = Assert.Throws<InvalidOperationException>(() => hosts.ToArray());
        Assert.Contains("65,534", exception.Message);
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(33)]
    public void GetUsableHostCount_RejectsInvalidPrefix(int prefixLength)
    {
        Assert.Throws<ArgumentOutOfRangeException>(
            () => SubnetCalculator.GetUsableHostCount(prefixLength));
    }
}
