using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class UdpServiceProbeTests
{
    private static readonly IPAddress Local = IPAddress.Loopback;

    private static async Task<UdpServiceObservation> RespondAsync(
        int service, Func<byte[], byte[]> respond, IPAddress? localAddress = null)
    {
        using var server = new UdpClient(new IPEndPoint(Local, 0));
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        var check = UdpServiceProbe.CheckPortAsync(Local, localAddress ?? Local, service,
            ((IPEndPoint)server.Client.LocalEndPoint!).Port, TimeSpan.FromSeconds(1), deadline.Token);
        var request = await server.ReceiveAsync(deadline.Token);
        Assert.Equal(Local, request.RemoteEndPoint.Address);
        await server.SendAsync(respond(request.Buffer), request.RemoteEndPoint, deadline.Token);
        return await check;
    }

    [Theory]
    [InlineData(0)]
    [InlineData(3)]
    [InlineData(5)]
    public async Task Dns_MatchingSuccessAndErrorRepliesConfirmResponse(int code)
    {
        var observation = await RespondAsync(53, query =>
        {
            Assert.Equal(0, query[2]);
            Assert.True(query.Length < 64);
            query[2] = 0x80;
            query[3] = (byte)code;
            return query;
        });
        Assert.Equal(UdpServiceState.Responded, observation.State);
        Assert.Contains($"response code {code}", observation.Detail);
    }

    [Theory]
    [InlineData("transaction")]
    [InlineData("question")]
    [InlineData("truncated")]
    [InlineData("short")]
    [InlineData("oversized")]
    [InlineData("trailing")]
    [InlineData("compression-loop")]
    [InlineData("truncated-authority")]
    [InlineData("malformed-cname")]
    public async Task Dns_UntrustedOrMalformedReplyIsAnExplicitError(string fault)
    {
        var result = await RespondAsync(53, query =>
        {
            query[2] = 0x80;
            switch (fault)
            {
                case "transaction": query[0] ^= 1; break;
                case "question": query[13] ^= 1; break;
                case "truncated": query[2] |= 2; break;
                case "short": return query[..8];
                case "oversized": return new byte[513];
                case "trailing": return [.. query, 0];
                case "compression-loop": query[12] = 0xC0; query[13] = 12; break;
                case "truncated-authority": query[9] = 1; break;
                case "malformed-cname":
                    query[7] = 1;
                    return [.. query, 0xC0, 12, 0, 5, 0, 1, 0, 0, 0, 0, 0, 1, 0xC0];
            }
            return query;
        });
        Assert.Equal(UdpServiceState.Error, result.State);
        Assert.False(string.IsNullOrWhiteSpace(result.Detail));
    }

    private static byte[] NtpReply(byte[] query)
    {
        Assert.Equal(48, query.Length);
        Assert.Equal(0x23, query[0]);
        var reply = new byte[48];
        reply[0] = 0x24;
        reply[1] = 2;
        query.AsSpan(40, 8).CopyTo(reply.AsSpan(24));
        query.AsSpan(40, 8).CopyTo(reply.AsSpan(32));
        query.AsSpan(40, 8).CopyTo(reply.AsSpan(40));
        return reply;
    }

    [Fact]
    public async Task Ntp_MatchingServerReplyConfirmsResponse()
    {
        Assert.Equal(UdpServiceState.Responded, (await RespondAsync(123, NtpReply)).State);
    }

    [Theory]
    [InlineData("origin")]
    [InlineData("mode")]
    [InlineData("version")]
    [InlineData("short")]
    [InlineData("kiss-of-death")]
    [InlineData("unsynchronized")]
    [InlineData("stratum")]
    [InlineData("timestamps")]
    public async Task Ntp_InvalidOrUnusableReplyIsAnExplicitError(string fault)
    {
        var result = await RespondAsync(123, query =>
        {
            var reply = NtpReply(query);
            switch (fault)
            {
                case "origin": reply[24] ^= 1; break;
                case "mode": reply[0] = 0x23; break;
                case "version": reply[0] = 0x14; break;
                case "short": return reply[..47];
                case "kiss-of-death": reply[1] = 0; break;
                case "unsynchronized": reply[0] |= 0xC0; break;
                case "stratum": reply[1] = 16; break;
                case "timestamps": Array.Clear(reply, 32, 16); break;
            }
            return reply;
        });
        Assert.Equal(UdpServiceState.Error, result.State);
    }

    [Fact]
    public async Task Silence_IsBoundedInconclusiveAndSendsOnlyOneRequest()
    {
        Assert.Equal(TimeSpan.FromSeconds(2), UdpServiceProbe.Timeout);
        Assert.Equal(512, UdpServiceProbe.ResponseSizeLimit);
        using var server = new UdpClient(new IPEndPoint(Local, 0));
        var clock = Stopwatch.StartNew();
        var check = UdpServiceProbe.CheckPortAsync(Local, Local, 53,
            ((IPEndPoint)server.Client.LocalEndPoint!).Port, TimeSpan.FromMilliseconds(200), CancellationToken.None);
        using var receiveDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        await server.ReceiveAsync(receiveDeadline.Token);
        var result = await check;
        Assert.Equal(UdpServiceState.NoResponse, result.State);
        Assert.Contains("inconclusive", result.AccessibleLabel);
        Assert.InRange(clock.ElapsedMilliseconds, 100, 1500);
        Assert.Equal(0, server.Available);
    }

    [Fact]
    public async Task ReplyFromUnrelatedSourceCannotConfirmService()
    {
        using var server = new UdpClient(new IPEndPoint(Local, 0));
        using var unrelated = new UdpClient(new IPEndPoint(Local, 0));
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        var check = UdpServiceProbe.CheckPortAsync(Local, Local, 53,
            ((IPEndPoint)server.Client.LocalEndPoint!).Port, TimeSpan.FromMilliseconds(300), deadline.Token);
        var request = await server.ReceiveAsync(deadline.Token);
        request.Buffer[2] = 0x80;
        await unrelated.SendAsync(request.Buffer, request.RemoteEndPoint, deadline.Token);
        Assert.Equal(UdpServiceState.NoResponse, (await check).State);
    }

    [Fact]
    public async Task CancellationTerminatesPendingReceive()
    {
        using var server = new UdpClient(new IPEndPoint(Local, 0));
        using var cancel = new CancellationTokenSource();
        var check = UdpServiceProbe.CheckPortAsync(Local, Local, 123,
            ((IPEndPoint)server.Client.LocalEndPoint!).Port, TimeSpan.FromSeconds(2), cancel.Token);
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(2));
        await server.ReceiveAsync(deadline.Token);
        cancel.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => check.WaitAsync(TimeSpan.FromSeconds(1)));
    }

    [Fact]
    public async Task InvalidSelectedInterfaceIsAnErrorNotSilence()
    {
        var result = await UdpServiceProbe.CheckPortAsync(Local, IPAddress.Parse("203.0.113.99"),
            53, 12345, TimeSpan.FromMilliseconds(100), CancellationToken.None);
        Assert.Equal(UdpServiceState.Error, result.State);
    }
}
