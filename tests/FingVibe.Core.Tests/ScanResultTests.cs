using System.Net;
using System.Net.NetworkInformation;
using FingVibe.Core.Models;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class ScanResultTests
{
    private static readonly ScanResult Result = new(
        IPAddress.Parse("192.168.1.42"),
        HostStatus.Alive,
        17,
        TimeSpan.FromMilliseconds(20),
        "office-printer",
        PhysicalAddress.Parse("AABBCCDDEEFF"),
        "Example Devices",
        [new OpenPort(443, "HTTPS")]);

    [Theory]
    [InlineData("")]
    [InlineData("  ")]
    [InlineData("PRINTER")]
    [InlineData("192.168.1")]
    [InlineData("example devices")]
    [InlineData("443")]
    [InlineData("https")]
    [InlineData("ALIVE")]
    [InlineData("17 ms")]
    [InlineData("bb-cc")]
    public void MatchesFilter_ReturnsTrueForEveryDisplayedField(string filter)
    {
        Assert.True(Result.MatchesFilter(filter));
    }

    [Fact]
    public void MatchesFilter_ReturnsFalseWhenNoDisplayedFieldMatches()
    {
        Assert.False(Result.MatchesFilter("not present"));
    }
}
