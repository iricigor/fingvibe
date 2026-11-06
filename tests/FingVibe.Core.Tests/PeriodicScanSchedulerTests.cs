using FingVibe.App;
using FingVibe.Core.Models;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class PeriodicScanSchedulerTests
{
    private static readonly TimeSpan Interval = TimeSpan.FromMinutes(15);
    private static readonly TimeSpan Retry = TimeSpan.FromMinutes(1);
    private static readonly PeriodicScanPolicy Policy = new(Interval);

    [Fact]
    public void PolicyValidatesBoundsAndBacksOffExponentiallyUpToTheInterval()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => new PeriodicScanPolicy(TimeSpan.FromSeconds(59)));
        Assert.Throws<ArgumentOutOfRangeException>(() => new PeriodicScanPolicy(TimeSpan.FromDays(1).Add(TimeSpan.FromTicks(1))));
        Assert.Throws<ArgumentOutOfRangeException>(() => new PeriodicScanPolicy(Interval, TimeSpan.FromSeconds(9)));
        Assert.Throws<ArgumentOutOfRangeException>(() => new PeriodicScanPolicy(Interval, Interval + TimeSpan.FromTicks(1)));
        Assert.Equal(Retry, Policy.RetryDelay);
        Assert.Equal(TimeSpan.FromMinutes(1), new PeriodicScanPolicy(TimeSpan.FromMinutes(1)).RetryDelay);
        Assert.Equal(TimeSpan.FromDays(1), new PeriodicScanPolicy(TimeSpan.FromDays(1)).DelayAfter(0));

        Assert.Equal(
            new double[] { 15, 1, 2, 4, 8, 15, 15 },
            new[] { 0, 1, 2, 3, 4, 5, 6 }.Select(attempts => Policy.DelayAfter(attempts).TotalMinutes));
        Assert.Equal(Interval, Policy.DelayAfter(int.MaxValue));
    }

    [Fact]
    public async Task SchedulerStaysStoppedUntilStarted()
    {
        await using var harness = new SchedulerHarness();

        harness.Time.Advance(TimeSpan.FromDays(2));

        Assert.Equal(PeriodicScanState.Stopped, harness.Scheduler.Status.State);
        Assert.False(harness.Statuses.Reader.TryRead(out _));
        harness.AssertNoPendingWork();
    }

    [Fact]
    public async Task StartWaitsOneFullIntervalAndStopCancelsTheWait()
    {
        await using var harness = new SchedulerHarness();
        harness.Scheduler.Start(Policy);
        var waiting = await harness.ExpectWaitingAsync(Interval);
        Assert.Null(waiting.LastOutcome);
        Assert.Throws<InvalidOperationException>(() => harness.Scheduler.Start(Policy));

        harness.Time.Advance(Interval - TimeSpan.FromTicks(1));
        harness.AssertNoPendingWork();
        Assert.Equal(PeriodicScanState.Waiting, harness.Scheduler.Status.State);

        await harness.Scheduler.StopAsync().WaitAsync(ScanExecutionFixture.Timeout);
        await harness.ExpectAsync(PeriodicScanState.Stopped);
        harness.Time.Advance(Interval * 2);
        harness.AssertNoPendingWork();
        Assert.False(harness.Statuses.Reader.TryRead(out _));

        harness.Scheduler.Start(Policy);
        await harness.ExpectWaitingAsync(Interval);
        (await harness.TickToScheduledScanAsync(Interval)).Complete();
        await harness.ExpectWaitingAsync(Interval);
    }

    [Fact]
    public async Task LongScansAndMissedIntervalsProduceOneAttemptAndNoCatchUpQueue()
    {
        await using var harness = new SchedulerHarness();
        harness.Scheduler.Start(Policy);
        await harness.ExpectWaitingAsync(Interval);

        var longScan = await harness.TickToScheduledScanAsync(Interval);
        harness.Time.Advance(Interval * 3);
        harness.AssertNoPendingWork();
        Assert.Equal(PeriodicScanState.Running, harness.Scheduler.Status.State);
        longScan.Complete();
        var afterLongScan = await harness.ExpectWaitingAsync(Interval);
        Assert.Equal(ScanRunStatus.Completed, afterLongScan.LastOutcome!.Status);

        // A late timer, for example after sleep, still produces one attempt.
        (await harness.TickToScheduledScanAsync(Interval * 10)).Complete();
        await harness.ExpectWaitingAsync(Interval);
        harness.AssertNoPendingWork();
        Assert.Equal(2, harness.Steps.Saves.Count);
        Assert.All(harness.Steps.Ended, outcome => Assert.Equal(ScanRunStatus.Completed, outcome.Status));
    }

    [Fact]
    public async Task ManualScanCollisionSkipsScheduledTicksAndRecoversAfterward()
    {
        await using var harness = new SchedulerHarness();
        var manual = harness.RunManualAsync();
        var (manualRequest, _) = await harness.Steps.Began.ReadNextAsync();
        Assert.Equal(ScanTrigger.Manual, manualRequest.Trigger);
        var manualScan = await harness.Steps.Scans.ReadNextAsync();
        harness.Scheduler.Start(Policy);
        await harness.ExpectWaitingAsync(Interval);

        foreach (var (delay, attempts, next) in new[] { (Interval, 1, Retry), (Retry, 2, Retry * 2) })
        {
            await harness.TickAsync(delay);
            var busy = await harness.ExpectWaitingAsync(next);
            Assert.Equal(ScanRunStatus.Busy, busy.LastOutcome!.Status);
            Assert.Equal(NetworkActivityKind.LanScan, busy.LastOutcome.BlockingActivity);
            Assert.Equal(attempts, busy.ConsecutiveUnsuccessfulAttempts);
            harness.AssertNoPendingWork();
        }

        Assert.False(manualScan.Token.IsCancellationRequested);
        manualScan.Complete();
        Assert.Equal(ScanRunStatus.Completed, (await manual.WaitAsync(ScanExecutionFixture.Timeout)).Status);

        (await harness.TickToScheduledScanAsync(Retry * 2)).Complete();
        var recovered = await harness.ExpectWaitingAsync(Interval);
        Assert.Equal(ScanRunStatus.Completed, recovered.LastOutcome!.Status);
        Assert.Equal(0, recovered.ConsecutiveUnsuccessfulAttempts);
        Assert.Equal(2, harness.Steps.Saves.Count);
    }

    [Fact]
    public async Task ManualRequestDuringAScheduledScanIsRejectedWithoutInterruptingIt()
    {
        await using var harness = new SchedulerHarness();
        harness.Scheduler.Start(Policy);
        await harness.ExpectWaitingAsync(Interval);
        var scheduled = await harness.TickToScheduledScanAsync(Interval);

        var manual = await harness.RunManualAsync();

        Assert.Equal(ScanRunStatus.Busy, manual.Status);
        Assert.Equal(NetworkActivityKind.LanScan, manual.BlockingActivity);
        harness.AssertNoPendingWork();
        Assert.False(scheduled.Token.IsCancellationRequested);
        scheduled.Complete();
        Assert.Equal(ScanRunStatus.Completed, (await harness.ExpectWaitingAsync(Interval)).LastOutcome!.Status);
        Assert.Single(harness.Steps.Saves);
    }

    [Theory]
    [InlineData(nameof(NetworkActivityKind.InternetSpeedTest))]
    [InlineData(nameof(NetworkActivityKind.NetworkTroubleshooting))]
    [InlineData(nameof(NetworkActivityKind.DeviceServiceScan))]
    public async Task OtherMeasurementCollisionBacksOffWithinTheIntervalAndRecovers(string activeName)
    {
        var active = Enum.Parse<NetworkActivityKind>(activeName);
        await using var harness = new SchedulerHarness();
        Assert.True(harness.Coordinator.TryAcquire(active, out var lease));
        harness.Scheduler.Start(Policy);
        await harness.ExpectWaitingAsync(Interval);

        var delay = Interval;
        for (var attempts = 1; attempts <= 6; attempts++)
        {
            await harness.TickAsync(delay);
            delay = Policy.DelayAfter(attempts);
            var busy = await harness.ExpectWaitingAsync(delay);
            Assert.Equal(ScanRunStatus.Busy, busy.LastOutcome!.Status);
            Assert.Equal(active, busy.LastOutcome.BlockingActivity);
            Assert.Equal(attempts, busy.ConsecutiveUnsuccessfulAttempts);
            harness.AssertNoPendingWork();
            Assert.Equal(active, harness.Coordinator.ActiveKind);
        }

        Assert.Equal(Interval, delay);
        lease!.Dispose();
        (await harness.TickToScheduledScanAsync(delay)).Complete();
        var recovered = await harness.ExpectWaitingAsync(Interval);
        Assert.Equal(ScanRunStatus.Completed, recovered.LastOutcome!.Status);
        Assert.Equal(0, recovered.ConsecutiveUnsuccessfulAttempts);
    }

    [Fact]
    public async Task UserCancellationWaitsAFullIntervalWithoutSaving()
    {
        await using var harness = new SchedulerHarness();
        harness.Scheduler.Start(Policy);
        await harness.ExpectWaitingAsync(Interval);

        await harness.TickAsync(Interval);
        var (_, cancellation) = await harness.Steps.Began.ReadNextAsync();
        var scan = await harness.Steps.Scans.ReadNextAsync();
        cancellation.Cancel();

        var waiting = await harness.ExpectWaitingAsync(Interval);
        Assert.True(scan.Token.IsCancellationRequested);
        Assert.Equal(ScanRunStatus.Cancelled, waiting.LastOutcome!.Status);
        Assert.Equal(0, waiting.ConsecutiveUnsuccessfulAttempts);
        Assert.Empty(harness.Steps.Saves);
        Assert.Null(harness.Coordinator.ActiveKind);
    }

    [Fact]
    public async Task ScanAndStorageErrorsBackOffAndASuccessfulScanRestoresTheInterval()
    {
        await using var harness = new SchedulerHarness();
        harness.Scheduler.Start(Policy);
        await harness.ExpectWaitingAsync(Interval);

        (await harness.TickToScheduledScanAsync(Interval)).Fail(new IOException("socket failure"));
        var failed = await harness.ExpectWaitingAsync(Retry);
        Assert.Equal(ScanRunStatus.Failed, failed.LastOutcome!.Status);
        Assert.Equal("socket failure", failed.LastOutcome.Message);
        Assert.Empty(harness.Steps.Saves);

        harness.Steps.Save = _ => Task.FromResult(new ScanSaveResult([new DeviceDiscovery("001122334466")], "disk full"));
        (await harness.TickToScheduledScanAsync(Retry)).Complete();
        var saveFailed = await harness.ExpectWaitingAsync(Retry * 2);
        Assert.Equal(ScanRunStatus.SaveFailed, saveFailed.LastOutcome!.Status);
        Assert.Empty(saveFailed.LastOutcome.Discoveries);
        Assert.Equal(2, saveFailed.ConsecutiveUnsuccessfulAttempts);

        harness.Steps.Save = _ => Task.FromResult(new ScanSaveResult([]));
        (await harness.TickToScheduledScanAsync(Retry * 2)).Complete();
        var recovered = await harness.ExpectWaitingAsync(Interval);
        Assert.Equal(ScanRunStatus.Completed, recovered.LastOutcome!.Status);
        Assert.Equal(0, recovered.ConsecutiveUnsuccessfulAttempts);
        Assert.Null(harness.Coordinator.ActiveKind);
    }

    [Fact]
    public async Task StopCancelsTheInFlightScheduledScanAndReleasesTheLease()
    {
        await using var harness = new SchedulerHarness();
        harness.Scheduler.Start(Policy);
        await harness.ExpectWaitingAsync(Interval);
        var scan = await harness.TickToScheduledScanAsync(Interval);

        await harness.Scheduler.StopAsync().WaitAsync(ScanExecutionFixture.Timeout);

        Assert.True(scan.Token.IsCancellationRequested);
        var stopped = await harness.ExpectAsync(PeriodicScanState.Stopped);
        Assert.Equal(ScanRunStatus.Cancelled, stopped.LastOutcome!.Status);
        Assert.Equal(PeriodicScanState.Stopped, harness.Scheduler.Status.State);
        Assert.Empty(harness.Steps.Saves);
        Assert.Null(harness.Coordinator.ActiveKind);
        harness.Time.Advance(Interval * 2);
        harness.AssertNoPendingWork();
    }

    [Fact]
    public async Task UnexpectedAttemptErrorsAreRecordedAndRetried()
    {
        var calls = 0;
        await using var harness = new SchedulerHarness(_ =>
        {
            if (++calls == 1) throw new NotSupportedException("unexpected");
            throw new OperationCanceledException();
        });
        harness.Scheduler.Start(Policy);
        await harness.ExpectWaitingAsync(Interval);

        await harness.TickAsync(Interval);
        var failed = await harness.ExpectWaitingAsync(Retry);
        Assert.Equal(ScanRunStatus.Failed, failed.LastOutcome!.Status);
        Assert.Equal("unexpected", failed.LastOutcome.Message);

        await harness.TickAsync(Retry);
        var cancelled = await harness.ExpectWaitingAsync(Interval);
        Assert.Equal(ScanRunStatus.Cancelled, cancelled.LastOutcome!.Status);
        Assert.Equal(2, calls);
    }

    [Fact]
    public async Task PolicyUpdatesRequireARunningScheduler()
    {
        await using var harness = new SchedulerHarness();
        Assert.Throws<InvalidOperationException>(() => harness.Scheduler.UpdatePolicy(Policy));

        harness.Scheduler.Start(Policy);
        await harness.ExpectWaitingAsync(Interval);
        await harness.Scheduler.StopAsync().WaitAsync(ScanExecutionFixture.Timeout);
        await harness.ExpectAsync(PeriodicScanState.Stopped);

        Assert.Throws<InvalidOperationException>(() => harness.Scheduler.UpdatePolicy(Policy));
        harness.Time.Advance(Interval * 2);
        harness.AssertNoPendingWork();
    }

    [Fact]
    public async Task PolicyUpdateRestartsAPendingWaitFromNow()
    {
        var longer = new PeriodicScanPolicy(Interval * 2);
        await using var harness = new SchedulerHarness();
        harness.Scheduler.Start(Policy);
        await harness.ExpectWaitingAsync(Interval);
        harness.Time.Advance(Interval - TimeSpan.FromMinutes(1));

        harness.Scheduler.UpdatePolicy(longer);

        await harness.ExpectWaitingAsync(longer.Interval);
        harness.Time.Advance(longer.Interval - TimeSpan.FromTicks(1));
        harness.AssertNoPendingWork();
        Assert.Equal(PeriodicScanState.Waiting, harness.Scheduler.Status.State);
        (await harness.TickToScheduledScanAsync(TimeSpan.FromTicks(1))).Complete();
        await harness.ExpectWaitingAsync(longer.Interval);
        Assert.Single(harness.Steps.Saves);
    }

    [Fact]
    public async Task PolicyUpdateDuringAScheduledScanAppliesToTheFollowingWait()
    {
        var shorter = new PeriodicScanPolicy(TimeSpan.FromMinutes(5));
        await using var harness = new SchedulerHarness();
        harness.Scheduler.Start(Policy);
        await harness.ExpectWaitingAsync(Interval);
        var scan = await harness.TickToScheduledScanAsync(Interval);

        harness.Scheduler.UpdatePolicy(shorter);

        Assert.False(scan.Token.IsCancellationRequested);
        Assert.False(harness.Statuses.Reader.TryRead(out _));
        scan.Complete();
        var waiting = await harness.ExpectWaitingAsync(shorter.Interval);
        Assert.Equal(ScanRunStatus.Completed, waiting.LastOutcome!.Status);
    }

    [Fact]
    public async Task PolicyUpdateKeepsRetryBackoffAndLastOutcome()
    {
        var longer = new PeriodicScanPolicy(Interval * 2);
        await using var harness = new SchedulerHarness();
        Assert.True(harness.Coordinator.TryAcquire(NetworkActivityKind.InternetSpeedTest, out var lease));
        harness.Scheduler.Start(Policy);
        await harness.ExpectWaitingAsync(Interval);
        await harness.TickAsync(Interval);
        await harness.ExpectWaitingAsync(Retry);

        harness.Scheduler.UpdatePolicy(longer);

        var retrying = await harness.ExpectWaitingAsync(longer.DelayAfter(1));
        Assert.Equal(1, retrying.ConsecutiveUnsuccessfulAttempts);
        Assert.Equal(ScanRunStatus.Busy, retrying.LastOutcome!.Status);
        lease!.Dispose();
        (await harness.TickToScheduledScanAsync(Retry)).Complete();
        await harness.ExpectWaitingAsync(longer.Interval);
    }
}
