using System.Collections.Concurrent;
using System.Net;
using System.Net.NetworkInformation;
using System.Text;
using FingVibe.App;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using FingVibe.Core.Storage;
using Microsoft.Extensions.Time.Testing;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class ServiceDiscoveryTests
{
    private static readonly DateTimeOffset Observed = new(2026, 11, 18, 7, 0, 0, TimeSpan.Zero);
    private static readonly IPAddress Device = IPAddress.Parse("192.0.2.10");

    [Fact]
    public void EnumerationResolvesAServiceTypeOutsideTheExplicitListWithMetadataAndEndpoint()
    {
        var budget = new MdnsDiscoveryBudget();
        var initial = budget.InitialQueries();
        Assert.Contains(("_ipp._tcp.local", 12), initial);
        Assert.Equal((ServiceDiscoveryCatalog.EnumerationName, 12), initial[^1]);
        Assert.DoesNotContain(initial, query => query.Name == "_example-sensor._tcp.local");

        var enumeration = Records(Device, Packet(
            (ServiceDiscoveryCatalog.EnumerationName, 12, Name("_example-sensor._tcp.local"))));
        Assert.Equal([("_example-sensor._tcp.local", 12)], budget.Accept(enumeration));

        var instance = Records(Device, Packet(("_example-sensor._tcp.local", 12, Name("Hall sensor._example-sensor._tcp.local"))));
        Assert.Equal([("Hall sensor._example-sensor._tcp.local", 33), ("Hall sensor._example-sensor._tcp.local", 16)],
            budget.Accept(instance));

        var resolved = Records(Device, Packet(
            ("Hall sensor._example-sensor._tcp.local", 33, Srv(8443, "sensor-7.local")),
            ("Hall sensor._example-sensor._tcp.local", 16, Txt("md=Sensor X2").Concat(Txt("manufacturer=Example Labs")).ToArray()),
            ("sensor-7.local", 1, Device.GetAddressBytes())));
        Assert.Contains(("sensor-7.local", 1), budget.Accept(resolved));

        var device = MdnsDeviceDiscoveryService.BuildDeviceMap(budget.Records)[Device];
        Assert.True(device.RespondedFromAddress);
        var advertisement = Assert.Single(device.Advertisements);
        Assert.Equal(("_example-sensor._tcp.local", "_example-sensor._tcp.local", null),
            (advertisement.ServiceType, advertisement.ServiceLabel, advertisement.Role));
        Assert.Equal(("Hall sensor", "sensor-7.local", 8443, EndpointProtocol.Tcp),
            (advertisement.InstanceName, advertisement.Host, advertisement.Port, advertisement.Transport));
        Assert.Equal(("Sensor X2", "Example Labs", Observed), (advertisement.Model, advertisement.Manufacturer, advertisement.ObservedAt));
        Assert.Equal("sensor-7.local", device.HostName);
    }

    [Fact]
    public void EnumerationAndFollowUpsShareOneQueryAndRecordBudget()
    {
        var budget = new MdnsDiscoveryBudget();
        var sent = budget.InitialQueries().Count;
        var types = Enumerable.Range(0, 400).Select(index =>
            (ServiceDiscoveryCatalog.EnumerationName, 12, Name($"_type-{index}._tcp.local"))).ToArray();
        // Packets stay below the parser's 9,000-byte limit.
        foreach (var chunk in types.Chunk(100))
            sent += budget.Accept(Records(Device, Packet(chunk))).Count;
        sent += budget.Accept(Records(Device, Packet(types[..10]))).Count;

        Assert.Equal(MdnsDeviceDiscoveryService.MaximumQueries, sent);
        Assert.Equal(MdnsDeviceDiscoveryService.MaximumQueries, budget.QueryCount);
        Assert.Empty(budget.Accept(Records(Device, Packet(("_late._tcp.local", 12, Name("Late._late._tcp.local"))))));

        var many = Enumerable.Range(0, 200).Select(index =>
            ((string Name, int Type, byte[] Data))($"host-{index}.local", 1, new byte[] { 192, 0, 2, 10 })).ToArray();
        while (!budget.IsFull) budget.Accept(Records(Device, Packet(many)));
        Assert.Equal(MdnsDeviceDiscoveryService.MaximumRecords, budget.Records.Count);
    }

    [Theory]
    [InlineData("_spotify-connect._tcp.local", "Spotify Connect", "Spotify Connect playback endpoint", "CPath=/zc", null)]
    [InlineData("_hue._tcp.local", "Philips Hue", "Hue bridge service", "modelid=BSB002", "BSB002")]
    [InlineData("_home-assistant._tcp.local", "Home Assistant", "Home Assistant server", "location_name=Home", null)]
    [InlineData("_matter._tcp.local", "Matter", "Matter operational node", "", null)]
    [InlineData("_matterc._udp.local", "Matter", "Matter commissionable device", "DN=Kitchen plug", null)]
    public void KnownServicesProduceTruthfulRolesWithoutFabricatedNamesOrModels(
        string service, string label, string role, string text, string? model)
    {
        var packet = Packet(
            ($"Living room._{service[1..]}", 33, Srv(service.Contains("_udp") ? 5540 : 4070, "speaker-host.local")),
            ($"Living room._{service[1..]}", 16, text.Length == 0 ? new byte[] { 0 } : Txt(text)),
            ("speaker-host.local", 1, Device.GetAddressBytes()));
        var device = MdnsDeviceDiscoveryService.BuildDeviceMap(Records(Device, packet))[Device];
        var advertisement = Assert.Single(device.Advertisements);

        Assert.Equal((label, role), (advertisement.ServiceLabel, advertisement.Role));
        Assert.Equal("Living room", advertisement.InstanceName);
        Assert.Equal(model, advertisement.Model);
        Assert.Null(advertisement.Manufacturer);
        Assert.Equal(text.StartsWith("location_name") ? "Home" : text.StartsWith("DN") ? "Kitchen plug" : null,
            advertisement.AdvertisedName);
        Assert.Equal(service.Contains("_udp") ? EndpointProtocol.Udp : EndpointProtocol.Tcp, advertisement.Transport);
        // The hostname comes only from the responder's address record; roles never become names or models.
        Assert.Equal("speaker-host.local", device.HostName);
        Assert.Null(device.Model);
    }

    [Fact]
    public void OnlyFreshValidRepliesFromTheAddressItselfEstablishPresenceOrServices()
    {
        var other = IPAddress.Parse("192.0.2.11");
        var mentioned = MdnsDeviceDiscoveryService.BuildDeviceMap(Records(other, Packet(
            ("Printer._ipp._tcp.local", 33, Srv(631, "printer.local")),
            ("printer.local", 1, Device.GetAddressBytes()))));
        Assert.False(mentioned[Device].RespondedFromAddress);
        Assert.Empty(mentioned[Device].Advertisements);

        var goodbye = MdnsDeviceDiscoveryService.ParseRecords(Packet(ttl: 0,
            ("Printer._ipp._tcp.local", 33, Srv(631, "printer.local")),
            ("printer.local", 1, Device.GetAddressBytes())));
        Assert.Empty(goodbye);
        Assert.Empty(MdnsDeviceDiscoveryService.ParseRecords(Packet(("printer.local", 1, Device.GetAddressBytes()))[..20]));
        Assert.Empty(MdnsDeviceDiscoveryService.BuildDeviceMap(Records(Device, Packet(
            ("Printer._ipp._tcp.local", 12, Name("Printer._ipp._tcp.local"))))));

        var repeated = Records(Device, Packet(
            ("Printer._ipp._tcp.local", 33, Srv(631, "printer.local")),
            ("printer.local", 1, Device.GetAddressBytes())));
        var device = MdnsDeviceDiscoveryService.BuildDeviceMap([.. repeated, .. repeated])[Device];
        Assert.True(device.RespondedFromAddress);
        Assert.Single(device.Advertisements);
    }

    [Fact]
    public void ConflictingHostClaimsDoNotMergeServicesAcrossAddresses()
    {
        var other = IPAddress.Parse("192.0.2.11");
        var records = Records(Device, Packet(
                ("Office._ipp._tcp.local", 33, Srv(631, "shared.local")),
                ("shared.local", 1, Device.GetAddressBytes())))
            .Concat(Records(other, Packet(("shared.local", 1, other.GetAddressBytes()))))
            .ToArray();
        var devices = MdnsDeviceDiscoveryService.BuildDeviceMap(records);
        Assert.Single(devices[Device].Advertisements);
        Assert.True(devices[other].RespondedFromAddress);
        Assert.Empty(devices[other].Advertisements);
    }

    [Fact]
    public async Task ServiceDiscoveryRespondersAppearOnceWithoutIcmpOrArpAndOnlyInScope()
    {
        var network = new LanNetwork("Ethernet", IPAddress.Parse("192.0.2.5"), IPAddress.Parse("192.0.2.0"), 29, true,
            IPAddress.Parse("192.0.2.1"));
        var mdns = new Dictionary<IPAddress, MdnsDeviceInfo>
        {
            [IPAddress.Parse("192.0.2.3")] = new([]) { RespondedFromAddress = true, Advertisements = [Ad(631)] },
            [IPAddress.Parse("192.0.2.6")] = new([]) { RespondedFromAddress = false, Advertisements = [] },
            [IPAddress.Parse("198.51.100.9")] = new([]) { RespondedFromAddress = true, Advertisements = [Ad(80)] }
        };
        var ssdp = new Dictionary<IPAddress, IReadOnlyList<SsdpDeviceInfo>>
        {
            [IPAddress.Parse("192.0.2.3")] = [new("Speaker", null, null, null, null) { ObservedAt = Observed }],
            [IPAddress.Parse("192.0.2.4")] = [new("Renderer", null, null, null, null) { ObservedAt = Observed }]
        };
        var time = new FakeTimeProvider(Observed);
        var enricher = new AdvertisingEnricher();
        var scanner = new LanScannerService(700, 256, enricher, (_, _) => Task.FromResult(new ScanDiscovery(ssdp, mdns)),
            (_, _) => Task.FromResult(new IcmpEchoReply(IPStatus.TimedOut, 0, null)), time,
            (_, _, _) => Task.FromResult<PhysicalAddress?>(null), (_, _, _) => Task.FromResult(true));
        var results = new ConcurrentQueue<ScanResult>();
        var progress = new ConcurrentQueue<LanScanProgress>();
        var scan = scanner.ScanAsync(network, new Collector<ScanResult>(results.Enqueue),
            new Collector<LanScanProgress>(progress.Enqueue));
        for (var wait = 0; wait < 2; wait++)
        {
            var phase = wait == 0 ? LanScanPhase.RetryWait : LanScanPhase.FinalRetryWait;
            await WaitUntilAsync(() => progress.Any(item => item.Phase == phase));
            time.Advance(LanScannerService.RetryPause);
        }
        var summary = await scan.WaitAsync(TimeSpan.FromSeconds(10));

        var alive = results.Where(result => result.Status == HostStatus.Alive).OrderBy(result => result.AddressText).ToArray();
        Assert.Equal(["192.0.2.3", "192.0.2.4"], alive.Select(result => result.AddressText));
        Assert.Equal(2, summary.Alive);
        Assert.All(alive, result => Assert.Null(result.RoundtripTimeMilliseconds));
        Assert.Equal("MAC unavailable", alive[1].MacAddressText);
        Assert.Equal(AdvertisedEndpointState.Open,
            Assert.Single(alive[0].ServiceAdvertisements, item => item.Protocol == ServiceDiscoveryProtocol.Mdns).Verification);
        Assert.Equal("Speaker", Assert.Single(alive[0].ServiceAdvertisements,
            item => item.Protocol == ServiceDiscoveryProtocol.Ssdp).AdvertisedName);
        Assert.Contains(alive[0].OpenPortItems, port => port.Port == 631 && port.ServiceName == "IPP printing (advertised)");
        Assert.DoesNotContain(enricher.Enriched, address => address.ToString() is "192.0.2.6" or "198.51.100.9");
    }

    [Fact]
    public async Task AdvertisedEndpointsAreVerifiedWithinFixedCapsOnlyForTheAdvertisingAddress()
    {
        var probes = new ConcurrentQueue<(IPAddress Address, int Port)>();
        var inFlight = 0;
        var peak = 0;
        var verifier = new AdvertisedEndpointVerifier(async (address, port, token) =>
        {
            probes.Enqueue((address, port));
            var current = Interlocked.Increment(ref inFlight);
            InterlockedMax(ref peak, current);
            await Task.Delay(20, token);
            Interlocked.Decrement(ref inFlight);
            return port % 2 == 0;
        });

        var known = new[] { new OpenPort(80, "HTTP") };
        var first = await verifier.VerifyAsync(Device,
            [.. Enumerable.Range(0, 10).Select(index => Ad(1000 + index)), Ad(1000), Ad(80), Ad(5353, EndpointProtocol.Udp)],
            known, CancellationToken.None);
        Assert.Equal(AdvertisedEndpointVerifier.MaximumEndpointsPerDevice, probes.Count);
        Assert.All(probes, probe => Assert.Equal(Device, probe.Address));
        Assert.DoesNotContain(probes, probe => probe.Port is 80 or 5353);
        Assert.Equal(AdvertisedEndpointState.Open, first.Advertisements.Single(item => item.Port == 80).Verification);
        Assert.Equal(AdvertisedEndpointState.NoResponse, first.Advertisements.First(item => item.Port == 1001).Verification);
        Assert.Equal(AdvertisedEndpointState.NotChecked, first.Advertisements.Single(item => item.Port == 1009).Verification);
        Assert.Equal(AdvertisedEndpointState.NotApplicable, first.Advertisements.Single(item => item.Port == 5353).Verification);
        Assert.Equal([80, 1000, 1002, 1004, 1006], first.OpenPorts.Select(port => port.Port));

        var devices = Enumerable.Range(20, 10).Select(host => IPAddress.Parse($"192.0.2.{host}")).ToArray();
        await Task.WhenAll(devices.Select(address => verifier.VerifyAsync(address,
            Enumerable.Range(2000, 8).Select(port => Ad(port)).ToArray(), [], CancellationToken.None)));
        Assert.Equal(AdvertisedEndpointVerifier.MaximumEndpointsPerScan, verifier.Started);
        Assert.Equal(AdvertisedEndpointVerifier.MaximumEndpointsPerScan, probes.Count);
        Assert.InRange(peak, 1, AdvertisedEndpointVerifier.MaximumConcurrency);
        Assert.Equal(TimeSpan.FromMilliseconds(400), AdvertisedEndpointVerifier.ConnectTimeout);

        using var cancellation = new CancellationTokenSource();
        var blocked = new AdvertisedEndpointVerifier((_, _, token) => Task.Delay(Timeout.Infinite, token).ContinueWith(_ => false, token));
        var pending = blocked.VerifyAsync(Device, [Ad(9000)], [], cancellation.Token);
        cancellation.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pending);
    }

    [Fact]
    public async Task CheckpointAndInventoryKeepEvidenceWithoutCreatingMacLessEquipment()
    {
        var macless = new ScanResult(Device, HostStatus.Alive, null, TimeSpan.Zero, "speaker-host.local")
        {
            ServiceAdvertisements = [Ad(631) with { Verification = AdvertisedEndpointState.Open }]
        };
        var withMac = new ScanResult(IPAddress.Parse("192.0.2.12"), HostStatus.Alive, null, TimeSpan.Zero,
            MacAddress: PhysicalAddress.Parse("02AABBCCDD12")) { ServiceAdvertisements = [Ad(8009)] };
        var snapshot = new ScanSnapshot("192.0.2.0/24", Observed, [macless, withMac])
        {
            ScanId = Guid.NewGuid(), State = ScanCheckpointState.Pending, NetworkId = "network-a"
        };
        var restored = ScanSnapshotStore.Deserialize(ScanSnapshotStore.Serialize(snapshot));
        Assert.Equal(macless.ServiceAdvertisements, restored.Results[0].ServiceAdvertisements);
        Assert.Null(restored.Results[0].MacAddress);

        var directory = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N"));
        try
        {
            var store = new ScanSnapshotStore(Path.Combine(directory, "latest-scan.json"));
            await store.SaveAsync(snapshot with { State = ScanCheckpointState.Complete });
            Assert.Equal(withMac.ServiceAdvertisements, (await store.LoadAsync())!.Results[1].ServiceAdvertisements);
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }

        var observed = DeviceInventoryData.Empty.ObserveCompletedScan("network-a", snapshot with { State = ScanCheckpointState.Complete });
        var device = Assert.Single(observed.Devices.Values);
        Assert.Equal("02:AA:BB:CC:DD:12".Replace(":", string.Empty), device.Mac);
        Assert.Equal(withMac.ServiceAdvertisements, device.LatestObservation!.ServiceAdvertisements);
        Assert.Equal(withMac.ServiceAdvertisements, device.LatestObservation.ToScanResult(device.Mac).ServiceAdvertisements);

        var invalid = snapshot with { Results = [macless with { ServiceAdvertisements = [Ad(0)] }] };
        Assert.Throws<InvalidDataException>(() => ScanSnapshotStore.Deserialize(
            ScanSnapshotStore.Serialize(snapshot).Replace("\"port\": 631", "\"port\": 0")));
        Assert.False(ServiceAdvertisement.IsValid(invalid.Results[0].ServiceAdvertisements));
    }

    [Fact]
    public void RowsShowTheLatestScanIconMacUnavailableAndNoFabricatedLatency()
    {
        var current = new ScanResultRow(new ScanResult(Device, HostStatus.Alive, null, TimeSpan.Zero, "speaker-host.local")
        {
            ServiceAdvertisements = [Ad(631), Ad(8009) with { ServiceLabel = "Google Cast", Role = "Cast receiver" }]
        }, 24);
        Assert.True(current.HasLatestServiceDiscovery);
        Assert.Equal("--", current.LatencyLabel);
        Assert.Equal("MAC unavailable", current.MacAddressText);
        Assert.Equal("Service discovery: 2 advertised services", current.ServiceDiscoveryName);
        Assert.Equal("speaker-host.local", current.NameText);
        Assert.Contains("• Google Cast (Cast receiver) - mDNS/DNS-SD", current.ServiceDiscoveryText);
        Assert.Contains($"observed {ServiceDiscoveryPresentation.Time(Observed)}", current.ServiceDiscoveryText);

        var historical = new ScanResultRow(current.Result!, 24, historical: true);
        Assert.False(historical.HasLatestServiceDiscovery);
        var plain = new ScanResultRow(new ScanResult(Device, HostStatus.Alive, null, TimeSpan.Zero), 24);
        Assert.False(plain.HasLatestServiceDiscovery);
        Assert.Equal("-", plain.LatencyLabel);

        var fields = ServiceDiscoveryPresentation.Fields(Ad(631) with { Verification = AdvertisedEndpointState.NoResponse },
            TimeZoneInfo.Utc);
        Assert.Contains(("TCP verification", "TCP verified: no response - not counted as open"), fields);
        Assert.Contains(("Observed", "2026-11-18 07:00:00"), fields);
        Assert.DoesNotContain(fields, field => field.Label == "Advertised model");
    }

    private static ServiceAdvertisement Ad(int port, EndpointProtocol transport = EndpointProtocol.Tcp) =>
        new(ServiceDiscoveryProtocol.Mdns, transport == EndpointProtocol.Udp ? "_matterc._udp.local" : "_ipp._tcp.local",
            transport == EndpointProtocol.Udp ? "Matter" : "IPP printing", null, "Office", "printer.local", port, transport,
            null, null, null, Observed);

    private static IReadOnlyList<MdnsResourceRecord> Records(IPAddress source, byte[] packet) =>
        MdnsDeviceDiscoveryService.ParseRecords(packet)
            .Select(record => record with { Source = source, ReceivedAt = Observed }).ToArray();

    private static async Task WaitUntilAsync(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (!condition())
        {
            if (DateTime.UtcNow > deadline) throw new TimeoutException();
            await Task.Delay(10);
        }
    }

    private static void InterlockedMax(ref int target, int value)
    {
        int current;
        while (value > (current = Volatile.Read(ref target)) && Interlocked.CompareExchange(ref target, value, current) != current) { }
    }

    private static byte[] Srv(int port, string target) =>
        new byte[] { 0, 0, 0, 0, (byte)(port >> 8), (byte)port }.Concat(Name(target)).ToArray();

    private static byte[] Name(string name) => name.Split('.')
        .SelectMany(label => new[] { (byte)Encoding.UTF8.GetByteCount(label) }.Concat(Encoding.UTF8.GetBytes(label)))
        .Append((byte)0).ToArray();

    private static byte[] Txt(string text) =>
        new[] { (byte)Encoding.UTF8.GetByteCount(text) }.Concat(Encoding.UTF8.GetBytes(text)).ToArray();

    private static byte[] Packet(params (string Name, int Type, byte[] Data)[] records) => Packet(120, records);

    private static byte[] Packet(int ttl, params (string Name, int Type, byte[] Data)[] records)
    {
        var bytes = new List<byte> { 0, 0, 0x84, 0, 0, 0, (byte)(records.Length >> 8), (byte)records.Length, 0, 0, 0, 0 };
        foreach (var record in records)
        {
            bytes.AddRange(Name(record.Name));
            bytes.AddRange([(byte)(record.Type >> 8), (byte)record.Type, 0, 1, 0, 0, 0, (byte)ttl,
                (byte)(record.Data.Length >> 8), (byte)record.Data.Length]);
            bytes.AddRange(record.Data);
        }
        return bytes.ToArray();
    }

    private sealed class Collector<T>(Action<T> report) : IProgress<T>
    {
        public void Report(T value) => report(value);
    }

    private sealed class AdvertisingEnricher : IScanResultEnricher
    {
        public ConcurrentQueue<IPAddress> Enriched { get; } = new();

        public async Task<ScanEnrichment> EnrichAsync(
            IPAddress address, Task<ScanDiscovery> discoveryTask, CancellationToken cancellationToken, int? responseTtl = null)
        {
            Enriched.Enqueue(address);
            var discovery = await discoveryTask;
            return new ScanEnrichment(null, null, "Unknown", [])
            {
                ServiceAdvertisements = ScanResultEnricher.CollectAdvertisements(
                    discovery.SsdpDevices.GetValueOrDefault(address) ?? [], discovery.MdnsDevices.GetValueOrDefault(address))
            };
        }
    }
}
