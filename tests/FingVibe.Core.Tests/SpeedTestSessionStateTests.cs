using FingVibe.App;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class SpeedTestSessionStateTests
{
    [Fact]
    public void ProgressAndSuccessfulResultCompleteOnlyTheCurrentRun()
    {
        var session = new SpeedTestSessionState();
        Assert.True(session.TryStart("first"));
        Assert.True(session.CanStartEngine);
        Assert.False(session.TryStart("second"));
        Assert.True(session.Apply(new SpeedTestBridgeMessage("progress", "first", Phase: "download")));
        Assert.Equal(SpeedTestSessionStatus.Running, session.Status);

        Assert.True(session.Apply(new SpeedTestBridgeMessage(
            "result", "first", DownloadBps: 10, UploadBps: 5, LatencyMs: 2)));

        Assert.Equal(SpeedTestSessionStatus.Succeeded, session.Status);
        Assert.False(session.IsActive);
        Assert.False(session.Apply(new SpeedTestBridgeMessage("error", "first", Category: "measurement")));
    }

    [Fact]
    public void CancellationWinsOverLateResultsAndAllowsRetry()
    {
        var session = new SpeedTestSessionState();
        Assert.True(session.TryStart("first"));
        Assert.True(session.RequestCancellation("first"));
        Assert.Equal(SpeedTestSessionStatus.Cancelling, session.Status);
        Assert.False(session.CanStartEngine);
        Assert.False(session.Apply(new SpeedTestBridgeMessage("progress", "first", Phase: "upload")));

        Assert.True(session.Apply(new SpeedTestBridgeMessage(
            "result", "first", DownloadBps: 10, UploadBps: 5, LatencyMs: 2)));

        Assert.Equal(SpeedTestSessionStatus.Cancelled, session.Status);
        Assert.True(session.TryStart("second"));
        Assert.False(session.Apply(new SpeedTestBridgeMessage("error", "first", Category: "measurement")));
        Assert.Equal(SpeedTestSessionStatus.Running, session.Status);
    }

    [Fact]
    public void FailureAndBridgeCancellationAreDistinctAndRetryable()
    {
        var session = new SpeedTestSessionState();
        Assert.True(session.TryStart("first"));
        Assert.True(session.Apply(new SpeedTestBridgeMessage(
            "error", "first", Category: "rate-limited", ErrorMessage: "HTTP 429", HttpStatus: 429)));
        Assert.Equal(SpeedTestSessionStatus.Failed, session.Status);

        Assert.True(session.TryStart("second"));
        Assert.True(session.Apply(new SpeedTestBridgeMessage("cancelled", "second")));
        Assert.Equal(SpeedTestSessionStatus.Cancelled, session.Status);
        Assert.True(session.TryStart("third"));
    }

    [Fact]
    public void ResetClearsCompletedResultsButCannotInterruptAnActiveRun()
    {
        var session = new SpeedTestSessionState();
        Assert.True(session.TryStart("first"));
        Assert.False(session.TryReset());
        Assert.True(session.Apply(new SpeedTestBridgeMessage("cancelled", "first")));
        Assert.True(session.TryReset());

        Assert.Null(session.RunId);
        Assert.Equal(SpeedTestSessionStatus.Idle, session.Status);
    }
}
