using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Microsoft.Data.Sqlite;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class DeviceMatchSuggestionsTests : IDisposable
{
    private const string A = "001122AA0001";
    private const string B = "001122AA0002";
    private const string C = "001122AA0003";
    private static readonly DateTimeOffset Start = DateTimeOffset.Parse("2026-11-01T12:00:00+00:00");
    private static readonly IReadOnlySet<string> NoAdapters = new HashSet<string>();
    private readonly string _directory = Path.Combine(Path.GetTempPath(), $"fingvibe-matches-{Guid.NewGuid():N}");

    private static ObservedDeviceValue Value(ReportedDeviceValueKind kind, string value, int minute = 0) =>
        new(kind, value, Start.AddMinutes(minute));

    private static DeviceObservation Observation(string address, string? hostname = null, string network = "home",
        DeviceClassification? classification = null, int lastSeenMinute = 10, params ObservedDeviceValue[] values) =>
        new(network, "192.0.2.0/24", address, hostname, "Example", classification ?? DeviceClassification.Unknown, [],
            1, TimeSpan.Zero, Start, Start.AddMinutes(lastSeenMinute), Start.AddMinutes(lastSeenMinute), true)
        { ReportedValues = values };

    private static InventoryDevice Device(string mac, params DeviceObservation[] observations) =>
        new(mac, new ImportedDeviceMetadata(), observations);

    private static DeviceInventoryData Data(params InventoryDevice[] devices) =>
        DeviceInventoryData.Empty with { Devices = devices.ToDictionary(device => device.Mac) };

    private static IReadOnlyDictionary<string, IReadOnlyList<DeviceMatchSuggestion>> Find(
        DeviceInventoryData data, IReadOnlySet<string>? adapters = null) =>
        DeviceMatchSuggestions.Find(data, adapters ?? NoAdapters);

    private static InventoryDevice Named(string mac, string address, ReportedDeviceValueKind kind, string name,
        DeviceClassification? classification = null, string network = "home") =>
        Device(mac, Observation(address, network: network, classification: classification, values: Value(kind, name)));

    [Fact]
    public void HostNamesCompareBeforeTheFirstDotAndOtherNamesCompareInFull()
    {
        var data = Data(
            Named(A, "192.0.2.10", ReportedDeviceValueKind.NetBiosName, "REY"),
            Named(B, "192.0.2.11", ReportedDeviceValueKind.MdnsName, "rey.local"),
            Named(C, "192.0.2.12", ReportedDeviceValueKind.ReverseDnsName, "rey.fritz.box"),
            Named("001122AA0004", "192.0.2.13", ReportedDeviceValueKind.MdnsName, "rey-2.local"),
            Named("001122AA0005", "192.0.2.14", ReportedDeviceValueKind.MdnsName, "rey-wifi.local"),
            Named("001122AA0006", "192.0.2.15", ReportedDeviceValueKind.SsdpName, " Mr. Coffee "),
            Named("001122AA0007", "192.0.2.16", ReportedDeviceValueKind.MdnsName, "mr.local"));
        data = data with { Names = new Dictionary<string, string> { ["001122AA0008"] = "mr. coffee" } };
        data = data with
        {
            Devices = new Dictionary<string, InventoryDevice>(data.Devices)
                { ["001122AA0008"] = Device("001122AA0008", Observation("192.0.2.17")) }
        };

        var suggestions = Find(data);

        Assert.Equal([B, C], suggestions[A].Select(item => item.OtherMac).Order());
        Assert.Equal([A, C], suggestions[B].Select(item => item.OtherMac).Order());
        Assert.All(suggestions[A], item => Assert.Equal(DeviceMatchReason.SameName, item.Reason));
        Assert.False(suggestions.ContainsKey("001122AA0004"));
        Assert.False(suggestions.ContainsKey("001122AA0005"));
        Assert.Equal("001122AA0008", Assert.Single(suggestions["001122AA0006"]).OtherMac);
        Assert.False(suggestions.ContainsKey("001122AA0007"));
    }

    [Fact]
    public void NamesGivenInFingVibeOrFingAlwaysCount()
    {
        var a = Device(A, Observation("192.0.2.10"));
        var b = Device(B, Observation("192.0.2.11")) with { Imported = new ImportedDeviceMetadata(Name: "Rey") };
        var c = Device(C, Observation("192.0.2.12")) with { Imported = new ImportedDeviceMetadata(Hostname: "REY.fritz.box") };
        var data = Data(a, b, c) with { Names = new Dictionary<string, string> { [A] = " rey " } };

        Assert.Equal([B, C], Find(data)[A].Select(item => item.OtherMac).Order());
    }

    [Theory]
    [InlineData("iPhone")]
    [InlineData("raspberrypi.local")]
    [InlineData("Unknown")]
    [InlineData("192.0.2.10")]
    [InlineData("host-192-0-2-10.local")]
    [InlineData("ESP_AA0001")]
    [InlineData("device-00-11-22-aa-00-01")]
    [InlineData("   ")]
    public void GenericAddressAndMacBasedNamesNeverMatch(string name)
    {
        var data = Data(
            Named(A, "192.0.2.10", ReportedDeviceValueKind.MdnsName, name),
            Named(B, "192.0.2.10", ReportedDeviceValueKind.MdnsName, name) with { Mac = B });

        Assert.Empty(Find(data));
    }

    [Fact]
    public void OnlyNamesFromTheMostRecentNamingScanCount()
    {
        var a = Device(A, Observation("192.0.2.10", values:
        [
            Value(ReportedDeviceValueKind.MdnsName, "old-name.local", 1),
            Value(ReportedDeviceValueKind.SsdpName, "Living room TV", 5)
        ]));
        var data = Data(a,
            Named(B, "192.0.2.11", ReportedDeviceValueKind.MdnsName, "old-name.local"),
            Named(C, "192.0.2.12", ReportedDeviceValueKind.SsdpName, "living room tv"));

        Assert.Equal(C, Assert.Single(Find(data)[A]).OtherMac);
    }

    [Fact]
    public void RecordsWithoutReportedValuesUseTheirLatestObservationHostname()
    {
        var a = Device(A, Observation("192.0.2.10", "kitchen-pi.fritz.box", lastSeenMinute: 2),
            Observation("192.0.2.20", "kitchen-hub.fritz.box", lastSeenMinute: 9));
        var data = Data(a,
            Device(B, Observation("192.0.2.11", "KITCHEN-HUB")),
            Device(C, Observation("192.0.2.12", "kitchen-pi")));

        Assert.Equal(B, Assert.Single(Find(data)[A]).OtherMac);
    }

    [Fact]
    public void ClearTypeConflictsSuppressOnlyNameMatches()
    {
        var printer = new DeviceClassification(Type: DeviceType.Printer);
        var storage = new DeviceClassification(Type: DeviceType.Storage);
        var likelyStorage = new DeviceClassification(Type: DeviceType.Storage, TypeIsInferred: true);
        var computer = new DeviceClassification(Type: DeviceType.Computer);
        var data = Data(
            Named(A, "192.0.2.10", ReportedDeviceValueKind.MdnsName, "office.local", printer),
            Named(B, "192.0.2.11", ReportedDeviceValueKind.MdnsName, "office.local", storage),
            Named(C, "192.0.2.12", ReportedDeviceValueKind.MdnsName, "office.local", likelyStorage),
            Named("001122AA0004", "192.0.2.13", ReportedDeviceValueKind.MdnsName, "office.local", computer));

        var suggestions = Find(data);

        Assert.DoesNotContain(suggestions[A], item => item.OtherMac == B);
        Assert.Contains(suggestions[A], item => item.OtherMac == C);
        Assert.Contains(suggestions[A], item => item.OtherMac == "001122AA0004");

        var sameId = Data(
            Device(A, Observation("192.0.2.10", classification: printer, values: Value(ReportedDeviceValueKind.UpnpUuid, "abc"))),
            Device(B, Observation("192.0.2.11", classification: storage, values: Value(ReportedDeviceValueKind.UpnpUuid, "ABC"))));
        Assert.Equal(DeviceMatchReason.SameDeviceId, Assert.Single(Find(sameId)[A]).Reason);

        var overridden = data with
        {
            Classifications = new Dictionary<string, DeviceClassificationOverride> { [C] = new(Type: DeviceType.Printer) }
        };
        Assert.DoesNotContain(Find(overridden)[B], item => item.OtherMac == C);
    }

    [Fact]
    public void DeviceIdsMustShareTheirKind()
    {
        var data = Data(
            Named(A, "192.0.2.10", ReportedDeviceValueKind.HomeKitId, "11:22:33"),
            Named(B, "192.0.2.11", ReportedDeviceValueKind.AirPlayDeviceId, "11:22:33"),
            Named(C, "192.0.2.12", ReportedDeviceValueKind.HomeKitId, "11:22:33"));

        var suggestion = Assert.Single(Find(data)[A]);
        Assert.Equal(C, suggestion.OtherMac);
        Assert.Equal("Same device ID (HomeKit ID)", suggestion.ShortReason);
    }

    [Fact]
    public void ReasonsAreOrderedStrongestFirstThenByMostRecentlySeen()
    {
        var uuid = Value(ReportedDeviceValueKind.UpnpUuid, "uuid-1");
        var data = Data(
            Device(A, Observation("192.0.2.10", values: [uuid, Value(ReportedDeviceValueKind.MdnsName, "rey.local")])),
            Device(B, Observation("192.0.2.11", lastSeenMinute: 20, values: Value(ReportedDeviceValueKind.MdnsName, "rey.local"))),
            Device(C, Observation("192.0.2.12", lastSeenMinute: 5, values: uuid)),
            Device("001122AA0004", Observation("192.0.2.13", lastSeenMinute: 30, values: Value(ReportedDeviceValueKind.MdnsName, "REY"))),
            Device("001122AA0005", Observation("192.0.2.14", lastSeenMinute: 1)));
        var adapters = new HashSet<string> { A, "001122AA0005" };

        var ordered = Find(data, adapters)[A];

        Assert.Equal(["001122AA0005", C, "001122AA0004", B], ordered.Select(item => item.OtherMac));
        Assert.Equal([DeviceMatchReason.LocalAdapters, DeviceMatchReason.SameDeviceId,
            DeviceMatchReason.SameName, DeviceMatchReason.SameName], ordered.Select(item => item.Reason));
    }

    [Fact]
    public void StrongerEvidenceReplacesWeakerEvidenceForThePair()
    {
        var data = Data(
            Device(A, Observation("192.0.2.10", values: [Value(ReportedDeviceValueKind.UpnpUuid, "u"), Value(ReportedDeviceValueKind.MdnsName, "rey")])),
            Device(B, Observation("192.0.2.11", values: [Value(ReportedDeviceValueKind.UpnpUuid, "u"), Value(ReportedDeviceValueKind.MdnsName, "rey")])));

        Assert.Equal(DeviceMatchReason.SameDeviceId, Assert.Single(Find(data)[B]).Reason);
    }

    [Fact]
    public void OnlyRecordsObservedOnTheSameIdentifiedNetworkAreCompared()
    {
        var fingOnly = new InventoryDevice(C, new ImportedDeviceMetadata(Name: "Rey"), []);
        var unidentified = Device("001122AA0004", Observation("192.0.2.13", network: null!) with { NetworkId = null })
            with { Imported = new ImportedDeviceMetadata(Name: "Rey") };
        var data = Data(
            Named(A, "192.0.2.10", ReportedDeviceValueKind.MdnsName, "rey.local"),
            Named(B, "192.0.2.11", ReportedDeviceValueKind.MdnsName, "rey.local", network: "work"),
            fingOnly, unidentified);

        Assert.Empty(Find(data, new HashSet<string> { A, B, C }));
    }

    [Fact]
    public void VirtualDevicesAndTheirGroupedMacsAreNeverSuggested()
    {
        const string privateMac = "02AABB000001";
        var observation = Observation("192.0.2.30", values: Value(ReportedDeviceValueKind.MdnsName, "rey.local"));
        var slot = new PrivateVirtualDevice(Guid.NewGuid(), "home", "192.0.2.0/24", "02AABB", 1, privateMac,
            Start.AddMinutes(10), true, [new(privateMac, observation, false)]);
        var data = Data(Named(A, "192.0.2.10", ReportedDeviceValueKind.MdnsName, "rey.local"), Device(privateMac, observation))
            with { VirtualDevices = [slot] };

        Assert.Empty(Find(data));
    }

    [Fact]
    public void VendorPrefixNearbyAddressesPortsAndRoomsAreNotEvidence()
    {
        var room = new ManagedRoom(Guid.NewGuid(), "Office", "O");
        var ports = new[] { new OpenPort(80, "HTTP") };
        var data = Data(
            Device(A, Observation("192.0.2.10") with { Ports = ports }),
            Device(B, Observation("192.0.2.11") with { Ports = ports }));
        data = data with { PeopleRooms = new PeopleRoomsData([], [room]).AssignRoom(A, room.Id).AssignRoom(B, room.Id) };

        Assert.Empty(Find(data));
    }

    [Fact]
    public void DeclinedPairsAreNeverSuggestedButOtherSuggestionsRemain()
    {
        var data = Data(
            Named(A, "192.0.2.10", ReportedDeviceValueKind.MdnsName, "rey.local"),
            Named(B, "192.0.2.11", ReportedDeviceValueKind.MdnsName, "rey.local"),
            Named(C, "192.0.2.12", ReportedDeviceValueKind.MdnsName, "rey.local"));

        var declined = data.DeclineMatch(B, A);
        var suggestions = Find(declined, new HashSet<string> { A, B });

        Assert.Equal(C, Assert.Single(suggestions[A]).OtherMac);
        Assert.Equal(C, Assert.Single(suggestions[B]).OtherMac);
        Assert.Equal(2, suggestions[C].Count);
        Assert.Same(declined, declined.DeclineMatch(A, B));
        Assert.Throws<ArgumentException>(() => data.DeclineMatch(A, A));
        Assert.Throws<ArgumentException>(() => data.DeclineMatch(A, "001122AA00FF"));
    }

    [Fact]
    public void LargeInventoriesAreGroupedRatherThanComparedPairwise()
    {
        var devices = Enumerable.Range(0, 30_000).Select(index =>
        {
            var mac = $"0011{index:X8}";
            var name = index % 1000 == 0 ? "shared-name.local" : $"device-name-{index}.local";
            return Named(mac, $"10.{index / 65536}.{index / 256 % 256}.{index % 256}", ReportedDeviceValueKind.MdnsName, name);
        }).ToArray();
        var data = Data(devices);
        var clock = Stopwatch.StartNew();

        var suggestions = Find(data);

        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(10), $"Suggestions took {clock.Elapsed}.");
        Assert.Equal(30, suggestions.Count);
        Assert.All(suggestions.Values, list => Assert.Equal(29, list.Count));
    }

    [Fact]
    public async Task DeclinedPairsPersistAcrossRestartsAndExistingInventoriesGainTheirTable()
    {
        var path = Path.Combine(_directory, "device-inventory.json");
        var store = new DeviceInventoryStore(path);
        var scanned = DeviceInventoryData.Empty.ObserveCompletedScan("home", new("192.0.2.0/24", Start,
            [Result("192.0.2.10", A), Result("192.0.2.11", B)]));
        var saved = await store.SaveAsync(scanned, Guid.Empty);
        Execute(path, "DROP TABLE declined_matches");

        var reopened = new DeviceInventoryStore(path);
        var loaded = (await reopened.LoadAsync())!;
        Assert.Empty(loaded.DeclinedMatches);
        await reopened.SaveAsync(loaded.DeclineMatch(B, A), loaded.Revision);

        var restarted = (await new DeviceInventoryStore(path).LoadAsync())!;
        Assert.Equal(DeclinedDeviceMatch.Create(A, B), Assert.Single(restarted.DeclinedMatches));
        Assert.NotEqual(saved.Revision, restarted.Revision);
    }

    [Theory]
    [InlineData("001122AA0002|001122AA0001", """{"firstMac":"001122AA0002","secondMac":"001122AA0001"}""")]
    [InlineData("001122AA0001|001122AA0003", """{"firstMac":"001122AA0001","secondMac":"001122AA0003"}""")]
    [InlineData("001122AA0001|001122AA0002", """{"firstMac":"001122AA0001","secondMac":"001122AA0002","x":1""")]
    [InlineData("other", """{"firstMac":"001122AA0001","secondMac":"001122AA0002"}""")]
    public async Task MalformedDeclinedPairsAreRejected(string id, string json)
    {
        var path = Path.Combine(_directory, "device-inventory.json");
        await new DeviceInventoryStore(path).SaveAsync(DeviceInventoryData.Empty.ObserveCompletedScan("home",
            new("192.0.2.0/24", Start, [Result("192.0.2.10", A), Result("192.0.2.11", B)])), Guid.Empty);
        Execute(path, "INSERT INTO declined_matches(id,data) VALUES($id,$data)", ("$id", id), ("$data", json));

        await Assert.ThrowsAsync<InvalidDataException>(() => new DeviceInventoryStore(path).LoadAsync());
    }

    private static ScanResult Result(string address, string mac) => new(IPAddress.Parse(address), HostStatus.Alive, 1,
        TimeSpan.FromMilliseconds(1), null, PhysicalAddress.Parse(mac), "Example");

    private static void Execute(string jsonPath, string sql, params (string Name, object Value)[] parameters)
    {
        using var connection = new SqliteConnection($"Data Source={Path.ChangeExtension(jsonPath, ".sqlite")};Pooling=False");
        connection.Open();
        using var command = connection.CreateCommand();
        command.CommandText = sql;
        foreach (var (name, value) in parameters) command.Parameters.AddWithValue(name, value);
        command.ExecuteNonQuery();
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory)) Directory.Delete(_directory, recursive: true);
    }
}
