using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.Json;
using FingVibe.App;
using FingVibe.Core.Models;
using Xunit;
using Xunit.Abstractions;

namespace FingVibe.Core.Tests;

public sealed class InventoryPresentationBenchmarkAttribute : FactAttribute
{
    public InventoryPresentationBenchmarkAttribute()
    {
        if (Environment.GetEnvironmentVariable("FINGVIBE_INVENTORY_PRESENTATION_BENCHMARK") != "1")
            Skip = "Opt in with FINGVIBE_INVENTORY_PRESENTATION_BENCHMARK=1.";
    }
}

public sealed class InventoryPresentationBenchmark(ITestOutputHelper output)
{
    private const int SampleCount = 15;

    [InventoryPresentationBenchmark]
    public void RecordBaselineAndFinalProtocol()
    {
        var refreshes = MeasureRefreshWorkloads();
        var people = MeasurePeopleRoomProjections();
        var results = new InventoryPresentationEvidence(
            "inventory-presentation-v1",
            Environment.GetEnvironmentVariable("FINGVIBE_BENCHMARK_REVISION") ?? "unspecified",
            Environment.GetEnvironmentVariable("FINGVIBE_BENCHMARK_PHASE") ?? "unspecified",
            DateTimeOffset.UtcNow,
            $"{RuntimeInformation.OSDescription}; {RuntimeInformation.FrameworkDescription}; "
                + $"{RuntimeInformation.ProcessArchitecture}; CPUs={Environment.ProcessorCount}",
            SampleCount,
            [
                MeasureRows("empty", []),
                MeasureRows("same-order-small-128", Enumerable.Range(0, 128).ToArray()),
                MeasureRows("same-order-large-10000", Enumerable.Range(0, 10_000).ToArray()),
                MeasureRows("filter-large-10000-to-5000", Enumerable.Range(0, 10_000).ToArray(),
                    Enumerable.Range(0, 5_000).Select(index => index * 2).ToArray()),
                MeasureRows("reverse-large-5000", Enumerable.Range(0, 5_000).ToArray(),
                    Enumerable.Range(0, 5_000).Reverse().ToArray())
            ],
            people,
            refreshes);
        var json = JsonSerializer.Serialize(results, new JsonSerializerOptions { WriteIndented = true });
        output.WriteLine(json);
        var resultPath = Environment.GetEnvironmentVariable("FINGVIBE_INVENTORY_PRESENTATION_RESULTS");
        if (!string.IsNullOrWhiteSpace(resultPath))
        {
            Directory.CreateDirectory(Path.GetDirectoryName(resultPath)!);
            File.WriteAllText(resultPath, json);
        }
    }

    private static InventoryTiming[] MeasurePeopleRoomProjections()
    {
        var small = CreateProjection(0, 8, 8);
        var large = CreateProjection(4_000, 200, 200);
        return
        [
            Measure("people-rooms-empty", () => Project(small)),
            Measure("people-rooms-large-4000x200x200", () => Project(large))
        ];
    }

    private static long Project((PeopleRoomsData Data, AssignedDeviceListRow[] Devices) fixture)
    {
        var people = PeopleRoomsPresentation.PeopleRows(fixture.Data, fixture.Devices, true);
        var rooms = PeopleRoomsPresentation.RoomRows(fixture.Data, fixture.Devices, true);
        return people.Sum(row => row.DeviceCountText.Length)
            + rooms.Sum(row => row.DeviceCountText.Length + row.RespondedCountText.Length);
    }

    private static (PeopleRoomsData Data, AssignedDeviceListRow[] Devices) CreateProjection(
        int deviceCount, int personCount, int roomCount)
    {
        var people = Enumerable.Range(0, personCount)
            .Select(index => new ManagedPerson(GuidFrom(index + 1), $"Person {index}",
                index.ToString("X3", CultureInfo.InvariantCulture))).ToArray();
        var rooms = Enumerable.Range(0, roomCount)
            .Select(index => new ManagedRoom(GuidFrom(index + 10_001), $"Room {index}",
                index.ToString("X3", CultureInfo.InvariantCulture))).ToArray();
        var assignments = Enumerable.Range(0, deviceCount).ToDictionary(
            index => index.ToString("X12", CultureInfo.InvariantCulture),
            index => new DeviceAssignment(people[index % people.Length].Id, rooms[index % rooms.Length].Id));
        var devices = assignments.Keys.Select(key => new AssignedDeviceListRow(key, null)).ToArray();
        return (new PeopleRoomsData(people, rooms, assignments), devices);
    }

    private static InventoryTiming MeasureRows(string name, int[] source, int[]? desired = null)
    {
        desired ??= source;
        return Measure(name, () =>
        {
            var current = new ObservableCollection<int>(source);
            InventoryPresentation.Reconcile(current, desired);
            Assert.Equal(desired.Length, current.Count);
            return current.Count == 0 ? 0 : current[0] + current[^1];
        });
    }

    private static InventoryTiming Measure(string name, Func<long> operation)
    {
        for (var warmup = 0; warmup < 3; warmup++) operation();
        var milliseconds = new double[SampleCount];
        var allocations = new long[SampleCount];
        long checksum = 0;
        for (var sample = 0; sample < SampleCount; sample++)
        {
            GC.Collect();
            GC.WaitForPendingFinalizers();
            GC.Collect();
            var allocated = GC.GetAllocatedBytesForCurrentThread();
            var clock = Stopwatch.StartNew();
            checksum += operation();
            clock.Stop();
            milliseconds[sample] = clock.Elapsed.TotalMilliseconds;
            allocations[sample] = GC.GetAllocatedBytesForCurrentThread() - allocated;
        }
        return new InventoryTiming(name, milliseconds, allocations,
            milliseconds.Order().ElementAt((SampleCount * 95 + 99) / 100 - 1), allocations.Max(), checksum);
    }

    private static UsageRefreshMeasurement[] MeasureRefreshWorkloads()
    {
        const string saved = "revision-saved/network/subnet/date";
        const string next = "revision-next/network/subnet/date";
        return
        [
            MeasureRefresh("usage-override-save", saved,
                (next, true, false), (next, true, false)),
            MeasureRefresh("scan-checkpoint-or-import", saved,
                (next, true, false), (next, true, false)),
            MeasureRefresh("navigation-same-state", next, (next, true, false)),
            MeasureRefresh("network-or-revision-change", saved, (next, true, false)),
            MeasureRefresh("explicit-refresh-or-retry", next, (next, true, true)),
            MeasureRefresh("timer-same-completed-state", next, (next, false, false))
        ];
    }

    private static UsageRefreshMeasurement MeasureRefresh(
        string name, string initialKey, params (string Key, bool Force, bool Explicit)[] calls)
    {
        var key = initialKey;
        var starts = 0;
        var cancellations = 0;
        var inFlight = false;
        foreach (var call in calls)
        {
            if (!InventoryPresentation.ShouldStartUsageRefresh(key, call.Key, call.Force, call.Explicit)) continue;
            if (inFlight) cancellations++;
            inFlight = true;
            key = call.Key;
            starts++;
        }
        var completed = inFlight ? 1 : 0;
        return new(name, starts, cancellations, completed, starts + completed, calls.Length);
    }

    private static Guid GuidFrom(int value) =>
        Guid.ParseExact($"00000000-0000-0000-0000-{value:D12}", "D");
}

public sealed record InventoryPresentationEvidence(
    string Protocol,
    string Revision,
    string Phase,
    DateTimeOffset RecordedAt,
    string Environment,
    int Samples,
    InventoryTiming[] VisibleRows,
    InventoryTiming[] AssignmentProjections,
    UsageRefreshMeasurement[] UsageRefreshes);

public sealed record InventoryTiming(
    string Name,
    double[] Milliseconds,
    long[] AllocatedBytes,
    double P95Milliseconds,
    long MaxAllocatedBytes,
    long Checksum);

public sealed record UsageRefreshMeasurement(
    string Name,
    int QueryStarts,
    int Cancellations,
    int Completions,
    int PresentationPasses,
    int AutomaticCalls);
