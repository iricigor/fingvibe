using FingVibe.App;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class SpeedGaugeMotionTests
{
    [Theory]
    [InlineData(1, -90)]
    [InlineData(10, -54)]
    [InlineData(100, -18)]
    [InlineData(1000, 18)]
    [InlineData(10000, 54)]
    [InlineData(100000, 90)]
    [InlineData(1000000, 90)]
    public void FixedScaleMapsMbpsToLabeledTicks(double mbps, double expected)
    {
        var motion = new SpeedGaugeMotion();
        motion.SetBandwidth(mbps * 1_000_000);
        Assert.False(motion.Advance(0, false));
        Assert.Equal(expected, motion.Angle, 6);
    }

    [Fact]
    public void SamplesRetargetFromCurrentPositionWithoutResetOrOvershoot()
    {
        var motion = new SpeedGaugeMotion();
        motion.SetBandwidth(1000_000_000);
        Assert.True(motion.Advance(0.1, true));
        var previous = motion.Angle;
        Assert.InRange(previous, -89.99, 17.99);
        motion.SetBandwidth(2000_000_000);
        Assert.Equal(previous, motion.Angle);
        for (var i = 0; i < 200; i++)
        {
            motion.Advance(0.016, true);
            Assert.InRange(motion.Angle, previous, 28.8371);
            Assert.True(motion.Angle - previous < 10);
            previous = motion.Angle;
        }

        Assert.Equal(-90 + 36 * Math.Log10(2000), motion.Angle, 6);
        motion.SetBandwidth(100_000_000);
        Assert.Equal(previous, motion.Angle);
        motion.Advance(0.016, true);
        Assert.InRange(motion.Angle, -18, previous);
    }

    [Fact]
    public void IndependentGaugesRetainReadingsUntilExplicitReset()
    {
        var download = new SpeedGaugeMotion();
        var upload = new SpeedGaugeMotion();
        download.SetBandwidth(1000_000_000);
        download.Advance(0, false);
        upload.SetBandwidth(100_000_000);
        upload.Advance(0, false);
        Assert.Equal(18, download.Angle);
        Assert.Equal(-18, upload.Angle);
        upload.Reset();
        Assert.Equal(18, download.Angle);
        Assert.Equal(-90, upload.Angle);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(-1)]
    [InlineData(double.NaN)]
    [InlineData(double.PositiveInfinity)]
    public void RejectsInvalidMeasurements(double value)
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => new SpeedGaugeMotion().SetBandwidth(value));
    }
}
