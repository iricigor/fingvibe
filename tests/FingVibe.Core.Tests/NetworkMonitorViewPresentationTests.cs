using System.Globalization;
using System.Net;
using FingVibe.App;
using FingVibe.Core.Models;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class NetworkMonitorViewPresentationTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 20, 9, 25, 0, TimeSpan.Zero);
    private static readonly LanNetwork Network = new("Ethernet", IPAddress.Parse("192.168.0.10"),
        IPAddress.Parse("192.168.0.0"), 24, true, IPAddress.Parse("192.168.0.1"));

    private static NetworkMonitorView View(NetworkMonitorState state, NetworkMonitorObservation? observation, string detail = "Status.") =>
        NetworkMonitorViewPresentation.Create(new(state, Now, null, observation, detail), Now, TimeZoneInfo.Utc, CultureInfo.InvariantCulture);

    [Fact]
    public void OffWithoutResultStaysExplicitlyNotHealthy()
    {
        var view = View(NetworkMonitorState.Off, null, "Off. No background network checks are scheduled.");

        Assert.Equal(NetworkMonitorIndicatorKind.Off, view.Kind);
        Assert.Equal("Monitoring off", view.Title);
        Assert.Equal(NetworkMonitorViewPresentation.OffDetail, view.Detail);
        Assert.Equal("No raw check has completed yet.", view.LastCheck);
        Assert.Empty(view.Rows);
        Assert.Equal("Network monitoring: Monitoring off. No raw check has completed yet. Opens Network health.", view.IndicatorName);
        Assert.EndsWith("will not overwrite the file.", View(NetworkMonitorState.Off, null,
            "Off. No background network checks are scheduled. " + NetworkMonitorPresentation.LoadFailedMessage).Detail);
    }

    [Fact]
    public void StatesAndResultAgesStayDistinct()
    {
        var fresh = NetworkMonitorReviewFixture.Create(Network, Now.AddSeconds(-30));
        var old = NetworkMonitorReviewFixture.Create(Network, Now.AddMinutes(-3));
        var views = new[]
        {
            View(NetworkMonitorState.Off, null), View(NetworkMonitorState.Paused, fresh), View(NetworkMonitorState.Waiting, null),
            View(NetworkMonitorState.Checking, fresh), View(NetworkMonitorState.Waiting, fresh), View(NetworkMonitorState.Waiting, old)
        };

        Assert.Equal(Enum.GetValues<NetworkMonitorIndicatorKind>(), views.Select(view => view.Kind).ToArray());
        Assert.Equal(6, views.Select(view => view.Title).Distinct().Count());
        Assert.Equal("Last raw check: today 09:24:30. Not current: monitoring is paused.", views[1].LastCheck);
        Assert.Equal("Last raw check: today 09:24:30.", views[4].LastCheck);
        Assert.Equal("Last raw check: today 09:22:00. Not current: no newer result has been delivered.", views[5].LastCheck);
        Assert.All(views[1..], view => Assert.Contains(NetworkMonitorViewPresentation.RawNote, view.Detail));
        Assert.All(views, view => Assert.DoesNotContain("healthy", view.Title, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void RowsSummarizeEachTargetAndResolverWithoutAVerdict()
    {
        var rows = NetworkMonitorViewPresentation.Rows(NetworkMonitorReviewFixture.Create(Network, Now));

        Assert.Equal(
        [
            new("Gateway 192.168.0.1", "5/5 ping responses, 2-4 ms"),
            new("Cloudflare 1.1.1.1", "5/5 ping responses, 11-14 ms"),
            new("Google 8.8.8.8", "4/5 ping responses, 15-17 ms"),
            new("Windows DNS (may use cache)", "Resolved, 9 ms"),
            new("Cloudflare DNS", "Resolved, 15 ms"),
            new("Google DNS", "Error: Timed out after 2 seconds")
        ], rows);
    }
}
