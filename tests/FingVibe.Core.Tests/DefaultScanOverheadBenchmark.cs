using System.Collections;
using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Reflection;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using Xunit;
using Xunit.Abstractions;

namespace FingVibe.Core.Tests;

public sealed class ScanBenchmarkAttribute : FactAttribute
{
    public ScanBenchmarkAttribute()
    {
        if (Environment.GetEnvironmentVariable("FINGVIBE_SCAN_BENCHMARK") != "1")
            Skip = "Opt in to the real-time default-scan overhead benchmark with FINGVIBE_SCAN_BENCHMARK=1.";
    }
}

// Runs unchanged on the pre-split revision (no service-discovery admission or endpoint verification) and on
// later revisions. Features are detected by reflection so the same fixture measures #481 and #567 overhead.
public sealed class DefaultScanOverheadBenchmark(ITestOutputHelper output)
{
    private const int Repetitions = 3;
    private static readonly Assembly Core = typeof(ScanResult).Assembly;
    private static readonly Type? AdvertisementType = Core.GetType("FingVibe.Core.Models.ServiceAdvertisement");

    [ScanBenchmark]
    public async Task ResponsiveAndTimeoutHeavyDefaultScans()
    {
        output.WriteLine($"Revision features: service discovery={(AdvertisementType is not null ? "present" : "absent")}; " +
            $"CPUs={Environment.ProcessorCount}; {System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription}.");
        foreach (var fixture in new[] { Fixture.Responsive, Fixture.TimeoutHeavy })
        {
            var durations = new List<double>();
            Counters? counters = null;
            for (var run = 0; run < Repetitions; run++)
            {
                (var seconds, counters) = await RunAsync(fixture);
                durations.Add(seconds);
            }
            output.WriteLine($"{fixture.Name}: hosts={fixture.Hosts}, ICMP responders={fixture.IcmpResponders}, " +
                $"SD-only responders={fixture.ServiceOnlyResponders}, advertised TCP endpoints={fixture.AdvertisedEndpoints}; " +
                $"ICMP probes={counters!.Icmp}, ARP probes={counters.Arp}, enrichments={counters.Enrichments}, " +
                $"endpoint probes={counters.Endpoints}, alive={counters.Alive}; " +
                $"durations s=[{string.Join(", ", durations.Select(value => value.ToString("F2")))}], mean={durations.Average():F2}.");
        }
    }

    private static async Task<(double Seconds, Counters Counters)> RunAsync(Fixture fixture)
    {
        var counters = new Counters();
        var network = new LanNetwork("Ethernet", IPAddress.Parse("10.20.0.1"), IPAddress.Parse("10.20.0.0"),
            fixture.Prefix, true, IPAddress.Parse("10.20.0.1"));
        var hosts = SubnetCalculator.EnumerateUsableHosts(network.NetworkAddress, network.PrefixLength).ToArray();
        var icmp = hosts.Take(fixture.IcmpResponders).ToHashSet();
        var serviceOnly = hosts.Skip(fixture.IcmpResponders).Take(fixture.ServiceOnlyResponders).ToHashSet();
        var advertised = hosts.Take(fixture.IcmpResponders + fixture.ServiceOnlyResponders)
            .Where((_, index) => index % fixture.AdvertiserStride == 0).ToArray();

        var mdns = new Dictionary<IPAddress, MdnsDeviceInfo>();
        foreach (var address in advertised.Concat(serviceOnly).Distinct())
        {
            var info = new MdnsDeviceInfo([]);
            SetIfPresent(info, "RespondedFromAddress", true);
            SetIfPresent(info, "Advertisements", Advertisements(advertised.Contains(address) ? fixture.EndpointsPerAdvertiser : 0));
            mdns[address] = info;
        }
        var discovery = new ScanDiscovery(new Dictionary<IPAddress, IReadOnlyList<SsdpDeviceInfo>>(), mdns);

        var enricher = new SimulatedEnricher(counters, serviceOnly);
        Func<IPAddress, CancellationToken, Task<ScanDiscovery>> discover = async (_, token) =>
        {
            await Task.Delay(1500, token);
            return discovery;
        };
        Func<IPAddress, int, Task<IcmpEchoReply>> echo = async (address, timeout) =>
        {
            Interlocked.Increment(ref counters.Icmp);
            if (icmp.Contains(address))
            {
                await Task.Delay(5);
                return new IcmpEchoReply(IPStatus.Success, 5, 64);
            }
            await Task.Delay(timeout);
            return new IcmpEchoReply(IPStatus.TimedOut, 0, null);
        };
        Func<IPAddress, LanNetwork, CancellationToken, Task<PhysicalAddress?>> arp = async (_, _, token) =>
        {
            Interlocked.Increment(ref counters.Arp);
            await Task.Delay(100, token);
            return null;
        };
        Func<IPAddress, int, CancellationToken, Task<bool>> connect = async (_, _, token) =>
        {
            Interlocked.Increment(ref counters.Endpoints);
            await Task.Delay(fixture.EndpointsRespond ? 10 : 400, token);
            return fixture.EndpointsRespond;
        };
        var scanner = CreateScanner(enricher, discover, echo, arp, connect);
        var buffer = new Buffer();
        var clock = Stopwatch.StartNew();
        var summary = await scanner.ScanAsync(network, buffer);
        clock.Stop();
        counters.Alive = summary.Alive;
        return (clock.Elapsed.TotalSeconds, counters);
    }

    private static LanScannerService CreateScanner(IScanResultEnricher enricher,
        Func<IPAddress, CancellationToken, Task<ScanDiscovery>> discover, Func<IPAddress, int, Task<IcmpEchoReply>> echo,
        Func<IPAddress, LanNetwork, CancellationToken, Task<PhysicalAddress?>> arp,
        Func<IPAddress, int, CancellationToken, Task<bool>> connect)
    {
        var constructor = typeof(LanScannerService).GetConstructors(BindingFlags.Instance | BindingFlags.NonPublic)
            .Single(item => item.GetParameters().Length >= 7);
        object?[] arguments = [LanScannerService.DefaultTimeoutMilliseconds, LanScannerService.DefaultMaximumConcurrency,
            enricher, discover, echo, TimeProvider.System, arp];
        if (constructor.GetParameters().Length > arguments.Length)
            arguments = [.. arguments, connect, .. Enumerable.Repeat<object?>(null, constructor.GetParameters().Length - arguments.Length - 1)];
        return (LanScannerService)constructor.Invoke(arguments);
    }

    private static object? Advertisements(int count)
    {
        if (AdvertisementType is null) return null;
        var protocol = Enum.ToObject(Core.GetType("FingVibe.Core.Models.ServiceDiscoveryProtocol")!, 0);
        var state = Enum.ToObject(Core.GetType("FingVibe.Core.Models.AdvertisedEndpointState")!, 0);
        var list = Array.CreateInstance(AdvertisementType, count);
        for (var index = 0; index < count; index++)
            list.SetValue(Activator.CreateInstance(AdvertisementType, protocol, $"_bench-{index}._tcp.local", "Benchmark service",
                null, "Benchmark", "bench.local", 20_000 + index, EndpointProtocol.Tcp, null, null, null,
                DateTimeOffset.UtcNow, state), index);
        return list;
    }

    private static void SetIfPresent(object target, string name, object? value)
    {
        if (value is not null) target.GetType().GetProperty(name)?.SetValue(target, value);
    }

    private sealed record Fixture(string Name, int Prefix, int IcmpResponders, int ServiceOnlyResponders,
        int AdvertiserStride, int EndpointsPerAdvertiser, bool EndpointsRespond)
    {
        public int Hosts => (1 << (32 - Prefix)) - 2;
        public int AdvertisedEndpoints => (IcmpResponders + ServiceOnlyResponders + AdvertiserStride - 1) / AdvertiserStride
            * EndpointsPerAdvertiser;

        // Every host answers ICMP quickly: no retry pauses; a few hosts advertise endpoints that answer.
        public static Fixture Responsive { get; } = new("responsive /27", 27, 30, 0, 8, 3, true);

        // Most hosts time out, retries run, and service-only responders advertise endpoints that never answer.
        public static Fixture TimeoutHeavy { get; } = new("timeout-heavy /24", 24, 10, 8, 1, 8, false);
    }

    private sealed class Counters
    {
        public int Icmp;
        public int Arp;
        public int Enrichments;
        public int Endpoints;
        public int Alive;
    }

    private sealed class Buffer : IProgress<ScanResult>
    {
        public void Report(ScanResult value) { }
    }

    private sealed class SimulatedEnricher(Counters counters, HashSet<IPAddress> serviceOnly) : IScanResultEnricher
    {
        public async Task<ScanEnrichment> EnrichAsync(
            IPAddress address, Task<ScanDiscovery> discoveryTask, CancellationToken cancellationToken, int? responseTtl = null)
        {
            Interlocked.Increment(ref counters.Enrichments);
            // The fixed default TCP scan times out at 400 ms on hosts without open ports.
            await Task.Delay(400, cancellationToken);
            var discovery = await discoveryTask;
            var enrichment = new ScanEnrichment(null,
                serviceOnly.Contains(address) ? null : PhysicalAddress.Parse($"0200{address.GetAddressBytes()[2]:X2}{address.GetAddressBytes()[3]:X2}0000"),
                "Unknown", []);
            if (discovery.MdnsDevices.GetValueOrDefault(address) is { } info
                && info.GetType().GetProperty("Advertisements")?.GetValue(info) is IEnumerable advertisements)
                SetIfPresent(enrichment, "ServiceAdvertisements", advertisements);
            return enrichment;
        }
    }
}
