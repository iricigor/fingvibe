using System.ComponentModel;
using System.Runtime.Versioning;
using System.Text.Json;
using FingVibe.App;
using FingVibe.Core.Updates;
using Xunit;

namespace FingVibe.Core.Tests;

[SupportedOSPlatform("windows")]
public sealed class ReleaseUpdateCloseSchedulerTests
{
    [Fact]
    public void StoreRoundTripsPendingAndArmedSchedules()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"fingvibe-close-schedule-{Guid.NewGuid():N}");
        var path = Path.Combine(directory, "schedule.json");
        try
        {
            var store = new ReleaseUpdateScheduleStore(path);
            Assert.Null(store.Load());
            var pending = new ReleaseUpdateSchedule("1.2.130", DateTimeOffset.Parse("2026-11-22T10:00:00Z"));
            store.Save(pending);
            Assert.Equal(pending, store.Load());

            var file = Path.Combine(directory, "FingVibe-1.2.130-win-x64-Setup.exe");
            File.WriteAllText(file, "setup");
            var armed = pending with
            {
                InstallerPath = file,
                InstallerSha256 = new string('A', 64),
                InstallerSize = 5
            };
            store.Save(armed);
            Assert.Equal(armed, store.Load());
            store.Clear();
            Assert.Null(store.Load());
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, true);
        }
    }

    [Fact]
    public void StoreRejectsIncompleteInstallerMetadata()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"fingvibe-close-schedule-{Guid.NewGuid():N}");
        try
        {
            var store = new ReleaseUpdateScheduleStore(Path.Combine(directory, "schedule.json"));
            var pending = new ReleaseUpdateSchedule("1.2.130", DateTimeOffset.UtcNow);
            Assert.Throws<JsonException>(() => store.Save(pending with
            {
                InstallerPath = Path.Combine(directory, "Setup.exe")
            }));
        }
        finally
        {
            if (Directory.Exists(directory)) Directory.Delete(directory, true);
        }
    }

    [WindowsUpdateFact]
    public async Task SchedulePersistsAndIsRestoredAfterRestart()
    {
        using var fixture = new Fixture();
        await fixture.Session.CheckAsync();
        await fixture.Scheduler.ScheduleAsync(new Progress<double>());

        Assert.True(fixture.Scheduler.IsScheduled);
        Assert.True(fixture.Scheduler.IsReady);
        var saved = fixture.Store.Load();
        Assert.NotNull(saved);
        Assert.True(saved.IsArmed);
        Assert.Equal(1, fixture.Review.DownloadCount);

        fixture.Restart();
        await fixture.Session.CheckAsync();
        await fixture.Scheduler.WaitForIdleAsync();

        Assert.True(fixture.Scheduler.IsScheduled);
        Assert.True(fixture.Scheduler.IsReady);
        Assert.Equal(saved, fixture.Store.Load());
        Assert.Equal(1, fixture.Review.DownloadCount);
    }

    [WindowsUpdateFact]
    public async Task InvalidPersistedFileIsRedownloadedWithoutLosingSchedule()
    {
        using var fixture = new Fixture();
        await fixture.Session.CheckAsync();
        await fixture.Scheduler.ScheduleAsync(new Progress<double>());
        var saved = Assert.IsType<ReleaseUpdateSchedule>(fixture.Store.Load());
        await File.WriteAllTextAsync(saved.InstallerPath!, "tampered");

        fixture.Restart();
        await fixture.Session.CheckAsync();
        await fixture.Scheduler.WaitForIdleAsync();

        Assert.True(fixture.Scheduler.IsScheduled);
        Assert.True(fixture.Scheduler.IsReady);
        Assert.Equal(2, fixture.Review.DownloadCount);
        var refreshed = Assert.IsType<ReleaseUpdateSchedule>(fixture.Store.Load());
        Assert.True(refreshed.IsArmed);
        Assert.True(File.Exists(refreshed.InstallerPath));
        Assert.NotEqual("tampered", await File.ReadAllTextAsync(refreshed.InstallerPath!));
    }

    [WindowsUpdateFact]
    public async Task NewReleaseSupersedesPendingScheduleAndCancellingClearsIt()
    {
        using var fixture = new Fixture();
        await fixture.Session.CheckAsync();
        await fixture.Scheduler.ScheduleAsync(new Progress<double>());

        fixture.Write("newest", now: DateTimeOffset.Parse("2026-11-22T10:00:01Z"));
        await fixture.Session.CheckAsync();
        await fixture.Scheduler.WaitForIdleAsync();

        Assert.Equal("1.2.131", fixture.Scheduler.ScheduledVersion?.ToString(3));
        Assert.True(fixture.Scheduler.IsReady);
        Assert.Equal(2, fixture.Review.DownloadCount);

        await fixture.Scheduler.CancelAsync();
        Assert.False(fixture.Scheduler.IsScheduled);
        Assert.Null(fixture.Store.Load());
    }

    [WindowsUpdateFact]
    public async Task PendingScheduleSurvivesCloseWithoutAReadyFileAndFailedHandoffKeepsIt()
    {
        using var fixture = new Fixture(download: "fail");
        await fixture.Session.CheckAsync();
        await Assert.ThrowsAsync<HttpRequestException>(
            () => fixture.Scheduler.ScheduleAsync(new Progress<double>()));

        Assert.True(fixture.Scheduler.IsScheduled);
        Assert.False(fixture.Scheduler.IsReady);
        Assert.False(await fixture.Scheduler.TryInstallOnCloseAsync());
        Assert.True(fixture.Scheduler.IsScheduled);

        fixture.Write("newer", "installed", "success",
            now: DateTimeOffset.Parse("2026-11-22T10:00:01Z"));
        await fixture.Session.CheckAsync();
        await fixture.Scheduler.WaitForIdleAsync();
        Assert.True(fixture.Scheduler.IsReady);
        await Assert.ThrowsAsync<Win32Exception>(() => fixture.Scheduler.TryInstallOnCloseAsync());
        Assert.True(fixture.Scheduler.IsScheduled);
    }

    [WindowsUpdateFact]
    public async Task CancellingScheduleStopsItsPendingDownloadAndClearsPersistence()
    {
        using var fixture = new Fixture(download: "slow");
        await fixture.Session.CheckAsync();
        var scheduled = fixture.Scheduler.ScheduleAsync(new Progress<double>());
        while (fixture.Review.DownloadCount == 0)
            await Task.Delay(10);

        await fixture.Scheduler.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => scheduled);
        Assert.False(fixture.Scheduler.IsScheduled);
        Assert.Null(fixture.Store.Load());
    }

    [WindowsUpdateFact]
    public async Task PortableCopyCannotPersistADeferredInstall()
    {
        using var fixture = new Fixture(deployment: "portable");
        await fixture.Session.CheckAsync();

        await Assert.ThrowsAsync<InvalidOperationException>(
            () => fixture.Scheduler.ScheduleAsync(new Progress<double>()));
        Assert.False(fixture.Scheduler.IsScheduled);
        Assert.Equal(0, fixture.Review.DownloadCount);
    }

    internal sealed class WindowsUpdateFactAttribute : FactAttribute
    {
        public WindowsUpdateFactAttribute()
        {
            if (!OperatingSystem.IsWindows()) Skip = "Windows update handoff checks.";
        }
    }

    private sealed class Fixture : IDisposable
    {
        private readonly string _directory =
            Path.Combine(Path.GetTempPath(), $"fingvibe-close-update-{Guid.NewGuid():N}");
        private readonly string _responsePath;
        private readonly HttpClient _http;
        private bool _disposed;

        public UpdateReviewFixture Review { get; }
        public ReleaseUpdateSession Session { get; private set; }
        public ReleaseUpdateActions Actions { get; private set; }
        public ReleaseUpdateCloseScheduler Scheduler { get; private set; }
        public ReleaseUpdateScheduleStore Store { get; }

        public Fixture(string download = "success", string deployment = "installed")
        {
            Directory.CreateDirectory(_directory);
            _responsePath = Path.Combine(_directory, "response.json");
            Write("newer", deployment, download,
                DateTimeOffset.Parse("2026-11-22T10:00:00Z"));
            Review = new(_responsePath);
            _http = new(Review.CreateHandler());
            Store = new(Path.Combine(_directory, "update-schedule.json"));
            Session = new(true, "1.2.99", new GitHubReleaseSource(_http, Review).GetLatestAsync, Review);
            Actions = new(_http, Session, Review);
            Scheduler = new(Session, Actions, Store, Review);
        }

        public void Write(string outcome, string deployment = "installed", string download = "success",
            DateTimeOffset? now = null)
        {
            File.WriteAllText(_responsePath, JsonSerializer.Serialize(new
            {
                now = (now ?? DateTimeOffset.Parse("2026-11-22T10:00:00Z")).ToString("O"),
                outcome, deployment, download, metered = true
            }));
        }

        public void Restart()
        {
            StopScheduler();
            Actions.Dispose();
            Session.Dispose();
            Session = new(true, "1.2.99", new GitHubReleaseSource(_http, Review).GetLatestAsync, Review);
            Actions = new(_http, Session, Review);
            Scheduler = new(Session, Actions, Store, Review);
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            StopScheduler();
            Actions.Dispose();
            Session.Dispose();
            _http.Dispose();
            Directory.Delete(_directory, true);
        }

        // Disposal stops new reconciles; wait for one already in flight so it cannot write into a deleted or
        // restarted fixture directory.
        private void StopScheduler()
        {
            Scheduler.Dispose();
            Scheduler.WaitForIdleAsync().GetAwaiter().GetResult();
        }
    }
}
