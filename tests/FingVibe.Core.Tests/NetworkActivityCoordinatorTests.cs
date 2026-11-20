using FingVibe.App;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class NetworkActivityCoordinatorTests
{
    [Theory]
    [InlineData(nameof(NetworkActivityKind.LanScan), nameof(NetworkActivityKind.InternetSpeedTest))]
    [InlineData(nameof(NetworkActivityKind.InternetSpeedTest), nameof(NetworkActivityKind.LanScan))]
    [InlineData(nameof(NetworkActivityKind.NetworkTroubleshooting), nameof(NetworkActivityKind.LanScan))]
    [InlineData(nameof(NetworkActivityKind.LanScan), nameof(NetworkActivityKind.NetworkTroubleshooting))]
    [InlineData(nameof(NetworkActivityKind.NetworkTroubleshooting), nameof(NetworkActivityKind.InternetSpeedTest))]
    [InlineData(nameof(NetworkActivityKind.InternetSpeedTest), nameof(NetworkActivityKind.NetworkTroubleshooting))]
    [InlineData(nameof(NetworkActivityKind.DeviceServiceScan), nameof(NetworkActivityKind.LanScan))]
    [InlineData(nameof(NetworkActivityKind.DeviceServiceScan), nameof(NetworkActivityKind.InternetSpeedTest))]
    [InlineData(nameof(NetworkActivityKind.DeviceServiceScan), nameof(NetworkActivityKind.NetworkTroubleshooting))]
    [InlineData(nameof(NetworkActivityKind.LanScan), nameof(NetworkActivityKind.DeviceServiceScan))]
    public void ActiveNetworkActivityPreventsAnotherActivity(
        string activeName,
        string requestedName)
    {
        var active = Enum.Parse<NetworkActivityKind>(activeName);
        var requested = Enum.Parse<NetworkActivityKind>(requestedName);
        var coordinator = new NetworkActivityCoordinator();

        Assert.True(coordinator.TryAcquire(active, out var first));
        Assert.False(coordinator.TryAcquire(requested, out var second));
        Assert.Null(second);
        Assert.Equal(active, coordinator.ActiveKind);

        first!.Dispose();

        Assert.True(coordinator.TryAcquire(requested, out var retry));
        Assert.Equal(requested, coordinator.ActiveKind);
        retry!.Dispose();
        Assert.Null(coordinator.ActiveKind);
    }

    [Fact]
    public void DisposingAnOldLeaseCannotReleaseANewerActivity()
    {
        var coordinator = new NetworkActivityCoordinator();
        Assert.True(coordinator.TryAcquire(NetworkActivityKind.LanScan, out var first));

        first!.Dispose();
        Assert.True(coordinator.TryAcquire(NetworkActivityKind.InternetSpeedTest, out var second));
        first.Dispose();

        Assert.Equal(NetworkActivityKind.InternetSpeedTest, coordinator.ActiveKind);
        second!.Dispose();
        Assert.Null(coordinator.ActiveKind);
    }

    [Fact]
    public void ConcurrentAcquisitionsAllowOnlyOneNetworkActivity()
    {
        var coordinator = new NetworkActivityCoordinator();
        var acquired = 0;
        var leases = new List<IDisposable>();
        var sync = new object();

        Parallel.For(0, 32, index =>
        {
            if (coordinator.TryAcquire(
                    index % 2 == 0 ? NetworkActivityKind.LanScan : NetworkActivityKind.InternetSpeedTest,
                    out var lease))
            {
                Interlocked.Increment(ref acquired);
                lock (sync)
                {
                    leases.Add(lease!);
                }
            }
        });

        Assert.Equal(1, acquired);
        Assert.Single(leases);
        leases[0].Dispose();
        Assert.Null(coordinator.ActiveKind);
    }

    [Fact]
    public async Task ForegroundActivityCancelsAndAwaitsTheBackgroundMonitor()
    {
        var coordinator = new NetworkActivityCoordinator();
        using var monitorCancellation = new CancellationTokenSource();
        Assert.True(coordinator.TryAcquireBackground(
            NetworkActivityKind.NetworkHealthMonitor, monitorCancellation, out var monitor));

        var foreground = coordinator.AcquireAsync(NetworkActivityKind.LanScan);

        Assert.True(monitorCancellation.IsCancellationRequested);
        Assert.False(foreground.IsCompleted);
        Assert.Equal(NetworkActivityKind.NetworkHealthMonitor, coordinator.ActiveKind);
        monitor!.Dispose();

        using var lease = await foreground.WaitAsync(ScanExecutionFixture.Timeout);
        Assert.NotNull(lease);
        Assert.Equal(NetworkActivityKind.LanScan, coordinator.ActiveKind);
        lease!.Dispose();
        Assert.Null(coordinator.ActiveKind);
    }

    [Fact]
    public async Task ForegroundActivityDoesNotDisplaceAnotherForegroundActivity()
    {
        var coordinator = new NetworkActivityCoordinator();
        Assert.True(coordinator.TryAcquire(NetworkActivityKind.InternetSpeedTest, out var speedTest));

        Assert.Null(await coordinator.AcquireAsync(NetworkActivityKind.LanScan));
        Assert.False(coordinator.TryAcquireBackground(
            NetworkActivityKind.NetworkHealthMonitor, new(), out _));
        Assert.Equal(NetworkActivityKind.InternetSpeedTest, coordinator.ActiveKind);

        speedTest!.Dispose();
    }
}
