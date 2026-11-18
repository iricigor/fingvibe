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

    private sealed class EndpointProgress(Action<OpenPort> report) : IProgress<OpenPort>
    {
        public void Report(OpenPort value) => report(value);
    }

    [Fact]
    public async Task AdditionalWorkersBoundConcurrencyAndReportEveryCataloguePort()
    {
        Assert.Equal(32, PortScannerService.AdditionalConcurrency);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var filled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var active = 0;
        var maximum = 0;
        var reported = new System.Collections.Concurrent.ConcurrentBag<ScanProgress>();
        var scan = PortScannerService.RunProbesAsync(PortScannerService.AdditionalPlan, async (port, _, token) =>
        {
            var count = Interlocked.Increment(ref active);
            lock (reported) maximum = Math.Max(maximum, count);
            if (count == 32) filled.TrySetResult();
            await release.Task.WaitAsync(token);
            await Task.Delay(5, token);
            Interlocked.Decrement(ref active);
            return new OpenPort(port.Key, port.Value);
        }, CancellationToken.None, new InlineProgress(reported.Add));
        await filled.Task.WaitAsync(TimeSpan.FromSeconds(2));
        Assert.Equal(32, Volatile.Read(ref active));
        release.SetResult();
        var results = await scan.WaitAsync(TimeSpan.FromSeconds(3));
        Assert.Equal(32, maximum);
        var catalogueCount = PortScannerService.AdditionalPorts.Count;
        Assert.Equal(catalogueCount, results.Count);
        Assert.Equal(Enumerable.Range(1, catalogueCount), reported.Select(value => value.Completed).Order());
        Assert.All(reported, value => Assert.Equal(catalogueCount, value.Total));
    }

    [Fact]
    public async Task CancellationStopsQueuedAndActiveWorkers()
    {
        using var cancel = new CancellationTokenSource();
        var filled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var started = 0;
        var scan = PortScannerService.RunProbesAsync(PortScannerService.AdditionalPlan, async (port, _, token) =>
        {
            if (Interlocked.Increment(ref started) == 32) filled.SetResult();
            await Task.Delay(Timeout.InfiniteTimeSpan, token);
            return null;
        }, cancel.Token);
        await filled.Task.WaitAsync(TimeSpan.FromSeconds(2));
        cancel.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => scan.WaitAsync(TimeSpan.FromSeconds(1)));
        Assert.Equal(32, started);
    }

    [Fact]
    public async Task CompletedEndpointIsReportedBeforeOtherProbesFinish()
    {
        using var cancel = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        var reported = new TaskCompletionSource<OpenPort>(TaskCreationOptions.RunContinuationsAsynchronously);
        var scan = PortScannerService.RunProbesAsync(PortScannerService.AdditionalPlan, async (port, _, token) =>
        {
            if (port.Key == 3389) return new OpenPort(port.Key, port.Value);
            await Task.Delay(Timeout.InfiniteTimeSpan, token);
            return null;
        }, cancel.Token, resultProgress: new EndpointProgress(port => reported.TrySetResult(port)));
        var endpoint = await reported.Task.WaitAsync(TimeSpan.FromSeconds(1));
        Assert.Equal(3389, endpoint.Port);
        Assert.False(scan.IsCompleted);
        cancel.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => scan);
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

    [Fact]
    public async Task AdditionalScanKeepsTheDefaultTimeoutAndNeverProbesDefaultPorts()
    {
        var probed = new System.Collections.Concurrent.ConcurrentBag<(int Port, TimeSpan Timeout)>();
        var scanner = new PortScannerService((_, port, timeout, _) =>
        {
            probed.Add((port.Key, timeout));
            return Task.FromResult<OpenPort?>(null);
        });

        await scanner.ScanAdditionalAsync(IPAddress.Parse("192.0.2.10"), CancellationToken.None);

        Assert.Equal(PortScannerService.AdditionalPorts.Keys.Order(), probed.Select(item => item.Port).Order());
        Assert.Empty(probed.Select(item => item.Port).Intersect(PortScannerService.CommonPorts.Keys));
        Assert.All(probed, item => Assert.Equal(TimeSpan.FromMilliseconds(400), item.Timeout));
    }

    [Fact]
    public async Task FullScanProbesEveryTcpPortOnceWithBoundedConcurrencyAndShortTimeout()
    {
        var counts = new int[65_536];
        var active = 0;
        var maximum = 0;
        var timeouts = new System.Collections.Concurrent.ConcurrentDictionary<TimeSpan, byte>();
        var outOfRange = 0;
        var reported = new System.Collections.Concurrent.ConcurrentBag<ScanProgress>();
        var scanner = new PortScannerService(async (_, port, timeout, token) =>
        {
            var current = Interlocked.Increment(ref active);
            int observed;
            while (current > (observed = Volatile.Read(ref maximum))
                && Interlocked.CompareExchange(ref maximum, current, observed) != observed) { }
            timeouts.TryAdd(timeout, 0);
            if (port.Key is < 1 or > 65_535) Interlocked.Increment(ref outOfRange);
            else Interlocked.Increment(ref counts[port.Key]);
            await Task.Yield();
            Interlocked.Decrement(ref active);
            return port.Key is 22 or 31_337 ? new OpenPort(port.Key, port.Value) : null;
        });

        var results = await scanner.ScanFullTcpAsync(IPAddress.Parse("192.0.2.10"), CancellationToken.None,
            progress: new InlineProgress(reported.Add)).WaitAsync(TimeSpan.FromSeconds(30));

        Assert.Equal(0, outOfRange);
        Assert.Equal(0, counts[0]);
        Assert.All(Enumerable.Range(1, 65_535), port => Assert.Equal(1, counts[port]));
        Assert.InRange(maximum, 2, 128);
        Assert.Equal(new[] { TimeSpan.FromMilliseconds(200) }, timeouts.Keys);
        Assert.Equal(new[] { 22, 31_337 }, results.Select(port => port.Port));
        Assert.Equal(new[] { "SSH", PortScannerService.UnlistedServiceName }, results.Select(port => port.ServiceName));
        Assert.Equal(65_535, reported.Max(value => value.Completed));
        Assert.All(reported, value => Assert.Equal(65_535, value.Total));
        Assert.True(reported.Count < 1_000, "Progress is throttled for 65,535 probes.");
    }

    [Fact]
    public async Task FullScanUsesAtMost128ConcurrentAttempts()
    {
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var filled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var active = 0;
        var started = 0;
        var scan = PortScannerService.RunProbesAsync(PortScannerService.FullTcpPlan, async (port, _, token) =>
        {
            Interlocked.Increment(ref started);
            if (Interlocked.Increment(ref active) == 128) filled.TrySetResult();
            await release.Task.WaitAsync(token);
            Interlocked.Decrement(ref active);
            return null;
        }, CancellationToken.None);
        await filled.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await Task.Delay(50);
        Assert.Equal(128, Volatile.Read(ref started));
        release.SetResult();
        await scan.WaitAsync(TimeSpan.FromSeconds(30));
        Assert.Equal(65_535, started);
    }

    [Fact]
    public async Task FullScanCancellationStopsDispatchCancelsInFlightAndKeepsCompletedResults()
    {
        using var cancel = new CancellationTokenSource();
        var filled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var started = 0;
        var blocked = 0;
        var canceledInFlight = 0;
        var found = new System.Collections.Concurrent.ConcurrentBag<OpenPort>();
        var scan = PortScannerService.RunProbesAsync(PortScannerService.FullTcpPlan, async (port, _, token) =>
        {
            Interlocked.Increment(ref started);
            if (port.Key <= 3) return new OpenPort(port.Key, port.Value);
            if (Interlocked.Increment(ref blocked) == 128) filled.TrySetResult();
            try { await Task.Delay(Timeout.InfiniteTimeSpan, token); }
            catch (OperationCanceledException) { Interlocked.Increment(ref canceledInFlight); throw; }
            return null;
        }, cancel.Token, resultProgress: new EndpointProgress(found.Add));
        await filled.Task.WaitAsync(TimeSpan.FromSeconds(5));
        cancel.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => scan.WaitAsync(TimeSpan.FromSeconds(2)));
        var startedAtCancel = Volatile.Read(ref started);
        await Task.Delay(100);
        Assert.Equal(startedAtCancel, Volatile.Read(ref started));
        Assert.Equal(128 + 3, startedAtCancel);
        Assert.Equal(128, canceledInFlight);
        Assert.Equal(new[] { 1, 2, 3 }, found.Select(port => port.Port).Order());
    }

    [Fact]
    public async Task FullScanFailureSurfacesAfterCompletedResultsWereReported()
    {
        var found = new System.Collections.Concurrent.ConcurrentBag<OpenPort>();
        var scan = PortScannerService.RunProbesAsync(PortScannerService.FullTcpPlan, (port, _, _) =>
            port.Key switch
            {
                < 100 => Task.FromResult<OpenPort?>(port.Key == 80 ? new OpenPort(80, "HTTP") : null),
                100 => Task.FromException<OpenPort?>(new SocketException((int)SocketError.NetworkUnreachable)),
                _ => Task.FromResult<OpenPort?>(null)
            }, CancellationToken.None, resultProgress: new EndpointProgress(found.Add));
        await Assert.ThrowsAsync<SocketException>(() => scan.WaitAsync(TimeSpan.FromSeconds(30)));
        Assert.Contains(found, port => port.Port == 80);
    }

    [Fact]
    public async Task AccessDeniedPortsAreReportedAsBlockedWithoutAbortingTheScan()
    {
        var blocked = new System.Collections.Concurrent.ConcurrentBag<int>();
        var scanner = new PortScannerService((_, port, _, _) => port.Key switch
        {
            137 => Task.FromException<OpenPort?>(new SocketException((int)SocketError.AccessDenied)),
            7 => Task.FromResult<OpenPort?>(new OpenPort(7, port.Value)),
            _ => Task.FromResult<OpenPort?>(null)
        });

        var results = await scanner.ScanFullTcpAsync(IPAddress.Loopback, CancellationToken.None,
            blocked: blocked.Add).WaitAsync(TimeSpan.FromSeconds(30));

        Assert.Equal(new[] { 137 }, blocked);
        Assert.Equal(new[] { 7 }, results.Select(port => port.Port));
        await Assert.ThrowsAsync<SocketException>(() => new PortScannerService((_, port, _, _) =>
            Task.FromException<OpenPort?>(new SocketException((int)SocketError.AddressNotAvailable)))
            .ScanFullTcpAsync(IPAddress.Loopback, CancellationToken.None));
    }
}