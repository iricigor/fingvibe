using System.Net;
using System.Net.Sockets;
using System.Text;

namespace FingVibe.Core.Networking;

public sealed class MdnsDeviceDiscoveryService
{
    private static readonly string[] ServiceTypes =
    [
        "_ipp._tcp.local", "_ipps._tcp.local", "_printer._tcp.local",
        "_googlecast._tcp.local", "_airplay._tcp.local", "_raop._tcp.local",
        "_device-info._tcp.local", "_hap._tcp.local"
    ];
    private readonly TimeSpan _timeout;

    public MdnsDeviceDiscoveryService(TimeSpan? timeout = null) =>
        _timeout = timeout ?? TimeSpan.FromMilliseconds(700);

    public async Task<MdnsDeviceInfo> DiscoverAsync(IPAddress address, CancellationToken cancellationToken)
    {
        var services = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var models = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var conflictingModels = false;
        using var client = new UdpClient(address.AddressFamily);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(_timeout);
        try
        {
            // Legacy-unicast DNS-SD queries avoid a multicast query storm during parallel host enrichment.
            foreach (var service in ServiceTypes)
            {
                await client.SendAsync(DeviceNameResolver.CreateDnsQuery(service, 12),
                    new IPEndPoint(address, 5353), timeout.Token).ConfigureAwait(false);
            }

            while (true)
            {
                var response = await client.ReceiveAsync(timeout.Token).ConfigureAwait(false);
                if (!response.RemoteEndPoint.Address.Equals(address) || response.RemoteEndPoint.Port != 5353)
                {
                    continue;
                }

                var info = ParseResponse(response.Buffer);
                services.UnionWith(info.Services);
                conflictingModels |= info.HasConflictingModels;
                if (info.Model is not null)
                {
                    models.Add(info.Model);
                }
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return new MdnsDeviceInfo(services.Order(StringComparer.Ordinal).ToArray(),
                !conflictingModels && models.Count == 1 ? models.Single() : null,
                conflictingModels || models.Count > 1);
        }
        catch (SocketException)
        {
            return new MdnsDeviceInfo(services.Order(StringComparer.Ordinal).ToArray(),
                !conflictingModels && models.Count == 1 ? models.Single() : null,
                conflictingModels || models.Count > 1);
        }
    }

    internal static MdnsDeviceInfo ParseResponse(byte[] packet)
    {
        var services = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var models = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (packet.Length < 12 || (packet[2] & 0x80) == 0 || (packet[3] & 0x0F) != 0)
        {
            return new MdnsDeviceInfo([]);
        }

        int UInt16(int offset) => (packet[offset] << 8) | packet[offset + 1];
        var offset = 12;
        for (var index = 0; index < UInt16(4); index++)
        {
            if (DeviceNameResolver.ReadDnsName(packet, ref offset) is null || offset + 4 > packet.Length)
            {
                return new MdnsDeviceInfo([]);
            }

            offset += 4;
        }

        var count = UInt16(6) + UInt16(8) + UInt16(10);
        for (var index = 0; index < count; index++)
        {
            var name = DeviceNameResolver.ReadDnsName(packet, ref offset);
            if (name is null || offset + 10 > packet.Length)
            {
                return new MdnsDeviceInfo([]);
            }

            var type = UInt16(offset);
            var isInternet = (UInt16(offset + 2) & 0x7FFF) == 1;
            var isLive = packet.AsSpan(offset + 4, 4).IndexOfAnyExcept((byte)0) >= 0;
            var length = UInt16(offset + 8);
            offset += 10;
            var end = offset + length;
            if (end > packet.Length)
            {
                return new MdnsDeviceInfo([]);
            }

            if (isInternet && isLive && type == 12
                && ServiceTypes.Contains(name, StringComparer.OrdinalIgnoreCase))
            {
                var ptrOffset = offset;
                var instance = DeviceNameResolver.ReadDnsName(packet, ref ptrOffset);
                if (instance is not null && ptrOffset <= end
                    && instance.EndsWith("." + name, StringComparison.OrdinalIgnoreCase))
                {
                    services.Add(name.ToLowerInvariant());
                }
            }
            else if (isInternet && isLive && type == 16
                && new[] { "_device-info._tcp.local", "_airplay._tcp.local", "_raop._tcp.local" }
                    .Any(service => name.EndsWith("." + service, StringComparison.OrdinalIgnoreCase)))
            {
                var textOffset = offset;
                while (textOffset < end)
                {
                    var textLength = packet[textOffset++];
                    if (textOffset + textLength > end)
                    {
                        return new MdnsDeviceInfo([]);
                    }

                    var text = Encoding.UTF8.GetString(packet, textOffset, textLength);
                    var separator = text.IndexOf('=');
                    if (separator > 0 && (text[..separator].Equals("model", StringComparison.OrdinalIgnoreCase)
                        || text[..separator].Equals("am", StringComparison.OrdinalIgnoreCase)))
                    {
                        var model = text[(separator + 1)..].Trim();
                        if (model.Length is > 0 and <= 128)
                        {
                            models.Add(model);
                        }
                    }

                    textOffset += textLength;
                }
            }

            offset = end;
        }

        return new MdnsDeviceInfo(services.Order(StringComparer.Ordinal).ToArray(),
            models.Count == 1 ? models.Single() : null, models.Count > 1);
    }
}
