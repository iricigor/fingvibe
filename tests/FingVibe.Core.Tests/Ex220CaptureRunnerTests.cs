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
        public CancellationTokenSource? Cancel { get; init; }
        public bool SignedIn { get; private set; }
        public List<int> Pages { get; } = [];
        private int _page;

        public Task EnsureSignedInAsync(CancellationToken token)
        {
            SignedIn = true;
            return Task.CompletedTask;
        }

        public Task NavigateAsync(ClientSource source, CancellationToken token) => Task.CompletedTask;

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
            return Task.FromResult(new RouterTablePage(
                [new("Device", $"00:11:22:33:44:{address:X2}", $"192.168.0.{address + 1}")],
                _page, count, source.ToString()));
        }
    }
}
