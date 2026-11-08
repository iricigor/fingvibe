using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Microsoft.Data.Sqlite;
using Xunit;
using Xunit.Abstractions;

namespace FingVibe.Core.Tests;

public sealed class AnalyticsBenchmarkAttribute : FactAttribute
{
    public AnalyticsBenchmarkAttribute()
    {
        if (Environment.GetEnvironmentVariable("FINGVIBE_ANALYTICS_BENCHMARK") != "1")
            Skip = "Opt in to the isolated 10M-row F1.7 workload with FINGVIBE_ANALYTICS_BENCHMARK=1.";
    }
}

[Collection("History workload")]
public sealed class AnalyticsEvidenceBenchmark(ITestOutputHelper output) : IDisposable
{
    private const string Subnet = "192.0.2.0/24";
    private static readonly DateTimeOffset End = DateTimeOffset.Parse("2026-11-07T12:00:00Z");
    private static readonly DateTimeOffset Start = End.AddDays(-1000);
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"fingvibe-analytics-benchmark-{Guid.NewGuid():N}");
    private string Database => Path.Combine(_directory, "inventory.sqlite");

    [AnalyticsBenchmark]
    public async Task RepresentativeF17Workload()
    {
        var (store, data) = await Seed();
        var request = new AnalyticsEvidenceRequest("network-0", Subnet, End, 30, TimeZoneInfo.Utc, data.Revision);
        output.WriteLine($"Runtime: {RuntimeInformation.OSDescription}; {RuntimeInformation.FrameworkDescription}; {RuntimeInformation.ProcessArchitecture}; CPUs={Environment.ProcessorCount}.");
        output.WriteLine("Fixture: 900 normal + 100 virtual logical identities (100 associated MACs suppressed); " +
            "100,000 scan rows every 864s over 1,000 days, network=i%3, identical subnet on all 3 networks. " +
            "10,000 observations per logical identity; scan ordinal=9999+9*sequence+network. " +
            "20% nonresponses; every 50th observation is unlinked legacy evidence. No retention trimming. " +
            "Network-0 selection: 300 normal + 100 virtual identities; equipment: first 50 of these. " +
            "First-query/cold measurements do not flush the operating-system filesystem cache.");
        using (var connection = Open())
        using (var command = connection.CreateCommand())
        {
            command.CommandTimeout = 600;
            command.CommandText = """
                SELECT COUNT(*),
                    SUM(CASE WHEN network_id='network-0' AND completed_ticks>=$thirty THEN 1 ELSE 0 END),
                    SUM(CASE WHEN network_id='network-0' AND completed_ticks>=$seven THEN 1 ELSE 0 END)
                FROM scan_history
                """;
            command.Parameters.AddWithValue("$thirty", End.Date.AddDays(-29).Ticks);
            command.Parameters.AddWithValue("$seven", End.Date.AddDays(-6).Ticks);
            using var reader = command.ExecuteReader();
            Assert.True(reader.Read());
            Assert.Equal(10_000_000L, reader.GetInt64(0));
            output.WriteLine($"Exact observation counts: retained={reader.GetInt64(0)}; selected network/30 dates={reader.GetInt64(1)}; selected network/7 dates={reader.GetInt64(2)}.");
        }
        var single = request with { Devices = [LogicalDeviceId.Mac("001122000000")] };
        var roster = Enumerable.Range(0, 900).Where(i => i % 3 == 0).Take(50)
            .Select(i => LogicalDeviceId.Mac($"001122{i:X6}")).ToArray();
        await Measure("single device 30-date query + production activity buckets", 1000, single, store, classify: false);
        await Measure("network 30-date query + production aligned bucket union", 2000, request, store, classify: false);
        await Measure("equipment 30-date query + production aligned bucket union", 2000,
            request with { Devices = roster }, store, classify: false);
        await Measure("all-device 7-date query + production usage classification", 2000,
            request with { CalendarDays = 7 }, store, classify: true);

        var cancellations = new List<double>();
        for (var run = 0; run < 20; run++)
        {
            using var cancellation = new CancellationTokenSource();
            var query = Task.Run(async () =>
            {
                var evidence = await store.QueryAnalyticsAsync(request, cancellation.Token);
                return DeviceActivity.Group(evidence, 1, cancellation.Token);
            }, cancellation.Token);
            await Task.Delay(20);
            var clock = Stopwatch.StartNew();
            cancellation.Cancel();
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => query);
            using (var connection = Open())
            using (var command = connection.CreateCommand())
            {
                command.CommandText = "BEGIN EXCLUSIVE; ROLLBACK;";
                command.ExecuteNonQuery();
            }
            cancellations.Add(clock.Elapsed.TotalMilliseconds);
        }
        output.WriteLine($"Cancellation + exclusive-lock resource-release ms (20): {string.Join(", ", cancellations.Select(ms => ms.ToString("F3")))}; max={cancellations.Max():F3}; ceiling=250.");
        Assert.True(cancellations.Max() <= 250, $"Cancellation/resource release exceeded 250ms: {cancellations.Max():F3}.");
    }

    private async Task Measure(string label, double milliseconds, AnalyticsEvidenceRequest request,
        DeviceInventoryStore store, bool classify)
    {
        async Task<(double Milliseconds, long Allocated, long Rss, long Checksum)> Run()
        {
            GC.Collect();
            GC.WaitForPendingFinalizers();
            GC.Collect();
            var before = GC.GetTotalAllocatedBytes(precise: true);
            var clock = Stopwatch.StartNew();
            var evidence = await store.QueryAnalyticsAsync(request);
            var checksum = classify ? ClassificationCounts(evidence) : BucketUnion(evidence);
            clock.Stop();
            var allocated = GC.GetTotalAllocatedBytes(precise: true) - before;
            return (clock.Elapsed.TotalMilliseconds, allocated, Process.GetCurrentProcess().WorkingSet64, checksum);
        }
        var cold = await Run();
        output.WriteLine($"{label}: first-query/cold={cold.Milliseconds:F3}ms; allocated={cold.Allocated} bytes; RSS={cold.Rss} bytes; checksum={cold.Checksum}.");
        await Run();
        var times = new List<double>();
        long maxAllocation = 0, maxRss = 0;
        for (var index = 0; index < 20; index++)
        {
            var run = await Run();
            Assert.Equal(cold.Checksum, run.Checksum);
            times.Add(run.Milliseconds);
            maxAllocation = Math.Max(maxAllocation, run.Allocated);
            maxRss = Math.Max(maxRss, run.Rss);
        }
        var p95 = times.Order().ElementAt(18);
        output.WriteLine($"{label}: warm ms (20)={string.Join(", ", times.Select(ms => ms.ToString("F3")))}; " +
            $"nearest-rank p95={p95:F3}ms; max additional managed allocation={maxAllocation} bytes ({maxAllocation / 1048576d:F3}MiB); " +
            $"max sampled process RSS={maxRss} bytes; ceilings={milliseconds}ms/128MiB.");
        Assert.True(p95 <= milliseconds, $"{label}: p95 {p95:F3}ms exceeds {milliseconds}ms.");
        Assert.True(maxAllocation <= 128 * 1048576L, $"{label}: allocation {maxAllocation} exceeds 128MiB.");
    }

    private static long BucketUnion(AnalyticsEvidence evidence)
    {
        var buckets = DeviceActivity.Group(evidence, 1);
        if (evidence.Devices.Count == 1)
            Assert.Equal(7 * 24, DeviceActivity.ByWeekday(buckets, 0).Count);
        return buckets.Days.Sum(bucket => (long)bucket.RespondingIdentities.Count);
    }

    private static long ClassificationCounts(AnalyticsEvidence evidence)
    {
        var classified = DeviceUsageClassifier.Classify(evidence);
        Assert.Equal(evidence.Devices.Count, classified.Count);
        Assert.All(classified.Values, value => Assert.Equal(
            value.OvernightWeekend.Eligible + value.WeekdayDaytime.Eligible, value.Total.Eligible));
        return classified.Values.Sum(value => (long)value.Total.Eligible + value.Total.Responded + (int)value.Category);
    }

    private async Task<(DeviceInventoryStore Store, DeviceInventoryData Data)> Seed()
    {
        var store = new DeviceInventoryStore(Database);
        var normal = Enumerable.Range(0, 900).Select(i => $"001122{i:X6}").ToArray();
        var privateMacs = Enumerable.Range(0, 100).Select(i => $"D0C907{i:X6}").ToArray();
        var results = normal.Concat(privateMacs).Select((mac, i) => new ScanResult(
            IPAddress.Parse($"192.0.2.{i % 250 + 1}"), HostStatus.Alive, 1, TimeSpan.Zero,
            MacAddress: PhysicalAddress.Parse(mac), VendorName: i < 900 ? "Example" : "Private")).ToArray();
        var data = DeviceInventoryData.Empty.ObserveCompletedScan("network-0", new(Subnet, Start, results));
        var networks = normal.Select((mac, i) => (mac, Network: i % 3)).ToDictionary(item => item.mac, item => item.Network);
        data = data with
        {
            LatestScan = null,
            Devices = data.Devices.ToDictionary(pair => pair.Key, pair => pair.Value with
            {
                ScanHistory = [],
                Observations = pair.Value.Observations.Select(item => item with
                    { NetworkId = $"network-{networks.GetValueOrDefault(pair.Key)}" }).ToArray()
            }),
            VirtualDevices = data.VirtualDevices.Select(slot => slot with { ScanHistory = [] }).ToArray()
        };
        data = await store.SaveAsync(data, Guid.Empty);
        using var connection = Open();
        using var transaction = connection.BeginTransaction();
        using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandTimeout = 1800;
        command.CommandText = "CREATE TEMP TABLE fixture_devices(kind TEXT,id TEXT,network INTEGER)";
        command.ExecuteNonQuery();
        foreach (var identity in normal.Select(mac => ("mac", mac, networks[mac]))
                     .Concat(data.VirtualDevices.Select(slot => ("virtual", slot.Id.ToString("D"), 0))))
        {
            command.CommandText = "INSERT INTO fixture_devices VALUES($kind,$id,$network)";
            command.Parameters.Clear();
            command.Parameters.AddWithValue("$kind", identity.Item1);
            command.Parameters.AddWithValue("$id", identity.Item2);
            command.Parameters.AddWithValue("$network", identity.Item3);
            command.ExecuteNonQuery();
        }
        command.Parameters.Clear();
        command.Parameters.AddWithValue("$start", Start.ToString("yyyy-MM-ddTHH:mm:ss"));
        command.Parameters.AddWithValue("$ticks", Start.UtcTicks);
        command.CommandText = """
            WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM n WHERE i<99999)
            INSERT INTO scan_evidence
            SELECT printf('00000000-0000-0000-0001-%012d',i), 'network-' || (i%3), '192.0.2.0/24',
                strftime('%Y-%m-%dT%H:%M:%S+00:00',$start,'+' || (i*864) || ' seconds'),
                $ticks+i*8640000000,0,0 FROM n;
            WITH RECURSIVE n(i) AS (SELECT 0 UNION ALL SELECT i+1 FROM n WHERE i<9999)
            INSERT INTO scan_history
            SELECT kind,id,i,
                strftime('%Y-%m-%dT%H:%M:%S+00:00',$start,'+' || ((9999+9*i+network)*864) || ' seconds'),
                'network-' || network,'192.0.2.0/24',CASE WHEN i%5=0 THEN 0 ELSE 1 END,
                $ticks+(9999+9*i+network)*8640000000,
                CASE WHEN i%50=0 THEN NULL ELSE printf('00000000-0000-0000-0001-%012d',9999+9*i+network) END,NULL
            FROM fixture_devices CROSS JOIN n ORDER BY kind,id,i;
            """;
        var clock = Stopwatch.StartNew();
        command.ExecuteNonQuery();
        transaction.Commit();
        output.WriteLine($"Fixture creation: {clock.Elapsed.TotalSeconds:F3}s; database={new FileInfo(Database).Length} bytes.");
        return (store, data);
    }

    private SqliteConnection Open()
    {
        var connection = new SqliteConnection($"Data Source={Database};Pooling=False");
        connection.Open();
        return connection;
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }
}
