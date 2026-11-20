using System.Net;
using System.Net.Http.Headers;
using FingVibe.Core.Networking;
using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class OfficialServiceStatusSourceTests
{
    private static readonly DateTimeOffset Now =
        new(2026, 11, 20, 9, 25, 0, TimeSpan.Zero);

    private static readonly IReadOnlyDictionary<string, Uri> Endpoints =
        new Dictionary<string, Uri>(StringComparer.Ordinal)
        {
            ["azure"] = new("https://provider.test/azure.rss"),
            ["aws"] = new("https://provider.test/aws.rss"),
            ["google-workspace"] = new("https://provider.test/google-workspace.json"),
            ["google-cloud"] = new("https://provider.test/google-cloud.json"),
            ["cloudflare"] = new("https://provider.test/cloudflare.json"),
            ["github"] = new("https://provider.test/github.json")
        };

    [Fact]
    public async Task SupportedFeedsProduceScopedTruthfulReportsForEveryMonitoredEntry()
    {
        var handler = HealthyHandler();
        var source = Source(handler);

        var snapshot = await source.GetReportsAsync(false, CancellationToken.None);
        var reports = snapshot.Reports.ToDictionary(report => report.EntryId);

        Assert.Equal(8, reports.Count);
        Assert.DoesNotContain("microsoft-outlook", reports.Keys);
        Assert.DoesNotContain("amazon-shopping", reports.Keys);
        Assert.DoesNotContain(reports.Keys, key => key.StartsWith("apple-", StringComparison.Ordinal));
        Assert.Equal(
            new[] { "microsoft-azure", "google-gmail", "google-cloud", "amazon-aws",
                "cloudflare-dns", "cloudflare-network", "github-website", "github-actions" }.Order().ToArray(),
            reports.Keys.Order().ToArray());
        Assert.Equal(ProviderReportState.Incident, reports["microsoft-azure"].State);
        Assert.Equal(ProviderReportState.Incident, reports["google-gmail"].State);
        Assert.Equal(ProviderReportState.Incident, reports["google-cloud"].State);
        Assert.Equal(ProviderReportState.Incident, reports["amazon-aws"].State);
        Assert.Equal(ProviderReportState.NoIncidents, reports["cloudflare-dns"].State);
        Assert.Equal(ProviderReportState.Incident, reports["cloudflare-network"].State);
        Assert.Equal(ProviderReportState.NoIncidents, reports["github-website"].State);
        Assert.Equal(ProviderReportState.Incident, reports["github-actions"].State);
        Assert.Equal("Azure storage degraded", reports["microsoft-azure"].IncidentTitle);
        Assert.Equal("Gmail sign-in issue", reports["google-gmail"].IncidentTitle);
        Assert.Contains("Compute Engine", reports["google-cloud"].Scope);
        Assert.Contains("europe-west1", reports["google-cloud"].Scope);
        Assert.Equal("Cloudflare CDN/Cache and Network components", reports["cloudflare-network"].Scope);
        Assert.Equal("GitHub Actions component degraded", reports["github-actions"].IncidentTitle);
        Assert.Equal("Amazon EC2 in us-east-1", reports["amazon-aws"].Scope);
        Assert.All(reports.Values, report => Assert.Null(report.FailedAt));
        Assert.Equal(Now, snapshot.RetrievedAt);
        var rows = ServiceStatusPresentation.Rows(snapshot, Now);
        Assert.Equal(12, rows.Count);
        Assert.Equal("Azure storage degraded",
            rows.Single(row => row.Entry.Id == "microsoft-azure").Headline);
        Assert.Equal("Gmail sign-in issue",
            rows.Single(row => row.Entry.Id == "google-gmail").Headline);
        Assert.Equal(ProviderReportState.SourcePending,
            rows.Single(row => row.Entry.Id == "microsoft-outlook").State);
        Assert.Equal(6, handler.Requests.Count);
        Assert.All(handler.Requests, request =>
        {
            Assert.Equal(HttpMethod.Get, request.Method);
            Assert.False(request.HasContent);
            Assert.Contains("FingVibe-ProviderStatus/1.0", request.UserAgent);
        });
    }

    [Fact]
    public async Task PageOpenUsesFiveMinuteCacheAndExplicitRefreshAlwaysFetches()
    {
        var time = new FakeTimeProvider(Now);
        var handler = HealthyHandler();
        var source = Source(handler, time);

        var first = await source.GetReportsAsync(false, CancellationToken.None);
        var cached = await source.GetReportsAsync(false, CancellationToken.None);
        Assert.Same(first, cached);
        Assert.Equal(6, handler.Requests.Count);

        time.Advance(TimeSpan.FromMinutes(4));
        Assert.Same(first, await source.GetReportsAsync(false, CancellationToken.None));
        Assert.Equal(6, handler.Requests.Count);

        var refreshed = await source.GetReportsAsync(true, CancellationToken.None);
        Assert.NotSame(first, refreshed);
        Assert.Equal(12, handler.Requests.Count);

        time.Advance(TimeSpan.FromMinutes(6));
        await source.GetReportsAsync(false, CancellationToken.None);
        Assert.Equal(18, handler.Requests.Count);
    }

    [Fact]
    public async Task HttpFailureUsesUnavailableInitiallyAndMarksRetainedFeedStale()
    {
        var time = new FakeTimeProvider(Now);
        var handler = HealthyHandler();
        var source = Source(handler, time);
        var first = await source.GetReportsAsync(false, CancellationToken.None);
        Assert.Equal(ProviderReportState.Incident,
            first.Reports.Single(report => report.EntryId == "amazon-aws").State);

        handler.Set(Endpoints["aws"], HttpStatusCode.ServiceUnavailable, "offline");
        time.Advance(TimeSpan.FromSeconds(1));
        var second = await source.GetReportsAsync(true, CancellationToken.None);
        var aws = Assert.Single(second.Reports, report => report.EntryId == "amazon-aws");

        Assert.Equal(ProviderReportState.Stale, aws.State);
        Assert.Equal(Now.AddSeconds(1), aws.FailedAt);
        Assert.Equal("AWS EC2 issue", aws.IncidentTitle);

        time.Advance(TimeSpan.FromSeconds(1));
        var third = await source.GetReportsAsync(true, CancellationToken.None);
        var stillStale = Assert.Single(third.Reports, report => report.EntryId == "amazon-aws");
        Assert.Equal(ProviderReportState.Stale, stillStale.State);
        Assert.Equal("AWS EC2 issue", stillStale.IncidentTitle);
        Assert.Equal(Now.AddSeconds(2), stillStale.FailedAt);
    }

    [Fact]
    public async Task HttpFailureWithoutPriorReportIsUnavailableAndMalformedJsonIsDistinct()
    {
        var handler = HealthyHandler();
        handler.Set(Endpoints["aws"], HttpStatusCode.BadGateway, "offline");
        handler.Set(Endpoints["cloudflare"], HttpStatusCode.OK, "{\"components\":null}");

        var snapshot = await Source(handler).GetReportsAsync(true, CancellationToken.None);

        Assert.Equal(
            ProviderReportState.Unavailable,
            snapshot.Reports.Single(report => report.EntryId == "amazon-aws").State);
        Assert.All(
            snapshot.Reports.Where(report => report.EntryId.StartsWith("cloudflare-", StringComparison.Ordinal)),
            report => Assert.Equal(ProviderReportState.Malformed, report.State));
        var rows = ServiceStatusPresentation.Rows(snapshot, Now);
        Assert.Equal(
            "Provider request failed.",
            rows.Single(row => row.Entry.Id == "amazon-aws").Detail);
        Assert.Equal(
            "Provider response could not be read.",
            rows.Single(row => row.Entry.Id == "cloudflare-dns").Detail);
    }

    [Fact]
    public async Task GoogleResolvedIncidentsAndEmptyRssAreNotPresentedAsIncidents()
    {
        var handler = HealthyHandler();
        handler.Set(Endpoints["google-workspace"], HttpStatusCode.OK,
            """
            [{
              "id":"resolved-gmail",
              "begin":"2026-11-18T09:00:00Z",
              "end":"2026-11-18T10:00:00Z",
              "modified":"2026-11-18T10:01:00Z",
              "service_name":"Gmail",
              "affected_products":[{"title":"Gmail"}],
              "uri":"incidents/resolved-gmail"
            }]
            """);
        handler.Set(Endpoints["aws"], HttpStatusCode.OK,
            """
            <rss version="2.0"><channel><title>EC2</title>
            <lastBuildDate>Fri, 20 Nov 2026 09:00:00 GMT</lastBuildDate>
            </channel></rss>
            """);

        var snapshot = await Source(handler).GetReportsAsync(true, CancellationToken.None);

        Assert.Equal(
            ProviderReportState.NoIncidents,
            snapshot.Reports.Single(report => report.EntryId == "google-gmail").State);
        Assert.Equal(
            ProviderReportState.NoIncidents,
            snapshot.Reports.Single(report => report.EntryId == "amazon-aws").State);
    }

    [Fact]
    public async Task CancellationDoesNotConvertIntoAProviderFailure()
    {
        var handler = new ProviderHandler(HealthyResponses(), blockRequests: true);
        using var cancellation = new CancellationTokenSource();
        var run = Source(handler).GetReportsAsync(true, cancellation.Token);
        await WaitUntilAsync(() => handler.Requests.Count > 0);

        cancellation.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => run);
    }

    private static OfficialServiceStatusSource Source(
        ProviderHandler handler,
        TimeProvider? time = null) =>
        new(new HttpClient(handler), time ?? new FakeTimeProvider(Now), Endpoints);

    private static ProviderHandler HealthyHandler() => new(HealthyResponses());

    private static Dictionary<Uri, ProviderResponse> HealthyResponses() => new()
    {
        [Endpoints["azure"]] = new(HttpStatusCode.OK,
            """
            <rss version="2.0"><channel><title>Azure</title>
            <lastBuildDate>Fri, 20 Nov 2026 09:00:00 GMT</lastBuildDate>
            <item><title>Azure storage degraded</title><link>https://azure.status.microsoft/en-us/status/history/</link>
            <pubDate>Fri, 20 Nov 2026 09:00:00 GMT</pubDate></item>
            </channel></rss>
            """),
        [Endpoints["aws"]] = new(HttpStatusCode.OK,
            """
            <rss version="2.0"><channel><title>EC2</title>
            <lastBuildDate>Thu, 19 Nov 2026 17:50:30 PST</lastBuildDate>
            <item><title>AWS EC2 issue</title><link>https://status.aws.amazon.com/</link>
            <pubDate>Thu, 19 Nov 2026 17:40:00 PST</pubDate></item>
            </channel></rss>
            """),
        [Endpoints["google-workspace"]] = new(HttpStatusCode.OK,
            """
            [{
              "id":"gmail-1","begin":"2026-11-20T09:00:00Z","modified":"2026-11-20T09:20:00Z",
              "service_name":"Gmail","affected_products":[{"title":"Gmail"}],
              "most_recent_update":{"text":"**Summary:**\nGmail sign-in issue"},
              "uri":"incidents/gmail-1"
            }]
            """),
        [Endpoints["google-cloud"]] = new(HttpStatusCode.OK,
            """
            [{
              "id":"cloud-1","begin":"2026-11-20T08:30:00Z","modified":"2026-11-20T09:10:00Z",
              "service_name":"Compute Engine","affected_products":[{"title":"Compute Engine"}],
              "currently_affected_locations":[{"title":"europe-west1"}],
              "most_recent_update":{"text":"**Summary:**\nElevated errors in Compute Engine"},
              "uri":"incidents/cloud-1"
            }]
            """),
        [Endpoints["cloudflare"]] = new(HttpStatusCode.OK,
            """
            {
              "page":{"updated_at":"2026-11-20T09:22:00Z","url":"https://www.cloudflarestatus.com/"},
              "components":[
                {"id":"dns","name":"Recursive DNS","status":"operational","updated_at":"2026-11-20T09:00:00Z"},
                {"id":"cdn","name":"CDN/Cache","status":"degraded_performance","updated_at":"2026-11-20T09:21:00Z"},
                {"id":"network","name":"Network","status":"operational","updated_at":"2026-11-20T09:20:00Z"}
              ],
              "incidents":[
                {"name":"Cloudflare CDN incident","status":"investigating",
                 "components":[{"id":"cdn"}],"shortlink":"https://www.cloudflarestatus.com/incidents/cf-1"}
              ]
            }
            """),
        [Endpoints["github"]] = new(HttpStatusCode.OK,
            """
            {
              "page":{"updated_at":"2026-11-20T09:23:00Z","url":"https://www.githubstatus.com/"},
              "components":[
                {"id":"git","name":"Git Operations","status":"operational","updated_at":"2026-11-20T09:00:00Z"},
                {"id":"issues","name":"Issues","status":"operational","updated_at":"2026-11-20T09:00:00Z"},
                {"id":"prs","name":"Pull Requests","status":"operational","updated_at":"2026-11-20T09:00:00Z"},
                {"id":"api","name":"API Requests","status":"operational","updated_at":"2026-11-20T09:00:00Z"},
                {"id":"actions","name":"Actions","status":"partial_outage","updated_at":"2026-11-20T09:21:00Z"}
              ],
              "incidents":[
                {"name":"GitHub Actions component degraded","status":"investigating",
                 "components":[{"id":"actions"}],"shortlink":"https://www.githubstatus.com/incidents/gh-1"}
              ]
            }
            """)
    };

    private static async Task WaitUntilAsync(Func<bool> condition)
    {
        for (var attempt = 0; attempt < 100 && !condition(); attempt++)
        {
            await Task.Yield();
        }
        Assert.True(condition());
    }

    private sealed record ProviderResponse(HttpStatusCode Status, string Body);

    private sealed record CapturedRequest(HttpMethod Method, Uri Uri, bool HasContent, string UserAgent)
    {
        public bool Content => HasContent;
    }

    private sealed class ProviderHandler(
        Dictionary<Uri, ProviderResponse> responses,
        bool blockRequests = false) : HttpMessageHandler
    {
        public List<CapturedRequest> Requests { get; } = [];

        public void Set(Uri endpoint, HttpStatusCode status, string body) =>
            responses[endpoint] = new(status, body);

        protected override async Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            Requests.Add(new(
                request.Method,
                request.RequestUri!,
                request.Content is not null,
                string.Join(" ", request.Headers.UserAgent.Select(Product))));
            if (blockRequests)
            {
                await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken);
            }

            var response = responses[request.RequestUri!];
            return new HttpResponseMessage(response.Status)
            {
                RequestMessage = request,
                Content = new StringContent(response.Body)
            };
        }

        private static string Product(ProductInfoHeaderValue value) => value.ToString();
    }
}
