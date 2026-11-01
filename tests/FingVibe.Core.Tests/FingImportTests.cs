using System.IO.Compression;
using System.Net;
using System.Net.NetworkInformation;
using System.Xml.Linq;
using System.Text.Json.Nodes;
using FingVibe.App;
using FingVibe.Core.Import;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class FingImportTests
{
    private const string Mac = "001122334455";
    private static readonly DateTimeOffset Start = new(2026, 10, 1, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void Workbook_ReadsFingSchemaSharedStringsAndUnicodeWithoutImportingEvents()
    {
        using var workbook = Workbook(
            ["MAC", "IP", "State", "Name", "Location", "Group", "Type", "Brand", "Family", "Model", "OS", "OS Version", "Owner", "Last change", "First seen", "Hostname", "Alerted"],
            [Mac, "192.0.2.4", "UP", "\uD83C\uDFE0 Living room", "Bedroom", "Do not import", "Smart Cleaner", "Example", "Series", "Model", "Android", "14", "Alice", "yesterday", "last year", "device.local", "true"]);
        var export = FingWorkbookReader.Read(workbook);
        var device = Assert.Single(export.Devices);
        Assert.Equal(Mac, device.Mac);
        Assert.Equal("\uD83C\uDFE0 Living room", device.Metadata.Name);
        Assert.Equal("device.local", device.Metadata.Hostname);
        Assert.Equal("Alice", device.Owner);
        Assert.Equal("Bedroom", device.Location);
        Assert.Equal("14", device.Metadata.OperatingSystemVersion);
        Assert.Contains(export.Warnings, warning => warning.Contains("timestamps"));
    }

    [Fact]
    public void Workbook_SkipsAllDuplicateMacsInvalidAndFormulaRecordsButRetainsIpCollisions()
    {
        using var workbook = Workbook(["MAC", "IP", "Name"],
            [Mac, "192.0.2.1", "Duplicate 1"],
            ["00-11-22-33-44-55", "192.0.2.2", "Duplicate 2"],
            ["not a MAC", "192.0.2.3", "Invalid"],
            ["020000000001", "192.0.2.5", "Private"],
            ["001122334456", "192.0.2.5", "Same IP"],
            ["001122334457", "invalid address", "No IP"]);
        var export = FingWorkbookReader.Read(workbook);
        Assert.Equal(3, export.Devices.Count);
        Assert.Equal(6, export.DeviceRows);
        Assert.Equal(2, export.Devices.Count(device => device.Metadata.Address == "192.0.2.5"));
        Assert.Null(export.Devices[^1].Metadata.Address);
        Assert.Contains(export.Warnings, warning => warning.Contains("duplicate MAC"));
        Assert.Contains(export.Warnings, warning => warning.Contains("private/randomized"));
        Assert.Contains(export.Warnings, warning => warning.Contains("invalid IPv4"));
    }

    [Fact]
    public void Workbook_RejectsMissingOrDuplicateHeadersAndMalformedZip()
    {
        using var missing = Workbook(["Name"], ["Device"]);
        Assert.Throws<InvalidDataException>(() => FingWorkbookReader.Read(missing));
        using var duplicate = Workbook(["MAC", "MAC"], [Mac, Mac]);
        Assert.Throws<InvalidDataException>(() => FingWorkbookReader.Read(duplicate));
        using var invalid = new MemoryStream([1, 2, 3]);
        Assert.Throws<InvalidDataException>(() => FingWorkbookReader.Read(invalid));
    }

    [Fact]
    public void Workbook_DoesNotEvaluateOrTrustCachedFormulaValues()
    {
        using var stream = Workbook(["MAC", "Name"], [Mac, "Cached value"], formula: true);
        var export = FingWorkbookReader.Read(stream);
        Assert.Empty(export.Devices);
        Assert.Contains(export.Warnings, warning => warning.Contains("formulas"));
    }

    [Fact]
    public void Analysis_IsReadOnlyKeepsCustomizationsAndRequiresPerFieldReplacement()
    {
        var person = new ManagedPerson(Guid.NewGuid(), "Alice", "A");
        var previousPerson = new ManagedPerson(Guid.NewGuid(), "Bob", "B");
        var data = Observe(DeviceInventoryData.Empty) with
        {
            Names = new Dictionary<string, string> { [Mac] = "My name" },
            Classifications = new Dictionary<string, DeviceClassificationOverride>
            {
                [Mac] = new(DeviceOperatingSystem.Windows, DeviceType.Computer, DeviceType.Printer)
            },
            PeopleRooms = new PeopleRoomsData([person, previousPerson]).AssignPerson(Mac, previousPerson.Id)
        };
        var export = Export(new(Name: "Incoming", Hostname: "import.local", Type: "Mobile", OperatingSystem: "Android"), owner: " alice ");
        var kept = FingImportAnalyzer.Analyze(export, data);
        Assert.Equal("My name", data.Names[Mac]);
        Assert.Equal("My name", kept.Updated.Names[Mac]);
        Assert.Equal("Mobile", kept.Updated.Devices[Mac].Imported.Type);
        Assert.Equal(DeviceType.Computer, kept.Updated.Classifications[Mac].Type);
        Assert.Equal(previousPerson.Id, kept.Updated.PeopleRooms.Assignments[Mac].PersonId);
        Assert.Contains(kept.Changes, change => change.Field == "Name" && change.Current == "My name" && !change.Apply);
        Assert.Contains(kept.Changes, change => change.Field == "Person" && change.Current == "Bob" && !change.Apply);
        var replaced = FingImportAnalyzer.Analyze(export, data, new HashSet<string>
        {
            $"{Mac}:Name", $"{Mac}:Person", $"{Mac}:Device type correction", $"{Mac}:OS correction"
        });
        Assert.False(replaced.Updated.Names.ContainsKey(Mac));
        Assert.Equal("Incoming", replaced.Updated.Devices[Mac].Imported.Name);
        Assert.Equal(person.Id, replaced.Updated.PeopleRooms.Assignments[Mac].PersonId);
        Assert.Null(replaced.Updated.Classifications[Mac].Type);
        Assert.Null(replaced.Updated.Classifications[Mac].OperatingSystem);
        Assert.Equal(DeviceType.Printer, replaced.Updated.Classifications[Mac].Icon);
        Assert.Equal(data.Revision, replaced.Revision);
    }

    [Fact]
    public void MissingAndAmbiguousAssignmentsSkipOnlyThatFieldAndMatchAfterReanalysis()
    {
        var data = DeviceInventoryData.Empty;
        var export = Export(new(Name: "Device", Model: "Model"), owner: "Alice", location: "Bedroom");
        var missing = FingImportAnalyzer.Analyze(export, data);
        Assert.Equal(1, missing.Added);
        Assert.Equal("Device", missing.Updated.Devices[Mac].Imported.Name);
        Assert.Empty(missing.Updated.PeopleRooms.People);
        Assert.Empty(missing.Updated.PeopleRooms.Rooms);
        Assert.Equal(2, missing.Changes.Count(change => change.SkipReason is not null));
        var alice = new ManagedPerson(Guid.NewGuid(), "Alice", "A");
        var room = new ManagedRoom(Guid.NewGuid(), "Bedroom", "BR");
        var updated = data with { PeopleRooms = new PeopleRoomsData([alice], [room]) };
        var matched = FingImportAnalyzer.Analyze(export, updated);
        Assert.Equal(alice.Id, matched.Updated.PeopleRooms.Assignments[Mac].PersonId);
        Assert.Equal(room.Id, matched.Updated.PeopleRooms.Assignments[Mac].RoomId);
        var ambiguous = updated with { PeopleRooms = new PeopleRoomsData([alice, new(Guid.NewGuid(), "Alice", "AA")], [room]) };
        var skipped = FingImportAnalyzer.Analyze(export, ambiguous);
        Assert.Null(skipped.Updated.PeopleRooms.Assignments[Mac].PersonId);
        Assert.Equal(room.Id, skipped.Updated.PeopleRooms.Assignments[Mac].RoomId);
    }

    [Fact]
    public void BlankFieldsNeverClearMetadataOrAssignmentsAndGroupsAreNotAssignments()
    {
        var person = new ManagedPerson(Guid.NewGuid(), "Alice", "A");
        var data = FingImportAnalyzer.Analyze(Export(new(Name: "Saved", Hostname: "host", Type: "Controller")), DeviceInventoryData.Empty).Updated with
        {
            PeopleRooms = new PeopleRoomsData([person]).AssignPerson(Mac, person.Id)
        };
        var analysis = FingImportAnalyzer.Analyze(Export(new()), data);
        Assert.False(analysis.CanImport);
        Assert.Equal("Saved", analysis.Updated.Devices[Mac].Imported.Name);
        Assert.Equal(person.Id, analysis.Updated.PeopleRooms.Assignments[Mac].PersonId);
        Assert.Empty(analysis.Changes);
    }

    [Fact]
    public void UnmappedTypeAndOsAreRetainedWithWarningsAndNeverManufactureObservations()
    {
        var analysis = FingImportAnalyzer.Analyze(Export(new(Type: "Unmapped gadget", OperatingSystem: "Unmapped OS", Address: "192.0.2.10")),
            DeviceInventoryData.Empty);
        var device = analysis.Updated.Devices[Mac];
        Assert.Equal("Unmapped gadget", device.Imported.Type);
        Assert.Equal("Unmapped OS", device.Imported.OperatingSystem);
        Assert.Contains(analysis.Warnings, warning => warning.Contains("no reliable"));
        Assert.Empty(device.Observations);
        Assert.Equal(InventoryDeviceStatus.FingOnly, device.Status);
        var row = new ScanResultRow(device, 0);
        Assert.Null(row.Result);
        Assert.False(row.IsOnline);
        Assert.False(row.IsOffline);
        Assert.Equal("Fing Only", row.StatusLabel);
        Assert.False(row.CanProbe);
        Assert.True(row.MatchesFilter("Unmapped gadget"));
    }

    [Fact]
    public void StatusTransitionsRequireSuccessfulSameNetworkScanAndPreserveHistoricalIp()
    {
        var data = FingImportAnalyzer.Analyze(Export(new(Address: "192.0.2.99")), DeviceInventoryData.Empty).Updated;
        Assert.Equal(InventoryDeviceStatus.FingOnly, data.Devices[Mac].Status);
        data = Observe(data);
        Assert.Equal(InventoryDeviceStatus.Online, data.Devices[Mac].Status);
        var different = data.ObserveCompletedScan("another-network", new("192.0.2.0/24", Start.AddMinutes(1), []));
        Assert.Equal(InventoryDeviceStatus.Online, different.Devices[Mac].Status);
        var unknownNetwork = data.ObserveCompletedScan(null, new("192.0.2.0/24", Start.AddMinutes(1), []));
        Assert.Equal(InventoryDeviceStatus.Online, unknownNetwork.Devices[Mac].Status);
        var differentSubnet = data.ObserveCompletedScan("network", new("198.51.100.0/24", Start.AddMinutes(1), []));
        Assert.Equal(InventoryDeviceStatus.Online, differentSubnet.Devices[Mac].Status);
        var absent = data.ObserveCompletedScan("network", new("192.0.2.0/24", Start.AddMinutes(2), []));
        Assert.Equal(InventoryDeviceStatus.Offline, absent.Devices[Mac].Status);
        Assert.Equal("192.0.2.1", absent.Devices[Mac].LatestObservation!.Address);
        Assert.Equal("192.0.2.99", absent.Devices[Mac].Imported.Address);
        Assert.Equal(Start, absent.Devices[Mac].LatestObservation!.LastSeen);
        Assert.Equal(Start.AddMinutes(2), absent.Devices[Mac].LatestObservation!.LastChecked);
    }

    [Fact]
    public void HistoricalRestoreDoesNotInferAbsenceOrFreshPresence()
    {
        var data = Observe(DeviceInventoryData.Empty);
        var restored = data.ObserveCompletedScan("network", new("192.0.2.0/24", Start.AddMinutes(1), []), historical: true);
        Assert.Equal(InventoryDeviceStatus.Online, restored.Devices[Mac].Status);
        var row = new ScanResultRow(restored.Devices[Mac], 24);
        Assert.True(row.IsHistorical);
        Assert.False(row.IsCurrentScanResponse);
        Assert.False(row.CanProbe);
        Assert.Contains("historical", row.StatusContext);
        var anotherScan = new ScanResultRow(restored.Devices[Mac], 24, showLatency: false);
        Assert.False(anotherScan.HasLatency);
        Assert.Null(anotherScan.LatencyMilliseconds);
    }

    [Fact]
    public void DisplayNameSeparatesNameAndLocalAndImportedHostnamesAndIp()
    {
        var imported = new InventoryDevice(Mac, new(Name: "\uD83D\uDE00 Name", Hostname: "imported.local", Address: "192.0.2.2"), []);
        Assert.Equal("\uD83D\uDE00 Name", new ScanResultRow(imported, 0).NameText);
        Assert.Equal("User name", new ScanResultRow(imported, 0, "User name").NameText);
        var hostnameOnly = imported with { Imported = imported.Imported with { Name = null } };
        Assert.Equal("imported.local", new ScanResultRow(hostnameOnly, 0).NameText);
        var ipOnly = imported with { Imported = new(Address: "192.0.2.2") };
        Assert.Equal("192.0.2.2", new ScanResultRow(ipOnly, 0).NameText);
        Assert.Equal(0.65, new ScanResultRow(ipOnly, 0).NameOpacity);
        var data = Observe(DeviceInventoryData.Empty);
        var observed = data.Devices[Mac] with { Imported = hostnameOnly.Imported };
        var row = new ScanResultRow(observed, 24);
        Assert.Equal("local.local", row.NameText);
        Assert.Equal("local.local", row.HostnameText);
    }

    [Fact]
    public void StatusFilteringAndPeopleRoomsIncludeFingOnlyWithoutLiveCounts()
    {
        var imported = new ScanResultRow(new InventoryDevice(Mac, new(Name: "Imported"), []), 0);
        var online = new ScanResultRow(Observe(DeviceInventoryData.Empty).Devices[Mac], 24, historical: false);
        Assert.True(new DeviceResultFilter(false, false, "", Status: InventoryDeviceStatus.FingOnly).Matches(imported));
        Assert.False(new DeviceResultFilter(false, false, "", Status: InventoryDeviceStatus.Online).Matches(imported));
        Assert.True(new DeviceResultFilter(false, false, "", Status: InventoryDeviceStatus.Online).Matches(online));
        var assigned = new AssignedDeviceListRow(Mac, imported);
        Assert.Equal("Fing Only", assigned.StatusText);
        Assert.Equal("Imported", assigned.NameText);
        Assert.False(imported.IsCurrentScanResponse);
    }

    [Fact]
    public async Task AtomicInventoryCommitSurvivesRestartAndRejectsStalePreview()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"fingvibe-import-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        try
        {
            var path = Path.Combine(directory, "inventory.json");
            var store = new DeviceInventoryStore(path);
            Assert.Null(await store.LoadAsync());
            var initial = Observe(DeviceInventoryData.Empty) with
            {
                Names = new Dictionary<string, string> { [Mac] = "Legacy name" },
                Classifications = new Dictionary<string, DeviceClassificationOverride> { [Mac] = new(Type: DeviceType.Printer) },
                PeopleRooms = new PeopleRoomsData(
                    [new(Guid.Parse("00000000-0000-0000-0000-000000000001"), "Alice", "A")],
                    [new(Guid.Parse("00000000-0000-0000-0000-000000000002"), "Bedroom", "BR")])
                    .AssignPerson(Mac, Guid.Parse("00000000-0000-0000-0000-000000000001"))
                    .AssignRoom(Mac, Guid.Parse("00000000-0000-0000-0000-000000000002"))
            };
            var saved = await store.SaveAsync(initial, Guid.Empty);
            var analysis = FingImportAnalyzer.Analyze(Export(new(Name: "Incoming", Model: "\uD83D\uDE00 Model", Hostname: "imported.local")), saved);
            var committed = await store.SaveAsync(analysis.Updated, analysis.Revision);
            var restored = await new DeviceInventoryStore(path).LoadAsync();
            Assert.Equal(committed.Revision, restored!.Revision);
            Assert.Equal("Legacy name", restored.Names[Mac]);
            Assert.Equal(DeviceType.Printer, restored.Classifications[Mac].Type);
            Assert.Equal(Start, restored.Devices[Mac].LatestObservation!.FirstSeen);
            Assert.Equal("\uD83D\uDE00 Model", restored.Devices[Mac].Imported.Model);
            Assert.Equal(initial.PeopleRooms.Assignments[Mac], restored.PeopleRooms.Assignments[Mac]);
            Assert.Equal(initial.PeopleRooms.People[0], restored.PeopleRooms.People[0]);
            Assert.Equal(initial.PeopleRooms.Rooms[0], restored.PeopleRooms.Rooms[0]);
            await Assert.ThrowsAsync<InvalidOperationException>(() => store.SaveAsync(analysis.Updated, analysis.Revision));
            Assert.Equal(committed.Revision, (await store.LoadAsync())!.Revision);
            Assert.Empty(Directory.GetFiles(directory, "*.tmp"));
        }
        finally
        {
            File.Delete(Path.Combine(directory, "inventory.json"));
            File.Delete(Path.Combine(directory, "inventory.json.lock"));
            Directory.Delete(directory);
        }
    }

    [Theory]
    [InlineData("people")]
    [InlineData("rooms")]
    [InlineData("assignments")]
    public async Task IncompletePeopleRoomsInInventoryFailsClosed(string missingField)
    {
        var directory = Path.Combine(Path.GetTempPath(), $"fingvibe-incomplete-inventory-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "inventory.json");
        try
        {
            var store = new DeviceInventoryStore(path);
            await store.SaveAsync(DeviceInventoryData.Empty, Guid.Empty);
            var document = JsonNode.Parse(await File.ReadAllTextAsync(path))!;
            document["data"]!["peopleRooms"]!.AsObject().Remove(missingField);
            var broken = document.ToJsonString();
            await File.WriteAllTextAsync(path, broken);
            await Assert.ThrowsAsync<InvalidDataException>(() => store.LoadAsync());
            await Assert.ThrowsAsync<InvalidDataException>(() => store.SaveAsync(DeviceInventoryData.Empty, Guid.Empty));
            Assert.Equal(broken, await File.ReadAllTextAsync(path));
        }
        finally
        {
            File.Delete(path);
            File.Delete(path + ".lock");
            Directory.Delete(directory);
        }
    }

    [Fact]
    public void UnmappedImportDoesNotHideInferredAutomaticFallbackAndBlankHostnameFallsBack()
    {
        var data = Observe(DeviceInventoryData.Empty);
        var device = data.Devices[Mac] with
        {
            Imported = new(Type: "Controller", OperatingSystem: "Unmapped OS", Hostname: "import.local"),
            Observations = data.Devices[Mac].Observations.Select(observation => observation with
            {
                Hostname = "",
                Classification = new(DeviceOperatingSystem.Linux, DeviceType.SmartDevice,
                    OperatingSystemIsInferred: true, TypeIsInferred: true)
            }).ToArray()
        };
        var row = new ScanResultRow(device, 24);
        Assert.Equal("import.local", row.HostnameText);
        Assert.Equal("Linux (likely)", row.OperatingSystemText);
        Assert.Equal("IoT/smart device (likely)", row.DeviceTypeText);
        Assert.Contains("unmapped", row.OperatingSystemSource);
        Assert.Contains("automatic category", row.DeviceTypeSource);
    }

    [Fact]
    public async Task InvalidInventoryIsNotOverwritten()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"fingvibe-invalid-inventory-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "inventory.json");
        try
        {
            await File.WriteAllTextAsync(path, "{\"version\":999}");
            var store = new DeviceInventoryStore(path);
            await Assert.ThrowsAsync<InvalidDataException>(() => store.LoadAsync());
            await Assert.ThrowsAsync<InvalidDataException>(() => store.SaveAsync(DeviceInventoryData.Empty, Guid.Empty));
            Assert.Equal("{\"version\":999}", await File.ReadAllTextAsync(path));
        }
        finally
        {
            File.Delete(path);
            File.Delete(path + ".lock");
            Directory.Delete(directory);
        }
    }

    private static DeviceInventoryData Observe(DeviceInventoryData data) => data.ObserveCompletedScan("network",
        new ScanSnapshot("192.0.2.0/24", Start,
            [new(IPAddress.Parse("192.0.2.1"), HostStatus.Alive, 1, TimeSpan.FromMilliseconds(1),
                "local.local", PhysicalAddress.Parse(Mac))]));

    private static FingExport Export(ImportedDeviceMetadata metadata, string? owner = null, string? location = null) =>
        new([new(2, Mac, metadata, owner, location)], [], 1);

    private static MemoryStream Workbook(string[] headers, params string[][] values) => Workbook(headers, values, false);

    private static MemoryStream Workbook(string[] headers, string[] values, bool formula) => Workbook(headers, [values], formula);

    private static MemoryStream Workbook(string[] headers, string[][] values, bool formula)
    {
        XNamespace spreadsheet = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
        XNamespace relationships = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
        var strings = headers.Concat(values.SelectMany(row => row)).Distinct().ToArray();
        var rows = new[] { headers }.Concat(values).Select((row, index) =>
            new XElement(spreadsheet + "row", new XAttribute("r", index + 1),
                row.Select((value, column) => new XElement(spreadsheet + "c",
                    new XAttribute("r", $"{(char)('A' + column)}{index + 1}"), new XAttribute("t", "s"),
                    formula && index == 1 && column == 1 ? new XElement(spreadsheet + "f", "CONCAT(\"cached\")") : null,
                    new XElement(spreadsheet + "v", Array.IndexOf(strings, value))))));
        var stream = new MemoryStream();
        using (var zip = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true))
        {
            Write("xl/workbook.xml", new XElement(spreadsheet + "workbook",
                new XElement(spreadsheet + "sheets", new XElement(spreadsheet + "sheet",
                    new XAttribute("name", "Devices"), new XAttribute(relationships + "id", "device-sheet")))));
            Write("xl/_rels/workbook.xml.rels", new XElement("Relationships",
                new XElement("Relationship", new XAttribute("Id", "device-sheet"), new XAttribute("Target", "worksheets/sheet3.xml"))));
            Write("xl/sharedStrings.xml", new XElement(spreadsheet + "sst",
                strings.Select(value => new XElement(spreadsheet + "si", new XElement(spreadsheet + "t", value)))));
            Write("xl/worksheets/sheet3.xml", new XElement(spreadsheet + "worksheet", new XElement(spreadsheet + "sheetData", rows)));
            void Write(string name, XElement xml)
            {
                using var writer = new StreamWriter(zip.CreateEntry(name).Open());
                writer.Write(xml.ToString());
            }
        }
        stream.Position = 0;
        return stream;
    }
}
