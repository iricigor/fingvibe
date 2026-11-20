using System.Globalization;
using System.Net;
using FingVibe.App;
using FingVibe.Core.Models;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class NetworkMonitorPresentationTests
{
    private static readonly DateTimeOffset Now =
        new(2026, 11, 20, 1, 0, 0, TimeSpan.Zero);

    [Fact]
    public void DisclosureNamesExactTargetsCadenceAndWindowsCache()
    {
        Assert.Contains("five", NetworkMonitorPresentation.Disclosure);
        Assert.Contains("one-second-spaced", NetworkMonitorPresentation.Disclosure);
        Assert.Contains("gateway", NetworkMonitorPresentation.Disclosure);
        Assert.Contains("1.1.1.1", NetworkMonitorPresentation.Disclosure);
        Assert.Contains("8.8.8.8", NetworkMonitorPresentation.Disclosure);
        Assert.Contains("including its cache", NetworkMonitorPresentation.Disclosure);
        Assert.Contains("public DNS resolvers", NetworkMonitorPresentation.Disclosure);
        Assert.Contains("User-started network work takes priority", NetworkMonitorPresentation.Disclosure);
    }

    [Fact]
    public void StatusAndSnapshotExposeOnlyRawExecutionState()
    {
        var status = new NetworkMonitorStatus(
            NetworkMonitorSchedulerState.Running,
            LastOutcome: new NetworkMonitorRunOutcome(NetworkMonitorRunStatus.Completed));
        var snapshot = NetworkMonitorPresentation.Snapshot(
            new(true), status, false, Now, "Collecting raw observations.");

        Assert.Equal(NetworkMonitorState.Checking, snapshot.State);
        Assert.Equal("Collecting raw observations.", snapshot.Detail);
        Assert.Equal(
            "Collecting raw ping and DNS observations.",
            NetworkMonitorPresentation.Status(
                new(true), status, false, Now, TimeZoneInfo.Utc, CultureInfo.InvariantCulture));
        Assert.DoesNotContain("healthy", snapshot.Detail, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("verdict", snapshot.Detail, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void OffPausedAndCancelledStatesRemainExplicit()
    {
        Assert.Equal(
            "Off. No background network checks are scheduled.",
            NetworkMonitorPresentation.Status(
                NetworkMonitorSettings.Default,
                new(NetworkMonitorSchedulerState.Stopped),
                false,
                Now,
                TimeZoneInfo.Utc,
                CultureInfo.InvariantCulture));
        Assert.Contains(
            "Paused while Windows sleeps",
            NetworkMonitorPresentation.Status(
                new(true), new(NetworkMonitorSchedulerState.Stopped), true,
                Now, TimeZoneInfo.Utc, CultureInfo.InvariantCulture));
        Assert.Contains(
            "no failure was inferred",
            NetworkMonitorPresentation.Status(
                new(true),
                new(NetworkMonitorSchedulerState.Waiting, Now.AddMinutes(1),
                    new(NetworkMonitorRunStatus.Cancelled)),
                false,
                Now,
                TimeZoneInfo.Utc,
                CultureInfo.InvariantCulture));
    }

    [Fact]
    public void SnapshotRetainsRawObservationAcrossASubsequentSkip()
    {
        var observation = new NetworkMonitorObservation(
            Now,
            Now.AddSeconds(5),
            "network",
            IPAddress.Parse("192.0.2.1"),
            [],
            [],
            false,
            "Raw observations completed.");
        var status = new NetworkMonitorStatus(
            NetworkMonitorSchedulerState.Waiting,
            Now.AddMinutes(1),
            new NetworkMonitorRunOutcome(NetworkMonitorRunStatus.Skipped),
            observation);

        var snapshot = NetworkMonitorPresentation.Snapshot(
            new(true), status, false, Now, "Skipped for foreground work.");

        Assert.Same(observation, snapshot.LastObservation);
        Assert.Equal(NetworkMonitorState.Waiting, snapshot.State);
    }
}
