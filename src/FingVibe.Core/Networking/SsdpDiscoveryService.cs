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

    public SsdpDiscoveryService(HttpClient? httpClient = null, TimeSpan? discoveryWindow = null)
    {
        _httpClient = httpClient ?? new HttpClient { Timeout = TimeSpan.FromSeconds(2) };
        _discoveryWindow = discoveryWindow ?? TimeSpan.FromMilliseconds(900);
    }

    public async Task<IReadOnlyDictionary<IPAddress, string>> DiscoverNamesAsync(
        CancellationToken cancellationToken)
    {
        var locations = await DiscoverLocationsAsync(cancellationToken).ConfigureAwait(false);
        var names = new ConcurrentDictionary<IPAddress, string>();

        await Parallel.ForEachAsync(
            locations,
            new ParallelOptions
            {
                CancellationToken = cancellationToken,
                MaxDegreeOfParallelism = 8
            },
            async (device, token) =>
            {
                var friendlyName = await GetFriendlyNameAsync(device, token).ConfigureAwait(false);
                if (!string.IsNullOrWhiteSpace(friendlyName))
                {
                    names.TryAdd(device.Address, friendlyName);
                }
            }).ConfigureAwait(false);

        return names;
    }

    private async Task<IReadOnlyList<SsdpDeviceLocation>> DiscoverLocationsAsync(
        CancellationToken cancellationToken)
    {
        const string request =
            "M-SEARCH * HTTP/1.1\r\n" +
            "HOST: 239.255.255.250:1900\r\n" +
            "MAN: \"ssdp:discover\"\r\n" +
            "MX: 1\r\n" +
            "ST: ssdp:all\r\n\r\n";

        using var client = new UdpClient(AddressFamily.InterNetwork);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(_discoveryWindow);
        var payload = Encoding.ASCII.GetBytes(request);
        var locations = new Dictionary<Uri, IPAddress>();

        try
        {
            await client.SendAsync(payload, MulticastEndpoint, cancellationToken).ConfigureAwait(false);
            while (true)
            {
                var response = await client.ReceiveAsync(timeout.Token).ConfigureAwait(false);
                var location = GetHeader(Encoding.UTF8.GetString(response.Buffer), "LOCATION");
                if (Uri.TryCreate(location, UriKind.Absolute, out var uri) &&
                    IsAllowedLocation(uri, response.RemoteEndPoint.Address))
                {
                    locations.TryAdd(uri, response.RemoteEndPoint.Address);
                }
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return locations
                .Select(pair => new SsdpDeviceLocation(pair.Value, pair.Key))
                .ToArray();
        }
        catch (SocketException)
        {
            return [];
        }
    }

    private async Task<string?> GetFriendlyNameAsync(
        SsdpDeviceLocation device,
        CancellationToken cancellationToken)
    {
        try
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, device.Location);
            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/xml"));
            using var response = await _httpClient.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken).ConfigureAwait(false);
            if (response.RequestMessage?.RequestUri is not { } finalLocation ||
                !IsAllowedLocation(finalLocation, device.Address))
            {
                return null;
            }

            response.EnsureSuccessStatusCode();

            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
            using var reader = XmlReader.Create(
                stream,
                new XmlReaderSettings
                {
                    Async = true,
                    DtdProcessing = DtdProcessing.Prohibit,
                    MaxCharactersInDocument = 1_000_000
                });
            var document = await XDocument.LoadAsync(reader, LoadOptions.None, cancellationToken).ConfigureAwait(false);
            return document
                .Descendants()
                .FirstOrDefault(element => element.Name.LocalName == "friendlyName")
                ?.Value;
        }
        catch (HttpRequestException)
        {
            return null;
        }
        catch (TaskCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return null;
        }
        catch (XmlException)
        {
            return null;
        }
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

    private sealed record SsdpDeviceLocation(IPAddress Address, Uri Location);
}
