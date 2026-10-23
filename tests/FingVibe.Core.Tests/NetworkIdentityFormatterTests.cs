using System.Net;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class NetworkIdentityFormatterTests
{
    private static readonly LanNetwork Network = new(
        "Ethernet",
        IPAddress.Parse("192.168.0.42"),
        IPAddress.Parse("192.168.0.0"),
        24,
        true);

    [Fact]
    public void FormatSummary_CombinesIspAndLanCidr()
    {
        var identity = new PublicNetworkIdentity(
            IPAddress.Parse("203.0.113.10"),
            "Example ISP");

        var summary = NetworkIdentityFormatter.FormatSummary(Network, identity);

        Assert.Equal("Example ISP, 192.168.0.0/24", summary);
    }

    [Theory]
    [InlineData(1, "Example ISP, 192.168.0.0/24, 1 online device")]
    [InlineData(19, "Example ISP, 192.168.0.0/24, 19 online devices")]
    public void FormatSummary_AppendsOnlineDeviceCount(int count, string expected)
    {
        var identity = new PublicNetworkIdentity(
            IPAddress.Parse("203.0.113.10"),
            "Example ISP");

        var summary = NetworkIdentityFormatter.FormatSummary(Network, identity, count);

        Assert.Equal(expected, summary);
    }

    [Fact]
    public void FormatSummary_ExplainsUnavailableIsp()
    {
        var summary = NetworkIdentityFormatter.FormatSummary(Network, null);

        Assert.Equal("ISP unavailable, 192.168.0.0/24", summary);
    }

    [Theory]
    [InlineData("Novi Sad", "Vojvodina", "Serbia", "Novi Sad, Vojvodina, Serbia")]
    [InlineData(" ", null, "Serbia", "Serbia")]
    [InlineData("Belgrade", "belgrade", "Serbia", "Belgrade, Serbia")]
    public void FormatLocation_JoinsDistinctNonEmptyParts(
        string? city,
        string? region,
        string? country,
        string expected)
    {
        Assert.Equal(expected, NetworkIdentityFormatter.FormatLocation(city, region, country));
    }

    [Fact]
    public void FormatLocation_ReturnsNullWithoutParts()
    {
        Assert.Null(NetworkIdentityFormatter.FormatLocation(null, "", " "));
    }
}
