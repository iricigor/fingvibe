using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Diagnostics;
using FingVibe.Core.Models;

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
    internal const int MaximumQueries = 256;
    internal const int MaximumRecords = 4096;
    internal static IReadOnlyList<string> ExplicitServiceTypes => ServiceTypes;
    private readonly TimeSpan _timeout;

    public MdnsDeviceDiscoveryService(TimeSpan? timeout = null) =>
        _timeout = timeout ?? TimeSpan.FromMilliseconds(1500);

    public async Task<IReadOnlyDictionary<IPAddress, MdnsDeviceInfo>> DiscoverNetworkAsync(
        IPAddress localAddress, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var budget = new MdnsDiscoveryBudget();
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

            async Task SendAsync(IEnumerable<(string Name, int Type)> planned)
            {
                foreach (var (name, type) in planned)
                {
                    await client.SendAsync(DeviceNameResolver.CreateDnsQuery(name, (ushort)type, requestUnicast),
                        new IPEndPoint(multicast, 5353), timeout.Token).ConfigureAwait(false);
                }
            }

            // One shared discovery window per scan also receives responders that ignore the QU bit.
            await SendAsync(budget.InitialQueries()).ConfigureAwait(false);

            while (!budget.IsFull)
            {
                var response = await client.ReceiveAsync(timeout.Token).ConfigureAwait(false);
                if (response.RemoteEndPoint.Port != 5353)
                {
                    continue;
                }

                var receivedAt = DateTimeOffset.UtcNow;
                var received = ParseRecords(response.Buffer).Select(record =>
                    record with { Source = response.RemoteEndPoint.Address, ReceivedAt = receivedAt }).ToArray();
                await SendAsync(budget.Accept(received)).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
        }
        catch (SocketException exception)
        {
            Trace.TraceWarning($"mDNS discovery could not complete: {exception.Message}");
        }

        return BuildDeviceMap(budget.Records);
    }

    internal static IEnumerable<(string Name, int Type)> GetFollowUpQueries(MdnsResourceRecord record)
    {
        if (record.Type == 12 && record.Target is { } serviceType
            && string.Equals(record.Name, ServiceDiscoveryCatalog.EnumerationName, StringComparison.OrdinalIgnoreCase))
        {
            if (ServiceDiscoveryCatalog.IsServiceType(serviceType))
            {
                yield return (serviceType, 12);
            }
            yield break;
        }
        if (record.Type == 12 && record.Target is { } instance && ServiceDiscoveryCatalog.IsServiceType(record.Name))
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
                int? port = type == 33 && UInt16(offset + 4) > 0 ? UInt16(offset + 4) : null;
                var target = DeviceNameResolver.ReadDnsName(packet, ref dataOffset);
                if (target is null || dataOffset != end)
                {
                    return [];
                }
                if (type == 33
                    || type == 12 && target.EndsWith("." + name, StringComparison.OrdinalIgnoreCase)
                    || type == 12 && string.Equals(name, ServiceDiscoveryCatalog.EnumerationName, StringComparison.OrdinalIgnoreCase)
                        && ServiceDiscoveryCatalog.IsServiceType(target))
                {
                    records.Add(new(name, type, Target: target, Port: port));
                }
            }
            else if (type == 16)
            {
                var values = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                var entries = new List<KeyValuePair<string, string>>();
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
                        var key = text[..separator];
                        var value = text[(separator + 1)..].Trim();
                        values.TryAdd(key, value);
                        entries.Add(new(key, value));
                    }
                    textOffset += textLength;
                }
                records.Add(new(name, type, Text: values, TextEntries: entries));
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
        IReadOnlyList<MdnsResourceRecord> records, DateTimeOffset? observedAt = null)
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
            var info = CreateDeviceInfo(metadata, services, hosts.Order(StringComparer.OrdinalIgnoreCase).First());
            // Presence and service evidence need the responder's own packets: an address merely mentioned in
            // another host's packet is not a response, and its services are not attributed to that address.
            var attributedHosts = group.Where(record => record.Source is null || record.Source.Equals(group.Key))
                .Select(record => record.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
            var advertisements = instances
                .Where(record => attributedHosts.Contains(record.Target!)
                    && (record.Source is null || record.Source.Equals(group.Key)))
                .Select(record => CreateAdvertisement(record, records, observedAt))
                .OfType<ServiceAdvertisement>()
                .DistinctBy(item => (item.ServiceType.ToLowerInvariant(), item.InstanceName?.ToLowerInvariant(), item.Port))
                .OrderBy(item => item.ServiceType, StringComparer.OrdinalIgnoreCase)
                .ThenBy(item => item.InstanceName, StringComparer.OrdinalIgnoreCase)
                .Take(ServiceAdvertisement.MaximumPerResult)
                .ToArray();
            devices[group.Key] = info with
            {
                ReportedValues = DeviceReportedValues.Collect(info.ReportedValues.Concat(
                    hosts.Select(host => new ReportedDeviceValue(ReportedDeviceValueKind.MdnsName, host)))),
                RespondedFromAddress = group.Any(record => group.Key.Equals(record.Source)),
                Advertisements = advertisements
            };
        }
        return devices;
    }

    private static ServiceAdvertisement? CreateAdvertisement(
        MdnsResourceRecord service, IReadOnlyList<MdnsResourceRecord> records, DateTimeOffset? observedAt)
    {
        var serviceType = ServiceForInstance(service.Name)!.ToLowerInvariant();
        var (label, role) = ServiceDiscoveryCatalog.Describe(serviceType);
        var text = records.Where(record => record.Type == 16 && record.Text is not null
                && string.Equals(record.Name, service.Name, StringComparison.OrdinalIgnoreCase)
                && (service.Source is null || record.Source is null || record.Source.Equals(service.Source)))
            .SelectMany(record => record.TextEntries ?? record.Text!.ToArray()).ToArray();
        string? Field(params string[] keys) => text.Where(entry => keys.Contains(entry.Key, StringComparer.OrdinalIgnoreCase))
            .Select(entry => Bounded(entry.Value)).FirstOrDefault(value => value is not null);
        var time = service.ReceivedAt ?? observedAt;
        if (time is null)
        {
            return null;
        }
        var transport = ServiceDiscoveryCatalog.TransportOf(serviceType);
        return new ServiceAdvertisement(
            ServiceDiscoveryProtocol.Mdns, serviceType, label, role,
            Bounded(service.Name[..^(serviceType.Length + 1)]), Bounded(service.Target),
            service.Port, service.Port is null ? null : transport,
            Field("fn", "location_name", "DN"), Field("manufacturer", "mf", "usb_MFG"),
            Field("md", "model", "modelid", "am", "ty"), time.Value);
    }

    private static string? Bounded(string? value)
    {
        var trimmed = value?.Trim();
        return trimmed is { Length: > 0 and <= ServiceAdvertisement.MaximumTextLength } && !trimmed.Any(char.IsControl)
            ? trimmed : null;
    }

    // Known types match first; any other valid "Instance._type._tcp|udp.local" name keeps its service type.
    private static string? ServiceForInstance(string name)
    {
        if (ServiceTypes.FirstOrDefault(service => name.EndsWith("." + service, StringComparison.OrdinalIgnoreCase))
            is { } known)
        {
            return known;
        }
        var labels = name.Split('.');
        if (labels.Length < 4 || labels.Take(labels.Length - 3).Any(string.IsNullOrEmpty))
        {
            return null;
        }
        var service = string.Join('.', labels[^3..]);
        return ServiceDiscoveryCatalog.IsServiceType(service) ? service : null;
    }

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
        var values = new List<ReportedDeviceValue>();
        foreach (var record in records.Where(record => record.Text is not null))
        {
            var identifier = ServiceForInstance(record.Name) switch
            {
                "_googlecast._tcp.local" => (ReportedDeviceValueKind.GoogleCastId, "id"),
                "_hap._tcp.local" => (ReportedDeviceValueKind.HomeKitId, "id"),
                "_airplay._tcp.local" => (ReportedDeviceValueKind.AirPlayDeviceId, "deviceid"),
                "_ipp._tcp.local" or "_ipps._tcp.local" or "_printer._tcp.local" => (ReportedDeviceValueKind.PrinterUuid, "UUID"),
                _ => ((ReportedDeviceValueKind Kind, string Key)?)null
            };
            if (identifier is not { } field) continue;
            foreach (var entry in record.TextEntries ?? record.Text!.ToArray())
                if (string.Equals(entry.Key, field.Key, StringComparison.OrdinalIgnoreCase))
                    values.Add(new(field.Kind, entry.Value));
        }
        return new MdnsDeviceInfo(services.Select(service => service.ToLowerInvariant())
            .Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToArray(),
            models.Count == 1 ? models.Single() : null, models.Count > 1, hostName)
        {
            ReportedValues = DeviceReportedValues.Collect(values)
        };
    }
}

// Explicit types go first; DNS-SD enumeration and every follow-up share one per-scan budget of
// 256 distinct queries and 4,096 retained records, never a fresh allowance per service.
internal sealed class MdnsDiscoveryBudget
{
    private readonly HashSet<string> _queries = new(StringComparer.OrdinalIgnoreCase);

    public List<MdnsResourceRecord> Records { get; } = [];
    public int QueryCount => _queries.Count;
    public bool IsFull => Records.Count >= MdnsDeviceDiscoveryService.MaximumRecords;

    public IReadOnlyList<(string Name, int Type)> InitialQueries() =>
        Plan(MdnsDeviceDiscoveryService.ExplicitServiceTypes.Select(service => (service, 12))
            .Append((ServiceDiscoveryCatalog.EnumerationName, 12)));

    public IReadOnlyList<(string Name, int Type)> Accept(IReadOnlyList<MdnsResourceRecord> received)
    {
        Records.AddRange(received.Take(MdnsDeviceDiscoveryService.MaximumRecords - Records.Count));
        return Plan(received.SelectMany(MdnsDeviceDiscoveryService.GetFollowUpQueries));
    }

    private IReadOnlyList<(string Name, int Type)> Plan(IEnumerable<(string Name, int Type)> candidates)
    {
        var planned = new List<(string, int)>();
        foreach (var (name, type) in candidates)
        {
            if (_queries.Count >= MdnsDeviceDiscoveryService.MaximumQueries) break;
            if (_queries.Add($"{type}:{name}")) planned.Add((name, type));
        }
        return planned;
    }
}

internal sealed record MdnsResourceRecord(
    string Name, int Type, string? Target = null, IPAddress? Address = null,
    IReadOnlyDictionary<string, string>? Text = null,
    IReadOnlyList<KeyValuePair<string, string>>? TextEntries = null,
    int? Port = null)
{
    // The packet's source address and receive time; absent only for records parsed outside a scan.
    public IPAddress? Source { get; init; }
    public DateTimeOffset? ReceivedAt { get; init; }
}
