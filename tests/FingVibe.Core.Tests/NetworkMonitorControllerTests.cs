using System.Threading.Channels;
using System.Net;
using FingVibe.App;
using FingVibe.Core.Models;
using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class NetworkMonitorControllerTests
{
    [Fact]
    public async Task SavedOptInStartsOnlyAfterActivationAndWaitsOneMinute()
    {
        await using var harness = new Harness();
        var controller = new NetworkMonitorController(harness.Scheduler, new NetworkMonitorSettings(true));

        harness.Time.Advance(TimeSpan.FromDays(1));
        Assert.False(controller.IsActive);

        await controller.ActivateAsync();

        var waiting = await harness.ExpectAsync(NetworkMonitorSchedulerState.Waiting);
        Assert.Equal(NetworkMonitorSchedulerState.Waiting, waiting.State);
        Assert.Equal(TimeSpan.FromMinutes(1), waiting.NextCheckAt - harness.Time.GetUtcNow());
        harness.Time.Advance(TimeSpan.FromMinutes(1) - TimeSpan.FromTicks(1));
        Assert.False(harness.Runs.Reader.TryRead(out _));
        harness.Time.Advance(TimeSpan.FromTicks(1));
        var run = await harness.Runs.ReadNextAsync();
        Assert.Equal(NetworkMonitorSchedulerState.Running,
            (await harness.ExpectAsync(NetworkMonitorSchedulerState.Running)).State);
        run.Complete(new NetworkMonitorRunOutcome(NetworkMonitorRunStatus.Completed));
        Assert.Equal(NetworkMonitorSchedulerState.Waiting,
            (await harness.ExpectAsync(NetworkMonitorSchedulerState.Waiting)).State);
    }

    [Fact]
    public async Task DisableSleepContextChangeAndShutdownAwaitCancellation()
    {
        await using var harness = new Harness();
        var controller = new NetworkMonitorController(harness.Scheduler, new NetworkMonitorSettings(true));
        await controller.ActivateAsync();
        await harness.ExpectAsync(NetworkMonitorSchedulerState.Waiting);

        harness.Time.Advance(TimeSpan.FromMinutes(1));
        var run = await harness.Runs.ReadNextAsync();
        await controller.ApplyAsync(NetworkMonitorSettings.Default).WaitAsync(ScanExecutionFixture.Timeout);
        Assert.True(run.Token.IsCancellationRequested);
        Assert.False(controller.IsActive);

        await controller.ApplyAsync(new(true));
        await harness.ExpectAsync(NetworkMonitorSchedulerState.Waiting);
        harness.Time.Advance(TimeSpan.FromMinutes(1));
        var beforeSleep = await harness.Runs.ReadNextAsync();
        await controller.SuspendAsync().WaitAsync(ScanExecutionFixture.Timeout);
        Assert.True(beforeSleep.Token.IsCancellationRequested);
        Assert.True(controller.IsSuspended);
        await controller.ResumeAsync();
        await harness.ExpectAsync(NetworkMonitorSchedulerState.Waiting);

        harness.Time.Advance(TimeSpan.FromMinutes(1));
        var beforeContext = await harness.Runs.ReadNextAsync();
        await controller.RefreshContextAsync().WaitAsync(ScanExecutionFixture.Timeout);
        Assert.True(beforeContext.Token.IsCancellationRequested);
        await harness.ExpectAsync(NetworkMonitorSchedulerState.Waiting);

        harness.Time.Advance(TimeSpan.FromMinutes(1));
        var beforeShutdown = await harness.Runs.ReadNextAsync();
        await controller.ShutdownAsync().WaitAsync(ScanExecutionFixture.Timeout);
        Assert.True(beforeShutdown.Token.IsCancellationRequested);
        Assert.False(controller.IsActive);
        await controller.ApplyAsync(new(true));
        await controller.ActivateAsync();
        Assert.False(controller.IsActive);
    }

    [Fact]
    public async Task RestoredOffPreferenceNeverStartsTheProbeLoop()
    {
        await using var harness = new Harness();
        var controller = new NetworkMonitorController(harness.Scheduler, NetworkMonitorSettings.Default);
        await controller.ActivateAsync();
        harness.Time.Advance(TimeSpan.FromHours(4));

        Assert.False(controller.IsActive);
        Assert.False(harness.Runs.Reader.TryRead(out _));
        Assert.False(harness.Statuses.Reader.TryRead(out _));
    }

    [Fact]
    public async Task LongChecksPreserveMinuteCadenceWithoutACatchUpQueue()
    {
        await using var harness = new Harness();
        var controller = new NetworkMonitorController(harness.Scheduler, new NetworkMonitorSettings(true));
        await controller.ActivateAsync();
        await harness.ExpectAsync(NetworkMonitorSchedulerState.Waiting);

        harness.Time.Advance(TimeSpan.FromMinutes(1));
        var run = await harness.Runs.ReadNextAsync();
        await harness.ExpectAsync(NetworkMonitorSchedulerState.Running);
        harness.Time.Advance(TimeSpan.FromSeconds(10));
        run.Complete(new NetworkMonitorRunOutcome(NetworkMonitorRunStatus.Completed));

        var waiting = await harness.ExpectAsync(NetworkMonitorSchedulerState.Waiting);
        Assert.Equal(TimeSpan.FromSeconds(50), waiting.NextCheckAt - harness.Time.GetUtcNow());
    }

    [Fact]
    public void ContextChangesRejectStaleCompletions()
    {
        var original = new LanNetwork(
            "Ethernet",
            IPAddress.Parse("192.0.2.10"),
            IPAddress.Parse("192.0.2.0"),
            24,
            true,
            IPAddress.Parse("192.0.2.1"),
            "ethernet");

        Assert.True(NetworkMonitorContext.Matches(original, "profile", original with { InterfaceName = "Renamed" }, "profile"));
        Assert.False(NetworkMonitorContext.Matches(original, "profile", null, null));
        Assert.False(NetworkMonitorContext.Matches(original, "profile", original, "other-profile"));
        Assert.False(NetworkMonitorContext.Matches(
            original, "profile", original with { LocalAddress = IPAddress.Parse("192.0.2.11") }, "profile"));
        Assert.False(NetworkMonitorContext.Matches(
            original, "profile", original with { GatewayAddress = IPAddress.Parse("192.0.2.254") }, "profile"));
    }

    [Fact]
    public async Task IssueCadenceShortensTheNextWaitToThirtySeconds()
    {
        var interval = TimeSpan.FromMinutes(1);
        await using var harness = new Harness(() => interval);
        harness.Scheduler.Start();
        await harness.ExpectAsync(NetworkMonitorSchedulerState.Waiting);
        harness.Time.Advance(TimeSpan.FromMinutes(1));
        var run = await harness.Runs.ReadNextAsync();
        interval = TimeSpan.FromSeconds(30);
        run.Complete(new NetworkMonitorRunOutcome(NetworkMonitorRunStatus.Completed));

        var waiting = await harness.ExpectAsync(NetworkMonitorSchedulerState.Waiting);
        Assert.Equal(TimeSpan.FromSeconds(30), waiting.NextCheckAt - harness.Time.GetUtcNow());
    }
    private sealed class Harness : IAsyncDisposable
    {
        public Harness(Func<TimeSpan>? interval = null)
        {
            Scheduler = new(async token =>
            {
                var completion = new TaskCompletionSource<NetworkMonitorRunOutcome>(
                    TaskCreationOptions.RunContinuationsAsynchronously);
                Runs.Writer.TryWrite(new(token, completion));
                return await completion.Task.WaitAsync(token);
            }, Time, interval);
            Scheduler.StatusChanged += (_, status) => Statuses.Writer.TryWrite(status);
        }

        public FakeTimeProvider Time { get; } = new();
        public Channel<Run> Runs { get; } = Channel.CreateUnbounded<Run>();
        public Channel<NetworkMonitorStatus> Statuses { get; } = Channel.CreateUnbounded<NetworkMonitorStatus>();
        public NetworkMonitorScheduler Scheduler { get; }
        public async Task<NetworkMonitorStatus> ExpectAsync(NetworkMonitorSchedulerState state)
        {
            while (true)
            {
                var status = await Statuses.ReadNextAsync();
                if (status.State == state) return status;
            }
        }
        public async ValueTask DisposeAsync() => await Scheduler.StopAsync();
    }

    private sealed record Run(CancellationToken Token, TaskCompletionSource<NetworkMonitorRunOutcome> Completion)
    {
        public void Complete(NetworkMonitorRunOutcome outcome) => Completion.TrySetResult(outcome);
    }
}
