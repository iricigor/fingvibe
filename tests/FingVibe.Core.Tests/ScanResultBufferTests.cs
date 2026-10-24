using System.Net;
using FingVibe.App;
using FingVibe.Core.Models;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class ScanResultBufferTests
{
    [Fact]
    public void BuffersOnlyRespondingDevices()
    {
        var buffer = new ScanResultBuffer();
        var alive = new ScanResult(IPAddress.Loopback, HostStatus.Alive, 1, TimeSpan.Zero);
        buffer.Report(new ScanResult(IPAddress.Any, HostStatus.Unreachable, null, TimeSpan.Zero));
        buffer.Report(alive);

        Assert.Equal(alive, Assert.Single(buffer.Results));
    }

    [Fact]
    public async Task CollectsConcurrentReportsWithoutMutatingPreviouslyReadResults()
    {
        var buffer = new ScanResultBuffer();
        var initial = buffer.Results;
        await Parallel.ForEachAsync(Enumerable.Range(1, 254), (index, _) =>
        {
            buffer.Report(new ScanResult(IPAddress.Parse($"192.168.0.{index}"),
                HostStatus.Alive, 1, TimeSpan.Zero));
            return ValueTask.CompletedTask;
        });

        Assert.Empty(initial);
        Assert.Equal(254, buffer.Results.Count);
        Assert.Equal(254, buffer.Results.Select(result => result.Address).Distinct().Count());
    }
}
