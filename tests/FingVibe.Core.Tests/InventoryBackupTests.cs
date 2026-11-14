using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.NetworkInformation;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Microsoft.Data.Sqlite;
using Xunit;
using Xunit.Abstractions;

namespace FingVibe.Core.Tests;

public sealed class InventoryBackupTests(ITestOutputHelper output) : IDisposable
{
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"fingvibe-backup-{Guid.NewGuid():N}");
    private string Database => Path.Combine(_directory, "device-inventory.sqlite");
    private InventoryBackupStore Backups => new(Database);

    [Fact]
    public async Task MissingSourceNeverCreatesAnEmptyDatabase()
    {
        Assert.True((await Backups.CreateAsync()).Missing);
        Assert.False(File.Exists(Database));
        Assert.Empty(await Backups.ListAsync());
    }

    private async Task<DeviceInventoryData> SeedAsync()
    {
        var person = new ManagedPerson(Guid.NewGuid(), "Backup person", "B");
        var room = new ManagedRoom(Guid.NewGuid(), "Backup room", "R");
        var snapshot = new ScanSnapshot("192.0.2.0/24", DateTimeOffset.UtcNow,
            [new(IPAddress.Parse("192.0.2.1"), HostStatus.Alive, 1, TimeSpan.Zero,
                null, PhysicalAddress.Parse("001122334455"), "Test")])
        { ScanId = Guid.NewGuid(), NetworkId = "backup-network" };
        var data = DeviceInventoryData.Empty.ObserveCompletedScan("backup-network", snapshot) with
        {
            LatestScan = snapshot,
            Names = new Dictionary<string, string> { ["001122334455"] = "Saved name" },
            PeopleRooms = new PeopleRoomsData([person], [room]).AssignPerson("001122334455", person.Id)
                .AssignRoom("001122334455", room.Id),
            Classifications = new Dictionary<string, DeviceClassificationOverride>
                { ["001122334455"] = new(Type: DeviceType.Computer) }
        };
        return await new DeviceInventoryStore(Database).SaveAsync(data, Guid.Empty);
    }

    [Fact]
    public async Task CopyReopensIndependentlyWithCommittedHistoryAssignmentsAndCheckpoint()
    {
        var saved = await SeedAsync();
        var result = await Backups.CreateAsync();
        var copy = await new DeviceInventoryStore(result.Backup!.Path).LoadAsync();
        Assert.Equal(saved.Revision, copy!.Revision);
        Assert.Equal("Saved name", copy.Names["001122334455"]);
        Assert.Equal(saved.PeopleRooms.Assignments["001122334455"], copy.PeopleRooms.Assignments["001122334455"]);
        Assert.Equal(DeviceType.Computer, copy.Classifications["001122334455"].Type);
        Assert.Single(copy.Devices["001122334455"].ScanHistory);
        Assert.Equal(saved.LatestScan!.ScanId, copy.LatestScan!.ScanId);
        Assert.Equal(ScanCheckpointState.Complete, copy.LatestScan.State);
        Assert.Single(await Backups.ListAsync());
    }

    [Fact]
    public async Task EighthSuccessfulCopyPrunesOnlyOldestSuccessfulFile()
    {
        await SeedAsync();
        var first = (await Backups.CreateAsync()).Backup!;
        await File.WriteAllTextAsync(Path.Combine(Backups.DirectoryPath, "unrelated.sqlite"), "preserve");
        await File.WriteAllTextAsync(Path.Combine(Backups.DirectoryPath, "interrupted.sqlite.partial"), "partial");
        for (var i = 0; i < 7; i++) await Backups.CreateAsync();
        var copies = await Backups.ListAsync();
        Assert.Equal(7, copies.Count);
        Assert.True(copies[0].IsDaily);
        Assert.Single(copies, copy => copy.IsDaily);
        Assert.False(File.Exists(first.Path));
        Assert.True(File.Exists(Path.Combine(Backups.DirectoryPath, "unrelated.sqlite")));
        Assert.True(copies.Zip(copies.Skip(1)).All(pair => pair.First.CreatedUtc >= pair.Second.CreatedUtc));
    }

    [Fact]
    public async Task DailyCopiesSurviveInactivityAndRotateOnlyAfterSevenNewerBackupDays()
    {
        await SeedAsync();
        var daily = new List<string>();
        var today = DateTimeOffset.UtcNow.Date;
        for (var day = 0; day < 7; day++)
        {
            var copy = (await Backups.CreateAsync()).Backup!;
            var created = new DateTimeOffset(today.AddDays(-70 + day * 7), TimeSpan.Zero);
            var timestamp = created.ToString("yyyyMMdd'T'HHmmssfffffff'Z'", CultureInfo.InvariantCulture);
            var path = Path.Combine(Backups.DirectoryPath, $"device-inventory-{timestamp}-{Guid.NewGuid():N}.sqlite");
            File.Move(copy.Path, path);
            daily.Add(path);
        }
        for (var copy = 0; copy < 7; copy++) await Backups.CreateAsync();
        var retained = await Backups.ListAsync();
        Assert.Equal(13, retained.Count);
        Assert.Equal(7, retained.Count(copy => copy.IsDaily));
        Assert.All(retained.Where(copy => copy.Path != retained[0].Path && copy.CreatedUtc.Date == retained[0].CreatedUtc.Date),
            copy => Assert.False(copy.IsDaily));
        Assert.False(File.Exists(daily[0]));
        Assert.All(daily.Skip(1), path => Assert.True(File.Exists(path)));
        for (var copy = 0; copy < 7; copy++) await Backups.CreateAsync();
        Assert.Equal(13, (await Backups.ListAsync()).Count);
        Assert.All(daily.Skip(1), path => Assert.True(File.Exists(path)));
        var beforeFailure = (await Backups.ListAsync()).Select(copy => copy.Path).ToArray();
        await File.WriteAllTextAsync(Database, "invalid SQLite");
        await Assert.ThrowsAsync<SqliteException>(() => Backups.CreateAsync());
        Assert.Equal(beforeFailure, (await Backups.ListAsync()).Select(copy => copy.Path));
    }

    [Fact]
    public void DailyRepresentativesUseLocalDatesAndOverlappingRecentCopiesAreNotDuplicated()
    {
        var zone = TimeZoneInfo.CreateCustomTimeZone("Backup local", TimeSpan.FromHours(2), "Backup local", "Backup local");
        var latest = new DateTimeOffset(2026, 11, 15, 0, 30, 0, TimeSpan.Zero);
        var recent = Enumerable.Range(0, 7).Select(index =>
            new InventoryBackup($"recent-{index}", latest.AddMinutes(-index), 1)).ToArray();
        var sameLocalDay = new InventoryBackup("same-local-day", latest.AddHours(-2), 1);
        var days = Enumerable.Range(1, 7).Select(day =>
            new InventoryBackup($"daily-{day}", latest.AddDays(-day * 10), 1)).ToArray();
        var copies = recent.Concat([sameLocalDay]).Concat(days).ToArray();
        var retained = InventoryBackupStore.RetainedPaths(copies, zone);
        Assert.Equal(13, retained.Count);
        Assert.All(recent, copy => Assert.Contains(copy.Path, retained));
        Assert.DoesNotContain(sameLocalDay.Path, retained);
        Assert.All(days.Take(6), copy => Assert.Contains(copy.Path, retained));
        Assert.DoesNotContain(days[^1].Path, retained);
        Assert.Equal(7, InventoryBackupStore.RetainedPaths(recent, zone).Count);
    }

    [Fact]
    public async Task FailedAndCancelledCopiesPreserveSevenPriorCopiesAndSource()
    {
        await SeedAsync();
        for (var i = 0; i < 7; i++) await Backups.CreateAsync();
        var before = (await Backups.ListAsync()).Select(item => item.Path).ToArray();
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Backups.CreateAsync(cancelled.Token));
        await File.WriteAllTextAsync(Database, "invalid SQLite");
        await Assert.ThrowsAsync<SqliteException>(() => Backups.CreateAsync());
        Assert.Equal(before, (await Backups.ListAsync()).Select(item => item.Path));
        Assert.Empty(Directory.GetFiles(Backups.DirectoryPath, "*.partial"));
        Assert.Equal("invalid SQLite", await File.ReadAllTextAsync(Database));
    }

    [Fact]
    public async Task CompetingInstanceDefersWithoutCreatingOrPruning()
    {
        await SeedAsync();
        Directory.CreateDirectory(Backups.DirectoryPath);
        using var held = new FileStream(Path.Combine(Backups.DirectoryPath, "device-inventory.backup.lock"),
            FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
        Assert.True((await new InventoryBackupStore(Database).CreateAsync()).Deferred);
        Assert.Empty(await Backups.ListAsync());
    }

    [Fact]
    public async Task ConcurrentUncommittedWriterCannotLeakIntoBackup()
    {
        await SeedAsync();
        using var writer = new SqliteConnection($"Data Source={Database};Pooling=False");
        writer.Open();
        using var transaction = writer.BeginTransaction();
        using var command = writer.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """UPDATE names SET data='"Uncommitted name"'""";
        command.ExecuteNonQuery();
        var result = await Backups.CreateAsync();
        var copy = (await new DeviceInventoryStore(result.Backup!.Path).LoadAsync())!;
        Assert.Equal("Saved name", copy.Names["001122334455"]);
        transaction.Rollback();
    }

    [Fact]
    public async Task ExclusiveSourceLockReportsBusyWithoutPublishingOrPruning()
    {
        await SeedAsync();
        var existing = (await Backups.CreateAsync()).Backup!;
        using var writer = new SqliteConnection($"Data Source={Database};Pooling=False");
        writer.Open();
        using var command = writer.CreateCommand();
        command.CommandText = "BEGIN EXCLUSIVE";
        command.ExecuteNonQuery();
        try
        {
            var error = await Assert.ThrowsAsync<SqliteException>(() => Backups.CreateAsync());
            Assert.Equal(5, error.SqliteErrorCode);
        }
        finally
        {
            command.CommandText = "ROLLBACK";
            command.ExecuteNonQuery();
        }
        Assert.Equal(existing.Path, Assert.Single(await Backups.ListAsync()).Path);
        Assert.Empty(Directory.GetFiles(Backups.DirectoryPath, "*.partial"));
        Assert.NotNull(await new DeviceInventoryStore(Database).LoadAsync());
    }

    [Fact]
    public async Task CancellationAfterSqliteCopyNeverPublishesInterruptedCopy()
    {
        await SeedAsync();
        var existing = (await Backups.CreateAsync()).Backup!;
        var copied = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var resume = new ManualResetEventSlim();
        var store = new InventoryBackupStore(Database, () =>
        {
            copied.SetResult();
            if (!resume.Wait(TimeSpan.FromSeconds(5)))
                throw new TimeoutException("Cancellation test did not release the completed SQLite copy.");
        });
        using var cancellation = new CancellationTokenSource();
        var task = store.CreateAsync(cancellation.Token);
        try
        {
            await copied.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Assert.False(task.IsCompleted);
            Assert.Single(Directory.GetFiles(store.DirectoryPath, "*.partial"));
            cancellation.Cancel();
        }
        finally { resume.Set(); }
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => task);
        Assert.Equal(existing.Path, Assert.Single(await store.ListAsync()).Path);
        Assert.Empty(Directory.GetFiles(Backups.DirectoryPath, "*.partial"));
        Assert.NotNull(await new DeviceInventoryStore(Database).LoadAsync());
    }

    [Fact]
    public async Task PruningFailureKeepsNewCopyAndReportsExtraRetention()
    {
        await SeedAsync();
        for (var i = 0; i < 7; i++) await Backups.CreateAsync();
        var oldest = (await Backups.ListAsync()).Last();
        using var held = new FileStream(oldest.Path, FileMode.Open, FileAccess.Read, FileShare.Read);
        var error = await Assert.ThrowsAsync<IOException>(() => Backups.CreateAsync());
        Assert.Contains("Extra copies remain", error.Message);
        Assert.Equal(8, (await Backups.ListAsync()).Count);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(100000)]
    public async Task MeasureBackupAndConcurrentForegroundSaveWithSyntheticHistory(int additionalHistory)
    {
        await SeedAsync();
        if (additionalHistory > 0)
        {
            using var connection = new SqliteConnection($"Data Source={Database};Pooling=False");
            connection.Open();
            using var command = connection.CreateCommand();
            command.CommandText = $"""
                WITH RECURSIVE seq(n) AS (SELECT 2 UNION ALL SELECT n+1 FROM seq WHERE n<{additionalHistory + 1})
                INSERT INTO scan_history(kind,id,sequence,completed_at,network_id,subnet,present)
                SELECT 'mac','001122334455',n,'2026-11-01T12:00:00+00:00','backup-network','192.0.2.0/24',1 FROM seq;
                """;
            command.ExecuteNonQuery();
        }
        var store = new DeviceInventoryStore(Database);
        var loaded = (await store.LoadMetadataAsync())!;
        var baseline = Stopwatch.StartNew();
        loaded = await store.SaveAsync(loaded, loaded.Revision);
        baseline.Stop();
        var backupClock = Stopwatch.StartNew();
        async Task<InventoryBackupResult> MeasureBackupAsync()
        {
            var result = await Backups.CreateAsync().ConfigureAwait(false);
            backupClock.Stop();
            return result;
        }
        var backup = MeasureBackupAsync();
        var saveClock = Stopwatch.StartNew();
        loaded = await store.SaveAsync(loaded, loaded.Revision);
        saveClock.Stop();
        var result = await backup;
        var copy = (await new DeviceInventoryStore(result.Backup!.Path).LoadMetadataAsync())!;
        Assert.NotEqual(Guid.Empty, copy.Revision);
        Assert.Equal(1 + additionalHistory, copy.Devices["001122334455"].ScanHistory.Count);
        Assert.Equal(loaded.LatestScan!.ScanId, copy.LatestScan!.ScanId);
        output.WriteLine($"history={additionalHistory + 1}; source={new FileInfo(Database).Length} bytes; "
            + $"backup={backupClock.Elapsed.TotalMilliseconds:F2}ms; "
            + $"foreground-save={saveClock.Elapsed.TotalMilliseconds:F2}ms; isolated-save={baseline.Elapsed.TotalMilliseconds:F2}ms");
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }
}
