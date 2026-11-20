using System.Globalization;
using System.Net.Http.Headers;
using System.Text.Json;
using System.Xml;
using System.Xml.Linq;

namespace FingVibe.Core.Networking;

public sealed class OfficialServiceStatusSource : IServiceStatusSource
{
    public const int MaximumFeedBytes = 8 * 1024 * 1024;
    public static readonly TimeSpan CacheLifetime = TimeSpan.FromMinutes(5);

    public static IReadOnlyDictionary<string, Uri> DefaultEndpoints { get; } =
        new Dictionary<string, Uri>(StringComparer.Ordinal)
        {
            [AzureFeed] = new("https://azure.status.microsoft/en-us/status/feed/"),
            [AwsFeed] = new("https://status.aws.amazon.com/rss/ec2-us-east-1.rss"),
            [GoogleWorkspaceFeed] = new("https://www.google.com/appsstatus/dashboard/incidents.json"),
            [GoogleCloudFeed] = new("https://status.cloud.google.com/incidents.json"),
            [CloudflareFeed] = new("https://www.cloudflarestatus.com/api/v2/summary.json"),
            [GitHubFeed] = new("https://www.githubstatus.com/api/v2/summary.json")
        };

    internal const string AzureFeed = "azure";
    internal const string AwsFeed = "aws";
    internal const string GoogleWorkspaceFeed = "google-workspace";
    internal const string GoogleCloudFeed = "google-cloud";
    internal const string CloudflareFeed = "cloudflare";
    internal const string GitHubFeed = "github";

    private static readonly FeedDefinition[] Feeds =
    [
        new(AzureFeed, ["microsoft-azure"], ParseAzure),
        new(AwsFeed, ["amazon-aws"], ParseAws),
        new(GoogleWorkspaceFeed, ["google-gmail"], ParseGoogleWorkspace),
        new(GoogleCloudFeed, ["google-cloud"], ParseGoogleCloud),
        new(CloudflareFeed, ["cloudflare-dns", "cloudflare-network"], ParseCloudflare),
        new(GitHubFeed, ["github-website", "github-actions"], ParseGitHub)
    ];

    private readonly HttpClient _http;
    private readonly TimeProvider _time;
    private readonly IReadOnlyDictionary<string, Uri> _endpoints;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private ServiceStatusSnapshot? _snapshot;

    public OfficialServiceStatusSource(
        HttpClient http,
        TimeProvider? time = null,
        IReadOnlyDictionary<string, Uri>? endpoints = null)
    {
        _http = http ?? throw new ArgumentNullException(nameof(http));
        _time = time ?? TimeProvider.System;
        _endpoints = endpoints ?? DefaultEndpoints;
        foreach (var feed in Feeds)
        {
            if (!_endpoints.TryGetValue(feed.Key, out var endpoint) || endpoint is null
                || endpoint.Scheme != Uri.UriSchemeHttps)
            {
                throw new ArgumentException(
                    $"Provider status endpoint '{feed.Key}' is missing or is not HTTPS.", nameof(endpoints));
            }
        }
    }

    public async Task<ServiceStatusSnapshot> GetReportsAsync(bool refresh, CancellationToken cancellationToken)
    {
        await _gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var now = _time.GetUtcNow();
            if (!refresh && _snapshot is { RetrievedAt: { } retrieved }
                && now - retrieved < CacheLifetime)
            {
                return _snapshot;
            }

            var previous = _snapshot?.Reports.GroupBy(report => report.EntryId, StringComparer.Ordinal)
                .ToDictionary(group => group.Key, group => group.Last(), StringComparer.Ordinal)
                ?? new Dictionary<string, ProviderReport>(StringComparer.Ordinal);
            var feeds = await Task.WhenAll(Feeds.Select(
                feed => ReadFeedAsync(feed, previous, cancellationToken))).ConfigureAwait(false);
            var completedAt = _time.GetUtcNow();
            _snapshot = new(
                [.. feeds.SelectMany(result => result)],
                completedAt);
            return _snapshot;
        }
        finally
        {
            _gate.Release();
        }
    }

    private async Task<IReadOnlyList<ProviderReport>> ReadFeedAsync(
        FeedDefinition feed,
        IReadOnlyDictionary<string, ProviderReport> previous,
        CancellationToken cancellationToken)
    {
        try
        {
            var payload = await GetPayloadAsync(_endpoints[feed.Key], cancellationToken).ConfigureAwait(false);
            var parsed = feed.Parse(payload, _time.GetUtcNow());
            if (parsed.Count != feed.EntryIds.Count
                || parsed.Select(report => report.EntryId).Distinct(StringComparer.Ordinal).Count() != feed.EntryIds.Count
                || parsed.Any(report => !feed.EntryIds.Contains(report.EntryId, StringComparer.Ordinal)))
            {
                throw new InvalidDataException($"Feed '{feed.Key}' did not return each expected entry exactly once.");
            }
            return parsed;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (OperationCanceledException)
        {
            return Failed(feed, previous, ProviderReportState.Unavailable, "Provider request timed out.");
        }
        catch (HttpRequestException)
        {
            return Failed(feed, previous, ProviderReportState.Unavailable, "Provider request failed.");
        }
        catch (Exception exception) when (exception is JsonException or XmlException or FormatException
            or InvalidDataException or InvalidOperationException or KeyNotFoundException or ArgumentException)
        {
            return Failed(feed, previous, ProviderReportState.Malformed, "Provider response could not be read.");
        }
    }

    private IReadOnlyList<ProviderReport> Failed(
        FeedDefinition feed,
        IReadOnlyDictionary<string, ProviderReport> previous,
        ProviderReportState state,
        string detail)
    {
        var failedAt = _time.GetUtcNow();
        return [.. feed.EntryIds.Select(id =>
        {
            if (state == ProviderReportState.Unavailable
                && previous.TryGetValue(id, out var retained)
                && retained.State is ProviderReportState.NoIncidents
                    or ProviderReportState.Incident
                    or ProviderReportState.Stale)
            {
                return retained with { State = ProviderReportState.Stale, FailedAt = failedAt };
            }

            return new ProviderReport(id, state, detail, FailedAt: failedAt);
        })];
    }

    private async Task<string> GetPayloadAsync(Uri endpoint, CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, endpoint);
        request.Headers.UserAgent.Add(new ProductInfoHeaderValue("FingVibe-ProviderStatus", "1.0"));
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/xml"));
        using var response = await _http.SendAsync(
            request, HttpCompletionOption.ResponseHeadersRead, cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            throw new HttpRequestException(
                $"Provider status endpoint returned HTTP {(int)response.StatusCode}.",
                null,
                response.StatusCode);
        }
        if (response.Content.Headers.ContentLength > MaximumFeedBytes)
        {
            throw new InvalidDataException("Provider status response is too large.");
        }

        var buffer = new MemoryStream();
        await using (var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false))
        {
            var chunk = new byte[81920];
            var copied = 0;
            while (true)
            {
                var read = await stream.ReadAsync(chunk, cancellationToken).ConfigureAwait(false);
                if (read == 0) break;
                copied += read;
                if (copied > MaximumFeedBytes)
                {
                    throw new InvalidDataException("Provider status response is too large.");
                }
                buffer.Write(chunk, 0, read);
            }
        }

        return System.Text.Encoding.UTF8.GetString(buffer.GetBuffer(), 0, checked((int)buffer.Length));
    }

    private static IReadOnlyList<ProviderReport> ParseAzure(string payload, DateTimeOffset now) =>
        ParseRss(payload, "microsoft-azure", "Azure public status feed",
            "Azure public status RSS");

    private static IReadOnlyList<ProviderReport> ParseAws(string payload, DateTimeOffset now) =>
        ParseRss(payload, "amazon-aws", "Amazon EC2 in us-east-1",
            "AWS public health RSS");

    private static IReadOnlyList<ProviderReport> ParseRss(
        string payload,
        string entryId,
        string scope,
        string titlePrefix)
    {
        var document = XDocument.Parse(payload);
        var channel = document.Root?.Element("channel")
            ?? throw new InvalidDataException("RSS channel is missing.");
        var items = channel.Elements("item").ToArray();
        var feedUpdated = RequiredDate(
            channel.Element("lastBuildDate")?.Value,
            "RSS lastBuildDate");
        if (items.Length == 0)
        {
            return [new(entryId, ProviderReportState.NoIncidents, scope, feedUpdated)];
        }

        var latest = items.Select(item => new
        {
            Title = item.Element("title")?.Value,
            Link = item.Element("link")?.Value,
            Updated = RequiredDate(
                item.Element("pubDate")?.Value ?? item.Element("pubdate")?.Value,
                "RSS item pubDate")
        }).OrderByDescending(item => item.Updated).First();
        if (string.IsNullOrWhiteSpace(latest.Title))
        {
            throw new InvalidDataException("RSS item title is missing.");
        }
        return [new(
            entryId,
            ProviderReportState.Incident,
            scope,
            latest.Updated,
            IncidentTitle: items.Length == 1 ? latest.Title : $"{items.Length} active reports; latest: {latest.Title}",
            IncidentLink: ReadUri(latest.Link))];
    }

    private static IReadOnlyList<ProviderReport> ParseGoogleWorkspace(string payload, DateTimeOffset now) =>
        ParseGoogleIncidents(
            payload,
            now,
            "google-gmail",
            "Gmail in the Google Workspace public incident feed",
            incident => ProductNames(incident).Any(name =>
                name.Equals("Gmail", StringComparison.OrdinalIgnoreCase)
                || name.Contains("Gmail", StringComparison.OrdinalIgnoreCase)),
            new("https://www.google.com/appsstatus/dashboard/"));

    private static IReadOnlyList<ProviderReport> ParseGoogleCloud(string payload, DateTimeOffset now) =>
        ParseGoogleIncidents(
            payload,
            now,
            "google-cloud",
            "Published Google Cloud product and region scope",
            _ => true,
            new("https://status.cloud.google.com/"));

    private static IReadOnlyList<ProviderReport> ParseGoogleIncidents(
        string payload,
        DateTimeOffset now,
        string entryId,
        string defaultScope,
        Func<JsonElement, bool> matches,
        Uri baseUri)
    {
        using var document = JsonDocument.Parse(payload);
        if (document.RootElement.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidDataException("Google incident feed is not an array.");
        }

        var active = document.RootElement.EnumerateArray()
            .Where(incident => matches(incident) && IsActiveGoogleIncident(incident, now))
            .ToArray();
        if (active.Length == 0)
        {
            return [new(entryId, ProviderReportState.NoIncidents, defaultScope)];
        }

        var latest = active.OrderByDescending(incident => OptionalDate(incident, "modified")).First();
        var products = active.SelectMany(ProductNames).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        var locations = active.SelectMany(CurrentLocationNames).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
        var scopeParts = products.Concat(locations).ToArray();
        var incidentTitle = GoogleIncidentTitle(latest);
        var id = latest.TryGetProperty("id", out var idValue) ? idValue.GetString() : null;
        return [new(
            entryId,
            ProviderReportState.Incident,
            scopeParts.Length == 0 ? defaultScope : ScopeText(scopeParts),
            OptionalDate(latest, "modified"),
            IncidentTitle: active.Length == 1 ? incidentTitle : $"{active.Length} active incidents; latest: {incidentTitle}",
            IncidentLink: string.IsNullOrWhiteSpace(id)
                ? baseUri
                : new Uri(baseUri, $"incidents/{Uri.EscapeDataString(id)}"))];
    }

    private static IReadOnlyList<ProviderReport> ParseCloudflare(string payload, DateTimeOffset now) =>
        ParseStatusPage(
            payload,
            "cloudflare-dns",
            ["Recursive DNS"],
            "Cloudflare Recursive DNS components",
            new("https://www.cloudflarestatus.com/"))
            .Concat(ParseStatusPage(
                payload,
                "cloudflare-network",
                ["CDN/Cache", "Network"],
                "Cloudflare CDN/Cache and Network components",
                new("https://www.cloudflarestatus.com/")))
            .ToArray();

    private static IReadOnlyList<ProviderReport> ParseGitHub(string payload, DateTimeOffset now) =>
        ParseStatusPage(
            payload,
            "github-website",
            ["Git Operations", "Issues", "Pull Requests", "API Requests"],
            "GitHub website, repository and API components",
            new("https://www.githubstatus.com/"))
            .Concat(ParseStatusPage(
                payload,
                "github-actions",
                ["Actions"],
                "GitHub Actions",
                new("https://www.githubstatus.com/")))
            .ToArray();

    private static IReadOnlyList<ProviderReport> ParseStatusPage(
        string payload,
        string entryId,
        string[] componentNames,
        string scope,
        Uri pageUri)
    {
        using var document = JsonDocument.Parse(payload);
        var root = document.RootElement;
        if (!root.TryGetProperty("components", out var components)
            || components.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidDataException("Statuspage components are missing.");
        }

        var selected = components.EnumerateArray()
            .Where(component => component.TryGetProperty("name", out var name)
                && componentNames.Contains(name.GetString(), StringComparer.Ordinal))
            .ToArray();
        if (selected.Length != componentNames.Length
            || selected.Any(component => !component.TryGetProperty("status", out var status)
                || status.ValueKind != JsonValueKind.String
                || string.IsNullOrWhiteSpace(status.GetString())))
        {
            throw new InvalidDataException("Expected Statuspage components are missing.");
        }

        var providerUpdated = ReadOptionalStatusDate(root, "page", "updated_at")
            ?? selected.Select(component => OptionalDate(component, "updated_at")).Max()
            ?? throw new InvalidDataException("Statuspage provider timestamp is missing.");
        var degraded = selected.Where(component =>
            !component.GetProperty("status").GetString()!.Equals("operational", StringComparison.Ordinal)).ToArray();
        if (degraded.Length == 0)
        {
            return [new(entryId, ProviderReportState.NoIncidents, scope, providerUpdated)];
        }

        var selectedIds = selected
            .Where(component => component.TryGetProperty("id", out _))
            .Select(component => component.GetProperty("id").GetString())
            .OfType<string>()
            .ToHashSet(StringComparer.Ordinal);
        JsonElement? matchingIncident = null;
        if (root.TryGetProperty("incidents", out var incidents) && incidents.ValueKind == JsonValueKind.Array)
        {
            matchingIncident = incidents.EnumerateArray()
                .Where(incident => !incident.TryGetProperty("status", out var status)
                    || !status.GetString()!.Equals("resolved", StringComparison.Ordinal))
                .FirstOrDefault(incident => incident.TryGetProperty("components", out var incidentComponents)
                    && incidentComponents.EnumerateArray().Any(component =>
                        component.TryGetProperty("id", out var id)
                        && id.GetString() is { } componentId
                        && selectedIds.Contains(componentId)));
        }

        string title;
        Uri link = pageUri;
        if (matchingIncident is { ValueKind: not JsonValueKind.Undefined } incident)
        {
            title = incident.TryGetProperty("name", out var name)
                ? name.GetString() ?? "Provider incident"
                : "Provider incident";
            if (incident.TryGetProperty("shortlink", out var shortlink)
                && Uri.TryCreate(shortlink.GetString(), UriKind.Absolute, out var incidentUri)
                && incidentUri.Scheme == Uri.UriSchemeHttps)
            {
                link = incidentUri;
            }
        }
        else
        {
            var names = string.Join(", ", degraded.Select(component => component.GetProperty("name").GetString()));
            title = $"{names} reporting a non-operational status";
        }

        return [new(entryId, ProviderReportState.Incident, scope, providerUpdated,
            IncidentTitle: title, IncidentLink: link)];
    }

    private static bool IsActiveGoogleIncident(JsonElement incident, DateTimeOffset now)
    {
        var begin = OptionalDate(incident, "begin");
        if (begin is null || begin > now) return false;
        if (!incident.TryGetProperty("end", out var end) || end.ValueKind == JsonValueKind.Null) return true;
        return end.GetDateTimeOffset() > now;
    }

    private static string[] ProductNames(JsonElement incident) =>
        StringArray(incident, "affected_products", "title").ToArray();

    private static string[] CurrentLocationNames(JsonElement incident) =>
        StringArray(incident, "currently_affected_locations", "title").ToArray();

    private static IEnumerable<string> StringArray(JsonElement incident, string property, string value)
    {
        if (!incident.TryGetProperty(property, out var array) || array.ValueKind != JsonValueKind.Array)
        {
            yield break;
        }

        foreach (var item in array.EnumerateArray())
        {
            if (item.TryGetProperty(value, out var text)
                && text.ValueKind == JsonValueKind.String
                && !string.IsNullOrWhiteSpace(text.GetString()))
            {
                yield return text.GetString()!;
            }
        }
    }

    private static string GoogleIncidentTitle(JsonElement incident)
    {
        if (incident.TryGetProperty("most_recent_update", out var update)
            && update.TryGetProperty("text", out var text))
        {
            var lines = text.GetString()?.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries) ?? [];
            var nextSummary = false;
            foreach (var line in lines)
            {
                var trimmed = line.Trim().Trim('*');
                if (trimmed.Equals("Summary", StringComparison.OrdinalIgnoreCase)
                    || trimmed.Equals("Summary:", StringComparison.OrdinalIgnoreCase)
                    || trimmed.Equals("Title", StringComparison.OrdinalIgnoreCase)
                    || trimmed.Equals("Title:", StringComparison.OrdinalIgnoreCase))
                {
                    nextSummary = true;
                    continue;
                }
                if (nextSummary && !string.IsNullOrWhiteSpace(trimmed))
                {
                    return trimmed;
                }
            }
        }

        return incident.TryGetProperty("service_name", out var service)
            ? service.GetString() ?? "Provider incident"
            : "Provider incident";
    }

    private static string ScopeText(IReadOnlyList<string> values)
    {
        var items = values.Where(value => !string.IsNullOrWhiteSpace(value)).Distinct(StringComparer.Ordinal).Take(4).ToArray();
        var remaining = values.Distinct(StringComparer.Ordinal).Count() - items.Length;
        return items.Length == 0 ? "Published provider scope"
            : remaining > 0 ? $"{string.Join(", ", items)} +{remaining} more" : string.Join(", ", items);
    }

    private static DateTimeOffset? ReadOptionalStatusDate(JsonElement root, string child, string property)
    {
        if (!root.TryGetProperty(child, out var value) || value.ValueKind != JsonValueKind.Object)
        {
            return null;
        }
        return OptionalDate(value, property);
    }

    private static DateTimeOffset? OptionalDate(JsonElement element, string property)
    {
        if (!element.TryGetProperty(property, out var value) || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }
        return value.GetDateTimeOffset();
    }

    private static DateTimeOffset? ReadDate(string? value)
    {
        if (value is null) return null;
        var normalized = value;
        foreach (var (abbreviation, offset) in UsTimeZoneOffsets)
        {
            if (!normalized.EndsWith(" " + abbreviation, StringComparison.Ordinal)) continue;
            normalized = normalized[..^abbreviation.Length] + offset;
            break;
        }

        return DateTimeOffset.TryParse(
            normalized,
            CultureInfo.InvariantCulture,
            DateTimeStyles.AllowWhiteSpaces | DateTimeStyles.AssumeUniversal,
            out var parsed)
            ? parsed
            : null;
    }

    private static DateTimeOffset RequiredDate(string? value, string field) =>
        ReadDate(value) ?? throw new InvalidDataException($"{field} is missing or invalid.");

    private static Uri? ReadUri(string? value) =>
        Uri.TryCreate(value, UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps ? uri : null;

    private static readonly (string Name, string Offset)[] UsTimeZoneOffsets =
    [
        ("PST", "-08:00"), ("PDT", "-07:00"),
        ("MST", "-07:00"), ("MDT", "-06:00"),
        ("CST", "-06:00"), ("CDT", "-05:00"),
        ("EST", "-05:00"), ("EDT", "-04:00")
    ];

    private sealed record FeedDefinition(
        string Key,
        IReadOnlyList<string> EntryIds,
        Func<string, DateTimeOffset, IReadOnlyList<ProviderReport>> Parse);
}
