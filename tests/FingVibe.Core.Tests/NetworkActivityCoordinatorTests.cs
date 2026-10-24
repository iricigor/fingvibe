using FingVibe.App;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class NetworkActivityCoordinatorTests
{
    [Theory]
    [InlineData(nameof(NetworkActivityKind.LanScan), nameof(NetworkActivityKind.InternetSpeedTest))]
    [InlineData(nameof(NetworkActivityKind.InternetSpeedTest), nameof(NetworkActivityKind.LanScan))]
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
}
