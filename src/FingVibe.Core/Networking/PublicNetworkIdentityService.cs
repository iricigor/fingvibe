using System.Net;
using System.Text.Json;
using FingVibe.Core.Models;

namespace FingVibe.Core.Networking;

public sealed class PublicNetworkIdentityService
{
    private static readonly Uri LookupEndpoint = new("https://ipwho.is/");
    private static readonly HttpClient SharedHttpClient = CreateHttpClient();
    private readonly HttpClient _httpClient;

    public PublicNetworkIdentityService(HttpClient? httpClient = null)
    {
        _httpClient = httpClient ?? SharedHttpClient;
    }

    public async Task<PublicNetworkIdentity> GetAsync(CancellationToken cancellationToken = default)
    {
        using var response = await _httpClient
            .GetAsync(LookupEndpoint, cancellationToken)
            .ConfigureAwait(false);
        response.EnsureSuccessStatusCode();

        await using var content = await response.Content
            .ReadAsStreamAsync(cancellationToken)
            .ConfigureAwait(false);
        using var document = await JsonDocument
            .ParseAsync(content, cancellationToken: cancellationToken)
            .ConfigureAwait(false);

        var root = document.RootElement;
        if (!root.TryGetProperty("success", out var success)
            || success.ValueKind != JsonValueKind.True)
        {
            throw new InvalidOperationException("The public network lookup provider rejected the request.");
        }

        if (!root.TryGetProperty("ip", out var ipElement)
            || !IPAddress.TryParse(ipElement.GetString(), out var publicAddress))
        {
            throw new InvalidOperationException("The public network lookup returned an invalid IP address.");
        }

        if (!root.TryGetProperty("connection", out var connection)
            || !connection.TryGetProperty("isp", out var ispElement)
            || string.IsNullOrWhiteSpace(ispElement.GetString()))
        {
            throw new InvalidOperationException("The public network lookup did not return an ISP name.");
        }

        var location = NetworkIdentityFormatter.FormatLocation(
            GetOptionalString(root, "city"),
            GetOptionalString(root, "region"),
            GetOptionalString(root, "country"));
        return new PublicNetworkIdentity(publicAddress, ispElement.GetString()!.Trim(), location);
    }

    private static string? GetOptionalString(JsonElement element, string propertyName) =>
        element.TryGetProperty(propertyName, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static HttpClient CreateHttpClient() =>
        new()
        {
            Timeout = TimeSpan.FromSeconds(5)
        };
}
