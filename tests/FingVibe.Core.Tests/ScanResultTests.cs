using System.Net;
using FingVibe.Core.Models;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class ScanResultTests
{
    private static readonly ScanResult Result = new(
        IPAddress.Parse("192.168.1.42"),
        HostStatus.Alive,
        17,
        "AA-BB-CC-DD-EE-FF",
        TimeSpan.FromMilliseconds(20));

    [Theory]
    [InlineData("")]
    [InlineData("  ")]
    [InlineData("192.168.1")]
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
