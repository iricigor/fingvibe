using System.Net;
using System.Net.NetworkInformation;
using System.Text.Json;
using FingVibe.App;
using FingVibe.Core.Import;
using FingVibe.Core.Models;
using FingVibe.Core.Storage;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class DeviceDetailsPresentationTests
{
    private const string Mac = "001122334455";
    private static readonly DateTimeOffset Now = new(2026, 11, 4, 12, 0, 0, TimeSpan.Zero);
    private static readonly DeviceClassificationOverride Choices = new(
        DeviceOperatingSystem.Android, DeviceType.Phone, DeviceType.Tablet, "Brand", "Family", "Model");

    [Theory]
    [InlineData(80, "http://192.0.2.1/", "Open HTTP")]
    [InlineData(443, "https://192.0.2.1/", "Open HTTPS")]
    [InlineData(8080, "http://192.0.2.1:8080/", "Try HTTP")]
    [InlineData(8443, "https://192.0.2.1:8443/", "Try HTTPS")]
    public void BrowserLinks_UseOnlyConfirmedCurrentTcpEndpoints(int number, string uri, string label)
    {
        var port = new OpenPort(number, "Unverified product");
        var result = Result() with { OpenPorts = [port] };
        var row = new ScanResultRow(result, 24);
        var endpoint = DeviceDetailsPresentation.Endpoint(row, port);
        Assert.Equal(uri, endpoint.BrowserUri!.AbsoluteUri);
        Assert.Equal(label, endpoint.BrowserLabel);
        Assert.Equal($"192.0.2.1:{number}", endpoint.Value);
        Assert.Equal(port.AccessibleLabel, endpoint.AccessibleLabel);
        Assert.Null(DeviceDetailsPresentation.Endpoint(new(result, 24, historical: true), port).BrowserUri);
        Assert.Null(DeviceDetailsPresentation.Endpoint(new(result with { Status = HostStatus.Unreachable }, 24), port).BrowserUri);
        Assert.Null(DeviceDetailsPresentation.Endpoint(new(Result(), 24), port).BrowserUri);
        Assert.Null(DeviceDetailsPresentation.Endpoint(row, port with { Protocol = EndpointProtocol.Udp }).BrowserUri);
    }

    [Theory]
    [InlineData(22)]
    [InlineData(445)]
    [InlineData(3389)]
    [InlineData(1883)]
    [InlineData(123)]
    public void NonWebPorts_NeverHaveBrowserActions(int number)
    {
        var port = new OpenPort(number, "Service");
        var row = new ScanResultRow(Result() with { OpenPorts = [port] }, 24);
        Assert.False(DeviceDetailsPresentation.Endpoint(row, port).HasBrowserAction);
    }

    [Fact]
    public void BrowserLinks_FollowSelectedCurrentAddressAndItsOwnPorts()
    {
        var port = new OpenPort(8443, "HTTPS alternate");
        var data = DeviceInventoryData.Empty.ObserveCompletedScan("network", new(
            "192.0.2.0/24", Now, [Result() with { OpenPorts = [port] },
                Result() with { Address = IPAddress.Parse("192.0.2.2"), OpenPorts = [port] }]));
        var row = new ScanResultRow(data.Devices[Mac], 24, historical: false);
        row.SelectAddress("192.0.2.2");
        Assert.Equal("https://192.0.2.2:8443/", DeviceDetailsPresentation.Endpoint(row, port).BrowserUri!.AbsoluteUri);
    }

    [Theory]
    [InlineData(null, false)]
    [InlineData("", false)]
    [InlineData(" ", false)]
    [InlineData("-", false)]
    [InlineData("Unknown", false)]
    [InlineData("Unknown (likely)", false)]
    [InlineData("192.0.2.1", true)]
    [InlineData("Example device", true)]
    public void CopyValues_ExcludeMissingPlaceholders(string? value, bool expected) =>
        Assert.Equal(expected, DeviceDetailsPresentation.CanCopy(value));

    [Fact]
    public void ImportedFields_ArePopulatedOnlyAndAddressIsExplicitlyHistorical()
    {
        Assert.Empty(DeviceDetailsPresentation.ImportedFields(null));
        Assert.Empty(DeviceDetailsPresentation.ImportedFields(new()));
        var fields = DeviceDetailsPresentation.ImportedFields(new(Brand: "Original", Family: "-", Model: " ",
            OperatingSystemVersion: "1.2", Address: "192.0.2.9"));
        Assert.Equal(["Original", "1.2", "192.0.2.9"], fields.Select(item => item.Value));
        Assert.Contains("Historical imported IP", fields[^1].Label);
        Assert.Equal("Unknown", Assert.Single(DeviceDetailsPresentation.ImportedFields(new(Type: "Unknown"))).Value);
    }

    [Fact]
    public void Metadata_OverridesImportAndResetRestoresUntouchedEvidence()
    {
        var imported = new ImportedDeviceMetadata(Brand: "Imported brand", Family: "Imported family", Model: "Imported model");
        var data = DeviceInventoryData.Empty with
        {
            Devices = new Dictionary<string, InventoryDevice> { [Mac] = new(Mac, imported, []) }
        };
        var row = new ScanResultRow(data.Devices[Mac], 24);
        row.SetClassificationOverride(Choices);
        Assert.Equal(("Brand", "Family", "Model"), (row.BrandText, row.FamilyText, row.ModelText));
        Assert.Equal("Brand", row.VendorText);
        Assert.Contains("Saved", row.ModelSource);
        Assert.True(row.MatchesFilter("Family"));
        Assert.Equal(imported, row.ImportedMetadata);
        row.SetClassificationOverride(new(Brand: "Other"));
        Assert.Equal("Imported family", row.FamilyText);
        row.SetClassificationOverride(null);
        Assert.Equal(("Imported brand", "Imported family", "Imported model"), (row.BrandText, row.FamilyText, row.ModelText));
        Assert.Contains("Fing", row.BrandSource);
        Assert.Equal(imported, row.ImportedMetadata);
    }

    [Fact]
    public void LegacyChoices_RemainCompatibleAndMetadataOnlyChoicesAreNotEmpty()
    {
        var legacy = JsonSerializer.Deserialize<DeviceClassificationOverride>("""{"Type":1}""");
        Assert.NotNull(legacy);
        Assert.Null(legacy.Brand);
        Assert.False(new DeviceClassificationOverride(Brand: "Brand").IsEmpty);
        Assert.True(new DeviceClassificationOverride().IsEmpty);
        Assert.False(new DeviceClassificationOverride(Model: " ").HasValidValues());
    }

    [Fact]
    public async Task Inventory_RoundTripsOrdinaryAndVirtualMetadataAndProtectsFailedWrites()
    {
        var path = Path.Combine(Path.GetTempPath(), $"fingvibe-details-{Guid.NewGuid():N}", "inventory.json");
        var store = new DeviceInventoryStore(path);
        try
        {
            var data = DeviceInventoryData.Empty.ObserveCompletedScan("network", new("192.0.2.0/24", Now,
                [Result(), Result() with { MacAddress = PhysicalAddress.Parse("D0C907000001"), VendorName = "Private",
                    Address = IPAddress.Parse("192.0.2.2") }]));
            data = data with
            {
                Classifications = new Dictionary<string, DeviceClassificationOverride> { [Mac] = Choices },
                VirtualDevices = data.VirtualDevices.Select(slot => slot with { Classification = Choices }).ToArray()
            };
            var saved = await store.SaveAsync(data, Guid.Empty);
            var loaded = Assert.IsType<DeviceInventoryData>(await store.LoadAsync());
            Assert.Equal(Choices, loaded.Classifications[Mac]);
            Assert.Equal(Choices, Assert.Single(loaded.VirtualDevices).Classification);
            Assert.Equal("Family", new ScanResultRow(loaded.VirtualDevices[0], loaded, 24).FamilyText);
            var bad = saved with { Classifications = new Dictionary<string, DeviceClassificationOverride> { [Mac] = new(Model: " ") } };
            await Assert.ThrowsAsync<InvalidDataException>(() => store.SaveAsync(bad, saved.Revision));
            Assert.Equal(Choices, (await store.LoadAsync())!.Classifications[Mac]);
            var reset = saved with
            {
                Classifications = new Dictionary<string, DeviceClassificationOverride>(),
                VirtualDevices = saved.VirtualDevices.Select(slot => slot with { Classification = null }).ToArray()
            };
            await store.SaveAsync(reset, saved.Revision);
            Assert.Empty((await store.LoadAsync())!.Classifications);
            Assert.Null(Assert.Single((await store.LoadAsync())!.VirtualDevices).Classification);
        }
        finally
        {
            if (File.Exists(path)) File.Delete(path);
            if (File.Exists(path + ".lock")) File.Delete(path + ".lock");
            if (Directory.Exists(Path.GetDirectoryName(path))) Directory.Delete(Path.GetDirectoryName(path)!);
        }
    }

    [Fact]
    public void ImportingOriginalMetadata_PreservesManualMetadataCorrections()
    {
        var data = DeviceInventoryData.Empty with
        {
            Devices = new Dictionary<string, InventoryDevice> { [Mac] = new(Mac, new(), []) },
            Classifications = new Dictionary<string, DeviceClassificationOverride> { [Mac] = Choices }
        };
        var export = new FingExport([new(2, Mac, new(Brand: "Incoming", Model: "Incoming model"), null, null)], [], 1);
        var imported = FingImportAnalyzer.Analyze(export, data).Updated;
        Assert.Equal(Choices, imported.Classifications[Mac]);
        Assert.Equal("Incoming", imported.Devices[Mac].Imported.Brand);
    }

    private static ScanResult Result() => new(IPAddress.Parse("192.0.2.1"), HostStatus.Alive, 1,
        TimeSpan.FromMilliseconds(2), MacAddress: PhysicalAddress.Parse(Mac));
}
