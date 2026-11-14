using FingVibe.App;
using FingVibe.Core.Storage;
using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class InventoryBackupSchedulerTests
{
    private static TaskCompletionSource Started() => new(TaskCreationOptions.RunContinuationsAsynchronously);

    [Fact]
    public async Task RepeatedTriggersResetOneFifteenSecondTimerAndManualReplacesIt()
    {
        var time = new FakeTimeProvider();
        var started = Started();
        var count = 0;
        using var scheduler = new InventoryBackupScheduler(_ =>
        {
            Interlocked.Increment(ref count);
            started.TrySetResult();
            return Task.FromResult(new InventoryBackupResult());
        }, time);
        scheduler.Schedule();
        time.Advance(TimeSpan.FromSeconds(14));
        Assert.Equal(0, count);
        scheduler.Schedule();
        time.Advance(TimeSpan.FromSeconds(14));
        Assert.Equal(0, count);
        scheduler.BackUpNow();
        time.Advance(TimeSpan.Zero);
        await started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await scheduler.Execution;
        time.Advance(TimeSpan.FromMinutes(1));
        Assert.Equal(1, count);
        Assert.False(scheduler.Status.Pending);
    }

    [Fact]
    public async Task RunningJobContinuesAndRepeatedEventsCoalesceIntoOneDelayedFollowUp()
    {
        var time = new FakeTimeProvider();
        var started = Started();
        var finish = new TaskCompletionSource<InventoryBackupResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        var count = 0;
        using var scheduler = new InventoryBackupScheduler(_ =>
        {
            Interlocked.Increment(ref count);
            started.TrySetResult();
            return finish.Task;
        }, time);
        scheduler.BackUpNow();
        time.Advance(TimeSpan.Zero);
        await started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        scheduler.Schedule();
        time.Advance(TimeSpan.FromSeconds(14));
        scheduler.Schedule();
        finish.SetResult(new());
        await scheduler.Execution;
        time.Advance(TimeSpan.FromSeconds(14));
        Assert.Equal(1, count);
        time.Advance(TimeSpan.FromSeconds(1));
        await scheduler.Execution;
        Assert.Equal(2, count);
        Assert.False(scheduler.Status.Pending);
    }

    [Fact]
    public async Task CompetitionDefersButFailureDoesNotCreateAnAutomaticRetryLoop()
    {
        var time = new FakeTimeProvider();
        var count = 0;
        using var scheduler = new InventoryBackupScheduler(_ => ++count == 1
            ? Task.FromResult(new InventoryBackupResult(Deferred: true))
            : Task.FromException<InventoryBackupResult>(new IOException("disk full")), time);
        scheduler.BackUpNow();
        time.Advance(TimeSpan.Zero);
        await scheduler.Execution;
        Assert.True(scheduler.Status.Pending);
        time.Advance(TimeSpan.FromSeconds(15));
        await scheduler.Execution;
        Assert.Contains("disk full", scheduler.Status.Error);
        time.Advance(TimeSpan.FromHours(1));
        Assert.Equal(2, count);
        Assert.False(scheduler.Status.Pending);
    }

    [Fact]
    public async Task ShutdownCancelsPendingAndRequestsActiveCancellationWithoutWaiting()
    {
        var time = new FakeTimeProvider();
        var started = Started();
        var cancelled = Started();
        var scheduler = new InventoryBackupScheduler(async token =>
        {
            started.SetResult();
            try { await Task.Delay(Timeout.Infinite, token); }
            finally { cancelled.SetResult(); }
            return new();
        }, time);
        scheduler.Schedule();
        scheduler.Dispose();
        time.Advance(TimeSpan.FromMinutes(1));
        Assert.False(started.Task.IsCompleted);

        scheduler = new InventoryBackupScheduler(async token =>
        {
            started.SetResult();
            try { await Task.Delay(Timeout.Infinite, token); }
            finally { cancelled.SetResult(); }
            return new();
        }, time);
        scheduler.BackUpNow();
        time.Advance(TimeSpan.Zero);
        await started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        scheduler.Schedule();
        scheduler.Dispose();
        await cancelled.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await scheduler.Execution;
        Assert.False(scheduler.Status.Pending);
        Assert.Null(scheduler.Status.Error);
    }
}
