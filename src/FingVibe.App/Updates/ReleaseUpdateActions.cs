using System.Diagnostics;
using System.Security;
using System.Security.Cryptography;
using System.Runtime.Versioning;
using FingVibe.Core.Updates;
using Microsoft.Win32;

namespace FingVibe.App;

[SupportedOSPlatform("windows")]
internal sealed class ReleaseUpdateActions(HttpClient http, ReleaseUpdateSession session, UpdateReviewFixture? fixture) : IDisposable
{
    private CancellationTokenSource? _downloadCancellation;
    private readonly CancellationTokenSource _lifetime = new();
    private (string Path, string Hash, ReleaseAsset Asset, Version Version)? _downloaded;
    private bool _disposed;

    public UpdateDeployment Deployment { get; } = fixture?.Deployment ?? DetectDeployment(session.InstalledVersion);
    public bool IsDownloading => _downloadCancellation is not null;
    public bool IsDisposed => _disposed;
    public string? DownloadedPath => _downloaded?.Path;
    public bool CanInstall => !_disposed && session.IsEligible && Deployment.IsInstalled && !IsDownloading
        && _downloaded is { } file && session.State.ConfirmedUpdate?.Version == file.Version;

    public ReleaseAsset? SelectedAsset => session.State.ConfirmedUpdate is { } release
        ? SelectAsset(release) : null;

    private ReleaseAsset? SelectAsset(StableRelease release) => Deployment.IsInstalled ? release.Setup : release.Portable;

    public async Task DownloadAsync(IProgress<double> progress)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (!session.IsEligible || IsDownloading) throw new InvalidOperationException("A download cannot start in the current update state.");
        var release = session.State.ConfirmedUpdate ?? throw new InvalidOperationException("No newer release has been confirmed.");
        var asset = SelectAsset(release) ?? throw new InvalidOperationException("The release does not provide the required asset. Use its release page.");
        using var cancellation = new CancellationTokenSource();
        _downloadCancellation = cancellation;
        _downloaded = null;
        try
        {
            var root = fixture?.DownloadRoot ?? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FingVibe", "Updates");
            var directory = Path.Combine(root, Guid.NewGuid().ToString("N"));
            var path = await ReleaseDownload.DownloadAsync(http, asset, directory, progress, cancellation.Token).ConfigureAwait(false);
            await using var stream = File.OpenRead(path);
            var hash = Convert.ToHexString(await SHA256.HashDataAsync(stream, cancellation.Token).ConfigureAwait(false));
            _downloaded = (path, hash, asset, release.Version);
        }
        finally
        {
            _downloadCancellation = null;
        }
    }

    public void CancelDownload()
    {
        var cancellation = _downloadCancellation;
        try { cancellation?.Cancel(); }
        catch (ObjectDisposedException)
        {
            Trace.TraceInformation("Update download finished before cancellation could be signalled.");
        }
    }

    public async Task LaunchInstallerAsync()
    {
        if (!CanInstall || _downloaded is not { } downloaded)
            throw new InvalidOperationException("A complete Setup for the currently confirmed update is required.");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        timeout.CancelAfter(TimeSpan.FromSeconds(30));
        var verified = false;
        try
        {
            await using var file = new FileStream(downloaded.Path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, true);
            var hash = Convert.ToHexString(await SHA256.HashDataAsync(file, timeout.Token).ConfigureAwait(false));
            if (file.Length != downloaded.Asset.Size || hash != downloaded.Hash
                || !(await File.ReadAllTextAsync(downloaded.Path + ":Zone.Identifier", timeout.Token).ConfigureAwait(false))
                    .Split('\n').Any(line => line.Trim() == "ZoneId=3"))
                throw new InvalidDataException("The downloaded Setup or its Internet security marking changed.");
            verified = true;
            timeout.Token.ThrowIfCancellationRequested();
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (fixture is not null) UpdateReviewFixture.RejectLaunch();
            using var process = Process.Start(new ProcessStartInfo(downloaded.Path) { UseShellExecute = true })
                ?? throw new IOException("Windows did not accept the installer launch.");
        }
        catch (Exception exception) when (!verified && exception is IOException or InvalidDataException or UnauthorizedAccessException or SecurityException)
        {
            _downloaded = null;
            throw new InvalidDataException("Setup verification failed. Do not run this file; obtain a fresh update manually.", exception);
        }
    }

    private static UpdateDeployment DetectDeployment(Version version)
    {
        try
        {
            using var registration = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Uninstall\{BA17F8F1-EF47-4D63-9D8F-E46B23F79225}_is1");
            using var marker = Registry.CurrentUser.OpenSubKey(@"Software\FingVibe\Installer");
            var directory = registration?.GetValue("InstallLocation") as string;
            var registeredVersion = registration?.GetValue("DisplayVersion") as string;
            var owned = File.Exists(Path.Combine(AppContext.BaseDirectory, "unins000.exe"))
                && File.Exists(Path.Combine(AppContext.BaseDirectory, "_fingvibe-files.txt"))
                && marker?.GetValue("VersionMS") is int ms && marker.GetValue("VersionLS") is int ls
                && unchecked((uint)ms) == ((uint)version.Major << 16 | (uint)version.Minor)
                && unchecked((uint)ls) == ((uint)version.Build << 16 | (uint)version.Revision);
            return UpdateDeployment.Assess(AppContext.BaseDirectory, directory, registeredVersion, version, owned);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or SecurityException or ArgumentException)
        {
            Trace.TraceWarning($"Update deployment verification failed: {exception}");
            return new(false, "Installation verification failed. Use the ZIP/manual replacement path; Setup is not offered.");
        }
    }

    public void Dispose()
    {
        _disposed = true;
        _lifetime.Cancel();
        CancelDownload();
    }
}
