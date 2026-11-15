using Ex220Inspector;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class Ex220CaptureRunnerTests
{
    [Fact]
    public async Task AllSourcesAndEveryPageAreCapturedBeforeReturningCompleteSnapshot()
    {
        var browser = new Browser();
        var capture = await InspectorCaptureRunner.CaptureAsync(browser, null, CancellationToken.None);
        Assert.Equal(3, capture.Count(ClientSource.Clients));
        Assert.Equal(4, capture.Count(ClientSource.Wired));
        Assert.Equal(2, capture.Count(ClientSource.Arp));
        Assert.Equal(9, capture.Rows(true).Count);
        Assert.Equal(new[] { 1, 2, 3, 1, 2, 3, 4, 1, 2 }, browser.Pages);
        Assert.True(browser.SignedIn);
    }

    [Theory]
    [InlineData(ClientSource.Clients, 3)]
    [InlineData(ClientSource.Wired, 4)]
    [InlineData(ClientSource.Arp, 2)]
    public async Task IndividualCaptureNavigatesOnlySelectedSourceAndReadsEveryPage(ClientSource source, int pages)
    {
        var browser = new Browser();
        var capture = await InspectorCaptureRunner.CaptureSourceAsync(browser, source, null, CancellationToken.None);
        Assert.Equal([source], browser.Sources);
        Assert.Equal(Enumerable.Range(1, pages), browser.Pages);
        Assert.Equal(pages, capture.Count(source));
        Assert.All(Enum.GetValues<ClientSource>().Where(other => other != source),
            other => Assert.False(capture.Has(other)));
        Assert.True(browser.SignedIn);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task FailedIndividualCaptureKeepsAllPreviousSources(bool cancel)
    {
        var previous = new ClientCapture();
        foreach (var source in Enum.GetValues<ClientSource>())
            previous.Add(source, [new("Previous", $"00:11:22:33:55:{(int)source:X2}", "192.168.0.99")]);
        var before = previous.Rows(true);
        using var cancellation = new CancellationTokenSource();
        var browser = new Browser { Failure = cancel ? null : "changing-count", Cancel = cancel ? cancellation : null };
        var error = await Record.ExceptionAsync(async () =>
        {
            var completed = await InspectorCaptureRunner.CaptureSourceAsync(browser, ClientSource.Wired, null, cancellation.Token);
            previous.ReplaceSource(ClientSource.Wired, completed);
        });
        if (cancel) Assert.IsAssignableFrom<OperationCanceledException>(error);
        else Assert.IsType<InvalidDataException>(error);
        Assert.Equal(before, previous.Rows(true));
        Assert.Equal([ClientSource.Wired], browser.Sources);
    }

    [Fact]
    public async Task ArpCanContainDifferentAddressesForTheSameMacAcrossPages()
    {
        var browser = new Browser { ArpAliases = true };
        var capture = await InspectorCaptureRunner.CaptureSourceAsync(browser, ClientSource.Arp, null, CancellationToken.None);
        Assert.Equal(new[] { 1, 2 }, browser.Pages);
        Assert.Equal(2, capture.Count(ClientSource.Arp));
        var row = Assert.Single(capture.Rows(true));
        Assert.Equal("", row.Ip);
        Assert.Equal("Multiple ARP IPs: 192.168.0.22, 192.168.0.23", row.ArpComparison);
    }

    [Fact]
    public async Task RepeatedWholeArpPageStillFailsInsteadOfPretendingPaginationSucceeded()
    {
        await Assert.ThrowsAsync<InvalidDataException>(() =>
            InspectorCaptureRunner.CaptureSourceAsync(new Browser { Failure = "duplicate" },
                ClientSource.Arp, null, CancellationToken.None));
    }

    [Theory]
    [InlineData("stuck")]
    [InlineData("changing-count")]
    [InlineData("duplicate")]
    public async Task InvalidOrStuckPaginationNeverReturnsPartialCapture(string failure)
    {
        var browser = new Browser { Failure = failure };
        await Assert.ThrowsAsync<InvalidDataException>(() =>
            InspectorCaptureRunner.CaptureAsync(browser, null, CancellationToken.None));
    }

    [Fact]
    public async Task CancellationStopsBeforePublishingOrVisitingRemainingSources()
    {
        using var cancellation = new CancellationTokenSource();
        var browser = new Browser { Cancel = cancellation };
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            InspectorCaptureRunner.CaptureAsync(browser, null, cancellation.Token));
        Assert.Equal(new[] { 1, 2 }, browser.Pages);
    }

    private sealed class Browser : IInspectorCaptureBrowser
    {
        public string? Failure { get; init; }
        public bool ArpAliases { get; init; }
        public CancellationTokenSource? Cancel { get; init; }
        public bool SignedIn { get; private set; }
        public List<int> Pages { get; } = [];
        public List<ClientSource> Sources { get; } = [];
        private int _page;

        public Task EnsureSignedInAsync(CancellationToken token)
        {
            SignedIn = true;
            return Task.CompletedTask;
        }

        public Task NavigateAsync(ClientSource source, CancellationToken token)
        {
            Sources.Add(source);
            return Task.CompletedTask;
        }

        public Task GoToPageAsync(ClientSource source, int page, CancellationToken token)
        {
            Pages.Add(page);
            _page = Failure == "stuck" ? 1 : page;
            if (page == 2) Cancel?.Cancel();
            token.ThrowIfCancellationRequested();
            return Task.CompletedTask;
        }

        public Task<RouterTablePage> ReadPageAsync(ClientSource source, CancellationToken token)
        {
            var count = source switch { ClientSource.Clients => 3, ClientSource.Wired => 4, _ => 2 };
            if (Failure == "changing-count" && _page > 1) count++;
            var address = (int)source * 10 + (Failure == "duplicate" ? 1 : _page);
            var mac = source == ClientSource.Arp && ArpAliases ? 250 : address;
            return Task.FromResult(new RouterTablePage(
                [new("Device", $"00:11:22:33:44:{mac:X2}", $"192.168.0.{address + 1}")],
                _page, count, source.ToString()));
        }
    }
}
