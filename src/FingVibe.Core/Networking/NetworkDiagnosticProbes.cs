using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using FingVibe.Core.Models;

namespace FingVibe.Core.Networking;

public sealed class NetworkDiagnosticProbes : INetworkDiagnosticProbes
{
    public async Task<DiagnosticObservation> PingAsync(
        DiagnosticCheckpoint checkpoint, IPAddress target, int ttl, CancellationToken cancellationToken)
    {
        using var ping = new Ping();
        var stopwatch = Stopwatch.StartNew();
        try
        {
            var reply = await ping.SendPingAsync(target,
                TimeSpan.FromMilliseconds(NetworkDiagnosticService.TimeoutMilliseconds),
                new byte[32], new PingOptions(ttl, false), cancellationToken).ConfigureAwait(false);
            var responded = reply.Status is IPStatus.Success or IPStatus.TtlExpired;
            return new(checkpoint, target.ToString(),
                responded ? DiagnosticState.Responded : DiagnosticState.Unanswered,
                reply.Status == IPStatus.TtlExpired ? "Router responded (TTL expired)." : reply.Status.ToString(),
                responded ? reply.Address : null,
                reply.Status == IPStatus.Success ? reply.RoundtripTime : responded ? stopwatch.ElapsedMilliseconds : null);
        }
        catch (Exception exception) when (exception is PingException or SocketException or InvalidOperationException)
        {
            return new(checkpoint, target.ToString(), DiagnosticState.Error, $"ICMP probe error: {exception.Message}");
        }
    }

    public async Task<DiagnosticObservation> ResolveAsync(
        DiagnosticCheckpoint checkpoint, IPAddress? resolver, CancellationToken cancellationToken)
    {
        var target = $"{NetworkDiagnosticService.DnsHostname} via {resolver?.ToString() ?? "Windows configured DNS"}";
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(NetworkDiagnosticService.TimeoutMilliseconds);
        var stopwatch = Stopwatch.StartNew();
        try
        {
            IPAddress[] addresses;
            if (resolver is null)
            {
                addresses = await Dns.GetHostAddressesAsync(NetworkDiagnosticService.DnsHostname,
                    AddressFamily.InterNetwork, deadline.Token).ConfigureAwait(false);
            }
            else
            {
                using var client = new UdpClient(AddressFamily.InterNetwork);
                client.Connect(resolver, 53);
                var id = (ushort)Random.Shared.Next(ushort.MaxValue + 1);
                var query = DiagnosticDnsPacket.CreateQuery(id, NetworkDiagnosticService.DnsHostname);
                await client.SendAsync(query, deadline.Token).ConfigureAwait(false);
                var response = await client.ReceiveAsync(deadline.Token).ConfigureAwait(false);
                addresses = DiagnosticDnsPacket.ReadResponse(response.Buffer, id, NetworkDiagnosticService.DnsHostname);
            }
            return addresses.Length > 0
                ? new(checkpoint, target, DiagnosticState.Responded,
                    $"Resolved: {string.Join(", ", addresses.Select(address => address.ToString()))}", addresses[0], stopwatch.ElapsedMilliseconds)
                : new(checkpoint, target, DiagnosticState.Unanswered, "DNS replied without an IPv4 answer.", RoundtripMilliseconds: stopwatch.ElapsedMilliseconds);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return new(checkpoint, target, DiagnosticState.Unanswered, "DNS timed out after 1.5 seconds.");
        }
        catch (Exception exception) when (exception is SocketException or InvalidDataException)
        {
            return new(checkpoint, target, DiagnosticState.Error, $"DNS query failed: {exception.Message}");
        }
    }
}

internal static class DiagnosticDnsPacket
{
    public static byte[] CreateQuery(ushort id, string hostname)
    {
        var packet = new List<byte> { (byte)(id >> 8), (byte)id, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0 };
        foreach (var label in hostname.Split('.'))
        {
            packet.Add((byte)label.Length);
            packet.AddRange(System.Text.Encoding.ASCII.GetBytes(label));
        }
        packet.AddRange([0, 0, 1, 0, 1]);
        return packet.ToArray();
    }

    public static IPAddress[] ReadResponse(byte[] packet, ushort id, string hostname)
    {
        int Word(int position)
        {
            if (position < 0 || position + 2 > packet.Length) throw new InvalidDataException("Truncated DNS packet.");
            return packet[position] << 8 | packet[position + 1];
        }
        string Name(ref int position)
        {
            var labels = new List<string>();
            var cursor = position;
            var jumped = false;
            for (var count = 0; count < 128; count++)
            {
                if (cursor >= packet.Length) throw new InvalidDataException("Truncated DNS name.");
                var length = packet[cursor++];
                if (length == 0)
                {
                    if (!jumped) position = cursor;
                    return string.Join(".", labels);
                }
                if ((length & 0xC0) == 0xC0)
                {
                    if (cursor >= packet.Length) throw new InvalidDataException("Truncated DNS pointer.");
                    var pointer = (length & 0x3F) << 8 | packet[cursor++];
                    if (!jumped) position = cursor;
                    cursor = pointer;
                    jumped = true;
                    continue;
                }
                if (length > 63 || cursor + length > packet.Length) throw new InvalidDataException("Invalid DNS label.");
                labels.Add(System.Text.Encoding.ASCII.GetString(packet, cursor, length));
                cursor += length;
            }
            throw new InvalidDataException("DNS name compression loop.");
        }

        if (packet.Length < 12 || Word(0) != id || (Word(2) & 0xF800) != 0x8000 || Word(4) != 1)
            throw new InvalidDataException("Unexpected DNS response header or transaction.");
        if ((Word(2) & 0x0200) != 0) throw new InvalidDataException("DNS response truncated; TCP fallback is not tested.");
        if ((Word(2) & 15) != 0) throw new InvalidDataException($"Resolver returned DNS error code {Word(2) & 15}.");
        var offset = 12;
        if (!Name(ref offset).Equals(hostname, StringComparison.OrdinalIgnoreCase) || Word(offset) != 1 || Word(offset + 2) != 1)
            throw new InvalidDataException("DNS question does not match the query.");
        offset += 4;
        var addresses = new List<IPAddress>();
        for (var index = 0; index < Word(6); index++)
        {
            Name(ref offset);
            var type = Word(offset);
            var recordClass = Word(offset + 2);
            var length = Word(offset + 8);
            offset += 10;
            if (offset + length > packet.Length) throw new InvalidDataException("Truncated DNS answer.");
            if (type == 1 && recordClass == 1 && length == 4)
                addresses.Add(new IPAddress(packet.AsSpan(offset, 4)));
            offset += length;
        }
        return addresses.ToArray();
    }
}
