using System.Text.Json;

namespace FingVibe.Core.Updates;

public sealed record ReleaseUpdateSchedule(
    string Version, DateTimeOffset ScheduledUtc, string? InstallerPath = null,
    string? InstallerSha256 = null, long? InstallerSize = null)
{
    public bool IsArmed => InstallerPath is not null && InstallerSha256 is not null &&
        InstallerSize is not null;
}

public sealed class ReleaseUpdateScheduleStore
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true
    };

    private readonly string _filePath;

    public ReleaseUpdateScheduleStore(string filePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(filePath);
        _filePath = filePath;
    }

    public ReleaseUpdateSchedule? Load()
    {
        string json;
        try
        {
            json = File.ReadAllText(_filePath);
        }
        catch (Exception exception) when (exception is FileNotFoundException or DirectoryNotFoundException)
        {
            return null;
        }

        var schedule = JsonSerializer.Deserialize<ReleaseUpdateSchedule>(json, JsonOptions)
            ?? throw new JsonException("The postponed update schedule is empty.");
        Validate(schedule);
        return schedule;
    }

    public void Save(ReleaseUpdateSchedule schedule)
    {
        ArgumentNullException.ThrowIfNull(schedule);
        Validate(schedule);
        var directory = Path.GetDirectoryName(_filePath)
            ?? throw new ArgumentException("The schedule path must include a directory.", nameof(schedule));
        Directory.CreateDirectory(directory);
        var temporaryPath = Path.Combine(directory, $".{Path.GetFileName(_filePath)}.{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllText(temporaryPath, JsonSerializer.Serialize(schedule, JsonOptions));
            File.Move(temporaryPath, _filePath, true);
        }
        finally
        {
            if (File.Exists(temporaryPath)) File.Delete(temporaryPath);
        }
    }

    public void Clear()
    {
        try
        {
            File.Delete(_filePath);
        }
        catch (DirectoryNotFoundException)
        {
        }
    }

    private static void Validate(ReleaseUpdateSchedule schedule)
    {
        if (!StableRelease.TryParseVersion(schedule.Version, out _))
            throw new JsonException("The postponed update version is invalid.");
        if (schedule.IsArmed != (schedule.InstallerPath is not null ||
                schedule.InstallerSha256 is not null || schedule.InstallerSize is not null))
            throw new JsonException("The postponed update installer fields are incomplete.");
        if (schedule.IsArmed)
        {
            if (schedule.InstallerPath is not { } path || !Path.IsPathFullyQualified(path))
                throw new JsonException("The postponed installer path is not absolute.");
            if (schedule.InstallerSize <= 0)
                throw new JsonException("The postponed installer size is invalid.");
            if (schedule.InstallerSha256 is not { Length: 64 })
                throw new JsonException("The postponed installer SHA-256 is invalid.");
        }
    }
}
