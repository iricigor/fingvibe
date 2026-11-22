using System.Diagnostics;
using System.ComponentModel;
using System.Security;
using System.Security.Cryptography;
using System.Text;
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
    public string? InstallHandoffRecordPath { get; private set; }
    public string LatestInstallHandoffRecordPath { get; } = fixture is null
        ? ReleaseInstallHandoffStore.DefaultRecordPath
        : Path.Combine(fixture.DownloadRoot, "install-handoff.json");
    public bool CanInstall => !_disposed && session.IsEligible && Deployment.IsInstalled && !IsDownloading
        && _downloaded is { } file && session.State.ConfirmedUpdate?.Version == file.Version;
    public bool CanUpdateNow => !_disposed && session.IsEligible && Deployment.IsInstalled && !IsDownloading
        && SelectedAsset is not null && session.State.ConfirmedUpdate is not null;

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

    public async Task<ReleaseInstallHandoffRecord> UpdateNowAsync(IProgress<double> progress)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (!CanUpdateNow) throw new InvalidOperationException("Update now is unavailable for this installation.");
        if (!CanInstall) await DownloadAsync(progress).ConfigureAwait(false);
        return await StartInstallHandoffAsync(relaunch: true).ConfigureAwait(false);
    }

    public Task<ReleaseInstallHandoffRecord?> ReadLatestInstallHandoffAsync() =>
        ReleaseInstallHandoffStore.ReadAsync(LatestInstallHandoffRecordPath);

    public void CancelDownload()
    {
        var cancellation = _downloadCancellation;
        try { cancellation?.Cancel(); }
        catch (ObjectDisposedException)
        {
            Trace.TraceInformation("Update download finished before cancellation could be signalled.");
        }
    }

    public async Task<ReleaseInstallHandoffRecord> StartInstallHandoffAsync(bool relaunch)
    {
        if (!CanInstall || _downloaded is null)
            throw new InvalidOperationException("A complete Setup for the currently confirmed update is required.");
        using var admission = new Semaphore(1, 1, "FingVibe-Update-Handoff-Admission");
        if (!admission.WaitOne(TimeSpan.FromSeconds(10)))
            throw new InvalidOperationException("Another update handoff is still being prepared.");
        try
        {
            return await StartInstallHandoffCoreAsync(relaunch).ConfigureAwait(false);
        }
        finally
        {
            admission.Release();
        }
    }

    private async Task<ReleaseInstallHandoffRecord> StartInstallHandoffCoreAsync(bool relaunch)
    {
        if (!CanInstall || _downloaded is not { } downloaded)
            throw new InvalidOperationException("A complete Setup for the currently confirmed update is required.");
        var previous = await ReleaseInstallHandoffStore.ReadAsync(LatestInstallHandoffRecordPath).ConfigureAwait(false);
        if (previous?.State is ReleaseInstallHandoffState.Requested or ReleaseInstallHandoffState.Waiting
            or ReleaseInstallHandoffState.Installing)
        {
            var helperAlive = IsMatchingProcess(previous.HelperProcessId, previous.HelperProcessStartedUtc);
            var installerAlive = IsMatchingProcess(previous.InstallerProcessId, previous.InstallerProcessStartedUtc);
            if (helperAlive || installerAlive)
                throw new InvalidOperationException("Another update handoff or installer is still in progress.");
            var stale = previous with
            {
                State = ReleaseInstallHandoffState.Failed,
                Outcome = new ReleaseInstallOutcome(DateTimeOffset.UtcNow, null, false, null,
                    "The previous update helper is no longer running; the attempt can be reconciled and retried.")
            };
            await ReleaseInstallHandoffStore.WriteAsync(previous.RecordPath, stale).ConfigureAwait(false);
            await ReleaseInstallHandoffStore.WriteAsync(LatestInstallHandoffRecordPath, stale).ConfigureAwait(false);
        }
        var attemptId = Guid.NewGuid().ToString("N");
        InstallHandoffRecordPath = fixture is null
            ? ReleaseInstallHandoffStore.AttemptRecordPath(attemptId)
            : Path.Combine(fixture.DownloadRoot, "Handoffs", attemptId, "install-handoff.json");
        var handoffDirectory = Path.GetDirectoryName(InstallHandoffRecordPath)
            ?? throw new InvalidOperationException("The update handoff record needs a parent directory.");
        Directory.CreateDirectory(handoffDirectory);
        using var origin = Process.GetCurrentProcess();
        var installationDirectory = Path.GetFullPath(AppContext.BaseDirectory).TrimEnd(Path.DirectorySeparatorChar);
        var request = new ReleaseInstallHandoffRecord
        {
            AttemptId = attemptId,
            State = ReleaseInstallHandoffState.Requested,
            RequestedUtc = DateTimeOffset.UtcNow,
            OriginProcessId = origin.Id,
            OriginProcessStartedUtc = origin.StartTime.ToUniversalTime(),
            OriginExecutablePath = Environment.ProcessPath
                ?? Path.Combine(installationDirectory, "FingVibe.App.exe"),
            RecordPath = InstallHandoffRecordPath,
            InstallerPath = downloaded.Path,
            InstallerSize = downloaded.Asset.Size,
            InstallerSha256 = downloaded.Hash,
            ExpectedZoneId = 3,
            ExpectedVersion = downloaded.Version.ToString(),
            InstallationDirectory = installationDirectory,
            RelaunchRequested = relaunch,
            RelaunchExecutablePath = Path.Combine(installationDirectory, "FingVibe.App.exe"),
            InstallerLogPath = Path.Combine(handoffDirectory, "installer.log"),
            LatestRecordPath = LatestInstallHandoffRecordPath
        };
        await ReleaseInstallHandoffStore.WriteAsync(InstallHandoffRecordPath, request).ConfigureAwait(false);
        await ReleaseInstallHandoffStore.WriteAsync(LatestInstallHandoffRecordPath, request).ConfigureAwait(false);
        var activeRecord = request;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        timeout.CancelAfter(TimeSpan.FromSeconds(30));
        var verified = false;
        Process? helper = null;
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
            var scriptSource = Path.Combine(AppContext.BaseDirectory, "Assets", "InstallUpdateHandoff.ps1");
            if (!File.Exists(scriptSource)) throw new IOException("The packaged update handoff helper is unavailable.");
            var encodedScript = Convert.ToBase64String(Encoding.Unicode.GetBytes(
                File.ReadAllText(scriptSource)));
            var start = new ProcessStartInfo(Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                "System32", "WindowsPowerShell", "v1.0", "powershell.exe"))
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = handoffDirectory
            };
            start.ArgumentList.Add("-NoLogo");
            start.ArgumentList.Add("-NoProfile");
            start.ArgumentList.Add("-NonInteractive");
            start.ArgumentList.Add("-EncodedCommand");
            start.ArgumentList.Add(encodedScript);
            start.Environment["FINGVIBE_UPDATE_HANDOFF_RECORD"] = InstallHandoffRecordPath;
            helper = Process.Start(start)
                ?? throw new IOException("Windows did not accept the update handoff launch.");
            await WaitForHandoffReadyAsync(helper, InstallHandoffRecordPath).ConfigureAwait(false);
            return activeRecord;
        }
        catch (Exception exception) when (exception is IOException or InvalidDataException or UnauthorizedAccessException
            or SecurityException or Win32Exception or InvalidOperationException or OperationCanceledException)
        {
            var current = await ReleaseInstallHandoffStore.ReadAsync(InstallHandoffRecordPath).ConfigureAwait(false);
            var failed = (current?.AttemptId == activeRecord.AttemptId ? current : activeRecord) with
            {
                State = ReleaseInstallHandoffState.Failed,
                Outcome = new ReleaseInstallOutcome(DateTimeOffset.UtcNow, null, false, null,
                    exception.GetBaseException().Message)
            };
            await ReleaseInstallHandoffStore.WriteAsync(InstallHandoffRecordPath, failed).ConfigureAwait(false);
            var latest = await ReleaseInstallHandoffStore.ReadAsync(LatestInstallHandoffRecordPath).ConfigureAwait(false);
            if (latest?.AttemptId == failed.AttemptId)
                await ReleaseInstallHandoffStore.WriteAsync(LatestInstallHandoffRecordPath, failed).ConfigureAwait(false);
            if (!verified && exception is IOException or InvalidDataException or UnauthorizedAccessException or SecurityException)
            {
                _downloaded = null;
                throw new InvalidDataException("Setup verification failed. Do not run this file; obtain a fresh update manually.", exception);
            }

            throw;
        }
        finally
        {
            helper?.Dispose();
        }
    }

    private static async Task WaitForHandoffReadyAsync(Process helper, string recordPath)
    {
        var deadline = Stopwatch.StartNew();
        while (deadline.Elapsed < TimeSpan.FromSeconds(10))
        {
            var record = await ReleaseInstallHandoffStore.ReadAsync(recordPath).ConfigureAwait(false);
            helper.Refresh();
            if (helper.HasExited)
            {
                if (record?.State == ReleaseInstallHandoffState.Failed)
                    throw new IOException(record.Outcome?.Error ?? "The update handoff failed before it was ready.");
                throw new IOException("The update handoff exited before it acknowledged readiness.");
            }
            if (record?.State == ReleaseInstallHandoffState.Failed)
            {
                if (!helper.HasExited) helper.Kill(entireProcessTree: true);
                await helper.WaitForExitAsync().ConfigureAwait(false);
                throw new IOException(record.Outcome?.Error ?? "The update handoff failed before it was ready.");
            }
            if (record?.State is ReleaseInstallHandoffState.Waiting or ReleaseInstallHandoffState.Installing
                or ReleaseInstallHandoffState.Succeeded)
                return;
            await Task.Delay(100).ConfigureAwait(false);
        }
        if (!helper.HasExited) helper.Kill(entireProcessTree: true);
        await helper.WaitForExitAsync().ConfigureAwait(false);
        throw new IOException("The update handoff did not acknowledge readiness in time.");
    }

    private static bool IsMatchingProcess(int? processId, DateTimeOffset? startedUtc)
    {
        if (processId is not int id || startedUtc is not DateTimeOffset started) return false;
        try
        {
            using var process = Process.GetProcessById(id);
            return !process.HasExited &&
                Math.Abs(((DateTimeOffset)process.StartTime.ToUniversalTime() - started).TotalSeconds) <= 2;
        }
        catch (ArgumentException)
        {
            return false;
        }
        catch (InvalidOperationException)
        {
            return false;
        }
        catch (Win32Exception)
        {
            return false;
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
