using FingVibe.App;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class AsyncSurfaceSessionTests
{
    [Fact]
    public void NewSession_IsIdleWithoutRequest()
    {
        using var session = new AsyncSurfaceSession();
        Assert.Equal(AsyncSurfaceState.Idle, session.State);
        Assert.Equal("Idle", session.Status);
        Assert.Null(session.Current);
    }

    [Fact]
    public void Start_ReportsLoadingWithSelectionAndIncreasingRequestNumber()
    {
        using var session = new AsyncSurfaceSession();
        var first = Assert.IsType<AsyncSurfaceSession.Request>(session.Start("Last 7 days, 1-hour cells"));
        Assert.Equal("Loading (request 1): Last 7 days, 1-hour cells", session.Status);
        var second = Assert.IsType<AsyncSurfaceSession.Request>(session.Start("Last 30 days, 1-hour cells"));
        Assert.Equal(2, second.Number);
        Assert.True(second.Number > first.Number);
        Assert.Equal("Loading (request 2): Last 30 days, 1-hour cells", session.Status);
    }

    [Fact]
    public void Ready_IsReportedOnlyAfterRendering()
    {
        using var session = new AsyncSurfaceSession();
        var request = session.Start("selection")!;
        var stateDuringRender = AsyncSurfaceState.Idle;
        Assert.True(session.Complete(request, AsyncSurfaceState.Ready, () => stateDuringRender = session.State));
        Assert.Equal(AsyncSurfaceState.Loading, stateDuringRender);
        Assert.Equal("Ready (request 1): selection", session.Status);
        Assert.Null(session.Current);
    }

    [Fact]
    public void Replacement_CancelsOldRequestAndRejectsItsStaleCompletion()
    {
        using var session = new AsyncSurfaceSession();
        var old = session.Start("old")!;
        var current = session.Start("new")!;
        Assert.True(old.CancellationToken.IsCancellationRequested);
        Assert.False(session.IsCurrent(old));
        var rendered = false;
        Assert.False(session.Complete(old, AsyncSurfaceState.Ready, () => rendered = true));
        Assert.False(rendered);
        Assert.Equal("Loading (request 2): new", session.Status);
        Assert.True(session.Complete(current, AsyncSurfaceState.Ready, () => { }));
        Assert.Equal("Ready (request 2): new", session.Status);
    }

    [Fact]
    public void Cancel_MakesSurfaceIdleAndRejectsLateCompletion()
    {
        using var session = new AsyncSurfaceSession();
        var request = session.Start("selection")!;
        session.Cancel();
        Assert.True(request.CancellationToken.IsCancellationRequested);
        Assert.Equal("Idle", session.Status);
        Assert.False(session.Complete(request, AsyncSurfaceState.Error, () => throw new InvalidOperationException("stale render")));
        Assert.Equal(AsyncSurfaceState.Idle, session.State);
    }

    [Fact]
    public void ReplacementDuringRender_SuppressesTheReplacedOutcome()
    {
        using var session = new AsyncSurfaceSession();
        var request = session.Start("old")!;
        AsyncSurfaceSession.Request? replacement = null;
        Assert.False(session.Complete(request, AsyncSurfaceState.Ready, () => replacement = session.Start("new")));
        Assert.Equal("Loading (request 2): new", session.Status);
        Assert.True(session.IsCurrent(replacement!));
    }

    [Fact]
    public void ErrorThenRetry_StartsNewRequestForSameSelection()
    {
        using var session = new AsyncSurfaceSession();
        var failed = session.Start("selection")!;
        Assert.True(session.Complete(failed, AsyncSurfaceState.Error, () => { }));
        Assert.Equal("Error (request 1): selection", session.Status);
        Assert.False(session.Complete(failed, AsyncSurfaceState.Ready, () => { }));
        var retry = session.Start("selection")!;
        Assert.Equal("Loading (request 2): selection", session.Status);
        Assert.True(session.Complete(retry, AsyncSurfaceState.Ready, () => { }));
        Assert.Equal("Ready (request 2): selection", session.Status);
    }

    [Theory]
    [InlineData((int)AsyncSurfaceState.Idle)]
    [InlineData((int)AsyncSurfaceState.Loading)]
    public void Complete_RejectsNonTerminalStates(int state)
    {
        using var session = new AsyncSurfaceSession();
        var request = session.Start("selection")!;
        Assert.Throws<ArgumentOutOfRangeException>(() => session.Complete(request, (AsyncSurfaceState)state, () => { }));
        Assert.True(session.IsCurrent(request));
    }

    [Fact]
    public void StateChanged_IsRaisedForEveryTransition()
    {
        using var session = new AsyncSurfaceSession();
        var statuses = new List<string>();
        session.StateChanged += (_, _) => statuses.Add(session.Status);
        var request = session.Start("a")!;
        session.Complete(request, AsyncSurfaceState.Empty, () => { });
        session.Cancel();
        Assert.Equal(["Loading (request 1): a", "Empty (request 1): a", "Idle"], statuses);
    }

    [Fact]
    public void Dispose_CancelsAndCannotStartRequests()
    {
        var session = new AsyncSurfaceSession();
        var request = session.Start("selection")!;
        session.Dispose();
        Assert.True(request.CancellationToken.IsCancellationRequested);
        Assert.Null(session.Start("selection"));
        Assert.False(session.IsCurrent(request));
        session.Dispose();
    }

    [Fact]
    public async Task ControllableLoader_ObservesCancellationOfReplacedRequest()
    {
        using var session = new AsyncSurfaceSession();
        var release = new TaskCompletionSource();
        var old = session.Start("old")!;
        var load = Task.Run(async () => await release.Task.WaitAsync(old.CancellationToken));
        session.Start("new");
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => load);
        Assert.False(session.Complete(old, AsyncSurfaceState.Ready, () => { }));
    }
}
