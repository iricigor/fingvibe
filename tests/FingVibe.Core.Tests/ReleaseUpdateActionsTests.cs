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
        await fixture.Actions.DownloadAsync(new Progress<double>());
        Assert.True(File.Exists(fixture.Actions.DownloadedPath));
        Assert.Equal(installed, fixture.Actions.CanInstall);
        if (installed)
        {
            await Assert.ThrowsAsync<Win32Exception>(() => fixture.Actions.LaunchInstallerAsync());
            Assert.True(fixture.Actions.CanInstall);
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
        await Assert.ThrowsAsync<InvalidDataException>(() => fixture.Actions.LaunchInstallerAsync());
        await fixture.Actions.DownloadAsync(new Progress<double>());
        path = fixture.Actions.DownloadedPath!;
        await File.WriteAllTextAsync(path + ":Zone.Identifier", "[ZoneTransfer]\r\nZoneId=0\r\n");
        await Assert.ThrowsAsync<InvalidDataException>(() => fixture.Actions.LaunchInstallerAsync());
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
        public UpdateReviewFixture Review { get; }
        public ReleaseUpdateSession Session { get; }
        public ReleaseUpdateActions Actions { get; }

        public Fixture(string deployment, bool eligible = true)
        {
            Directory.CreateDirectory(_directory);
            _path = Path.Combine(_directory, "response.json");
            Write("newer", deployment);
            Review = new(_path);
            _http = new(Review.CreateHandler());
            Session = new(eligible, "1.2.99", new GitHubReleaseSource(_http, Review).GetLatestAsync, Review);
            Actions = new(_http, Session, Review);
        }

        public void Write(string outcome, string deployment, string download = "success") =>
            File.WriteAllText(_path, JsonSerializer.Serialize(new
            {
                now = "2026-11-16T12:00:00Z", outcome, deployment, download
            }));

        public void Dispose()
        {
            Actions.Dispose();
            Session.Dispose();
            _http.Dispose();
            Directory.Delete(_directory, true);
        }
    }
}
