using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using FingVibe.App;
using FingVibe.Core.Updates;
using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class ReleaseUpdateTests
{
    private static readonly DateTimeOffset Start = new(2026, 11, 16, 12, 0, 0, TimeSpan.Zero);
    private static StableRelease Release(string version = "1.2.130") => StableRelease.Parse(Json(version));
    private static string Json(string version = "1.2.130", bool draft = false, bool prerelease = false) =>
        JsonSerializer.Serialize(new
        {
            tag_name = $"v{version}", draft, prerelease,
            html_url = $"https://github.com/iricigor/fingvibe/releases/tag/v{version}",
            assets = new[] { new
            {
                name = $"FingVibe-{version}-win-x64-Setup.exe", size = 17,
                browser_download_url = $"https://github.com/iricigor/fingvibe/releases/download/v{version}/FingVibe-{version}-win-x64-Setup.exe"
            } }
        });

    [Theory]
    [InlineData("1.2.130", UpdateOutcome.Available)]
    [InlineData("1.2.99.1", UpdateOutcome.Available)]
    [InlineData("1.2.99", UpdateOutcome.Current)]
    [InlineData("1.2.9", UpdateOutcome.Current)]
    public async Task NumericComparisonNeverOffersEqualOrOlder(string latest, UpdateOutcome outcome)
    {
        using var session = new ReleaseUpdateSession(true, "v1.2.99", _ => Task.FromResult(Release(latest)));
        await session.CheckAsync();
        Assert.Equal(outcome, session.State.Outcome);
        Assert.Equal(outcome == UpdateOutcome.Available, session.State.ConfirmedUpdate is not null);
        Assert.Equal($"v{latest}", session.State.Latest!.VersionText);
    }

    [Theory]
    [InlineData("1.2.130-beta")]
    [InlineData("invalid")]
    [InlineData("1.2")]
    [InlineData("99999999999.0.0")]
    public void InvalidVersionsAreNotComparable(string version) =>
        Assert.Throws<InvalidDataException>(() => Release(version));

    [Fact]
    public void DraftPrereleaseAndForeignAssetsAreRejected()
    {
        Assert.Throws<InvalidDataException>(() => StableRelease.Parse(Json(draft: true)));
        Assert.Throws<InvalidDataException>(() => StableRelease.Parse(Json(prerelease: true)));
        Assert.Throws<InvalidDataException>(() => StableRelease.Parse(Json().Replace("github.com", "example.com")));
        Assert.Throws<InvalidDataException>(() => StableRelease.Parse(Json().Replace("/download/v1.2.130/", "/download/v1.2.129/")));
        Assert.Throws<InvalidDataException>(() => StableRelease.Parse(Json().Replace("\"size\":17", "\"size\":0")));
        Assert.Throws<KeyNotFoundException>(() => StableRelease.Parse("{}"));
    }

    [Fact]
    public async Task MissingAssetsRemainAConfirmedReleaseWithoutAnExecutable()
    {
        var json = Json().Replace(JsonDocument.Parse(Json()).RootElement.GetProperty("assets").GetRawText(), "[]");
        using var session = new ReleaseUpdateSession(true, "1.2.99", _ => Task.FromResult(StableRelease.Parse(json)));
        await session.CheckAsync();
        Assert.Equal(UpdateOutcome.Available, session.State.Outcome);
        Assert.Null(session.State.ConfirmedUpdate!.Setup);
        Assert.Null(session.State.ConfirmedUpdate.Portable);
    }

    [Fact]
    public void CompactUpdatePresentationKeepsStatusRelativeTimeAndInstallOutcomeExplicit()
    {
        var current = new UpdateState(UpdateOutcome.Current, false, Release(), null,
            null, Start, Start.AddMinutes(10), null, null);
        Assert.Equal("FingVibe is up to date.", ReleaseUpdatePresentation.Status(current, new Version(1, 2, 130)));
        Assert.Equal("Last checked 2 hours ago",
            ReleaseUpdatePresentation.LastChecked(Start, Start.AddHours(2)));
        var record = NewHandoffRecord(ReleaseInstallHandoffState.Succeeded,
            new ReleaseInstallOutcome(Start, 0, true, 1234, null));
        Assert.Equal("Updated to 1.2.130.",
            ReleaseUpdatePresentation.InstallResult(record, new Version(1, 2, 130), "installed",
                "installed\\FingVibe.App.exe"));
        Assert.Null(ReleaseUpdatePresentation.InstallResult(record, new Version(1, 2, 130), "other-install",
            "other-install\\FingVibe.App.exe"));
        Assert.Contains("did not complete",
            ReleaseUpdatePresentation.InstallResult(record with
            {
                State = ReleaseInstallHandoffState.Failed,
                Outcome = record.Outcome! with { RelaunchStarted = false, Error = "Setup cancelled" }
            }, new Version(1, 2, 130)));
        Assert.Contains("did not finish reporting",
            ReleaseUpdatePresentation.InstallResult(record with
            {
                State = ReleaseInstallHandoffState.Installing,
                Outcome = null
            }, new Version(1, 2, 130), "installed", "installed\\FingVibe.App.exe"));
        Assert.Null(ReleaseUpdatePresentation.InstallResult(record with
        {
            State = ReleaseInstallHandoffState.Installing,
            Outcome = null
        }, new Version(1, 2, 130), "other-install", "other-install\\FingVibe.App.exe"));
    }

    [Fact]
    public async Task StartupManualCompletionAndDelayedTicksReplaceDeadlines()
    {
        var clock = new FakeTimeProvider(Start);
        var calls = 0;
        using var session = new ReleaseUpdateSession(true, "1.2.99", _ =>
        {
            calls++;
            clock.Advance(TimeSpan.FromSeconds(2));
            return Task.FromResult(Release());
        }, clock);
        clock.Advance(TimeSpan.FromSeconds(30));
        await session.RunDueAsync();
        Assert.Equal(0, calls);
        await session.CheckAsync();
        Assert.Equal(Start.AddSeconds(32).AddMinutes(10), session.State.NextCheckAt);
        clock.Advance(TimeSpan.FromSeconds(30));
        await session.RunDueAsync();
        Assert.Equal(1, calls);
        clock.Advance(TimeSpan.FromHours(2));
        await session.RunDueAsync();
        await session.RunDueAsync();
        Assert.Equal(2, calls);
        Assert.Equal(clock.GetUtcNow().AddMinutes(10), session.State.NextCheckAt);
    }

    [Fact]
    public async Task FailedManualBeforeStartupAlsoResetsSchedule()
    {
        var clock = new FakeTimeProvider(Start);
        using var session = new ReleaseUpdateSession(true, "1.2.99",
            _ => throw new HttpRequestException("offline"), clock);
        clock.Advance(TimeSpan.FromSeconds(10));
        await session.CheckAsync();
        Assert.Equal(UpdateOutcome.Failed, session.State.Outcome);
        Assert.Equal(Start.AddSeconds(10).AddMinutes(10), session.State.NextCheckAt);
        Assert.Null(session.State.ConfirmedUpdate);
    }

    [Fact]
    public async Task AutomaticChecksStartAtOneMinuteThenRecurTenMinutesAfterCompletion()
    {
        var clock = new FakeTimeProvider(Start);
        var calls = 0;
        using var session = new ReleaseUpdateSession(true, "1.2.99", _ =>
        {
            calls++;
            return Task.FromResult(Release());
        }, clock);
        clock.Advance(TimeSpan.FromSeconds(59));
        await session.RunDueAsync();
        Assert.Equal(0, calls);
        clock.Advance(TimeSpan.FromSeconds(1));
        await session.RunDueAsync();
        Assert.Equal(1, calls);
        clock.Advance(TimeSpan.FromMinutes(10));
        await session.RunDueAsync();
        clock.Advance(TimeSpan.FromMinutes(10));
        await session.RunDueAsync();
        Assert.Equal(3, calls);
        Assert.Equal(Start.AddMinutes(31), session.State.NextCheckAt);
    }

    [Theory]
    [InlineData("malformed")]
    [InlineData("draft")]
    [InlineData("timeout")]
    public async Task InvalidResponseAndTimeoutAreFailuresRatherThanCurrent(string mode)
    {
        Task<StableRelease> Check(CancellationToken _) => mode == "timeout"
            ? throw new TaskCanceledException()
            : Task.FromResult(StableRelease.Parse(mode == "draft" ? Json(draft: true) : "not json"));
        using var session = new ReleaseUpdateSession(true, "1.2.99", Check);
        await session.CheckAsync();
        Assert.Equal(UpdateOutcome.Failed, session.State.Outcome);
        Assert.False(session.State.IsChecking);
        Assert.NotEmpty(session.State.Error!);
        Assert.Null(session.State.ConfirmedUpdate);
        if (mode == "timeout") Assert.Contains("timed out", session.State.Error);
    }

    [Fact]
    public async Task FailureRetainsTimestampedConfirmationUntilSuccessfulCurrentCheck()
    {
        var clock = new FakeTimeProvider(Start);
        var result = 0;
        using var session = new ReleaseUpdateSession(true, "1.2.99", _ => result switch
        {
            0 => Task.FromResult(Release()),
            1 => throw new HttpRequestException("offline"),
            _ => Task.FromResult(Release("1.2.99"))
        }, clock);
        await session.CheckAsync();
        result = 1;
        clock.Advance(TimeSpan.FromMinutes(1));
        await session.CheckAsync();
        Assert.Equal(UpdateOutcome.Failed, session.State.Outcome);
        Assert.Equal(Start, session.State.ConfirmedAt);
        Assert.NotNull(session.State.ConfirmedUpdate);
        Assert.Contains("offline", session.State.Error);
        result = 2;
        await session.CheckAsync();
        Assert.Null(session.State.ConfirmedUpdate);
        Assert.Null(session.State.ConfirmedAt);
        Assert.Null(session.State.Error);
        Assert.Equal(UpdateOutcome.Current, session.State.Outcome);
    }

    [Fact]
    public async Task RateLimitPrecedesManualResetAndBlocksExtraRequests()
    {
        var clock = new FakeTimeProvider(Start);
        var calls = 0;
        using var session = new ReleaseUpdateSession(true, "1.2.99", _ =>
        {
            calls++;
            throw new ReleaseCheckException("limited", Start.AddMinutes(20));
        }, clock);
        await session.CheckAsync();
        clock.Advance(TimeSpan.FromMinutes(1));
        await session.CheckAsync();
        Assert.Equal(1, calls);
        Assert.Equal(Start.AddMinutes(20), session.State.NextCheckAt);
        Assert.Equal(UpdateOutcome.Failed, session.State.Outcome);
    }

    [Fact]
    public async Task ManualAndAutomaticChecksAreSingleFlightAndShutdownCancels()
    {
        var clock = new FakeTimeProvider(Start);
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var cancelled = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var calls = 0;
        using var session = new ReleaseUpdateSession(true, "1.2.99", async token =>
        {
            calls++;
            entered.SetResult();
            try { await Task.Delay(Timeout.InfiniteTimeSpan, token); }
            finally { cancelled.SetResult(); }
            return Release();
        }, clock);
        clock.Advance(TimeSpan.FromMinutes(1));
        var automatic = session.RunDueAsync();
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        var manual = session.CheckAsync();
        Assert.Same(automatic, manual);
        await session.RunDueAsync();
        Assert.True(session.State.IsChecking);
        session.Dispose();
        await cancelled.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await automatic;
        clock.Advance(TimeSpan.FromHours(1));
        await session.RunDueAsync();
        Assert.Equal(1, calls);
        await Assert.ThrowsAsync<ObjectDisposedException>(() => session.CheckAsync());
    }

    [Fact]
    public async Task NonReleaseAndInvalidInstalledVersionNeverContactGitHub()
    {
        var calls = 0;
        Task<StableRelease> Check(CancellationToken _) { calls++; return Task.FromResult(Release()); }
        using var development = new ReleaseUpdateSession(false, "1.2.99", Check);
        using var invalid = new ReleaseUpdateSession(true, "unknown", Check);
        await development.RunDueAsync();
        await invalid.RunDueAsync();
        await Assert.ThrowsAsync<InvalidOperationException>(() => development.CheckAsync());
        await Assert.ThrowsAsync<InvalidOperationException>(() => invalid.CheckAsync());
        Assert.Equal(UpdateOutcome.Disabled, development.State.Outcome);
        Assert.Equal(UpdateOutcome.Failed, invalid.State.Outcome);
        Assert.Equal(0, calls);
    }

    [Fact]
    public async Task ApiUsesStableEndpointAndHonorsBothRateLimitHeaders()
    {
        var clock = new FakeTimeProvider(Start);
        using var http = new HttpClient(new Handler(request =>
        {
            Assert.Equal("https://api.github.com/repos/iricigor/fingvibe/releases/latest", request.RequestUri!.AbsoluteUri);
            Assert.Contains("FingVibe", request.Headers.UserAgent.ToString());
            var response = new HttpResponseMessage(HttpStatusCode.TooManyRequests);
            response.Headers.RetryAfter = new(TimeSpan.FromMinutes(6));
            response.Headers.Add("X-RateLimit-Reset", Start.AddMinutes(10).ToUnixTimeSeconds().ToString());
            return response;
        }));
        var error = await Assert.ThrowsAsync<ReleaseCheckException>(() => new GitHubReleaseSource(http, clock).GetLatestAsync(default));
        Assert.Equal(Start.AddMinutes(10), error.RetryAfter);
    }

    [Theory]
    [InlineData(HttpStatusCode.NotFound)]
    [InlineData(HttpStatusCode.ServiceUnavailable)]
    public async Task NoReleaseAndServerFailureAreExplicit(HttpStatusCode code)
    {
        using var http = new HttpClient(new Handler(_ => new(code)));
        using var session = new ReleaseUpdateSession(true, "1.2.99", new GitHubReleaseSource(http, TimeProvider.System).GetLatestAsync);
        await session.CheckAsync();
        Assert.Equal(UpdateOutcome.Failed, session.State.Outcome);
        Assert.Contains(((int)code).ToString(), session.State.Error);
    }

    [Fact]
    public void InstalledDeploymentRequiresMatchingLocationVersionAndOwnership()
    {
        var directory = Path.GetFullPath("installed");
        var version = new Version(1, 2, 99, 0);
        Assert.True(UpdateDeployment.Assess(directory, directory, "1.2.99", version, true).IsInstalled);
        Assert.False(UpdateDeployment.Assess(directory, directory, "1.2.98", version, true).IsInstalled);
        Assert.False(UpdateDeployment.Assess(directory, directory, "1.2.99", version, false).IsInstalled);
        Assert.False(UpdateDeployment.Assess(directory, Path.GetFullPath("portable"), "1.2.99", version, true).IsInstalled);
        Assert.Contains("Portable", UpdateDeployment.Assess(directory, null, null, version, false).Description);
    }

    [Theory]
    [InlineData("complete")]
    [InlineData("short")]
    [InlineData("digest")]
    [InlineData("existing")]
    [InlineData("cancelled")]
    [InlineData("interrupted")]
    [InlineData("cancelled-midstream")]
    public async Task DownloadValidatesCompletenessDigestCancellationAndPreservesExistingFiles(string mode)
    {
        var directory = Path.Combine(Path.GetTempPath(), $"fingvibe-update-test-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var payload = Encoding.ASCII.GetBytes("controlled-update");
        var asset = Release().Setup! with
        {
            Sha256 = mode == "digest" ? new string('0', 64) : Convert.ToHexString(SHA256.HashData(payload))
        };
        var path = Path.Combine(directory, asset.Name);
        if (mode == "existing") await File.WriteAllTextAsync(path, "preserve");
        using var cancellation = new CancellationTokenSource();
        using var http = new HttpClient(new Handler(_ =>
        {
            HttpContent content = mode is "interrupted" or "cancelled-midstream"
                ? new StreamContent(new InterruptedStream(payload, mode == "cancelled-midstream" ? cancellation : null))
                : new ByteArrayContent(mode == "short" ? payload[..3] : payload);
            return new(HttpStatusCode.OK) { Content = content };
        }));
        if (mode == "cancelled") cancellation.Cancel();
        try
        {
            if (mode == "complete")
            {
                Assert.Equal(path, await ReleaseDownload.DownloadAsync(http, asset, directory, null, default));
                Assert.Equal(payload, await File.ReadAllBytesAsync(path));
                if (OperatingSystem.IsWindows()) Assert.Contains("ZoneId=3", await File.ReadAllTextAsync(path + ":Zone.Identifier"));
            }
            else
            {
                Task Download() => ReleaseDownload.DownloadAsync(http, asset, directory, null, cancellation.Token);
                if (mode.StartsWith("cancelled", StringComparison.Ordinal)) await Assert.ThrowsAnyAsync<OperationCanceledException>(Download);
                else if (mode is "existing" or "interrupted") await Assert.ThrowsAnyAsync<IOException>(Download);
                else await Assert.ThrowsAsync<InvalidDataException>(Download);
                if (mode == "existing") Assert.Equal("preserve", await File.ReadAllTextAsync(path));
                else Assert.False(File.Exists(path));
            }

        }
        finally { Directory.Delete(directory, true); }
    }

    private sealed class InterruptedStream(byte[] payload, CancellationTokenSource? cancellation) : MemoryStream(payload)
    {
        private bool _read;
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            if (_read)
            {
                if (cancellation is null) throw new IOException("Controlled midstream interruption.");
                cancellation.Cancel();
                cancellationToken.ThrowIfCancellationRequested();
            }
            _read = true;
            return base.ReadAsync(buffer[..Math.Min(8, buffer.Length)], cancellationToken);
        }
    }

    private static ReleaseInstallHandoffRecord NewHandoffRecord(
        string state, ReleaseInstallOutcome outcome) => new()
    {
        AttemptId = "attempt",
        State = state,
        RequestedUtc = Start,
        OriginProcessId = 100,
        OriginProcessStartedUtc = Start,
        OriginExecutablePath = "FingVibe.App.exe",
        RecordPath = "install-handoff.json",
        InstallerPath = "Setup.exe",
        InstallerSize = 17,
        InstallerSha256 = new string('A', 64),
        ExpectedZoneId = 3,
        ExpectedVersion = "1.2.130",
        InstallationDirectory = "installed",
        RelaunchRequested = true,
        RelaunchExecutablePath = "installed\\FingVibe.App.exe",
        InstallerLogPath = "installer.log",
        LatestRecordPath = "install-handoff.json",
        Outcome = outcome
    };

    private sealed class Handler(Func<HttpRequestMessage, HttpResponseMessage> response) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.FromResult(response(request));
        }
    }
}
