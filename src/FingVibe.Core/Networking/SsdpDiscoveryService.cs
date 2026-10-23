using System.Collections.Concurrent;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Sockets;
using System.Text;
using System.Xml;
using System.Xml.Linq;

namespace FingVibe.Core.Networking;

public sealed class SsdpDiscoveryService
{
    private static readonly IPEndPoint MulticastEndpoint =
        new(IPAddress.Parse("239.255.255.250"), 1900);

    private readonly HttpClient _httpClient;
    private readonly TimeSpan _discoveryWindow;

    public SsdpDiscoveryService(TimeSpan? discoveryWindow = null)
    {
        _httpClient = new HttpClient(
            new SocketsHttpHandler
            {
                AllowAutoRedirect = false
            })
        {
            Timeout = TimeSpan.FromSeconds(2)
        };
        _discoveryWindow = discoveryWindow ?? TimeSpan.FromMilliseconds(1500);
    }

    public async Task<IReadOnlyDictionary<IPAddress, string>> DiscoverNamesAsync(
        CancellationToken cancellationToken)
    {
        var devices = await DiscoverDevicesAsync(cancellationToken).ConfigureAwait(false);
        return GetDisplayNames(devices);
    }

    internal static IReadOnlyDictionary<IPAddress, string> GetDisplayNames(
        IReadOnlyDictionary<IPAddress, IReadOnlyList<SsdpDeviceInfo>> devices) =>
        devices.Select(pair => new
            {
                pair.Key,
                Name = pair.Value.Select(device => device.FriendlyName)
                    .FirstOrDefault(name => !string.IsNullOrWhiteSpace(name))
            })
            .Where(pair => pair.Name is not null)
            .ToDictionary(pair => pair.Key, pair => pair.Name!);

    public async Task<IReadOnlyDictionary<IPAddress, IReadOnlyList<SsdpDeviceInfo>>> DiscoverDevicesAsync(
        CancellationToken cancellationToken,
        IPAddress? localAddress = null)
    {
        var locations = await DiscoverLocationsAsync(cancellationToken, localAddress).ConfigureAwait(false);
        var devices = new ConcurrentDictionary<IPAddress, ConcurrentDictionary<Uri, SsdpDeviceInfo>>();

        await Parallel.ForEachAsync(
            locations,
            new ParallelOptions
            {
                CancellationToken = cancellationToken,
                MaxDegreeOfParallelism = 8
            },
            async (device, token) =>
            {
                var info = await GetDeviceInfoAsync(device, token).ConfigureAwait(false);
                if (info is not null)
                {
                    devices.GetOrAdd(device.Address, _ => new()).TryAdd(device.Location, info);
                }
            }).ConfigureAwait(false);

        return devices.ToDictionary(pair => pair.Key,
            pair => (IReadOnlyList<SsdpDeviceInfo>)pair.Value.OrderBy(device => device.Key.AbsoluteUri,
                StringComparer.Ordinal).Select(device => device.Value).ToArray());
    }

    private async Task<IReadOnlyList<SsdpDeviceLocation>> DiscoverLocationsAsync(
        CancellationToken cancellationToken, IPAddress? localAddress)
    {
        const string request =
            "M-SEARCH * HTTP/1.1\r\n" +
            "HOST: 239.255.255.250:1900\r\n" +
            "MAN: \"ssdp:discover\"\r\n" +
            "MX: 1\r\n" +
            "ST: ssdp:all\r\n\r\n";

        using var client = new UdpClient(new IPEndPoint(localAddress ?? IPAddress.Any, 0));
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(_discoveryWindow);
        var payload = Encoding.ASCII.GetBytes(request);
        var locations = new Dictionary<Uri, SsdpDeviceLocation>();

        try
        {
            if (localAddress is not null)
            {
                client.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastInterface,
                    localAddress.GetAddressBytes());
            }
            await client.SendAsync(payload, MulticastEndpoint, timeout.Token).ConfigureAwait(false);
            while (true)
            {
                var response = await client.ReceiveAsync(timeout.Token).ConfigureAwait(false);
                var location = GetHeader(Encoding.UTF8.GetString(response.Buffer), "LOCATION");
                if (Uri.TryCreate(location, UriKind.Absolute, out var uri) &&
                    IsAllowedLocation(uri, response.RemoteEndPoint.Address))
                {
                    locations.TryAdd(uri, new SsdpDeviceLocation(
                        response.RemoteEndPoint.Address, uri,
                        GetHeader(Encoding.UTF8.GetString(response.Buffer), "SERVER")));
                }
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return locations.Values.ToArray();
        }
        catch (SocketException)
        {
            return [];
        }
    }

    private async Task<SsdpDeviceInfo?> GetDeviceInfoAsync(
        SsdpDeviceLocation device,
        CancellationToken cancellationToken)
    {
        var advertised = new SsdpDeviceInfo(null, null, null, null, device.Server);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(2));
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, device.Location);
            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/xml"));
            using var response = await _httpClient.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                timeout.Token).ConfigureAwait(false);
            if (response.RequestMessage?.RequestUri is not { } finalLocation ||
                !IsAllowedLocation(finalLocation, device.Address))
            {
                return advertised;
            }

            response.EnsureSuccessStatusCode();

            await using var stream = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false);
            return await ReadDescriptionAsync(stream, device.Server, timeout.Token).ConfigureAwait(false)
                ?? advertised;
        }
        catch (HttpRequestException)
        {
            return advertised;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return advertised;
        }
        catch (XmlException)
        {
            return advertised;
        }
        catch (IOException)
        {
            return advertised;
        }
    }

    internal static async Task<SsdpDeviceInfo?> ReadDescriptionAsync(
        Stream stream, string? server, CancellationToken cancellationToken)
    {
        using var content = new MemoryStream();
        var buffer = new byte[8192];
        int read;
        while ((read = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false)) != 0)
        {
            if (content.Length + read > 1_000_000)
            {
                throw new XmlException("The UPnP device description exceeds the discovery size limit.");
            }
            content.Write(buffer, 0, read);
        }
        content.Position = 0;
        using var reader = XmlReader.Create(content, new XmlReaderSettings
        {
            Async = true,
            DtdProcessing = DtdProcessing.Prohibit,
            MaxCharactersInDocument = 1_000_000
        });
        var document = await XDocument.LoadAsync(reader, LoadOptions.None, cancellationToken).ConfigureAwait(false);
        return ParseDeviceDescription(document, server);
    }

    internal static SsdpDeviceInfo? ParseDeviceDescription(XDocument document, string? server)
    {
        var device = document.Root?.Elements().FirstOrDefault(element => element.Name.LocalName == "device");
        if (device is null)
        {
            return null;
        }

        string? Field(string name) => device.Elements()
            .FirstOrDefault(element => element.Name.LocalName == name)?.Value.Trim();
        return new SsdpDeviceInfo(
            Field("friendlyName"), Field("deviceType"), Field("manufacturer"), Field("modelName"), server);
    }

    private static bool IsAllowedLocation(Uri location, IPAddress respondingAddress)
    {
        return (location.Scheme == Uri.UriSchemeHttp || location.Scheme == Uri.UriSchemeHttps) &&
            IPAddress.TryParse(location.Host, out var locationAddress) &&
            locationAddress.Equals(respondingAddress);
    }

    private static string? GetHeader(string response, string headerName)
    {
        foreach (var line in response.Split(["\r\n", "\n"], StringSplitOptions.RemoveEmptyEntries))
        {
            var separator = line.IndexOf(':');
            if (separator > 0 &&
                line.AsSpan(0, separator).Equals(headerName, StringComparison.OrdinalIgnoreCase))
            {
                return line[(separator + 1)..].Trim();
            }
        }

        return null;
    }

    private sealed record SsdpDeviceLocation(IPAddress Address, Uri Location, string? Server);
}
