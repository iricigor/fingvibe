using System.Net;
using FingVibe.App;
using FingVibe.Core.Models;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class PeriodicScanControllerTests
{
    private static readonly PeriodicScanSettings Every15 = new(true, 15);
    private static readonly TimeSpan Fifteen = TimeSpan.FromMinutes(15);

    [Fact]
    public async Task NothingIsScheduledBeforeOptInOrStartupActivation()
    {
        await using var harness = new SchedulerHarness();
        var controller = new PeriodicScanController(harness.Scheduler, PeriodicScanSettings.Default);

        await controller.ActivateAsync();
        harness.Time.Advance(TimeSpan.FromDays(1));
        Assert.False(controller.IsActive);
        Assert.False(harness.Statuses.Reader.TryRead(out _));

        var saved = new PeriodicScanController(harness.Scheduler, Every15);
        harness.Time.Advance(TimeSpan.FromDays(1));
        Assert.False(saved.IsActive);
        Assert.False(harness.Statuses.Reader.TryRead(out _));
        harness.AssertNoPendingWork();
    }

    [Fact]
    public async Task SavedOptInStartsAfterActivationAndWaitsAFullInterval()
    {
        await using var harness = new SchedulerHarness();
        var controller = new PeriodicScanController(harness.Scheduler, new PeriodicScanSettings(true, 60));

        await controller.ActivateAsync();

        Assert.True(controller.IsActive);
        await harness.ExpectWaitingAsync(TimeSpan.FromHours(1));
        harness.Time.Advance(TimeSpan.FromHours(1) - TimeSpan.FromTicks(1));
        harness.AssertNoPendingWork();
        (await harness.TickToScheduledScanAsync(TimeSpan.FromTicks(1))).Complete();
        await harness.ExpectWaitingAsync(TimeSpan.FromHours(1));
    }

    [Fact]
    public async Task DisablingCancelsOnlyTheScheduledScanAndSavesNothing()
    {
        await using var harness = new SchedulerHarness();
        var controller = new PeriodicScanController(harness.Scheduler, PeriodicScanSettings.Default);
        await controller.ActivateAsync();
        await controller.ApplyAsync(Every15);
        await harness.ExpectWaitingAsync(Fifteen);
        var scheduled = await harness.TickToScheduledScanAsync(Fifteen);

        await controller.ApplyAsync(Every15 with { IsEnabled = false }).WaitAsync(ScanExecutionFixture.Timeout);

        Assert.True(scheduled.Token.IsCancellationRequested);
        var stopped = await harness.ExpectAsync(PeriodicScanState.Stopped);
        Assert.Equal(ScanRunStatus.Cancelled, stopped.LastOutcome!.Status);
        Assert.False(controller.IsActive);
        Assert.Empty(harness.Steps.Saves);
        Assert.Null(harness.Coordinator.ActiveKind);

        var manual = harness.RunManualAsync();
        var manualScan = await harness.Steps.Scans.ReadNextAsync();
        await controller.ApplyAsync(Every15);
        await harness.ExpectWaitingAsync(Fifteen);
        await controller.ApplyAsync(Every15 with { IsEnabled = false }).WaitAsync(ScanExecutionFixture.Timeout);
        await harness.ExpectAsync(PeriodicScanState.Stopped);

        Assert.False(manualScan.Token.IsCancellationRequested);
        manualScan.Complete();
        Assert.Equal(ScanRunStatus.Completed, (await manual.WaitAsync(ScanExecutionFixture.Timeout)).Status);
        Assert.Single(harness.Steps.Saves);
    }

    [Fact]
    public async Task IntervalChangesRestartTheCountdownAndRepeatedSettingsAreIgnored()
    {
        await using var harness = new SchedulerHarness();
        var controller = new PeriodicScanController(harness.Scheduler, Every15);
        await controller.ActivateAsync();
        await harness.ExpectWaitingAsync(Fifteen);
        harness.Time.Advance(TimeSpan.FromMinutes(10));

        await controller.ApplyAsync(new PeriodicScanSettings(true, 30));
        await harness.ExpectWaitingAsync(TimeSpan.FromMinutes(30));
        await controller.ApplyAsync(new PeriodicScanSettings(true, 30));

        Assert.False(harness.Statuses.Reader.TryRead(out _));
        Assert.Equal(30, controller.Settings.IntervalMinutes);
        harness.Time.Advance(TimeSpan.FromMinutes(30) - TimeSpan.FromTicks(1));
        harness.AssertNoPendingWork();
        (await harness.TickToScheduledScanAsync(TimeSpan.FromTicks(1))).Complete();
        await harness.ExpectWaitingAsync(TimeSpan.FromMinutes(30));
    }

    [Fact]
    public async Task SleepCancelsTheScheduledScanAndWakeWaitsAFullIntervalWithoutCatchUp()
    {
        await using var harness = new SchedulerHarness();
        var controller = new PeriodicScanController(harness.Scheduler, Every15);
        await controller.ActivateAsync();
        await harness.ExpectWaitingAsync(Fifteen);
        var scheduled = await harness.TickToScheduledScanAsync(Fifteen);

        await controller.SuspendAsync().WaitAsync(ScanExecutionFixture.Timeout);

        Assert.True(controller.IsSuspended);
        Assert.True(scheduled.Token.IsCancellationRequested);
        await harness.ExpectAsync(PeriodicScanState.Stopped);
        await controller.ApplyAsync(new PeriodicScanSettings(true, 30));
        harness.Time.Advance(TimeSpan.FromHours(8));
        Assert.False(harness.Statuses.Reader.TryRead(out _));
        harness.AssertNoPendingWork();

        await controller.ResumeAsync();

        Assert.False(controller.IsSuspended);
        await harness.ExpectWaitingAsync(TimeSpan.FromMinutes(30));
        harness.Time.Advance(TimeSpan.FromMinutes(30) - TimeSpan.FromTicks(1));
        harness.AssertNoPendingWork();
        (await harness.TickToScheduledScanAsync(TimeSpan.FromTicks(1))).Complete();
        await harness.ExpectWaitingAsync(TimeSpan.FromMinutes(30));
        Assert.Single(harness.Steps.Saves);
    }

    [Fact]
    public async Task ShutdownStopsSchedulingPermanently()
    {
        await using var harness = new SchedulerHarness();
        var controller = new PeriodicScanController(harness.Scheduler, Every15);
        await controller.ActivateAsync();
        await harness.ExpectWaitingAsync(Fifteen);

        await controller.ShutdownAsync().WaitAsync(ScanExecutionFixture.Timeout);
        await harness.ExpectAsync(PeriodicScanState.Stopped);
        await controller.ActivateAsync();
        await controller.ApplyAsync(new PeriodicScanSettings(true, 30));
        await controller.SuspendAsync();
        await controller.ResumeAsync();
        await controller.ShutdownAsync();

        Assert.False(controller.IsActive);
        harness.Time.Advance(TimeSpan.FromDays(1));
        Assert.False(harness.Statuses.Reader.TryRead(out _));
        harness.AssertNoPendingWork();
    }

    [Fact]
    public async Task OverlappingRequestsResolveToTheLatestStateWithOneLoop()
    {
        await using var harness = new SchedulerHarness();
        var controller = new PeriodicScanController(harness.Scheduler, PeriodicScanSettings.Default);
        await controller.ActivateAsync();

        await Task.WhenAll(
            controller.ApplyAsync(Every15),
            controller.ApplyAsync(Every15 with { IsEnabled = false }),
            controller.SuspendAsync(),
            controller.ApplyAsync(new PeriodicScanSettings(true, 30)),
            controller.ResumeAsync()).WaitAsync(ScanExecutionFixture.Timeout);

        PeriodicScanStatus status;
        do
        {
            status = await harness.Statuses.ReadNextAsync();
        }
        while (status.State != PeriodicScanState.Waiting || status.NextAttemptAt != harness.Time.GetUtcNow() + TimeSpan.FromMinutes(30));

        Assert.True(controller.IsActive);
        (await harness.TickToScheduledScanAsync(TimeSpan.FromMinutes(30))).Complete();
        await harness.ExpectWaitingAsync(TimeSpan.FromMinutes(30));
        harness.AssertNoPendingWork();
        Assert.Single(harness.Steps.Saves);
    }

    [Fact]
    public async Task UnsupportedIntervalsUseTheDefaultPolicy()
    {
        await using var harness = new SchedulerHarness();
        var controller = new PeriodicScanController(harness.Scheduler, new PeriodicScanSettings(true, 7));

        Assert.Equal(PeriodicScanSettings.DefaultIntervalMinutes, controller.Settings.IntervalMinutes);
        Assert.Equal(TimeSpan.FromHours(1), PeriodicScanController.PolicyFor(new PeriodicScanSettings(true, 7)).Interval);
        Assert.Equal(TimeSpan.FromHours(4), PeriodicScanController.PolicyFor(new PeriodicScanSettings(true, 240)).Interval);
    }

    [Fact]
    public void ScheduledTargetRequiresTheSameAdapterAndSubnet()
    {
        var selected = Network("Wi-Fi", "192.168.1.20", "192.168.1.0", 24, "wifi-id");

        Assert.True(PeriodicScanTarget.IsAvailable([Network("Wi-Fi", "192.168.1.44", "192.168.1.0", 24, "WIFI-ID")], selected));
        Assert.True(PeriodicScanTarget.IsAvailable([Network("Renamed", "192.168.1.20", "192.168.1.0", 24, "wifi-id")], selected));
        Assert.False(PeriodicScanTarget.IsAvailable([], selected));
        Assert.False(PeriodicScanTarget.IsAvailable([Network("Wi-Fi", "10.0.0.20", "10.0.0.0", 24, "wifi-id")], selected));
        Assert.False(PeriodicScanTarget.IsAvailable([Network("Wi-Fi", "192.168.1.20", "192.168.0.0", 23, "wifi-id")], selected));
        Assert.False(PeriodicScanTarget.IsAvailable([Network("Ethernet", "192.168.1.20", "192.168.1.0", 24, "eth-id")], selected));

        var unnamed = Network("Ethernet", "192.0.2.10", "192.0.2.0", 24, null);
        Assert.True(PeriodicScanTarget.IsAvailable([Network("Ethernet", "192.0.2.11", "192.0.2.0", 24, null)], unnamed));
        Assert.False(PeriodicScanTarget.IsAvailable([Network("Ethernet 2", "192.0.2.10", "192.0.2.0", 24, null)], unnamed));
    }

    private static LanNetwork Network(string name, string local, string network, int prefix, string? id) =>
        new(name, IPAddress.Parse(local), IPAddress.Parse(network), prefix, true, null, id);
}
