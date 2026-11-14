using System.Globalization;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;

namespace FingVibe.Core.Storage;

public sealed record InventoryBackup(string Path, DateTimeOffset CreatedUtc, long Size);
public sealed record InventoryBackupResult(InventoryBackup? Backup = null, bool Deferred = false, bool Missing = false);

public sealed partial class InventoryBackupStore
{
    private readonly string _source;
    private readonly Action? _copyCompleted;
    public string DirectoryPath { get; }

    public InventoryBackupStore(string databasePath) : this(databasePath, null) { }

    internal InventoryBackupStore(string databasePath, Action? copyCompleted)
    {
        _source = Path.GetFullPath(databasePath);
        _copyCompleted = copyCompleted;
        DirectoryPath = Path.Combine(Path.GetDirectoryName(_source)!, "Backups");
    }

    public Task<IReadOnlyList<InventoryBackup>> ListAsync(CancellationToken cancellationToken = default) =>
        Task.Run<IReadOnlyList<InventoryBackup>>(() => List(cancellationToken), cancellationToken);

    public Task<InventoryBackupResult> CreateAsync(CancellationToken cancellationToken = default) =>
        Task.Run(() => Create(cancellationToken), cancellationToken);

    private InventoryBackupResult Create(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        try { File.GetAttributes(_source); }
        catch (FileNotFoundException) { return new(Missing: true); }
        catch (DirectoryNotFoundException) { return new(Missing: true); }
        Directory.CreateDirectory(DirectoryPath);
        FileStream backupLock;
        try
        {
            backupLock = new FileStream(Path.Combine(DirectoryPath, "device-inventory.backup.lock"),
                FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        }
        catch (IOException exception) when ((exception.HResult & 0xffff) is 32 or 33)
        {
            return new(Deferred: true);
        }

        using (backupLock)
        {
            var timestamp = DateTimeOffset.UtcNow.ToString("yyyyMMdd'T'HHmmssfffffff'Z'", CultureInfo.InvariantCulture);
            var name = $"device-inventory-{timestamp}-{Guid.NewGuid():N}.sqlite";
            var completed = Path.Combine(DirectoryPath, name);
            var temporary = completed + ".partial";
            try
            {
                using (var source = Open(_source, SqliteOpenMode.ReadOnly))
                using (var destination = Open(temporary, SqliteOpenMode.ReadWriteCreate))
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    source.BackupDatabase(destination);
                    _copyCompleted?.Invoke();
                    cancellationToken.ThrowIfCancellationRequested();
                    using var check = destination.CreateCommand();
                    check.CommandText = "PRAGMA integrity_check";
                    using (var reader = check.ExecuteReader())
                    {
                        if (!reader.Read() || reader.GetString(0) != "ok" || reader.Read())
                            throw new InvalidDataException("The backup failed SQLite integrity validation. Earlier copies were retained.");
                    }
                    check.CommandText = "SELECT revision FROM inventory WHERE id=1";
                    if (check.ExecuteScalar() is not string revision || !Guid.TryParse(revision, out _))
                        throw new InvalidDataException("The backup has no valid inventory revision. Earlier copies were retained.");
                }
                using (var stream = new FileStream(temporary, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
                    stream.Flush(flushToDisk: true);
                cancellationToken.ThrowIfCancellationRequested();
                File.Move(temporary, completed, overwrite: false);
                // Pruning only starts after a validated copy is published. A failure keeps that copy and reports the extra copies.
                var copies = List(cancellationToken);
                var retained = RetainedPaths(copies, TimeZoneInfo.Local);
                foreach (var old in copies.Where(copy => !retained.Contains(copy.Path)))
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    try { File.Delete(old.Path); }
                    catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
                    {
                        throw new IOException("Backup created, but older copies could not be removed. Extra copies remain. "
                            + "Check backup folder permissions and try the next backup.", exception);
                    }
                }
                return new(List(cancellationToken).First(item => item.Path == completed));
            }
            finally
            {
                if (File.Exists(temporary)) File.Delete(temporary);
                if (File.Exists(temporary + "-journal")) File.Delete(temporary + "-journal");
            }
        }
    }

    internal static IReadOnlySet<string> RetainedPaths(IReadOnlyList<InventoryBackup> newestFirst, TimeZoneInfo timeZone) =>
        newestFirst.Take(7).Concat(newestFirst
            .GroupBy(copy => DateOnly.FromDateTime(TimeZoneInfo.ConvertTime(copy.CreatedUtc, timeZone).DateTime))
            .Take(7).Select(day => day.First()))
            .Select(copy => copy.Path).ToHashSet(StringComparer.Ordinal);

    private List<InventoryBackup> List(CancellationToken cancellationToken)
    {
        var backups = new List<InventoryBackup>();
        FileInfo[] files;
        try { files = new DirectoryInfo(DirectoryPath).GetFiles("device-inventory-*.sqlite"); }
        catch (DirectoryNotFoundException) { return backups; }
        foreach (var file in files)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var match = BackupName().Match(file.Name);
            if (match.Success && DateTimeOffset.TryParseExact(match.Groups[1].Value,
                "yyyyMMdd'T'HHmmssfffffff'Z'", CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal, out var created))
                backups.Add(new(file.FullName, created, file.Length));
        }
        return backups.OrderByDescending(item => item.CreatedUtc).ThenByDescending(item => item.Path, StringComparer.Ordinal).ToList();
    }

    private static SqliteConnection Open(string path, SqliteOpenMode mode)
    {
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder
        {
            DataSource = path, Mode = mode, Pooling = false, DefaultTimeout = 5
        }.ToString());
        try { connection.Open(); return connection; }
        catch { connection.Dispose(); throw; }
    }

    [GeneratedRegex(@"^device-inventory-(\d{8}T\d{13}Z)-[0-9a-f]{32}\.sqlite$", RegexOptions.CultureInvariant)]
    private static partial Regex BackupName();
}
