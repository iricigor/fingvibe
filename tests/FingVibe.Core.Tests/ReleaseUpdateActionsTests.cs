using System.ComponentModel;
using System.Runtime.Versioning;
using System.Text.Json;
using FingVibe.App;
using FingVibe.Core.Updates;
using Xunit;

namespace FingVibe.Core.Tests;

[SupportedOSPlatform("windows")]
public sealed class ReleaseUpdateActionsTests
{
    [WindowsUpdateTheory]
    [InlineData("installed", true)]
    [InlineData("portable", false)]
    [InlineData("uncertain", false)]
    public async Task DeploymentControlsAssetAndCompleteDownloadNeverExecutesInstaller(string deployment, bool installed)
    {
        using var fixture = new Fixture(deployment);
        await fixture.Session.CheckAsync();
        Assert.Equal(installed, fixture.Actions.Deployment.IsInstalled);
        Assert.Equal(installed ? ".exe" : ".zip", Path.GetExtension(fixture.Actions.SelectedAsset!.Name));
        Assert.False(fixture.Actions.CanInstall);
        Assert.Equal(installed, fixture.Actions.CanUpdateNow);
        await fixture.Actions.DownloadAsync(new Progress<double>());
        Assert.True(File.Exists(fixture.Actions.DownloadedPath));
        Assert.Equal(installed, fixture.Actions.CanInstall);
        if (installed)
        {
            await Assert.ThrowsAsync<Win32Exception>(() =>
                fixture.Actions.StartInstallHandoffAsync(relaunch: true));
            Assert.True(fixture.Actions.CanInstall);
            var recordPath = Assert.IsType<string>(fixture.Actions.InstallHandoffRecordPath);
            Assert.NotEqual(recordPath, fixture.Actions.LatestInstallHandoffRecordPath);
            Assert.Contains("Handoffs", recordPath);
            var relaunch = await ReleaseInstallHandoffStore.ReadAsync(recordPath);
            Assert.NotNull(relaunch);
            Assert.Equal(ReleaseInstallHandoffState.Failed, relaunch.State);
            Assert.True(relaunch.RelaunchRequested);
            Assert.NotNull(relaunch.Outcome?.Error);

            var currentProcess = System.Diagnostics.Process.GetCurrentProcess();
            await ReleaseInstallHandoffStore.WriteAsync(
                fixture.Actions.LatestInstallHandoffRecordPath,
                relaunch with
                {
                    State = ReleaseInstallHandoffState.Waiting,
                    HelperProcessId = currentProcess.Id,
                    HelperProcessStartedUtc = currentProcess.StartTime.ToUniversalTime()
                });
            await Assert.ThrowsAsync<InvalidOperationException>(() =>
                fixture.Actions.StartInstallHandoffAsync(relaunch: false));
            await ReleaseInstallHandoffStore.WriteAsync(
                fixture.Actions.LatestInstallHandoffRecordPath,
                relaunch with { State = ReleaseInstallHandoffState.Waiting });

            await Assert.ThrowsAsync<Win32Exception>(() =>
                fixture.Actions.StartInstallHandoffAsync(relaunch: false));
            var nextRecordPath = Assert.IsType<string>(fixture.Actions.InstallHandoffRecordPath);
            Assert.NotEqual(recordPath, nextRecordPath);
            var noRelaunch = await ReleaseInstallHandoffStore.ReadAsync(nextRecordPath);
            Assert.NotNull(noRelaunch);
            Assert.False(noRelaunch.RelaunchRequested);
            Assert.Equal(ReleaseInstallHandoffState.Failed, noRelaunch.State);
        }
        fixture.Write("current", deployment);
        await fixture.Session.CheckAsync();
        Assert.False(fixture.Actions.CanInstall);
    }

    [WindowsUpdateFact]
    public async Task ChangedSetupAndRemovedSecurityMarkRefuseLaunch()
    {
        using var fixture = new Fixture("installed");
        await fixture.Session.CheckAsync();
        await fixture.Actions.DownloadAsync(new Progress<double>());
        var path = fixture.Actions.DownloadedPath!;
        await File.WriteAllTextAsync(path, "modified-content!");
        await Assert.ThrowsAsync<InvalidDataException>(() =>
            fixture.Actions.StartInstallHandoffAsync(relaunch: true));
        await fixture.Actions.DownloadAsync(new Progress<double>());
        path = fixture.Actions.DownloadedPath!;
        await File.WriteAllTextAsync(path + ":Zone.Identifier", "[ZoneTransfer]\r\nZoneId=0\r\n");
        await Assert.ThrowsAsync<InvalidDataException>(() =>
            fixture.Actions.StartInstallHandoffAsync(relaunch: true));
    }

    [WindowsUpdateFact]
    public async Task UpdateNowDownloadsVerifiesAndUsesOneHandoffForInstalledCopies()
    {
        using var fixture = new Fixture("installed");
        await fixture.Session.CheckAsync();
        Assert.True(fixture.Actions.CanUpdateNow);
        Assert.False(fixture.Actions.CanInstall);
        await Assert.ThrowsAsync<Win32Exception>(() =>
            fixture.Actions.UpdateNowAsync(new Progress<double>()));
        Assert.True(File.Exists(fixture.Actions.DownloadedPath));
        Assert.True(fixture.Actions.CanInstall);
        var recordPath = Assert.IsType<string>(fixture.Actions.InstallHandoffRecordPath);
        var record = await ReleaseInstallHandoffStore.ReadAsync(recordPath);
        Assert.NotNull(record);
        Assert.True(record.RelaunchRequested);
        Assert.Equal(ReleaseInstallHandoffState.Failed, record.State);
    }

    [WindowsUpdateFact]
    public async Task FailedAndInterruptedDownloadsNeverEnableInstallation()
    {
        using var fixture = new Fixture("installed");
        await fixture.Session.CheckAsync();
        fixture.Write("newer", "installed", "fail");
        await Assert.ThrowsAsync<HttpRequestException>(() => fixture.Actions.DownloadAsync(new Progress<double>()));
        Assert.False(fixture.Actions.CanInstall);
        fixture.Write("newer", "installed", "interrupted");
        await Assert.ThrowsAsync<InvalidDataException>(() => fixture.Actions.DownloadAsync(new Progress<double>()));
        Assert.Null(fixture.Actions.DownloadedPath);
        Assert.False(fixture.Actions.CanInstall);
        Assert.Empty(Directory.GetFiles(fixture.Review.DownloadRoot, "*", SearchOption.AllDirectories));
    }

    [WindowsUpdateFact]
    public async Task NonReleaseAndShutdownCannotDownloadOrInstall()
    {
        using var fixture = new Fixture("installed", eligible: false);
        await Assert.ThrowsAsync<InvalidOperationException>(() => fixture.Actions.DownloadAsync(new Progress<double>()));
        Assert.False(fixture.Actions.CanInstall);
        fixture.Actions.Dispose();
        await Assert.ThrowsAsync<ObjectDisposedException>(() => fixture.Actions.DownloadAsync(new Progress<double>()));
    }

    [WindowsUpdateFact]
    public async Task MeteredOrUnknownConnectionSkipsBackgroundStaging()
    {
        using var fixture = new Fixture("installed", metered: true);
        await fixture.Session.CheckAsync();
        await fixture.Actions.WaitForDownloadAsync();

        Assert.Equal(0, fixture.Review.DownloadCount);
        Assert.False(fixture.Actions.CanInstall);
        Assert.Contains("metered or its cost is unknown", fixture.Actions.BackgroundDownloadStatus);
        Assert.Empty(Directory.GetFiles(fixture.Review.DownloadRoot, "*", SearchOption.AllDirectories));
    }

    [WindowsUpdateFact]
    public async Task MissingPublishedDigestSkipsBackgroundTransfer()
    {
        using var fixture = new Fixture("installed", metered: false, publishDigest: false);
        await fixture.Session.CheckAsync();
        await fixture.Actions.WaitForDownloadAsync();

        Assert.Equal(0, fixture.Review.DownloadCount);
        Assert.False(fixture.Actions.CanInstall);
        Assert.Contains("does not publish a SHA-256 digest", fixture.Actions.BackgroundDownloadStatus);
    }

    [WindowsUpdateFact]
    public async Task UnmeteredUpdateStagesOnceAndUpdateNowReusesIt()
    {
        using var fixture = new Fixture("installed", metered: false);
        var stale = Path.Combine(fixture.Review.DownloadRoot, "v1.2.120");
        Directory.CreateDirectory(stale);
        await fixture.Session.CheckAsync();
        await fixture.Actions.WaitForDownloadAsync();

        var path = Assert.IsType<string>(fixture.Actions.DownloadedPath);
        Assert.False(Directory.Exists(stale));
        Assert.True(fixture.Actions.CanInstall);
        Assert.True(File.Exists(path));
        Assert.Contains(Path.Combine("v1.2.130"), path);
        Assert.Equal(1, fixture.Review.DownloadCount);
        Assert.Contains("verified update to 1.2.130 is ready", fixture.Actions.BackgroundDownloadStatus);

        fixture.Write("newer", "installed", "fail", metered: false);
        await Assert.ThrowsAsync<Win32Exception>(() =>
            fixture.Actions.UpdateNowAsync(new Progress<double>()));
        Assert.Equal(1, fixture.Review.DownloadCount);
    }

    [WindowsUpdateFact]
    public async Task StagedUpdateIsRevalidatedAfterRestartAndInvalidFileIsReplaced()
    {
        using var fixture = new Fixture("installed", metered: false);
        await fixture.Session.CheckAsync();
        await fixture.Actions.WaitForDownloadAsync();
        Assert.Equal(1, fixture.Review.DownloadCount);
        var path = Assert.IsType<string>(fixture.Actions.DownloadedPath);

        fixture.Write("newer", "installed", metered: true,
            now: DateTimeOffset.Parse("2026-11-16T12:00:01Z"));
        fixture.Restart();
        await fixture.Session.CheckAsync();
        await fixture.Actions.WaitForDownloadAsync();
        Assert.Equal(1, fixture.Review.DownloadCount);
        Assert.Equal(path, fixture.Actions.DownloadedPath);

        await File.WriteAllTextAsync(path, "tampered");
        fixture.Restart();
        await fixture.Session.CheckAsync();
        await fixture.Actions.WaitForDownloadAsync();
        Assert.False(fixture.Actions.CanInstall);
        Assert.Equal(1, fixture.Review.DownloadCount);
        Assert.Contains("metered or its cost is unknown", fixture.Actions.BackgroundDownloadStatus);

        fixture.Write("newer", "installed", metered: false,
            now: DateTimeOffset.Parse("2026-11-16T12:00:02Z"));
        await fixture.Session.CheckAsync();
        await fixture.Actions.WaitForDownloadAsync();
        Assert.Equal(2, fixture.Review.DownloadCount);
        Assert.True(fixture.Actions.CanInstall);
        Assert.Null(fixture.Actions.BackgroundDownloadError);
    }

    [WindowsUpdateFact]
    public async Task ConcurrentUpdateNowWaitsForTheSingleBackgroundDownload()
    {
        using var fixture = new Fixture("installed", metered: false, download: "slow");
        await fixture.Session.CheckAsync();
        Assert.True(fixture.Actions.IsBackgroundDownloading);
        Assert.True(fixture.Actions.CanUpdateNow);
        var foreground = fixture.Actions.DownloadAsync(new Progress<double>());
        await fixture.Actions.WaitForDownloadAsync();
        await foreground;

        Assert.Equal(1, fixture.Review.DownloadCount);
        Assert.True(fixture.Actions.CanInstall);
    }

    [WindowsUpdateFact]
    public async Task NewerConfirmationWaitsForOldDownloadThenStagesOnlyCurrentVersion()
    {
        using var fixture = new Fixture("installed", metered: false, download: "slow-short");
        await fixture.Session.CheckAsync();
        while (fixture.Review.DownloadCount == 0)
            await Task.Delay(10);

        fixture.Write("newest", "installed", "success", metered: false,
            now: DateTimeOffset.Parse("2026-11-16T12:00:01Z"));
        await fixture.Session.CheckAsync();
        await fixture.Actions.WaitForDownloadAsync();

        Assert.Equal(2, fixture.Review.DownloadCount);
        Assert.Contains(Path.Combine("v1.2.131"), fixture.Actions.DownloadedPath);
        Assert.False(Directory.Exists(Path.Combine(fixture.Review.DownloadRoot, "v1.2.130")));
    }

    [WindowsUpdateFact]
    public async Task BackgroundFailureIsDiagnosedAndRetriesAtTheNextCheck()
    {
        using var fixture = new Fixture("installed", metered: false, download: "fail");
        await fixture.Session.CheckAsync();
        await fixture.Actions.WaitForDownloadAsync();
        Assert.False(fixture.Actions.CanInstall);
        Assert.Contains("Controlled download failure", fixture.Actions.BackgroundDownloadError);

        fixture.Write("newer", "installed", metered: false,
            now: DateTimeOffset.Parse("2026-11-16T12:00:01Z"));
        await fixture.Session.CheckAsync();
        await fixture.Actions.WaitForDownloadAsync();
        Assert.True(fixture.Actions.CanInstall);
        Assert.Equal(2, fixture.Review.DownloadCount);
        Assert.Null(fixture.Actions.BackgroundDownloadError);
    }

    [WindowsUpdateFact]
    public void StartupRemovesOldVersionAndForegroundGuidFolders()
    {
        using var fixture = new Fixture("installed", metered: true);
        var old = Path.Combine(fixture.Review.DownloadRoot, "v1.2.98");
        var newer = Path.Combine(fixture.Review.DownloadRoot, "v1.2.130");
        var guid = Path.Combine(fixture.Review.DownloadRoot, Guid.NewGuid().ToString("N"));
        var unrelated = Path.Combine(fixture.Review.DownloadRoot, "vnotes");
        Directory.CreateDirectory(old);
        Directory.CreateDirectory(newer);
        Directory.CreateDirectory(guid);
        Directory.CreateDirectory(unrelated);

        fixture.Restart();

        Assert.False(Directory.Exists(old));
        Assert.False(Directory.Exists(guid));
        Assert.True(Directory.Exists(newer));
        Assert.True(Directory.Exists(unrelated));
    }

    internal sealed class WindowsUpdateFactAttribute : FactAttribute
    {
        public WindowsUpdateFactAttribute()
        {
            if (!OperatingSystem.IsWindows()) Skip = "Windows release handoff and Internet security marking checks.";
        }
    }

    internal sealed class WindowsUpdateTheoryAttribute : TheoryAttribute
    {
        public WindowsUpdateTheoryAttribute()
        {
            if (!OperatingSystem.IsWindows()) Skip = "Windows release handoff and Internet security marking checks.";
        }
    }

    private sealed class Fixture : IDisposable
    {
        private readonly string _directory = Path.Combine(Path.GetTempPath(), $"fingvibe-update-actions-{Guid.NewGuid():N}");
        private readonly string _path;
        private readonly HttpClient _http;
        private bool _metered;
        public UpdateReviewFixture Review { get; }
        public ReleaseUpdateSession Session { get; private set; }
        public ReleaseUpdateActions Actions { get; private set; }

        public Fixture(string deployment, bool eligible = true, bool metered = true, string download = "success",
            bool publishDigest = true)
        {
            Directory.CreateDirectory(_directory);
            _path = Path.Combine(_directory, "response.json");
            _metered = metered;
            Write("newer", deployment, download, metered, publishDigest: publishDigest);
            Review = new(_path);
            _http = new(Review.CreateHandler());
            Session = new(eligible, "1.2.99", new GitHubReleaseSource(_http, Review).GetLatestAsync, Review);
            Actions = new(_http, Session, Review, Review.IsMeteredOrUnknown);
        }

        public void Write(string outcome, string deployment, string download = "success", bool? metered = null,
            DateTimeOffset? now = null, bool? publishDigest = null)
        {
            _metered = metered ?? _metered;
            File.WriteAllText(_path, JsonSerializer.Serialize(new
            {
                now = now?.ToString("O") ?? "2026-11-16T12:00:00Z", outcome, deployment, download,
                metered = _metered, publishDigest
            }));
        }

        public void Restart()
        {
            Actions.Dispose();
            Session.Dispose();
            Session = new(true, "1.2.99", new GitHubReleaseSource(_http, Review).GetLatestAsync, Review);
            Actions = new(_http, Session, Review, Review.IsMeteredOrUnknown);
        }

        public void Dispose()
        {
            Actions.Dispose();
            Session.Dispose();
            _http.Dispose();
            Directory.Delete(_directory, true);
        }
    }
}
