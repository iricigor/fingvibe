using FingVibe.App;
using FingVibe.Core.Models;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class ScanProgressPresentationTests
{
    [Theory]
    [InlineData(204, 36, 4)]
    [InlineData(44, 36, 4)]
    [InlineData(6, 6, 1)]
    public void BorderProgressUsesTheRoundedStrokeCenterline(double width, double height, double radius)
    {
        var expected = 2 * (width - 4 + height - 4 - 4 * radius) + 2 * Math.PI * radius;
        var perimeter = ScanProgressPresentation.BorderLength(width, height);
        Assert.Equal(expected, perimeter, 8);
        Assert.Equal(expected * 0.9, ScanProgressPresentation.FilledWidth(90, 100, perimeter), 8);
    }

    [Fact]
    public void UnmeasuredBorderHasNoProgressLength() =>
        Assert.Equal(0, ScanProgressPresentation.BorderLength(0, 0));

    [Theory]
    [InlineData(0, 254, 1000, 0)]
    [InlineData(127, 254, 1000, 500)]
    [InlineData(5, 100, 1000, 50)]
    [InlineData(90, 100, 1000, 900)]
    [InlineData(234, 254, 1016, 936)]
    [InlineData(254, 254, 1000, 1000)]
    [InlineData(300, 254, 1000, 1000)]
    [InlineData(-1, 254, 1000, 0)]
    [InlineData(0, 0, 1000, 0)]
    [InlineData(127, 254, 0, 0)]
    public void BorderFillRetainsTheMeasuredFraction(double completed, double maximum, double width, double expected)
    {
        Assert.Equal(expected, ScanProgressPresentation.FilledWidth(completed, maximum, width), 8);
    }

    [Theory]
    [InlineData(LanScanPhase.FirstPass, 0, 254, "Finding devices: 0 of 254 addresses checked")]
    [InlineData(LanScanPhase.FirstPass, 254, 254, "Finding devices: 254 of 254 addresses checked")]
    [InlineData(LanScanPhase.Arp, 0, 230, "Confirming remaining devices: address lookup, 0 of 230 unanswered addresses checked")]
    [InlineData(LanScanPhase.Arp, 230, 230, "Confirming remaining devices: address lookup, 230 of 230 unanswered addresses checked")]
    [InlineData(LanScanPhase.RetryWait, 0, 230, "Confirming remaining devices: waiting 10 seconds before trying unanswered addresses again")]
    [InlineData(LanScanPhase.Retry, 0, 230, "Confirming remaining devices: second try, 0 of 230 unanswered addresses checked")]
    [InlineData(LanScanPhase.Retry, 17, 230, "Confirming remaining devices: second try, 17 of 230 unanswered addresses checked")]
    [InlineData(LanScanPhase.FinalRetryWait, 0, 213, "Confirming remaining devices: waiting 10 seconds before the last try")]
    [InlineData(LanScanPhase.FinalRetry, 213, 213, "Confirming remaining devices: last try, 213 of 213 unanswered addresses checked")]
    public void ProgressMessageNamesTheUserFacingStageAndItsOwnCount(LanScanPhase phase, int completed, int total, string expected)
    {
        var message = ScanProgressPresentation.Message(new LanScanProgress(phase, completed, total));

        Assert.Equal(expected, message);
        Assert.DoesNotMatch(@"\(\d/\d\)|ARP|ICMP", message);
    }

    [Theory]
    [InlineData(LanScanPhase.FirstPass, 12, 254, "ICMP ping: 12/254 addresses")]
    [InlineData(LanScanPhase.Arp, 3, 230, "Background ARP: 3/230 ping misses")]
    [InlineData(LanScanPhase.RetryWait, 0, 230, "Waiting 10 seconds before ICMP attempt 2")]
    [InlineData(LanScanPhase.Retry, 17, 230, "ICMP attempt 2: 17/230 remaining misses")]
    [InlineData(LanScanPhase.FinalRetryWait, 0, 213, "Waiting 10 seconds before ICMP attempt 3")]
    [InlineData(LanScanPhase.FinalRetry, 213, 213, "ICMP attempt 3: 213/213 remaining misses")]
    public void ProgressDetailKeepsProtocolCounters(LanScanPhase phase, int completed, int total, string expected)
    {
        Assert.Equal(expected, ScanProgressPresentation.Detail(new LanScanProgress(phase, completed, total)));
    }

    [Theory]
    [InlineData(0, "0:00 elapsed")]
    [InlineData(9.9, "0:09 elapsed")]
    [InlineData(65, "1:05 elapsed")]
    [InlineData(3725, "62:05 elapsed")]
    [InlineData(-3, "0:00 elapsed")]
    public void ElapsedTimeIsShownWithoutAnEstimate(double seconds, string expected)
    {
        Assert.Equal(expected, ScanProgressPresentation.Elapsed(TimeSpan.FromSeconds(seconds)));
    }
}
