using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using FingVibe.Core.Models;

namespace FingVibe.Core.Networking;

public sealed class UdpServiceProbe
{
    public const int ResponseSizeLimit = 512;
    public static readonly TimeSpan Timeout = TimeSpan.FromSeconds(2);

    public async Task<IReadOnlyList<UdpServiceObservation>> CheckAsync(
        IPAddress address, IPAddress localAddress, CancellationToken cancellationToken,
        IProgress<ScanProgress>? progress = null)
    {
        var completed = 0;
        var tasks = new[] { 53, 123 }.Select(async port =>
        {
            var observation = await CheckPortAsync(address, localAddress, port, port, Timeout, cancellationToken)
                .ConfigureAwait(false);
            progress?.Report(new ScanProgress(Interlocked.Increment(ref completed), 2));
            return observation;
        });
        return await Task.WhenAll(tasks).ConfigureAwait(false);
    }

    internal static async Task<UdpServiceObservation> CheckPortAsync(
        IPAddress address, IPAddress localAddress, int servicePort, int destinationPort,
        TimeSpan timeout, CancellationToken cancellationToken)
    {
        var name = servicePort == 53 ? "DNS" : "NTP";
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(timeout);
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            using var socket = new Socket(address.AddressFamily, SocketType.Dgram, ProtocolType.Udp);
            socket.Bind(new IPEndPoint(localAddress, 0));
            socket.Connect(new IPEndPoint(address, destinationPort));
            var id = (ushort)RandomNumberGenerator.GetInt32(65536);
            var request = servicePort == 53
                ? DiagnosticDnsPacket.CreateQuery(id, NetworkDiagnosticService.DnsHostname)
                : CreateNtpRequest();
            // Avoid requesting recursive DNS work from a device being inspected.
            if (servicePort == 53) request[2] = 0;
            await socket.SendAsync(request, SocketFlags.None, deadline.Token).ConfigureAwait(false);
            var buffer = new byte[ResponseSizeLimit + 1];
            var length = await socket.ReceiveAsync(buffer, SocketFlags.None, deadline.Token).ConfigureAwait(false);
            if (length > ResponseSizeLimit)
                throw new InvalidDataException("Response exceeds the 512-byte limit.");
            var response = buffer[..length];
            string detail;
            if (servicePort == 53)
            {
                DiagnosticDnsPacket.ReadResponse(response, id, NetworkDiagnosticService.DnsHostname, allowErrorResponse: true);
                detail = $"Matching valid DNS reply (response code {response[3] & 15}).";
            }
            else
            {
                ValidateNtpResponse(response, request);
                detail = "Matching valid NTP server reply.";
            }
            return new(servicePort, name, UdpServiceState.Responded, detail);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return new(servicePort, name, UdpServiceState.NoResponse, "The check deadline expired; silence does not establish open or closed.");
        }
        catch (Exception exception) when (exception is SocketException or InvalidDataException)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return new(servicePort, name, UdpServiceState.Error, exception.Message);
        }
    }

    internal static byte[] CreateNtpRequest()
    {
        var request = new byte[48];
        request[0] = 0x23; // NTP version 4, client mode; no control or monitoring request.
        var seconds = (uint)(DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 2_208_988_800L);
        BinaryPrimitives.WriteUInt32BigEndian(request.AsSpan(40), seconds);
        RandomNumberGenerator.Fill(request.AsSpan(44, 4));
        return request;
    }

    internal static void ValidateNtpResponse(byte[] response, byte[] request)
    {
        if (response.Length != 48 || (response[0] & 7) != 4 || ((response[0] >> 3) & 7) is not (3 or 4)
            || !response.AsSpan(24, 8).SequenceEqual(request.AsSpan(40, 8)))
            throw new InvalidDataException("NTP response length, server mode, version, or origin timestamp does not match.");
        if (response[1] == 0)
            throw new InvalidDataException("NTP server returned a kiss-of-death response; no retry is sent.");
        if ((response[0] >> 6) == 3 || response[1] > 15
            || BinaryPrimitives.ReadUInt64BigEndian(response.AsSpan(32)) == 0
            || BinaryPrimitives.ReadUInt64BigEndian(response.AsSpan(40)) == 0)
            throw new InvalidDataException("NTP server is unsynchronized or returned invalid timestamps/stratum.");
    }
}
