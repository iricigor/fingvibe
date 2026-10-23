using System.Net;
using System.Net.Sockets;
using System.Text;
using FingVibe.Core.Networking;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class ServiceBannerProbeTests
{
    [Theory]
    [InlineData("HTTP/1.1 200 OK\r\nServer: Microsoft-IIS/10.0\r\n\r\n", false, "Microsoft-IIS/10.0")]
    [InlineData("HTTP/1.0 405 Method Not Allowed\r\nserver: Linux UPnP/1.0\r\n\r\n", false, "Linux UPnP/1.0")]
    [InlineData("SSH-2.0-OpenSSH_9.2p1 Debian-2\r\n", true, "SSH-2.0-OpenSSH_9.2p1 Debian-2")]
    [InlineData("HTTP/1.1 200 OK\r\n\r\nServer: Windows", false, null)]
    [InlineData("not-http\r\nServer: Windows\r\n\r\n", false, null)]
    [InlineData("Welcome to Linux\r\n", true, null)]
    public void Parser_OnlyUsesActualServerOrSshBanner(string response, bool ssh, string? expected)
    {
        Assert.Equal(expected, ServiceBannerProbe.ParseBanner(response, ssh, ssh ? 22 : 80)?.Value);
    }

    [Fact]
    public async Task Probe_ZeroTimeoutDoesNotConnectAndStillPropagatesCancellation()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        var probe = new ServiceBannerProbe(TimeSpan.Zero);

        Assert.Null(await probe.ProbePortAsync(IPAddress.Loopback, port, true, CancellationToken.None));
        Assert.False(listener.Pending());

        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            probe.ProbePortAsync(IPAddress.Loopback, port, true, cancellation.Token));
    }

    [Fact]
    public async Task Probe_ReadsFragmentedSshAfterPreambleWithoutWaitingForDisconnect()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var server = Task.Run(async () =>
        {
            using var client = await listener.AcceptTcpClientAsync(cancellation.Token);
            using var stream = client.GetStream();
            await stream.WriteAsync(Encoding.ASCII.GetBytes("Welcome\r\n"), cancellation.Token);
            await Task.Delay(30, cancellation.Token);
            await stream.WriteAsync(Encoding.ASCII.GetBytes("SSH-2.0-OpenSSH_9.2p1 Deb"), cancellation.Token);
            await Task.Delay(30, cancellation.Token);
            await stream.WriteAsync(Encoding.ASCII.GetBytes("ian-2\r\n"), cancellation.Token);
        }, cancellation.Token);
        var result = await new ServiceBannerProbe(TimeSpan.FromSeconds(2)).ProbePortAsync(
            IPAddress.Loopback, ((IPEndPoint)listener.LocalEndpoint).Port, true, cancellation.Token);
        await server;
        Assert.Equal("SSH-2.0-OpenSSH_9.2p1 Debian-2", result?.Value);
    }

    [Fact]
    public async Task Probe_SendsHeadRequestAndReadsHeadersOnly()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var server = Task.Run(async () =>
        {
            using var client = await listener.AcceptTcpClientAsync(cancellation.Token);
            using var stream = client.GetStream();
            var buffer = new byte[1024];
            var read = await stream.ReadAsync(buffer, cancellation.Token);
            Assert.StartsWith("HEAD / HTTP/1.0\r\n", Encoding.ASCII.GetString(buffer, 0, read));
            await stream.WriteAsync(Encoding.ASCII.GetBytes(
                "HTTP/1.1 200 OK\r\nServer: Microsoft-HTTPAPI/2.0\r\n\r\n"), cancellation.Token);
        }, cancellation.Token);
        var result = await new ServiceBannerProbe(TimeSpan.FromSeconds(2)).ProbePortAsync(
            IPAddress.Loopback, ((IPEndPoint)listener.LocalEndpoint).Port, false, cancellation.Token);
        await server;
        Assert.Equal("Microsoft-HTTPAPI/2.0", result?.Value);
    }

    [Fact]
    public async Task Probe_BoundsReadsAndPropagatesCancellation()
    {
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        using var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        var server = Task.Run(async () =>
        {
            using var client = await listener.AcceptTcpClientAsync(cancellation.Token);
            await client.GetStream().WriteAsync(new byte[8192], cancellation.Token);
        }, cancellation.Token);
        Assert.Null(await new ServiceBannerProbe(TimeSpan.FromSeconds(2)).ProbePortAsync(
            IPAddress.Loopback, ((IPEndPoint)listener.LocalEndpoint).Port, true, cancellation.Token));
        await server;

        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            new ServiceBannerProbe().ProbePortAsync(IPAddress.Loopback,
                ((IPEndPoint)listener.LocalEndpoint).Port, true, cancellation.Token));
    }
}
