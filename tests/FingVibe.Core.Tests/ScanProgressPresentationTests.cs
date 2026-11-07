using FingVibe.App;
using FingVibe.Core.Models;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class ScanProgressPresentationTests
{
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
    public void PulseIsConfinedToActualCompletedWidth(double completed, double maximum, double width, double expected)
    {
        Assert.Equal(expected, ScanProgressPresentation.FilledWidth(completed, maximum, width), 8);
    }

    [Fact]
    public void PulseTravelsFromBeginningToReachedPointAndRepeats()
    {
        Assert.Equal(-0.25, ScanProgressPresentation.PulsePosition(TimeSpan.Zero), 8);
        Assert.Equal(0.5, ScanProgressPresentation.PulsePosition(TimeSpan.FromSeconds(0.9)), 8);
        Assert.InRange(ScanProgressPresentation.PulsePosition(TimeSpan.FromSeconds(1.799)), 1.24, 1.25);
        Assert.Equal(-0.25, ScanProgressPresentation.PulsePosition(TimeSpan.FromSeconds(1.8)), 8);
    }

    [Theory]
    [InlineData(LanScanPhase.FirstPass, 0, 254, "Scanning ICMP: 0/254 addresses")]
    [InlineData(LanScanPhase.FirstPass, 254, 254, "Scanning ICMP: 254/254 addresses")]
    [InlineData(LanScanPhase.Arp, 0, 230, "(1/5) Background ARP: 0/230 misses")]
    [InlineData(LanScanPhase.Arp, 230, 230, "(1/5) Background ARP: 230/230 misses")]
    [InlineData(LanScanPhase.RetryWait, 0, 230, "(2/5) Waiting 10 seconds before ICMP attempt 2")]
    [InlineData(LanScanPhase.Retry, 0, 230, "(3/5) Background ICMP attempt 2: 0/230 misses")]
    [InlineData(LanScanPhase.Retry, 17, 230, "(3/5) Background ICMP attempt 2: 17/230 misses")]
    [InlineData(LanScanPhase.FinalRetryWait, 0, 213, "(4/5) Waiting 10 seconds before ICMP attempt 3")]
    [InlineData(LanScanPhase.FinalRetry, 213, 213, "(5/5) Background ICMP attempt 3: 213/213 misses")]
    public void ProgressMessageNamesTheScanPhaseAndItsOwnCount(LanScanPhase phase, int completed, int total, string expected)
    {
        Assert.Equal(expected, ScanProgressPresentation.Message(new LanScanProgress(phase, completed, total)));
    }
}
