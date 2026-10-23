using FingVibe.App;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class OverviewScanContextTests
{
    private static readonly DateTimeOffset ObservedAt = new(2026, 10, 23, 20, 0, 0, TimeSpan.Zero);

    [Fact]
    public void CompletedResults_RefreshAgeWithoutChangingObservation()
    {
        var context = new OverviewScanContext("192.168.0.0/24", ObservedAt, ScanDisplayStatus.Completed);

        Assert.Equal("Updated 15 minutes ago", context.Freshness(ObservedAt.AddMinutes(15)));
        Assert.Equal("Updated 1 hour ago", context.Freshness(ObservedAt.AddHours(1)));
        Assert.Contains("completed", context.Describe(context.Subnet));
        Assert.DoesNotContain("not for", context.Describe(context.Subnet));
        Assert.Equal(ObservedAt, context.ObservedAt);
    }

    [Theory]
    [InlineData("10.0.0.0/24")]
    [InlineData(null)]
    public void DifferentOrMissingTarget_ExplicitlyScopesRestoredResults(string? selectedSubnet)
    {
        var context = new OverviewScanContext("192.168.0.0/24", ObservedAt, ScanDisplayStatus.Completed);

        Assert.Contains("Results for 192.168.0.0/24", context.Describe(selectedSubnet));
        Assert.Contains("not for the selected scan target", context.Describe(selectedSubnet));
        Assert.Contains(selectedSubnet ?? "none", context.Describe(selectedSubnet));
    }

    [Theory]
    [InlineData(ScanDisplayStatus.Scanning, "in progress")]
    [InlineData(ScanDisplayStatus.Cancelled, "cancelled")]
    [InlineData(ScanDisplayStatus.Failed, "failed")]
    public void IncompleteScan_NeverClaimsCompletedFreshness(ScanDisplayStatus status, string expected)
    {
        var context = new OverviewScanContext("192.168.0.0/24", ObservedAt, status);

        Assert.Contains(expected, context.Freshness(ObservedAt.AddMinutes(15)));
        Assert.Contains("partial results", context.Freshness(ObservedAt));
        Assert.DoesNotContain("Updated", context.Freshness(ObservedAt));
        Assert.Contains("started", context.Describe(context.Subnet));
    }

    [Fact]
    public void FailedScan_PreservesFailureExplanation()
    {
        var context = new OverviewScanContext("0.0.0.0/0", ObservedAt, ScanDisplayStatus.Failed, "Subnet is too large.");

        Assert.Contains("Subnet is too large.", context.Describe(context.Subnet));
    }
}
