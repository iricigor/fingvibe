using System.Globalization;
using System.Net;
using FingVibe.App;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class NetworkMonitorViewPresentationTests
{
    private static readonly DateTimeOffset Now = new(2026, 11, 20, 9, 25, 0, TimeSpan.Zero);
    private static readonly LanNetwork Network = new("Ethernet", IPAddress.Parse("192.168.0.10"),
        IPAddress.Parse("192.168.0.0"), 24, true, IPAddress.Parse("192.168.0.1"));

    private static NetworkMonitorView View(NetworkMonitorState state, NetworkMonitorObservation? observation, string detail = "Status.",
        NetworkHealthAssessment? health = null) =>
        NetworkMonitorViewPresentation.Create(new(state, Now, null, observation, detail) { Health = health },
            Now, TimeZoneInfo.Utc, CultureInfo.InvariantCulture);

    private static NetworkHealthAssessment Health(NetworkHealthVerdict verdict, DateTimeOffset at, int recovery = 0) =>
        new(verdict, at, (verdict is NetworkHealthVerdict.Verifying or NetworkHealthVerdict.Problem)
            ? [new(NetworkHealthSymptomKind.HighLatency, NetworkMonitorTarget.Cloudflare, "High latency: Cloudflare 1.1.1.1 210 ms median (limit 150 ms)")]
            : [], recovery, 7, verdict == NetworkHealthVerdict.Uncertain ? ["More than one active network route is available."] : []);

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
        var old = NetworkMonitorReviewFixture.Create(Network, Now.AddMinutes(-3).AddSeconds(-1));
        var views = new[]
        {
            View(NetworkMonitorState.Off, null), View(NetworkMonitorState.Paused, fresh, health: Health(NetworkHealthVerdict.Problem, fresh.CompletedAt)),
            View(NetworkMonitorState.Waiting, null), View(NetworkMonitorState.Checking, null), View(NetworkMonitorState.Waiting, fresh),
            View(NetworkMonitorState.Waiting, old, health: Health(NetworkHealthVerdict.Healthy, old.CompletedAt)),
            View(NetworkMonitorState.Checking, fresh, health: Health(NetworkHealthVerdict.Learning, fresh.CompletedAt)),
            View(NetworkMonitorState.Waiting, fresh, health: Health(NetworkHealthVerdict.Healthy, fresh.CompletedAt)),
            View(NetworkMonitorState.Waiting, fresh, health: Health(NetworkHealthVerdict.Verifying, fresh.CompletedAt)),
            View(NetworkMonitorState.Waiting, fresh, health: Health(NetworkHealthVerdict.Problem, fresh.CompletedAt, 2)),
            View(NetworkMonitorState.Waiting, fresh, health: Health(NetworkHealthVerdict.Uncertain, fresh.CompletedAt))
        };

        Assert.Equal(Enum.GetValues<NetworkMonitorIndicatorKind>(), views.Select(view => view.Kind).ToArray());
        Assert.Equal(views.Length, views.Select(view => view.Title).Distinct().Count());
        Assert.Equal("Last raw check: today 09:24:30. Not current: monitoring is paused.", views[1].LastCheck);
        Assert.Equal("Last raw check: today 09:21:59. Not current: no newer result has been delivered.", views[5].LastCheck);
        Assert.StartsWith("No check has completed for over three minutes", views[5].Detail);
        Assert.StartsWith("No problems found. Learning normal latency: 7 of 20 healthy checks", views[6].Detail);
        Assert.StartsWith("High latency: Cloudflare 1.1.1.1 210 ms median (limit 150 ms). Checking again every 30 seconds", views[8].Detail);
        Assert.Contains("Recovery: 2 of 5 consecutive healthy checks.", views[9].Detail);
        Assert.Equal("Network monitoring: Problem confirmed. Last raw check: today 09:24:30. Opens Network health.", views[9].IndicatorName);
        Assert.StartsWith("FingVibe does not judge the selected LAN", views[10].Detail);
        Assert.Contains("Status.", views[9].Detail);
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
