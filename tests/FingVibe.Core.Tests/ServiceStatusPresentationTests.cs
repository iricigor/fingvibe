using FingVibe.Core.Networking;
using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class ServiceStatusPresentationTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 20, 9, 25, 0, TimeSpan.Zero);

    [Fact]
    public void CatalogHasTheApprovedSixProviderPairs()
    {
        var entries = ServiceStatusCatalog.Entries;
        Assert.Equal(12, entries.Count);
        Assert.Equal(12, entries.Select(entry => entry.Id).Distinct().Count());
        foreach (var provider in entries.GroupBy(entry => entry.Provider))
        {
            Assert.Equal([ServiceStatusCategory.Consumer, ServiceStatusCategory.Infrastructure],
                provider.Select(entry => entry.Category).ToArray());
        }
        Assert.Equal(["Microsoft", "Google", "Amazon", "Cloudflare", "Apple", "GitHub"],
            entries.Select(entry => entry.Provider).Distinct().ToArray());
        Assert.All(entries, entry => Assert.Equal(Uri.UriSchemeHttps, entry.Link.Scheme));
    }

    [Fact]
    public void ControlledFixtureDistinguishesEveryPresentationState()
    {
        var rows = ServiceStatusPresentation.Rows(ControlledServiceStatusSource.Create(Now), Now);

        Assert.Equal(
        [
            ProviderReportState.NoIncidents, ProviderReportState.Incident, ProviderReportState.SourcePending,
            ProviderReportState.OfficialPageOnly, ProviderReportState.Unavailable, ProviderReportState.Stale,
            ProviderReportState.Malformed
        ], rows.Select(row => row.State).Distinct().Order().ToArray());
        var headlines = rows.GroupBy(row => row.State).ToDictionary(group => group.Key,
            group => Assert.Single(group.Select(row => row.Headline).Distinct()));
        Assert.Equal(7, headlines.Values.Distinct().Count());
        var incident = Assert.Single(rows, row => row.State == ProviderReportState.Incident);
        Assert.Equal(("Degraded service", "Example: europe-west1", "Provider updated 09:21", "View incident"),
            (incident.Headline, incident.Detail, incident.TimestampLine, incident.LinkLabel));
        Assert.All(rows.Where(row => row.State is ProviderReportState.Unavailable or ProviderReportState.Stale
            or ProviderReportState.Malformed), row => Assert.Equal(ServiceStatusTone.Attention, row.Tone));
        Assert.Equal("1 reported issue | 3 feeds without current data | 4 entries not monitored",
            ServiceStatusPresentation.Summary(rows));
        Assert.Equal("Feed refresh: today, 09:25", ServiceStatusPresentation.RetrievalText(ControlledServiceStatusSource.Create(Now), Now));
    }

    [Fact]
    public void UnconnectedSourceNeverPresentsHealth()
    {
        var snapshot = new UnconnectedServiceStatusSource().GetReportsAsync(false, CancellationToken.None).Result;
        var rows = ServiceStatusPresentation.Rows(snapshot, Now);

        Assert.DoesNotContain(rows, row => row.Tone == ServiceStatusTone.Good);
        Assert.Equal(8, rows.Count(row => row.State == ProviderReportState.NotConnected));
        Assert.Equal("0 reported issues | 0 feeds without current data | 12 entries not monitored",
            ServiceStatusPresentation.Summary(rows));
        Assert.Equal("Provider feeds not retrieved", ServiceStatusPresentation.RetrievalText(snapshot, Now));
    }

    [Theory]
    [InlineData("microsoft-outlook", ProviderReportState.SourcePending)]
    [InlineData("amazon-shopping", ProviderReportState.SourcePending)]
    [InlineData("apple-icloud", ProviderReportState.OfficialPageOnly)]
    public void EntriesWithoutAnApprovedFeedIgnoreSuppliedReports(string id, ProviderReportState expected)
    {
        var entry = ServiceStatusCatalog.Entries.Single(entry => entry.Id == id);
        var row = ServiceStatusPresentation.Row(entry, new(id, ProviderReportState.NoIncidents, ProviderUpdated: Now), Now);

        Assert.Equal(expected, row.State);
        Assert.Equal(("Not monitored", "No feed timestamp", ServiceStatusTone.Neutral), (row.Detail, row.TimestampLine, row.Tone));
    }

    [Fact]
    public void FiltersKeepOnlyTheSelectedCategory()
    {
        var rows = ServiceStatusPresentation.Rows(null, Now);

        Assert.Equal(12, ServiceStatusPresentation.Filter(rows, ServiceStatusFilter.All).Count);
        Assert.All(ServiceStatusPresentation.Filter(rows, ServiceStatusFilter.Consumer),
            row => Assert.Equal(ServiceStatusCategory.Consumer, row.Entry.Category));
        Assert.Equal(6, ServiceStatusPresentation.Filter(rows, ServiceStatusFilter.Infrastructure).Count);
    }

    [Fact]
    public async Task FailedRefreshKeepsReportsButMarksThemOutdated()
    {
        var time = new FakeTimeProvider(Now);
        time.SetLocalTimeZone(TimeZoneInfo.Utc);
        var source = new SequenceSource(ControlledServiceStatusSource.Create(Now));
        var model = new ServiceStatusPageModel(source, time);
        await model.LoadAsync(false, CancellationToken.None);
        time.Advance(TimeSpan.FromMinutes(7));

        await model.LoadAsync(true, CancellationToken.None);

        Assert.Equal([false, true], source.Requests);
        Assert.Contains("Provider reports could not be retrieved: offline", model.RequestError);
        Assert.DoesNotContain(model.AllRows, row => row.State is ProviderReportState.NoIncidents or ProviderReportState.Incident);
        var azure = Assert.Single(model.AllRows, row => row.Entry.Id == "microsoft-azure");
        Assert.Equal(("Report outdated", "Retained from 09:25 - not current", "Refresh failed at 09:32"),
            (azure.Headline, azure.Detail, azure.TimestampLine));
    }

    private sealed class SequenceSource(ServiceStatusSnapshot first) : IServiceStatusSource
    {
        public List<bool> Requests { get; } = [];

        public Task<ServiceStatusSnapshot> GetReportsAsync(bool refresh, CancellationToken cancellationToken)
        {
            Requests.Add(refresh);
            return Requests.Count == 1 ? Task.FromResult(first) : throw new HttpRequestException("offline");
        }
    }
}
