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
        var request = canvas.Elements().Single(element => (string?)element.Attribute(xaml + "Name") == "DiagramRequestDot");
        Assert.Equal("8", (string?)request.Attribute("Width"));
        Assert.Equal("8", (string?)request.Attribute("Height"));
        Assert.Equal("Collapsed", (string?)request.Attribute("Visibility"));
        Assert.Equal("False", (string?)request.Attribute("IsHitTestVisible"));
        Assert.Equal("Raw", (string?)request.Attribute("AutomationProperties.AccessibilityView"));
        var endpoint = canvas.Elements().Single(element => (string?)element.Attribute(xaml + "Name") == "DiagramEndpoint");
        Assert.Equal("Collapsed", (string?)endpoint.Attribute("Visibility"));
        Assert.Equal("False", (string?)endpoint.Attribute("IsHitTestVisible"));
        Assert.Equal("Raw", (string?)endpoint.Attribute("AutomationProperties.AccessibilityView"));
    }

    [Fact]
    public void ShortChecksAreQueuedAndResultsDoNotSkipOutboundMotion()
    {
        var motion = new DiagnosticDiagramMotion();
        motion.Observe(DiagnosticCheckpoint.Gateway, DiagnosticState.Running);
        motion.Observe(DiagnosticCheckpoint.Gateway, DiagnosticState.Responded);
        motion.Observe(DiagnosticCheckpoint.GooglePing, DiagnosticState.Running);
        motion.Observe(DiagnosticCheckpoint.GooglePing, DiagnosticState.Unanswered);
        Assert.Equal(8, DiagnosticDiagramMotion.DotSize);
        Assert.Equal(DiagnosticCheckpoint.Gateway, motion.Checkpoint);
        Assert.Equal(DiagnosticState.Running, motion.State);
        Assert.Equal(0, motion.Progress);
        motion.Advance(0.1);
        Assert.InRange(motion.Progress, 0.01, 0.99);
        Advance(motion, 2 * DiagnosticDiagramMotion.TravelTime(DiagnosticCheckpoint.Gateway)
            + DiagnosticDiagramMotion.PulseSeconds - 0.1 + 0.02);
        Assert.Equal(DiagnosticCheckpoint.GooglePing, motion.Checkpoint);
        Advance(motion, DiagnosticDiagramMotion.TravelTime(DiagnosticCheckpoint.GooglePing)
            + DiagnosticDiagramMotion.PulseSeconds + DiagnosticDiagramMotion.FadeSeconds + 0.1);
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
        Advance(motion, DiagnosticDiagramMotion.PulseSeconds + 0.2);
        Assert.InRange(motion.Progress, 0.01, 0.99);
        Assert.Equal(1, motion.Opacity);
        Assert.False(motion.ShowPulse);
        Advance(motion, motion.TravelSeconds);
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
        Advance(motion, DiagnosticDiagramMotion.TravelTime(DiagnosticCheckpoint.CloudflareDns)
            + DiagnosticDiagramMotion.PulseSeconds + DiagnosticDiagramMotion.FadeSeconds / 2);
        Assert.Equal(state, motion.State);
        Assert.Equal(1, motion.Progress);
        Assert.InRange(motion.Opacity, 0.1, 0.9);
        Advance(motion, DiagnosticDiagramMotion.FadeSeconds);
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
        Advance(motion, 2 * motion.TravelSeconds + DiagnosticDiagramMotion.PulseSeconds + 0.1);
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
        var travelTime = motion.TravelSeconds;
        Advance(motion, travelTime + 0.2);
        Assert.Equal(DiagnosticCheckpoint.GooglePing, motion.Checkpoint);
        Assert.Equal(DiagnosticState.Responded, motion.State);
        Advance(motion, travelTime + DiagnosticDiagramMotion.PulseSeconds - 0.2 + 0.02);
        Advance(motion, 0.2);
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
        var start = DiagnosticDiagramMotion.Position(checkpoint, 0);
        Assert.Equal((165d, 198d), (start.X, start.Y));
        var end = DiagnosticDiagramMotion.Position(checkpoint, 1);
        Assert.Equal(x, end.X, 6);
        Assert.Equal(y, end.Y, 6);
        var previousX = 0d;
        var previousY = 198d;
        var stepDistance = DiagnosticDiagramMotion.TravelTime(checkpoint) * DiagnosticDiagramMotion.Speed / 1000;
        for (var index = 0; index <= 1000; index++)
        {
            var point = DiagnosticDiagramMotion.Position(checkpoint, index / 1000d);
            Assert.True(point.X >= previousX - 0.000001);
            Assert.True(point.Y <= previousY + 0.000001);
            Assert.InRange(point.Y, 55, 198);
            Assert.InRange(Math.Sqrt(Math.Pow(point.X - (index == 0 ? 165 : previousX), 2)
                + Math.Pow(point.Y - previousY, 2)), 0, stepDistance + 0.000001);
            if (point.Visible)
            {
                Assert.False(point.X > 355 && point.X < 435, "Do not draw traffic over the router icon.");
                Assert.False(point.X > 625 && point.X < 687, "Do not draw traffic over the hop icon.");
                Assert.False(point.X > 825 && point.X < 865, "Do not draw traffic over the internet icon.");
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
        var motion = new DiagnosticDiagramMotion();
        motion.Observe(checkpoint, DiagnosticState.Running);
        motion.Advance(0.25);
        var first = DiagnosticDiagramMotion.Position(checkpoint, motion.Progress);
        Assert.Equal(165 + DiagnosticDiagramMotion.Speed * 0.25, first.X, 6);
        Assert.Equal(198, first.Y, 6);
        Assert.Equal(0.25 / motion.TravelSeconds, motion.Progress, 6);
        motion.Advance(0.03);
        var next = DiagnosticDiagramMotion.Position(checkpoint, motion.Progress);
        Assert.Equal(DiagnosticDiagramMotion.Speed * 0.03, next.X - first.X, 6);
    }

    [Fact]
    public void FartherTargetsTakeLongerAndIconGapsDoNotTeleport()
    {
        var gatewayTime = DiagnosticDiagramMotion.TravelTime(DiagnosticCheckpoint.Gateway);
        var hopTime = DiagnosticDiagramMotion.TravelTime(DiagnosticCheckpoint.Hop2);
        var googleTime = DiagnosticDiagramMotion.TravelTime(DiagnosticCheckpoint.GooglePing);
        var cloudflareTime = DiagnosticDiagramMotion.TravelTime(DiagnosticCheckpoint.CloudflarePing);
        Assert.Equal(190 / DiagnosticDiagramMotion.Speed, gatewayTime, 6);
        Assert.Equal(460 / DiagnosticDiagramMotion.Speed, hopTime, 6);
        Assert.Equal(820 / DiagnosticDiagramMotion.Speed, googleTime, 6);
        Assert.True(gatewayTime < hopTime && hopTime < googleTime && googleTime < cloudflareTime);
        var inRouter = DiagnosticDiagramMotion.Position(DiagnosticCheckpoint.GooglePing, (395d - 165) / 820);
        Assert.Equal(395, inRouter.X, 6);
        Assert.False(inRouter.Visible);
    }

    [Fact]
    public void EndpointGrowsAndShrinksBeforeAConstantSpeedReturn()
    {
        var motion = new DiagnosticDiagramMotion();
        motion.Observe(DiagnosticCheckpoint.GooglePing, DiagnosticState.Running);
        motion.Observe(DiagnosticCheckpoint.GooglePing, DiagnosticState.Responded);
        motion.Advance(motion.TravelSeconds);
        Assert.True(motion.AtTarget);
        Assert.True(motion.ShowPulse);
        Assert.False(motion.Returning);
        Assert.Equal(8, motion.EndpointSize, 6);
        Advance(motion, DiagnosticDiagramMotion.PulseSeconds / 2);
        Assert.Equal(18, motion.EndpointSize, 6);
        Assert.Equal(1, motion.Progress);
        Advance(motion, DiagnosticDiagramMotion.PulseSeconds / 2 + 0.1);
        Assert.True(motion.Returning);
        Assert.False(motion.ShowPulse);
        Assert.Equal(8, motion.EndpointSize, 6);
        var position = DiagnosticDiagramMotion.Position(DiagnosticCheckpoint.GooglePing, motion.Progress);
        Assert.Equal(985 - DiagnosticDiagramMotion.Speed * 0.1, position.X, 6);
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

    [Theory]
    [InlineData(3)]
    [InlineData(4)]
    [InlineData(5)]
    public void ReplaysTheWholeSequenceExactlyTheChosenTotalNumberOfTimes(int passes)
    {
        var motion = new DiagnosticDiagramMotion();
        var results = new[]
        {
            Observation(DiagnosticCheckpoint.Loopback, DiagnosticState.Responded),
            Observation(DiagnosticCheckpoint.Gateway, DiagnosticState.Responded),
            Observation(DiagnosticCheckpoint.CloudflareDns, DiagnosticState.Unanswered)
        };
        motion.BeginRun(passes, results.Select(result => result with { State = DiagnosticState.Untested }));
        foreach (var result in results)
        {
            motion.Observe(result.Checkpoint, DiagnosticState.Running);
            motion.Observe(result.Checkpoint, result.State);
        }
        motion.CompleteRun(results);
        var visited = new List<(int Pass, DiagnosticCheckpoint? Checkpoint)>();
        for (var index = 0; motion.HasWork && index < 20000; index++)
        {
            var current = (motion.PassNumber, motion.Checkpoint);
            if (visited.Count == 0 || visited[^1] != current) visited.Add(current);
            motion.Advance(0.02);
        }
        Assert.False(motion.HasWork);
        Assert.Equal(passes, motion.PassNumber);
        Assert.Equal(passes, motion.TotalPasses);
        Assert.Equal(Enumerable.Range(1, passes).SelectMany(pass =>
            results.Select(result => (pass, (DiagnosticCheckpoint?)result.Checkpoint))), visited);
        Assert.All(results, result => Assert.NotEqual(DiagnosticState.Running, result.State));
    }

    [Fact]
    public void LiveQueueCanPauseBetweenChecksWithoutLosingTheFirstPassOrReplays()
    {
        var motion = new DiagnosticDiagramMotion();
        motion.BeginRun(3, []);
        motion.Observe(DiagnosticCheckpoint.Loopback, DiagnosticState.Running);
        motion.Observe(DiagnosticCheckpoint.Loopback, DiagnosticState.Responded);
        Advance(motion, 1);
        Assert.False(motion.HasWork);
        Assert.Equal(1, motion.PassNumber);
        motion.Observe(DiagnosticCheckpoint.Gateway, DiagnosticState.Running);
        motion.Observe(DiagnosticCheckpoint.Gateway, DiagnosticState.Responded);
        Advance(motion, 2);
        Assert.False(motion.HasWork);
        motion.CompleteRun([
            Observation(DiagnosticCheckpoint.Loopback, DiagnosticState.Responded),
            Observation(DiagnosticCheckpoint.Gateway, DiagnosticState.Responded)
        ]);
        Assert.Equal(2, motion.PassNumber);
        Assert.Equal(DiagnosticCheckpoint.Loopback, motion.Checkpoint);
    }

    [Fact]
    public void CompletingChecksDoesNotWaitForReplayAndMissingProgressStillGetsIllustrated()
    {
        var motion = new DiagnosticDiagramMotion();
        motion.BeginRun(5, []);
        motion.CompleteRun([
            Observation(DiagnosticCheckpoint.GooglePing, DiagnosticState.Responded),
            Observation(DiagnosticCheckpoint.RouterWan, DiagnosticState.Unavailable),
            Observation(DiagnosticCheckpoint.Hop2, DiagnosticState.Cancelled)
        ]);
        Assert.True(motion.HasWork);
        Assert.Equal(1, motion.PassNumber);
        Assert.Equal(DiagnosticCheckpoint.GooglePing, motion.Checkpoint);
        Assert.Equal(0, motion.Progress);
    }

    [Fact]
    public void StoppingReplayOrStartingANewRunDiscardsAllRemainingPasses()
    {
        var motion = new DiagnosticDiagramMotion();
        motion.BeginRun(5, []);
        motion.CompleteRun([Observation(DiagnosticCheckpoint.Loopback, DiagnosticState.Responded)]);
        Advance(motion, 1);
        Assert.Equal(2, motion.PassNumber);
        motion.Reset();
        Advance(motion, 100);
        Assert.False(motion.HasWork);
        motion.Observe(DiagnosticCheckpoint.Loopback, DiagnosticState.Responded);
        Assert.False(motion.HasWork);
        motion.BeginRun(3, []);
        Assert.Equal(3, motion.TotalPasses);
        Assert.Equal(1, motion.PassNumber);
        Assert.False(motion.HasWork);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(2)]
    [InlineData(6)]
    public void RejectsPassCountsOutsideTheApprovedRange(int passes) =>
        Assert.Throws<ArgumentOutOfRangeException>(() => new DiagnosticDiagramMotion().BeginRun(passes, []));

    [Fact]
    public void ConfirmedReturnOverlapsTheNextRequestAtEqualOppositeSpeeds()
    {
        var motion = new DiagnosticDiagramMotion();
        motion.BeginRun(3, [
            Observation(DiagnosticCheckpoint.Gateway, DiagnosticState.Responded),
            Observation(DiagnosticCheckpoint.Hop2, DiagnosticState.Responded)
        ]);
        var gatewayTravel = motion.TravelSeconds;
        motion.Advance(gatewayTravel + DiagnosticDiagramMotion.PulseSeconds + 0.1);
        Assert.True(motion.Returning);
        Assert.Equal(DiagnosticCheckpoint.Gateway, motion.Checkpoint);
        Assert.Equal(DiagnosticCheckpoint.Hop2, motion.RequestCheckpoint);
        var reply = DiagnosticDiagramMotion.Position(motion.Checkpoint!.Value, motion.Progress);
        var request = DiagnosticDiagramMotion.Position(motion.RequestCheckpoint!.Value, motion.RequestProgress);
        motion.Advance(0.02);
        var nextReply = DiagnosticDiagramMotion.Position(motion.Checkpoint.Value, motion.Progress);
        var nextRequest = DiagnosticDiagramMotion.Position(motion.RequestCheckpoint!.Value, motion.RequestProgress);
        Assert.Equal(-DiagnosticDiagramMotion.Speed * 0.02, nextReply.X - reply.X, 6);
        Assert.Equal(DiagnosticDiagramMotion.Speed * 0.02, nextRequest.X - request.X, 6);
        motion.Advance(gatewayTravel - 0.12 + 0.000001);
        Assert.Equal(DiagnosticCheckpoint.Hop2, motion.Checkpoint);
        Assert.Null(motion.RequestCheckpoint);
        Assert.Equal(gatewayTravel / motion.TravelSeconds, motion.Progress, 6);
        Assert.Equal(DiagnosticState.Running, motion.State);
        motion.Reset();
        Assert.Null(motion.RequestCheckpoint);
        Assert.False(motion.HasWork);
    }

    [Theory]
    [InlineData(DiagnosticState.Untested)]
    [InlineData(DiagnosticState.Running)]
    [InlineData(DiagnosticState.Unanswered)]
    [InlineData(DiagnosticState.Error)]
    public void PendingOrFailedChecksNeverProduceAReplyOrOverlap(DiagnosticState state)
    {
        var motion = new DiagnosticDiagramMotion();
        motion.BeginRun(3, [
            Observation(DiagnosticCheckpoint.Gateway, state),
            Observation(DiagnosticCheckpoint.Hop2, DiagnosticState.Responded)
        ]);
        motion.Advance(motion.TravelSeconds + DiagnosticDiagramMotion.PulseSeconds + 0.1);
        Assert.Equal(DiagnosticCheckpoint.Gateway, motion.Checkpoint);
        Assert.False(motion.Returning);
        Assert.Null(motion.RequestCheckpoint);
    }

    [Fact]
    public void InitialPassWaitsForHop2AndEveryPassUsesLogicalRatherThanArrivalOrder()
    {
        var motion = new DiagnosticDiagramMotion();
        var pending = new[]
        {
            Observation(DiagnosticCheckpoint.GooglePing, DiagnosticState.Untested),
            Observation(DiagnosticCheckpoint.Hop2, DiagnosticState.Untested),
            Observation(DiagnosticCheckpoint.Gateway, DiagnosticState.Untested)
        };
        motion.BeginRun(3, pending);
        motion.Observe(DiagnosticCheckpoint.GooglePing, DiagnosticState.Responded);
        motion.Observe(DiagnosticCheckpoint.Gateway, DiagnosticState.Responded);
        Assert.Equal(DiagnosticCheckpoint.Gateway, motion.Checkpoint);
        var visited = new List<(int Pass, DiagnosticCheckpoint? Checkpoint)> { (1, motion.Checkpoint) };
        for (var index = 0; motion.Checkpoint != DiagnosticCheckpoint.Hop2 && index < 1000; index++)
            motion.Advance(0.02);
        Assert.Equal(DiagnosticCheckpoint.Hop2, motion.Checkpoint);
        visited.Add((1, motion.Checkpoint));
        Advance(motion, 10);
        Assert.Equal(DiagnosticCheckpoint.Hop2, motion.Checkpoint);
        Assert.Equal(DiagnosticState.Untested, motion.State);
        Assert.Equal(1, motion.PassNumber);
        Assert.True(motion.AtTarget);
        Assert.False(motion.Returning);
        Assert.Null(motion.RequestCheckpoint);
        motion.Observe(DiagnosticCheckpoint.Hop2, DiagnosticState.Running);
        Assert.Equal(DiagnosticState.Running, motion.State);
        motion.Observe(DiagnosticCheckpoint.Hop2, DiagnosticState.Responded);
        motion.CompleteRun(pending.Select(item => item with { State = DiagnosticState.Responded }));
        for (var index = 0; motion.HasWork && index < 10000; index++)
        {
            var current = (motion.PassNumber, motion.Checkpoint);
            if (visited[^1] != current) visited.Add(current);
            motion.Advance(0.02);
        }
        Assert.False(motion.HasWork);
        var order = new[] { DiagnosticCheckpoint.Gateway, DiagnosticCheckpoint.Hop2, DiagnosticCheckpoint.GooglePing };
        Assert.Equal(Enumerable.Range(1, 3).SelectMany(pass =>
            order.Select(checkpoint => (pass, (DiagnosticCheckpoint?)checkpoint))), visited);
    }

    [Fact]
    public void UnavailableHop2DoesNotBlockProvidersOrCreateAFabricatedResponse()
    {
        var motion = new DiagnosticDiagramMotion();
        var results = new[]
        {
            Observation(DiagnosticCheckpoint.GooglePing, DiagnosticState.Responded),
            Observation(DiagnosticCheckpoint.Hop2, DiagnosticState.Unavailable),
            Observation(DiagnosticCheckpoint.Gateway, DiagnosticState.Responded)
        };
        motion.BeginRun(3, results.Select(item => item with { State = DiagnosticState.Untested }));
        motion.CompleteRun(results);
        var providerPasses = new HashSet<int>();
        for (var index = 0; motion.HasWork && index < 10000; index++)
        {
            if (motion.Checkpoint == DiagnosticCheckpoint.GooglePing) providerPasses.Add(motion.PassNumber);
            Assert.NotEqual(DiagnosticCheckpoint.Hop2, motion.RequestCheckpoint);
            if (motion.Checkpoint == DiagnosticCheckpoint.Hop2) Assert.False(motion.Returning);
            motion.Advance(0.02);
        }
        Assert.False(motion.HasWork);
        Assert.Equal(new[] { 1, 2, 3 }, providerPasses.Order());
    }

    private static DiagnosticObservation Observation(DiagnosticCheckpoint checkpoint, DiagnosticState state) =>
        new(checkpoint, "test target", state, "test result");

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
