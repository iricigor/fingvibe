using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Diagnostics;

namespace FingVibe.Core.Networking;

public sealed class MdnsDeviceDiscoveryService
{
    private static readonly string[] ServiceTypes =
    [
        "_ipp._tcp.local", "_ipps._tcp.local", "_printer._tcp.local",
        "_googlecast._tcp.local", "_airplay._tcp.local", "_raop._tcp.local",
        "_device-info._tcp.local", "_hap._tcp.local", "_workstation._tcp.local",
        "_smb._tcp.local", "_adisk._tcp.local", "_androidtvremote._tcp.local",
        "_androidtvremote2._tcp.local", "_adb-tls-connect._tcp.local"
    ];
    private readonly TimeSpan _timeout;

    public MdnsDeviceDiscoveryService(TimeSpan? timeout = null) =>
        _timeout = timeout ?? TimeSpan.FromMilliseconds(1500);

    public async Task<IReadOnlyDictionary<IPAddress, MdnsDeviceInfo>> DiscoverNetworkAsync(
        IPAddress localAddress, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var records = new List<MdnsResourceRecord>();
        var queries = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var multicast = IPAddress.Parse("224.0.0.251");
        using var client = new UdpClient(AddressFamily.InterNetwork);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(_timeout);
        try
        {
            client.ExclusiveAddressUse = false;
            client.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            try
            {
                client.Client.Bind(new IPEndPoint(IPAddress.Any, 5353));
            }
            catch (SocketException exception) when (exception.SocketErrorCode is
                SocketError.AddressAlreadyInUse or SocketError.AccessDenied)
            {
                Trace.TraceWarning($"mDNS port 5353 is unavailable; requesting unicast multicast-query replies: {exception.Message}");
                client.Client.Bind(new IPEndPoint(localAddress, 0));
            }

            client.JoinMulticastGroup(multicast, localAddress);
            client.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastInterface,
                localAddress.GetAddressBytes());
            client.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastTimeToLive, 255);
            var requestUnicast = ((IPEndPoint)client.Client.LocalEndPoint!).Port != 5353;

            async Task QueryAsync(string name, int type)
            {
                if (queries.Count < 256 && queries.Add($"{type}:{name}"))
                {
                    await client.SendAsync(DeviceNameResolver.CreateDnsQuery(name, (ushort)type, requestUnicast),
                        new IPEndPoint(multicast, 5353), timeout.Token).ConfigureAwait(false);
                }
            }

            // One shared discovery window per scan also receives responders that ignore the QU bit.
            foreach (var service in ServiceTypes)
            {
                await QueryAsync(service, 12).ConfigureAwait(false);
            }

            while (records.Count < 4096)
            {
                var response = await client.ReceiveAsync(timeout.Token).ConfigureAwait(false);
                if (response.RemoteEndPoint.Port != 5353)
                {
                    continue;
                }

                var received = ParseRecords(response.Buffer);
                records.AddRange(received.Take(4096 - records.Count));
                foreach (var record in received)
                {
                    foreach (var (name, type) in GetFollowUpQueries(record))
                    {
                        await QueryAsync(name, type).ConfigureAwait(false);
                    }
                }
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
        }
        catch (SocketException exception)
        {
            Trace.TraceWarning($"mDNS discovery could not complete: {exception.Message}");
        }

        return BuildDeviceMap(records);
    }

    internal static IEnumerable<(string Name, int Type)> GetFollowUpQueries(MdnsResourceRecord record)
    {
        if (record.Type == 12 && record.Target is { } instance && ServiceTypes.Contains(
            record.Name, StringComparer.OrdinalIgnoreCase))
        {
            yield return (instance, 33);
            yield return (instance, 16);
        }
        if (record.Type == 33 && record.Target is { } host)
        {
            yield return (host, 1);
            yield return (record.Name, 16);
            if (ServiceForInstance(record.Name) is { } service)
            {
                yield return (record.Name[..^(service.Length + 1)] + "._device-info._tcp.local", 16);
            }
        }
        if (record.Type == 1 && record.Name.EndsWith(".local", StringComparison.OrdinalIgnoreCase))
        {
            yield return (record.Name[..^6] + "._device-info._tcp.local", 16);
        }
    }

    internal static IReadOnlyList<MdnsResourceRecord> ParseRecords(byte[] packet)
    {
        if (packet.Length is < 12 or > 9000 || (packet[2] & 0x80) == 0 || (packet[3] & 0x0F) != 0)
        {
            return [];
        }
        var records = new List<MdnsResourceRecord>();
        int UInt16(int offset) => (packet[offset] << 8) | packet[offset + 1];
        var offset = 12;
        for (var index = 0; index < UInt16(4); index++)
        {
            if (DeviceNameResolver.ReadDnsName(packet, ref offset) is null || offset + 4 > packet.Length)
            {
                return [];
            }

            offset += 4;
        }

        var count = UInt16(6) + UInt16(8) + UInt16(10);
        if (count > 512)
        {
            return [];
        }
        for (var index = 0; index < count; index++)
        {
            var name = DeviceNameResolver.ReadDnsName(packet, ref offset);
            if (name is null || offset + 10 > packet.Length)
            {
                return [];
            }

            var type = UInt16(offset);
            var isInternet = (UInt16(offset + 2) & 0x7FFF) == 1;
            var isLive = packet.AsSpan(offset + 4, 4).IndexOfAnyExcept((byte)0) >= 0;
            var length = UInt16(offset + 8);
            offset += 10;
            var end = offset + length;
            if (end > packet.Length)
            {
                return [];
            }

            if (!isInternet || !isLive)
            {
                offset = end;
                continue;
            }
            if (type == 1 && length == 4)
            {
                records.Add(new(name, type, Address: new IPAddress(packet.AsSpan(offset, 4))));
            }
            else if (type is 12 or 33)
            {
                var dataOffset = offset + (type == 33 ? 6 : 0);
                if (dataOffset >= end)
                {
                    return [];
                }
                var target = DeviceNameResolver.ReadDnsName(packet, ref dataOffset);
                if (target is null || dataOffset != end)
                {
                    return [];
                }
                if (type == 33 || target.EndsWith("." + name, StringComparison.OrdinalIgnoreCase))
                {
                    records.Add(new(name, type, Target: target));
                }
            }
            else if (type == 16)
            {
                var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                var textOffset = offset;
                while (textOffset < end)
                {
                    var textLength = packet[textOffset++];
                    if (textOffset + textLength > end)
                    {
                        return [];
                    }

                    var text = Encoding.UTF8.GetString(packet, textOffset, textLength);
                    var separator = text.IndexOf('=');
                    if (separator > 0)
                    {
                        values.TryAdd(text[..separator], text[(separator + 1)..].Trim());
                    }
                    textOffset += textLength;
                }
                records.Add(new(name, type, Text: values));
            }

            offset = end;
        }

        return records;
    }

    internal static MdnsDeviceInfo ParseResponse(byte[] packet)
    {
        var records = ParseRecords(packet);
        var services = records.Where(record => record.Type == 12
                && ServiceTypes.Contains(record.Name, StringComparer.OrdinalIgnoreCase))
            .Select(record => record.Name);
        return CreateDeviceInfo(records, services, null);
    }

    internal static IReadOnlyDictionary<IPAddress, MdnsDeviceInfo> BuildDeviceMap(
        IReadOnlyList<MdnsResourceRecord> records)
    {
        var devices = new Dictionary<IPAddress, MdnsDeviceInfo>();
        foreach (var group in records.Where(record => record.Address is not null)
            .GroupBy(record => record.Address!))
        {
            var hosts = group.Select(record => record.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
            var instances = records.Where(record => record.Type == 33 && record.Target is not null
                && hosts.Contains(record.Target) && ServiceForInstance(record.Name) is not null).ToArray();
            var metadataNames = instances.Select(record => record.Name)
                .Concat(instances.Select(record => record.Name[..^(ServiceForInstance(record.Name)!.Length + 1)]
                    + "._device-info._tcp.local"))
                .Concat(hosts.Where(host => host.EndsWith(".local", StringComparison.OrdinalIgnoreCase))
                    .Select(host => host[..^6] + "._device-info._tcp.local"))
                .ToHashSet(StringComparer.OrdinalIgnoreCase);
            var metadata = records.Where(record => metadataNames.Contains(record.Name));
            var services = instances.Select(record => ServiceForInstance(record.Name)!);
            devices[group.Key] = CreateDeviceInfo(metadata, services,
                hosts.Order(StringComparer.OrdinalIgnoreCase).First());
        }
        return devices;
    }

    private static string? ServiceForInstance(string name) =>
        ServiceTypes.FirstOrDefault(service => name.EndsWith("." + service, StringComparison.OrdinalIgnoreCase));

    private static MdnsDeviceInfo CreateDeviceInfo(IEnumerable<MdnsResourceRecord> records,
        IEnumerable<string> services, string? hostName)
    {
        var models = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var record in records.Where(record => record.Text is not null
            && ServiceForInstance(record.Name) is
                "_device-info._tcp.local" or "_airplay._tcp.local" or "_raop._tcp.local"
                or "_googlecast._tcp.local" or "_ipp._tcp.local" or "_ipps._tcp.local" or "_printer._tcp.local"))
        {
            foreach (var key in new[] { "model", "am", "md", "ty" })
            {
                if (record.Text!.TryGetValue(key, out var model) && model.Length is > 0 and <= 128)
                {
                    models.Add(model);
                }
            }
        }
        return new MdnsDeviceInfo(services.Select(service => service.ToLowerInvariant())
            .Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray(),
            models.Count == 1 ? models.Single() : null, models.Count > 1, hostName);
    }
}

internal sealed record MdnsResourceRecord(
    string Name, int Type, string? Target = null, IPAddress? Address = null,
    IReadOnlyDictionary<string, string>? Text = null);
