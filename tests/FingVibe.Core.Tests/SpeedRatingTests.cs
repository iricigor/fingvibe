using FingVibe.App;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class SpeedRatingTests
{
    [Theory]
    [InlineData(SpeedDirection.Download, 0, SpeedRatingLevel.Slow)]
    [InlineData(SpeedDirection.Download, 24.99, SpeedRatingLevel.Slow)]
    [InlineData(SpeedDirection.Download, 25, SpeedRatingLevel.Fair)]
    [InlineData(SpeedDirection.Download, 99.99, SpeedRatingLevel.Fair)]
    [InlineData(SpeedDirection.Download, 100, SpeedRatingLevel.Good)]
    [InlineData(SpeedDirection.Download, 20000, SpeedRatingLevel.Good)]
    [InlineData(SpeedDirection.Upload, 4.99, SpeedRatingLevel.Slow)]
    [InlineData(SpeedDirection.Upload, 5, SpeedRatingLevel.Fair)]
    [InlineData(SpeedDirection.Upload, 19.99, SpeedRatingLevel.Fair)]
    [InlineData(SpeedDirection.Upload, 20, SpeedRatingLevel.Good)]
    public void RatesEachDirectionAtTheAgreedBoundaries(SpeedDirection direction, double mbps, SpeedRatingLevel expected)
    {
        Assert.Equal(expected, SpeedRating.Rate(direction, mbps));
    }

    [Theory]
    [InlineData(24_996_000, 25, SpeedRatingLevel.Fair)]
    [InlineData(24_994_000, 24.99, SpeedRatingLevel.Slow)]
    [InlineData(99_996_000, 100, SpeedRatingLevel.Good)]
    public void RatingMatchesTheDisplayedTwoDecimalValue(double bps, double displayed, SpeedRatingLevel expected)
    {
        var mbps = SpeedRating.DisplayMbps(bps);
        Assert.Equal(displayed, mbps);
        Assert.Equal(expected, SpeedRating.Rate(SpeedDirection.Download, mbps));
    }

    [Theory]
    [InlineData(SpeedDirection.Download, 25, 100)]
    [InlineData(SpeedDirection.Upload, 5, 20)]
    public void GradientPlacesYellowBetweenTheThresholds(SpeedDirection direction, double fair, double good)
    {
        var (slow, middle, goodFraction) = SpeedRating.GradientFractions(direction);
        Assert.Equal(SpeedGaugeMotion.ScaleFraction(fair), slow, 9);
        Assert.Equal(SpeedGaugeMotion.ScaleFraction(good), goodFraction, 9);
        Assert.InRange(middle, slow + 1e-6, goodFraction - 1e-6);
        Assert.Equal((slow + goodFraction) / 2, middle, 9);
    }

    [Theory]
    [InlineData(0, 0)]
    [InlineData(0.5, 0)]
    [InlineData(1, 0)]
    [InlineData(10, 0.25)]
    [InlineData(100, 0.5)]
    [InlineData(1000, 0.75)]
    [InlineData(10000, 1)]
    [InlineData(250000, 1)]
    public void ScalePinsReadingsOutsideOneMbpsToTenGbps(double mbps, double expected)
    {
        Assert.Equal(expected, SpeedGaugeMotion.ScaleFraction(mbps), 9);
    }

    [Fact]
    public void ArcOffsetsFollowTheSemicircleFromLeftToRight()
    {
        Assert.Equal(0, SpeedGaugeMotion.ArcHorizontalOffset(0), 9);
        Assert.Equal(0.5, SpeedGaugeMotion.ArcHorizontalOffset(0.5), 9);
        Assert.Equal(1, SpeedGaugeMotion.ArcHorizontalOffset(1), 9);
        Assert.True(SpeedGaugeMotion.ArcHorizontalOffset(0.25) < 0.25);
    }

    [Fact]
    public void CaptionNamesTheDirectionThresholds()
    {
        Assert.Contains("Slow below 25 Mbps; Good from 100 Mbps", SpeedRating.ScaleCaption(SpeedDirection.Download));
        Assert.Contains("Slow below 5 Mbps; Good from 20 Mbps", SpeedRating.ScaleCaption(SpeedDirection.Upload));
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(double.NaN)]
    [InlineData(double.PositiveInfinity)]
    public void RejectsInvalidSpeeds(double value)
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => SpeedRating.Rate(SpeedDirection.Download, value));
        Assert.Throws<ArgumentOutOfRangeException>(() => SpeedRating.DisplayMbps(value));
    }
}
