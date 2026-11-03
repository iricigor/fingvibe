using FingVibe.App;
using FingVibe.Core.Models;
using System.Xml.Linq;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class DiagnosticDiagramMotionTests
{
    [Fact]
    public void ThreeDecorativeOverlaysAndRoutesMatchTheRenderedDiagram()
    {
        var document = XDocument.Load(Path.Combine(AppContext.BaseDirectory, "NetworkTroubleshootingPage.xaml"));
        XNamespace xaml = "http://schemas.microsoft.com/winfx/2006/xaml";
        var canvas = document.Descendants().Single(element => (string?)element.Attribute(xaml + "Name") == "DiagramCanvas");
        var dots = canvas.Elements().Where(element =>
            ((string?)element.Attribute(xaml + "Name"))?.StartsWith("DiagramDot") == true).ToArray();
        Assert.Equal(DiagnosticDiagramMotion.DotCount, dots.Length);
        Assert.All(dots, dot =>
        {
            Assert.Equal(DiagnosticDiagramMotion.DotSize.ToString(), (string?)dot.Attribute("Width"));
            Assert.Equal(DiagnosticDiagramMotion.DotSize.ToString(), (string?)dot.Attribute("Height"));
        });
        var pulses = canvas.Elements().Where(element =>
            ((string?)element.Attribute(xaml + "Name"))?.StartsWith("DiagramPulse") == true).ToArray();
        Assert.Equal(3, pulses.Length);
        Assert.All(dots.Concat(pulses), element =>
        {
            Assert.Equal("Collapsed", (string?)element.Attribute("Visibility"));
            Assert.Equal("False", (string?)element.Attribute("IsHitTestVisible"));
            Assert.Equal("Raw", (string?)element.Attribute("AutomationProperties.AccessibilityView"));
        });
        Assert.Equal(new[]
        {
            "M165,198 H355", "M435,198 H625", "M687,198 H825", "M865,198 H985",
            "M885,198 V138 Q885,130 893,130 H984 Q992,130 992,122 V55"
        }, canvas.Elements().Where(element => element.Name.LocalName == "Path")
            .Take(5).Select(element => (string?)element.Attribute("Data")));
        var peers = canvas.Elements().Single(element => (string?)element.Attribute(xaml + "Name") == "LanPeers");
        Assert.Equal("120", (string?)peers.Attribute("Width"));
        Assert.Equal("0.5", (string?)peers.Attribute("Opacity"));
        Assert.Equal(395, (double)peers.Attribute("Canvas.Left")! + (double)peers.Attribute("Width")! / 2);
        Assert.All(peers.Descendants().Where(element => element.Name.LocalName == "FontIcon"),
            icon => Assert.Equal("16", (string?)icon.Attribute("FontSize")));
        Assert.Contains(document.Descendants(), element =>
            (string?)element.Attribute("Text") == "Logical checks\u2014not a physical network map.");
    }

    [Fact]
    public void ThreeSlotsStartIndependentlyAndMoveInOppositeDirections()
    {
        var motion = new DiagnosticDiagramMotion(new DelayRandom(0, 0.6, 0.95));
        motion.BeginRun([Observation(DiagnosticCheckpoint.Gateway, DiagnosticState.Responded)]);
        Assert.Equal(3, motion.Dots.Count);
        Assert.Equal(0.2, motion.Dots[0].DelaySeconds, 6);
        Assert.Equal(1.04, motion.Dots[1].DelaySeconds, 6);
        Assert.Equal(1.53, motion.Dots[2].DelaySeconds, 6);
        motion.Advance(1.1);
        var reply = motion.Dots[0];
        var request = motion.Dots[1];
        Assert.True(reply.Returning);
        Assert.False(request.AtTarget);
        Assert.Null(motion.Dots[2].Checkpoint);
        var replyX = DiagnosticDiagramMotion.Position(reply.Checkpoint!.Value, reply.Progress).X;
        var requestX = DiagnosticDiagramMotion.Position(request.Checkpoint!.Value, request.Progress).X;
        motion.Advance(0.02);
        Assert.Equal(-DiagnosticDiagramMotion.Speed * 0.02,
            DiagnosticDiagramMotion.Position(reply.Checkpoint.Value, reply.Progress).X - replyX, 6);
        Assert.Equal(DiagnosticDiagramMotion.Speed * 0.02,
            DiagnosticDiagramMotion.Position(request.Checkpoint.Value, request.Progress).X - requestX, 6);
    }

    [Fact]
    public void SeededRandomDestinationsAndDelaysVaryAcrossRepeatedTrips()
    {
        var motion = new DiagnosticDiagramMotion(new Random(1337));
        var results = Enum.GetValues<DiagnosticCheckpoint>()
            .Select(checkpoint => Observation(checkpoint, DiagnosticState.Responded)).ToArray();
        motion.BeginRun(results);
        Assert.All(motion.Dots, dot => Assert.InRange(dot.DelaySeconds,
            DiagnosticDiagramMotion.MinimumDelaySeconds, DiagnosticDiagramMotion.MaximumDelaySeconds));
        motion.CompleteRun(results);
        var destinations = new HashSet<DiagnosticCheckpoint>();
        var delays = new HashSet<double>();
        var simultaneous = false;
        for (var index = 0; index < 30000; index++)
        {
            motion.Advance(0.02);
            Assert.True(motion.HasWork);
            simultaneous |= motion.Dots.All(dot => dot.Checkpoint is not null);
            foreach (var dot in motion.Dots)
            {
                if (dot.Checkpoint is { } checkpoint) destinations.Add(checkpoint);
                else delays.Add(Math.Round(dot.DelaySeconds, 3));
            }
        }
        Assert.Equal(results.Length, destinations.Count);
        Assert.True(delays.Count > 10);
        Assert.True(simultaneous);
        motion.Reset();
        Assert.False(motion.HasWork);
        Assert.All(motion.Dots, dot => Assert.Null(dot.Checkpoint));
    }

    [Theory]
    [InlineData(DiagnosticState.Running)]
    [InlineData(DiagnosticState.Untested)]
    public void PendingCheckWaitsAtTargetThenShowsAFullResponsePulse(DiagnosticState state)
    {
        var motion = Start(DiagnosticCheckpoint.GooglePing, state);
        motion.Advance(10);
        var dot = motion.Dots[0];
        Assert.Equal(1, dot.Progress);
        Assert.Equal(DiagnosticState.Running, dot.State);
        Assert.False(dot.Returning);
        var pulse = dot.Pulse;
        motion.Advance(0.1);
        Assert.NotEqual(pulse, dot.Pulse);
        motion.Observe(DiagnosticCheckpoint.GooglePing, DiagnosticState.Responded);
        motion.Advance(0);
        Assert.Equal(DiagnosticState.Responded, dot.State);
        Assert.Equal(8, dot.EndpointSize, 6);
        motion.Advance(DiagnosticDiagramMotion.PulseSeconds / 2);
        Assert.Equal(18, dot.EndpointSize, 6);
        motion.Advance(DiagnosticDiagramMotion.PulseSeconds / 2 + 0.1);
        Assert.True(dot.Returning);
        Assert.False(dot.ShowPulse);
        Assert.Equal(985 - DiagnosticDiagramMotion.Speed * 0.1,
            DiagnosticDiagramMotion.Position(DiagnosticCheckpoint.GooglePing, dot.Progress).X, 6);
    }

    [Theory]
    [InlineData(DiagnosticState.Unanswered)]
    [InlineData(DiagnosticState.Error)]
    public void FailureFadesAtTargetWithoutFabricatingAReturn(DiagnosticState state)
    {
        var motion = Start(DiagnosticCheckpoint.CloudflareDns, state);
        var dot = motion.Dots[0];
        motion.Advance(dot.TravelSeconds + DiagnosticDiagramMotion.PulseSeconds
            + DiagnosticDiagramMotion.FadeSeconds / 2);
        Assert.Equal(state, dot.State);
        Assert.Equal(1, dot.Progress);
        Assert.False(dot.Returning);
        Assert.InRange(dot.Opacity, 0.1, 0.9);
        motion.Advance(DiagnosticDiagramMotion.FadeSeconds / 2 + 0.01);
        Assert.Null(dot.Checkpoint);
        Assert.True(motion.HasWork);
        Assert.InRange(dot.DelaySeconds, 0, DiagnosticDiagramMotion.MaximumDelaySeconds);
    }

    [Theory]
    [InlineData(DiagnosticCheckpoint.Loopback)]
    [InlineData(DiagnosticCheckpoint.LocalAddress)]
    [InlineData(DiagnosticCheckpoint.ConfiguredDns)]
    public void LocalChecksOnlyPulseAtThePc(DiagnosticCheckpoint checkpoint)
    {
        var motion = Start(checkpoint, DiagnosticState.Responded);
        motion.Advance(0.4);
        Assert.All(motion.Dots, dot =>
        {
            Assert.True(dot.IsLocal);
            Assert.True(dot.ShowPulse);
            Assert.False(dot.Returning);
        });
    }

    [Fact]
    public void ProviderPingAndDnsKeepIndependentOutcomes()
    {
        var motion = new DiagnosticDiagramMotion(new Random(42));
        motion.BeginRun([
            Observation(DiagnosticCheckpoint.GooglePing, DiagnosticState.Responded),
            Observation(DiagnosticCheckpoint.GoogleDns, DiagnosticState.Error)
        ]);
        var observed = new HashSet<DiagnosticCheckpoint>();
        for (var index = 0; index < 5000; index++)
        {
            motion.Advance(0.02);
            foreach (var dot in motion.Dots.Where(dot => dot.AtTarget))
            {
                observed.Add(dot.Checkpoint!.Value);
                Assert.Equal(dot.Checkpoint == DiagnosticCheckpoint.GooglePing
                    ? DiagnosticState.Responded : DiagnosticState.Error, dot.State);
                if (dot.Checkpoint == DiagnosticCheckpoint.GoogleDns) Assert.False(dot.Returning);
            }
        }
        Assert.Equal(2, observed.Count);
    }

    [Fact]
    public void UnavailableOrCancelledTargetsAreSkippedAndCannotBlockReplay()
    {
        var motion = Start(DiagnosticCheckpoint.Hop2, DiagnosticState.Untested);
        motion.Advance(10);
        motion.CompleteRun([
            Observation(DiagnosticCheckpoint.Hop2, DiagnosticState.Unavailable),
            Observation(DiagnosticCheckpoint.RouterWan, DiagnosticState.Cancelled),
            Observation(DiagnosticCheckpoint.GoogleDns, DiagnosticState.Responded)
        ]);
        Assert.All(motion.Dots, dot => Assert.Null(dot.Checkpoint));
        motion.Advance(0.3);
        Assert.All(motion.Dots, dot => Assert.Equal(DiagnosticCheckpoint.GoogleDns, dot.Checkpoint));
        motion.CompleteRun([]);
        Assert.False(motion.HasWork);
        Assert.All(motion.Dots, dot => Assert.Null(dot.Checkpoint));
    }

    [Fact]
    public void ResetIgnoresLateEventsAndNewRunDiscardsOldTrips()
    {
        var motion = Start(DiagnosticCheckpoint.Gateway, DiagnosticState.Responded);
        motion.Reset();
        motion.Observe(DiagnosticCheckpoint.Gateway, DiagnosticState.Running);
        motion.CompleteRun([Observation(DiagnosticCheckpoint.Gateway, DiagnosticState.Responded)]);
        motion.Advance(100);
        Assert.False(motion.HasWork);
        Assert.All(motion.Dots, dot => Assert.Null(dot.Checkpoint));
        motion.BeginRun([]);
        Assert.False(motion.HasWork);
        motion.Observe(DiagnosticCheckpoint.GooglePing, DiagnosticState.Responded);
        motion.Advance(0.3);
        Assert.All(motion.Dots, dot => Assert.Equal(DiagnosticCheckpoint.GooglePing, dot.Checkpoint));
        motion.BeginRun([Observation(DiagnosticCheckpoint.Hop2, DiagnosticState.Responded)]);
        Assert.All(motion.Dots, dot => Assert.Null(dot.Checkpoint));
        motion.Advance(0.3);
        Assert.All(motion.Dots, dot => Assert.Equal(DiagnosticCheckpoint.Hop2, dot.Checkpoint));
    }

    [Theory]
    [InlineData(DiagnosticCheckpoint.Gateway, 355, 198)]
    [InlineData(DiagnosticCheckpoint.RouterWan, 355, 198)]
    [InlineData(DiagnosticCheckpoint.Hop2, 625, 198)]
    [InlineData(DiagnosticCheckpoint.GooglePing, 985, 198)]
    [InlineData(DiagnosticCheckpoint.GoogleDns, 985, 198)]
    [InlineData(DiagnosticCheckpoint.CloudflarePing, 992, 55)]
    [InlineData(DiagnosticCheckpoint.CloudflareDns, 992, 55)]
    public void RoutesFollowConnectorsAndHideIconCrossings(DiagnosticCheckpoint checkpoint, double x, double y)
    {
        var start = DiagnosticDiagramMotion.Position(checkpoint, 0);
        Assert.Equal((165d, 198d), (start.X, start.Y));
        var end = DiagnosticDiagramMotion.Position(checkpoint, 1);
        Assert.Equal(x, end.X, 6);
        Assert.Equal(y, end.Y, 6);
        var previousX = 165d;
        var previousY = 198d;
        var stepDistance = DiagnosticDiagramMotion.TravelTime(checkpoint) * DiagnosticDiagramMotion.Speed / 1000;
        for (var index = 0; index <= 1000; index++)
        {
            var point = DiagnosticDiagramMotion.Position(checkpoint, index / 1000d);
            Assert.True(point.X >= previousX - 0.000001);
            Assert.True(point.Y <= previousY + 0.000001);
            Assert.InRange(Math.Sqrt(Math.Pow(point.X - previousX, 2)
                + Math.Pow(point.Y - previousY, 2)), 0, stepDistance + 0.000001);
            if (point.Visible)
            {
                Assert.False(point.X > 355 && point.X < 435);
                Assert.False(point.X > 625 && point.X < 687);
                Assert.False(point.X > 825 && point.X < 865);
            }
            previousX = point.X;
            previousY = point.Y;
        }
    }

    [Theory]
    [InlineData(DiagnosticCheckpoint.Gateway)]
    [InlineData(DiagnosticCheckpoint.Hop2)]
    [InlineData(DiagnosticCheckpoint.GooglePing)]
    [InlineData(DiagnosticCheckpoint.CloudflareDns)]
    public void TravelSpeedIsConstantAcrossRoutesAndFrameIntervals(DiagnosticCheckpoint checkpoint)
    {
        var motion = Start(checkpoint, DiagnosticState.Responded);
        var dot = motion.Dots[0];
        motion.Advance(0.25);
        var first = DiagnosticDiagramMotion.Position(checkpoint, dot.Progress);
        Assert.Equal(165 + DiagnosticDiagramMotion.Speed * 0.25, first.X, 6);
        motion.Advance(0.03);
        var next = DiagnosticDiagramMotion.Position(checkpoint, dot.Progress);
        Assert.Equal(DiagnosticDiagramMotion.Speed * 0.03, next.X - first.X, 6);
    }

    [Fact]
    public void FartherTargetsTakeLongerAndIconGapsDoNotTeleport()
    {
        Assert.Equal(190 / DiagnosticDiagramMotion.Speed,
            DiagnosticDiagramMotion.TravelTime(DiagnosticCheckpoint.Gateway), 6);
        Assert.Equal(460 / DiagnosticDiagramMotion.Speed,
            DiagnosticDiagramMotion.TravelTime(DiagnosticCheckpoint.Hop2), 6);
        Assert.Equal(820 / DiagnosticDiagramMotion.Speed,
            DiagnosticDiagramMotion.TravelTime(DiagnosticCheckpoint.GooglePing), 6);
        Assert.True(DiagnosticDiagramMotion.TravelTime(DiagnosticCheckpoint.CloudflarePing)
            > DiagnosticDiagramMotion.TravelTime(DiagnosticCheckpoint.GooglePing));
        var inRouter = DiagnosticDiagramMotion.Position(DiagnosticCheckpoint.GooglePing, (395d - 165) / 820);
        Assert.Equal(395, inRouter.X, 6);
        Assert.False(inRouter.Visible);
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

    private static DiagnosticDiagramMotion Start(DiagnosticCheckpoint checkpoint, DiagnosticState state)
    {
        var motion = new DiagnosticDiagramMotion(new DelayRandom(0));
        motion.BeginRun([Observation(checkpoint, state)]);
        motion.Advance(DiagnosticDiagramMotion.MinimumDelaySeconds);
        return motion;
    }

    private static DiagnosticObservation Observation(DiagnosticCheckpoint checkpoint, DiagnosticState state) =>
        new(checkpoint, "test target", state, "test result");

    private sealed class DelayRandom(params double[] values) : Random
    {
        private int _index;
        public override double NextDouble() => values[_index++ % values.Length];
        public override int Next(int maxValue) => 0;
    }
}
