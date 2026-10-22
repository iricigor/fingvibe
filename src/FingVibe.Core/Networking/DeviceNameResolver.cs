using System.Net;
using System.Net.Sockets;
using System.Text;

namespace FingVibe.Core.Networking;

public enum DeviceNameSource
{
    Ssdp,
    Mdns,
    NetBios,
    ReverseDns
}

public sealed record DeviceNameCandidate(string Name, DeviceNameSource Source);

public sealed class DeviceNameResolver
{
    private readonly TimeSpan _timeout;

    public DeviceNameResolver(TimeSpan? timeout = null)
    {
        _timeout = timeout ?? TimeSpan.FromMilliseconds(700);
    }

    public async Task<string?> ResolveAsync(
        IPAddress address,
        IReadOnlyDictionary<IPAddress, string> ssdpNames,
        CancellationToken cancellationToken)
    {
        var candidates = new List<DeviceNameCandidate>();
        if (ssdpNames.TryGetValue(address, out var ssdpName))
        {
            candidates.Add(new DeviceNameCandidate(ssdpName, DeviceNameSource.Ssdp));
        }

        var reverseDns = ResolveReverseDnsAsync(address, cancellationToken);
        var mdns = ResolveMdnsAsync(address, cancellationToken);
        var netBios = ResolveNetBiosAsync(address, cancellationToken);
        await Task.WhenAll(reverseDns, mdns, netBios).ConfigureAwait(false);

        if (reverseDns.Result is { } dnsName)
        {
            candidates.Add(new DeviceNameCandidate(dnsName, DeviceNameSource.ReverseDns));
        }

        if (mdns.Result is { } mdnsName)
        {
            candidates.Add(new DeviceNameCandidate(mdnsName, DeviceNameSource.Mdns));
        }

        if (netBios.Result is { } netBiosName)
        {
            candidates.Add(new DeviceNameCandidate(netBiosName, DeviceNameSource.NetBios));
        }

        return SelectDisplayName(candidates);
    }

    public static string? SelectDisplayName(IEnumerable<DeviceNameCandidate> candidates)
    {
        ArgumentNullException.ThrowIfNull(candidates);

        return candidates
            .Where(candidate => !string.IsNullOrWhiteSpace(candidate.Name))
            .OrderBy(candidate => candidate.Source)
            .Select(candidate => candidate.Name.Trim().TrimEnd('.'))
            .FirstOrDefault();
    }

    private async Task<string?> ResolveReverseDnsAsync(
        IPAddress address,
        CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(_timeout);

        try
        {
            var entry = await Dns.GetHostEntryAsync(
                address.ToString(),
                address.AddressFamily,
                timeout.Token).ConfigureAwait(false);
            return string.Equals(entry.HostName, address.ToString(), StringComparison.OrdinalIgnoreCase)
                ? null
                : entry.HostName;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return null;
        }
        catch (SocketException)
        {
            return null;
        }
    }

    private async Task<string?> ResolveNetBiosAsync(
        IPAddress address,
        CancellationToken cancellationToken)
    {
        var transactionId = (ushort)Random.Shared.Next(ushort.MaxValue + 1);
        var request = CreateNetBiosNodeStatusRequest(transactionId);
        using var client = new UdpClient(address.AddressFamily);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(_timeout);

        try
        {
            await client.SendAsync(request, new IPEndPoint(address, 137), timeout.Token).ConfigureAwait(false);
            var response = await client.ReceiveAsync(timeout.Token).ConfigureAwait(false);
            return ParseNetBiosNodeStatus(response.Buffer, transactionId);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return null;
        }
        catch (SocketException)
        {
            return null;
        }
    }

    private async Task<string?> ResolveMdnsAsync(
        IPAddress address,
        CancellationToken cancellationToken)
    {
        if (address.AddressFamily != AddressFamily.InterNetwork)
        {
            return null;
        }

        var reverseName = string.Join('.', address.GetAddressBytes().Reverse()) + ".in-addr.arpa";
        var request = CreateDnsQuery(reverseName, 12);
        using var client = new UdpClient(AddressFamily.InterNetwork);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(_timeout);

        try
        {
            await client.SendAsync(
                request,
                new IPEndPoint(IPAddress.Parse("224.0.0.251"), 5353),
                timeout.Token).ConfigureAwait(false);
            var response = await client.ReceiveAsync(timeout.Token).ConfigureAwait(false);
            return ParsePtrResponse(response.Buffer);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return null;
        }
        catch (SocketException)
        {
            return null;
        }
    }

    internal static byte[] CreateNetBiosNodeStatusRequest(ushort transactionId)
    {
        var request = new byte[50];
        request[0] = (byte)(transactionId >> 8);
        request[1] = (byte)transactionId;
        request[5] = 1;
        request[12] = 0x20;
        request[13] = 0x43;
        request[14] = 0x4B;
        Array.Fill(request, (byte)0x41, 15, 30);
        request[45] = 0;
        request[47] = 0x21;
        request[49] = 0x01;
        return request;
    }

    internal static string? ParseNetBiosNodeStatus(byte[] response, ushort transactionId)
    {
        if (response.Length < 57 ||
            response[0] != (byte)(transactionId >> 8) ||
            response[1] != (byte)transactionId)
        {
            return null;
        }

        var offset = 12;
        if (!SkipDnsName(response, ref offset) || offset + 4 > response.Length)
        {
            return null;
        }

        offset += 4;
        if (!SkipDnsName(response, ref offset) || offset + 10 > response.Length)
        {
            return null;
        }

        var dataLength = (response[offset + 8] << 8) | response[offset + 9];
        offset += 10;
        if (dataLength < 1 || offset + dataLength > response.Length)
        {
            return null;
        }

        var nameCount = response[offset++];
        for (var index = 0; index < nameCount && offset + 18 <= response.Length; index++, offset += 18)
        {
            var suffix = response[offset + 15];
            var flags = (response[offset + 16] << 8) | response[offset + 17];
            var isGroup = (flags & 0x8000) != 0;
            if (suffix == 0 && !isGroup)
            {
                return Encoding.ASCII.GetString(response, offset, 15).Trim();
            }
        }

        return null;
    }

    internal static byte[] CreateDnsQuery(string name, ushort recordType)
    {
        using var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream);
        writer.Write(new byte[4]);
        writer.Write((byte)0);
        writer.Write((byte)1);
        writer.Write(new byte[6]);

        foreach (var label in name.Split('.'))
        {
            var bytes = Encoding.ASCII.GetBytes(label);
            writer.Write((byte)bytes.Length);
            writer.Write(bytes);
        }

        writer.Write((byte)0);
        writer.Write((byte)(recordType >> 8));
        writer.Write((byte)recordType);
        writer.Write((byte)0x80);
        writer.Write((byte)0x01);
        return stream.ToArray();
    }

    internal static string? ParsePtrResponse(byte[] response)
    {
        if (response.Length < 12)
        {
            return null;
        }

        var questionCount = ReadUInt16(response, 4);
        var recordCount =
            ReadUInt16(response, 6) +
            ReadUInt16(response, 8) +
            ReadUInt16(response, 10);
        var offset = 12;

        for (var index = 0; index < questionCount; index++)
        {
            if (ReadDnsName(response, ref offset) is null || offset + 4 > response.Length)
            {
                return null;
            }

            offset += 4;
        }

        for (var index = 0; index < recordCount; index++)
        {
            if (ReadDnsName(response, ref offset) is null || offset + 10 > response.Length)
            {
                return null;
            }

            var recordType = ReadUInt16(response, offset);
            var dataLength = ReadUInt16(response, offset + 8);
            offset += 10;
            if (offset + dataLength > response.Length)
            {
                return null;
            }

            if (recordType == 12)
            {
                var dataOffset = offset;
                return ReadDnsName(response, ref dataOffset);
            }

            offset += dataLength;
        }

        return null;
    }

    private static string? ReadDnsName(byte[] packet, ref int offset)
    {
        var labels = new List<string>();
        var position = offset;
        var jumped = false;
        var hops = 0;

        while (position < packet.Length && hops++ < packet.Length)
        {
            var length = packet[position++];
            if (length == 0)
            {
                if (!jumped)
                {
                    offset = position;
                }

                return string.Join('.', labels);
            }

            if ((length & 0xC0) == 0xC0)
            {
                if (position >= packet.Length)
                {
                    return null;
                }

                var pointer = ((length & 0x3F) << 8) | packet[position++];
                if (!jumped)
                {
                    offset = position;
                    jumped = true;
                }

                position = pointer;
                continue;
            }

            if (position + length > packet.Length)
            {
                return null;
            }

            labels.Add(Encoding.UTF8.GetString(packet, position, length));
            position += length;
        }

        return null;
    }

    private static ushort ReadUInt16(byte[] value, int offset)
    {
        return (ushort)((value[offset] << 8) | value[offset + 1]);
    }

    private static bool SkipDnsName(byte[] packet, ref int offset)
    {
        while (offset < packet.Length)
        {
            var length = packet[offset++];
            if (length == 0)
            {
                return true;
            }

            if ((length & 0xC0) == 0xC0)
            {
                offset++;
                return offset <= packet.Length;
            }

            offset += length;
        }

        return false;
    }
}
