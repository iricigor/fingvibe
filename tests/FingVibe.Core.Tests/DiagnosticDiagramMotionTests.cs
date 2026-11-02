using FingVibe.App;
using FingVibe.Core.Models;
using System.Xml.Linq;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class DiagnosticDiagramMotionTests
{
    [Fact]
    public void OverlaySizeAndRoutesMatchTheRenderedDiagram()
    {
        var document = XDocument.Load(Path.Combine(AppContext.BaseDirectory, "NetworkTroubleshootingPage.xaml"));
        XNamespace xaml = "http://schemas.microsoft.com/winfx/2006/xaml";
        var canvas = document.Descendants().Single(element => (string?)element.Attribute(xaml + "Name") == "DiagramCanvas");
        var dot = canvas.Elements().Single(element => (string?)element.Attribute(xaml + "Name") == "DiagramDot");
        Assert.Equal(DiagnosticDiagramMotion.DotSize.ToString(), (string?)dot.Attribute("Width"));
        Assert.Equal(DiagnosticDiagramMotion.DotSize.ToString(), (string?)dot.Attribute("Height"));
        Assert.Equal("Collapsed", (string?)dot.Attribute("Visibility"));
        Assert.Equal("False", (string?)dot.Attribute("IsHitTestVisible"));
        Assert.Equal("Raw", (string?)dot.Attribute("AutomationProperties.AccessibilityView"));
        Assert.Equal(new[]
        {
            "M165,198 H355", "M435,198 H625", "M687,198 H825", "M865,198 H985",
            "M885,198 V138 Q885,130 893,130 H984 Q992,130 992,122 V55"
        }, canvas.Elements().Where(element => element.Name.LocalName == "Path")
            .Take(5).Select(element => (string?)element.Attribute("Data")));
        Assert.Single(canvas.Elements(), element => (string?)element.Attribute(xaml + "Name") == "DiagramDot");
    }

    [Fact]
    public void ShortChecksAreQueuedAndResultsDoNotSkipOutboundMotion()
    {
        var motion = new DiagnosticDiagramMotion();
        motion.Observe(DiagnosticCheckpoint.Gateway, DiagnosticState.Running);
        motion.Observe(DiagnosticCheckpoint.Gateway, DiagnosticState.Responded);
        motion.Observe(DiagnosticCheckpoint.GooglePing, DiagnosticState.Running);
        motion.Observe(DiagnosticCheckpoint.GooglePing, DiagnosticState.Unanswered);
        Assert.Equal(6, DiagnosticDiagramMotion.DotSize);
        Assert.Equal(DiagnosticCheckpoint.Gateway, motion.Checkpoint);
        Assert.Equal(DiagnosticState.Running, motion.State);
        Assert.Equal(0, motion.Progress);
        motion.Advance(0.1);
        Assert.InRange(motion.Progress, 0.01, 0.99);
        Advance(motion, 0.92);
        Assert.Equal(DiagnosticCheckpoint.GooglePing, motion.Checkpoint);
        Advance(motion, 0.9);
        Assert.False(motion.HasWork);
        Assert.Null(motion.Checkpoint);
    }

    [Fact]
    public void PendingCheckWaitsAtTargetUntilActualResponseThenReturnsGreen()
    {
        var motion = new DiagnosticDiagramMotion();
        motion.Observe(DiagnosticCheckpoint.GooglePing, DiagnosticState.Running);
        Advance(motion, 10);
        Assert.Equal(1, motion.Progress);
        Assert.Equal(DiagnosticState.Running, motion.State);
        Assert.True(motion.HasWork);
        var pulse = motion.Pulse;
        motion.Advance(0.1);
        Assert.NotEqual(pulse, motion.Pulse);
        motion.Observe(DiagnosticCheckpoint.GooglePing, DiagnosticState.Responded);
        Assert.Equal(DiagnosticState.Responded, motion.State);
        Advance(motion, 0.3);
        Assert.InRange(motion.Progress, 0.01, 0.99);
        Assert.Equal(1, motion.Opacity);
        Assert.False(motion.ShowPulse);
        Advance(motion, 0.3);
        Assert.False(motion.HasWork);
    }

    [Theory]
    [InlineData(DiagnosticState.Unanswered)]
    [InlineData(DiagnosticState.Error)]
    public void FailureFadesAtTargetWithoutFabricatingAReturn(DiagnosticState state)
    {
        var motion = new DiagnosticDiagramMotion();
        motion.Observe(DiagnosticCheckpoint.CloudflareDns, DiagnosticState.Running);
        motion.Observe(DiagnosticCheckpoint.CloudflareDns, state);
        Advance(motion, 0.6);
        Assert.Equal(state, motion.State);
        Assert.Equal(1, motion.Progress);
        Assert.InRange(motion.Opacity, 0.1, 0.9);
        Advance(motion, 0.3);
        Assert.False(motion.HasWork);
    }

    [Theory]
    [InlineData(DiagnosticCheckpoint.Loopback)]
    [InlineData(DiagnosticCheckpoint.LocalAddress)]
    [InlineData(DiagnosticCheckpoint.ConfiguredDns)]
    public void LocalChecksHaveNoTravelingDot(DiagnosticCheckpoint checkpoint)
    {
        var motion = new DiagnosticDiagramMotion();
        motion.Observe(checkpoint, DiagnosticState.Running);
        Assert.True(motion.IsLocal);
    }

    [Fact]
    public void ResetClearsActiveAndQueuedWorkAndLateResultsDoNotRestartIt()
    {
        var motion = new DiagnosticDiagramMotion();
        motion.Observe(DiagnosticCheckpoint.Gateway, DiagnosticState.Running);
        motion.Observe(DiagnosticCheckpoint.GooglePing, DiagnosticState.Running);
        motion.Reset();
        motion.Observe(DiagnosticCheckpoint.Gateway, DiagnosticState.Responded);
        motion.Advance(1);
        Assert.False(motion.HasWork);
        Assert.Equal(0, motion.Progress);
        motion.Observe(DiagnosticCheckpoint.GoogleDns, DiagnosticState.Running);
        Assert.Equal(DiagnosticCheckpoint.GoogleDns, motion.Checkpoint);
        Assert.Equal(0, motion.Progress);
    }

    [Fact]
    public void DuplicateRunningEventsDoNotQueueTheSameCheckTwice()
    {
        var motion = new DiagnosticDiagramMotion();
        motion.Observe(DiagnosticCheckpoint.Hop2, DiagnosticState.Running);
        motion.Observe(DiagnosticCheckpoint.Hop2, DiagnosticState.Running);
        motion.Observe(DiagnosticCheckpoint.Hop2, DiagnosticState.Responded);
        Advance(motion, 1.1);
        Assert.False(motion.HasWork);
    }

    [Fact]
    public void ProviderPingAndDnsKeepIndependentOutcomes()
    {
        var motion = new DiagnosticDiagramMotion();
        motion.Observe(DiagnosticCheckpoint.GooglePing, DiagnosticState.Running);
        motion.Observe(DiagnosticCheckpoint.GooglePing, DiagnosticState.Responded);
        motion.Observe(DiagnosticCheckpoint.GoogleDns, DiagnosticState.Running);
        motion.Observe(DiagnosticCheckpoint.GoogleDns, DiagnosticState.Error);
        Advance(motion, 0.6);
        Assert.Equal(DiagnosticCheckpoint.GooglePing, motion.Checkpoint);
        Assert.Equal(DiagnosticState.Responded, motion.State);
        Advance(motion, 0.96);
        Assert.Equal(DiagnosticCheckpoint.GoogleDns, motion.Checkpoint);
        Assert.Equal(DiagnosticState.Error, motion.State);
        Assert.Equal(1, motion.Progress);
    }

    [Theory]
    [InlineData(DiagnosticCheckpoint.Gateway, 355, 198)]
    [InlineData(DiagnosticCheckpoint.RouterWan, 355, 198)]
    [InlineData(DiagnosticCheckpoint.Hop2, 625, 198)]
    [InlineData(DiagnosticCheckpoint.GooglePing, 985, 198)]
    [InlineData(DiagnosticCheckpoint.GoogleDns, 985, 198)]
    [InlineData(DiagnosticCheckpoint.CloudflarePing, 992, 55)]
    [InlineData(DiagnosticCheckpoint.CloudflareDns, 992, 55)]
    public void RoutesFollowConnectorsAndEndAtTheCorrectBranch(DiagnosticCheckpoint checkpoint, double x, double y)
    {
        Assert.Equal((165d, 198d), DiagnosticDiagramMotion.Position(checkpoint, 0));
        var end = DiagnosticDiagramMotion.Position(checkpoint, 1);
        Assert.Equal(x, end.X, 6);
        Assert.Equal(y, end.Y, 6);
        var previousX = 0d;
        var previousY = 198d;
        for (var index = 0; index <= 1000; index++)
        {
            var point = DiagnosticDiagramMotion.Position(checkpoint, index / 1000d);
            Assert.True(point.X >= previousX - 0.000001);
            Assert.True(point.Y <= previousY + 0.000001);
            Assert.InRange(point.Y, 55, 198);
            Assert.False(point.X > 355 && point.X < 435, "Do not draw traffic over the router icon.");
            Assert.False(point.X > 625 && point.X < 687, "Do not draw traffic over the hop icon.");
            Assert.False(point.X > 825 && point.X < 865, "Do not draw traffic over the internet icon.");
            previousX = point.X;
            previousY = point.Y;
        }
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(double.NaN)]
    [InlineData(double.PositiveInfinity)]
    public void InvalidElapsedTimeIsRejected(double seconds) =>
        Assert.Throws<ArgumentOutOfRangeException>(() => new DiagnosticDiagramMotion().Advance(seconds));

    [Theory]
    [InlineData(-0.1)]
    [InlineData(1.1)]
    [InlineData(double.NaN)]
    public void InvalidRouteProgressIsRejected(double progress) =>
        Assert.Throws<ArgumentOutOfRangeException>(() => DiagnosticDiagramMotion.Position(DiagnosticCheckpoint.GooglePing, progress));

    private static void Advance(DiagnosticDiagramMotion motion, double seconds)
    {
        while (seconds > 0.000001)
        {
            var step = Math.Min(seconds, 0.02);
            motion.Advance(step);
            seconds -= step;
        }
    }
}
