using FingVibe.App;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class NavigationPaneSizingTests
{
    [Theory]
    [InlineData(-100, false, 216)]
    [InlineData(48, false, 216)]
    [InlineData(159.999, false, 216)]
    [InlineData(160, true, 160)]
    [InlineData(216, true, 216)]
    [InlineData(320, true, 320)]
    [InlineData(500, true, 320)]
    public void ResizeUsesExactThresholdAndBounds(double requested, bool isOpen, double expandedWidth)
    {
        var sizing = new NavigationPaneSizing();

        Assert.Equal(isOpen, sizing.Resize(requested, 48));
        Assert.Equal(expandedWidth, sizing.ExpandedWidth);
    }

    [Fact]
    public void CollapseRetainsLastExpandedWidthAndDragCanExpandAgain()
    {
        var sizing = new NavigationPaneSizing();

        Assert.True(sizing.Resize(280, 48));
        Assert.False(sizing.Resize(159, 48));
        Assert.Equal(280, sizing.ExpandedWidth);
        Assert.False(sizing.Resize(80, 48));
        Assert.Equal(280, sizing.ExpandedWidth);
        Assert.True(sizing.Resize(160, 48));
        Assert.Equal(160, sizing.ExpandedWidth);
    }

    [Theory]
    [InlineData(-100, 48, false)]
    [InlineData(80, 80, false)]
    [InlineData(120, 120, false)]
    [InlineData(159, 159, false)]
    [InlineData(160, 160, true)]
    [InlineData(500, 320, true)]
    public void DragGuideTracksBoundedPointerEvenWhenIconsRemain(double requested, double guide, bool open)
    {
        var sizing = new NavigationPaneSizing();

        Assert.Equal(open, sizing.Resize(requested, 48, isDragging: true));
        Assert.Equal(guide, sizing.DragWidth);
        if (!open) Assert.Equal(NavigationPaneSizing.DefaultWidth, sizing.ExpandedWidth);
        sizing.CompleteDrag();
        Assert.Null(sizing.DragWidth);
    }

    [Fact]
    public void ContinuousDragCrossesThresholdWithoutLosingGuideOrRememberedWidth()
    {
        var sizing = new NavigationPaneSizing();
        Assert.False(sizing.Resize(100, 48, isDragging: true));
        Assert.Equal(100, sizing.DragWidth);
        Assert.True(sizing.Resize(240, 48, isDragging: true));
        Assert.False(sizing.Resize(120, 48, isDragging: true));
        Assert.Equal(120, sizing.DragWidth);
        Assert.Equal(240, sizing.ExpandedWidth);
        sizing.CompleteDrag();
        Assert.Null(sizing.DragWidth);
        Assert.Equal(240, sizing.ExpandedWidth);
    }

    [Theory]
    [InlineData(double.NaN)]
    [InlineData(double.PositiveInfinity)]
    [InlineData(double.NegativeInfinity)]
    public void InvalidWidthIsRejected(double width)
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => new NavigationPaneSizing().Resize(width, 48));
    }
}
