using System.Text.Json;
using System.Text.Json.Serialization;

namespace FingVibe.Core.Updates;

public static class ReleaseInstallHandoffState
{
    public const string Requested = "requested";
    public const string Waiting = "waiting";
    public const string Installing = "installing";
    public const string Succeeded = "succeeded";
    public const string Failed = "failed";
}

public sealed record ReleaseInstallOutcome(
    DateTimeOffset CompletedUtc,
    int? InstallerExitCode,
    bool RelaunchStarted,
    int? RelaunchProcessId,
    string? Error);

public sealed record ReleaseInstallHandoffRecord
{
    public int Schema { get; init; } = 1;
    public required string AttemptId { get; init; }
    public required string State { get; init; }
    public required DateTimeOffset RequestedUtc { get; init; }
    public required int OriginProcessId { get; init; }
    public required DateTimeOffset OriginProcessStartedUtc { get; init; }
    public required string OriginExecutablePath { get; init; }
    public required string RecordPath { get; init; }
    public int? HelperProcessId { get; init; }
    public DateTimeOffset? HelperProcessStartedUtc { get; init; }
    public required string InstallerPath { get; init; }
    public required long InstallerSize { get; init; }
    public required string InstallerSha256 { get; init; }
    public required int ExpectedZoneId { get; init; }
    public required string ExpectedVersion { get; init; }
    public required string InstallationDirectory { get; init; }
    public required bool RelaunchRequested { get; init; }
    public required string RelaunchExecutablePath { get; init; }
    public required string InstallerLogPath { get; init; }
    public required string LatestRecordPath { get; init; }
    public int? InstallerProcessId { get; init; }
    public DateTimeOffset? InstallerProcessStartedUtc { get; init; }
    public ReleaseInstallOutcome? Outcome { get; init; }
}

public static class ReleaseInstallHandoffStore
{
    public static string DefaultRecordPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "FingVibe", "Updates", "install-handoff.json");

    public static string AttemptRecordPath(string attemptId) => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "FingVibe", "Updates", "Handoffs", attemptId, "install-handoff.json");

    private static readonly JsonSerializerOptions Options = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter() }
    };

    public static async Task WriteAsync(string path, ReleaseInstallHandoffRecord record,
        CancellationToken cancellationToken = default)
    {
        var fullPath = Path.GetFullPath(path);
        var directory = Path.GetDirectoryName(fullPath)
            ?? throw new ArgumentException("The handoff record needs a parent directory.", nameof(path));
        Directory.CreateDirectory(directory);
        var temporary = Path.Combine(directory, $".{Path.GetFileName(fullPath)}.{Guid.NewGuid():N}.tmp");
        var moved = false;
        try
        {
            await File.WriteAllTextAsync(temporary, JsonSerializer.Serialize(record, Options),
                cancellationToken).ConfigureAwait(false);
            File.Move(temporary, fullPath, true);
            moved = true;
        }
        finally
        {
            if (!moved && File.Exists(temporary)) File.Delete(temporary);
        }
    }

    public static async Task<ReleaseInstallHandoffRecord?> ReadAsync(string path,
        CancellationToken cancellationToken = default)
    {
        if (!File.Exists(path)) return null;
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete,
            65536, true);
        return await JsonSerializer.DeserializeAsync<ReleaseInstallHandoffRecord>(
            stream, Options, cancellationToken).ConfigureAwait(false);
    }
}
