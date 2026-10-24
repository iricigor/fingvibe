using FingVibe.App;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class IspLogoSessionTests
{
    private const string TestKey = "pk_test_not_a_real_key";

    [Theory]
    [InlineData(null, TestKey)]
    [InlineData("", TestKey)]
    [InlineData(" ", TestKey)]
    [InlineData("Example ISP", null)]
    [InlineData("Example ISP", "")]
    [InlineData("Example ISP", " ")]
    public void MissingIdentityOrKey_DoesNotStartRequest(string? name, string? key)
    {
        using var session = new IspLogoSession();
        Assert.Null(IspLogoSession.CreateUri(name, key));
        Assert.False(session.Update(name, key));
        Assert.Null(session.Current);
    }

    [Theory]
    [InlineData("T-Mobile Czech Republic a.s.", "T-Mobile%20Czech%20Republic%20a.s.")]
    [InlineData("AT&T / ISP?#", "AT%26T%20%2F%20ISP%3F%23")]
    public void CreateUri_PreservesAndEncodesExactName(string name, string encodedName)
    {
        var uri = IspLogoSession.CreateUri(name, TestKey);
        Assert.NotNull(uri);
        Assert.Equal($"https://img.logo.dev/name/{encodedName}"
            + $"?token={TestKey}&format=png&size=128&fallback=404", uri.AbsoluteUri);
    }

    [Theory]
    [InlineData("sk_test_not_a_real_key")]
    [InlineData("pk_")]
    public void CreateUri_RejectsNonPublishableKeysWithoutEchoingThem(string key)
    {
        var exception = Assert.Throws<ArgumentException>(() => IspLogoSession.CreateUri("ISP", key));
        Assert.DoesNotContain(key, exception.Message);
    }

    [Fact]
    public void RepeatedIdentity_ReusesRequestInsteadOfRetryingOrRefreshing()
    {
        using var session = new IspLogoSession();
        Assert.True(session.Update("Example ISP", TestKey));
        var request = Assert.IsType<IspLogoSession.Request>(session.Current);
        Assert.False(session.Update("Example ISP", TestKey));
        Assert.Same(request, session.Current);
        Assert.True(session.IsCurrent(request));
    }

    [Fact]
    public void ChangedIdentity_CancelsOldRequestAndRejectsStaleCompletion()
    {
        using var session = new IspLogoSession();
        session.Update("First ISP", TestKey);
        var first = Assert.IsType<IspLogoSession.Request>(session.Current);
        session.Update("Second ISP", TestKey);
        Assert.True(first.CancellationToken.IsCancellationRequested);
        Assert.False(session.IsCurrent(first));
        Assert.True(session.IsCurrent(Assert.IsType<IspLogoSession.Request>(session.Current)));
    }

    [Fact]
    public void RemovedIdentityOrKey_CancelsAndClearsRequest()
    {
        using var session = new IspLogoSession();
        session.Update("ISP", TestKey);
        var request = Assert.IsType<IspLogoSession.Request>(session.Current);
        Assert.True(session.Update(null, TestKey));
        Assert.True(request.CancellationToken.IsCancellationRequested);
        Assert.Null(session.Current);
        Assert.False(session.IsCurrent(request));
        session.Update("ISP", TestKey);
        Assert.True(session.Update("ISP", null));
        Assert.Null(session.Current);
    }

    [Fact]
    public void ClosedSession_CancelsAndCannotStartOrAcceptRequests()
    {
        var session = new IspLogoSession();
        session.Update("ISP", TestKey);
        var request = Assert.IsType<IspLogoSession.Request>(session.Current);
        session.Dispose();
        Assert.True(request.CancellationToken.IsCancellationRequested);
        Assert.False(session.IsCurrent(request));
        Assert.False(session.Update("Another ISP", TestKey));
        Assert.Null(session.Current);
        session.Dispose();
    }

    [Fact]
    public async Task PendingRequest_IsBoundedToFiveSecondsWithoutRetry()
    {
        using var session = new IspLogoSession();
        session.Update("Slow ISP", TestKey);
        var request = Assert.IsType<IspLogoSession.Request>(session.Current);
        Assert.False(request.CancellationToken.IsCancellationRequested);
        var cancelled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var registration = request.CancellationToken.Register(() => cancelled.SetResult());
        await cancelled.Task.WaitAsync(TimeSpan.FromSeconds(8));
        Assert.True(request.CancellationToken.IsCancellationRequested);
        Assert.False(session.Update("Slow ISP", TestKey));
        Assert.Same(request, session.Current);
    }
}
