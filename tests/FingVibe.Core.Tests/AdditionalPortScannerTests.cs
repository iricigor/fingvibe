using System.Net;
using System.Net.Sockets;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class AdditionalPortScannerTests
{
    private sealed class InlineProgress(Action<ScanProgress> report) : IProgress<ScanProgress>
    {
        public void Report(ScanProgress value) => report(value);
    }

    [Fact]
    public async Task AdditionalWorkersBoundConcurrencyAndReportAll100Ports()
    {
        Assert.Equal(16, PortScannerService.AdditionalConcurrency);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var filled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var active = 0;
        var maximum = 0;
        var reported = new System.Collections.Concurrent.ConcurrentBag<ScanProgress>();
        var scan = PortScannerService.RunAdditionalProbesAsync(async (port, token) =>
        {
            var count = Interlocked.Increment(ref active);
            lock (reported) maximum = Math.Max(maximum, count);
            if (count == 16) filled.TrySetResult();
            await release.Task.WaitAsync(token);
            await Task.Delay(5, token);
            Interlocked.Decrement(ref active);
            return new OpenPort(port.Key, port.Value);
        }, CancellationToken.None, new InlineProgress(reported.Add));
        await filled.Task.WaitAsync(TimeSpan.FromSeconds(2));
        Assert.Equal(16, Volatile.Read(ref active));
        release.SetResult();
        var results = await scan.WaitAsync(TimeSpan.FromSeconds(3));
        Assert.Equal(16, maximum);
        Assert.Equal(100, results.Count);
        Assert.Equal(Enumerable.Range(1, 100), reported.Select(value => value.Completed).Order());
        Assert.All(reported, value => Assert.Equal(100, value.Total));
    }

    [Fact]
    public async Task CancellationStopsQueuedAndActiveWorkers()
    {
        using var cancel = new CancellationTokenSource();
        var filled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var started = 0;
        var scan = PortScannerService.RunAdditionalProbesAsync(async (port, token) =>
        {
            if (Interlocked.Increment(ref started) == 16) filled.SetResult();
            await Task.Delay(Timeout.InfiniteTimeSpan, token);
            return null;
        }, cancel.Token);
        await filled.Task.WaitAsync(TimeSpan.FromSeconds(2));
        cancel.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => scan.WaitAsync(TimeSpan.FromSeconds(1)));
        Assert.Equal(16, started);
    }

    [Fact]
    public async Task SelectedInterfaceIsUsedForTcpConnectionsAndBindFailuresAreVisible()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        try
        {
            var port = ((IPEndPoint)listener.LocalEndpoint).Port;
            var scanner = new PortScannerService(TimeSpan.FromSeconds(1));
            var result = await scanner.ProbeAsync(IPAddress.Loopback, new(port, "Test"),
                CancellationToken.None, IPAddress.Loopback);
            Assert.Equal(port, result!.Port);
            using var client = await listener.AcceptTcpClientAsync();
            Assert.Equal(IPAddress.Loopback, ((IPEndPoint)client.Client.RemoteEndPoint!).Address);
            await Assert.ThrowsAsync<SocketException>(() => scanner.ProbeAsync(IPAddress.Loopback,
                new(port, "Test"), CancellationToken.None, IPAddress.Parse("203.0.113.99")));
        }
        finally { listener.Stop(); }
    }
}
