using System.Net;
using System.Xml.Linq;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class DeviceClassifierTests
{
    [Theory]
    [InlineData("Windows/10.0 UPnP/1.0", DeviceOperatingSystem.Windows)]
    [InlineData("Linux/4.9 Android/12 UPnP/1.0", DeviceOperatingSystem.Android)]
    [InlineData("Linux/5.0 UPnP/1.0", DeviceOperatingSystem.Linux)]
    [InlineData("macOS/14.0 UPnP/1.0", DeviceOperatingSystem.MacOS)]
    [InlineData("Mac OS X/10.15 UPnP/1.0", DeviceOperatingSystem.MacOS)]
    [InlineData("iOS/17.0", DeviceOperatingSystem.IOS)]
    [InlineData("iPadOS/18.0", DeviceOperatingSystem.IOS)]
    [InlineData("Darwin/23", DeviceOperatingSystem.Unknown)]
    [InlineData("NotWindowsDevice", DeviceOperatingSystem.Unknown)]
    [InlineData("Linux Windows", DeviceOperatingSystem.Unknown)]
    public void OsDetection_RequiresExplicitTokensAndRejectsConflicts(string server, DeviceOperatingSystem expected)
    {
        var result = DeviceClassifier.Classify(new(null, null, null, null, server), null);
        Assert.Equal(expected, result.OperatingSystem);
        Assert.NotEmpty(result.OperatingSystemEvidence);
    }

    [Theory]
    [InlineData("InternetGatewayDevice", DeviceType.Router)]
    [InlineData("WANDevice", DeviceType.Router)]
    [InlineData("Printer", DeviceType.Printer)]
    [InlineData("MediaRenderer", DeviceType.MediaDevice)]
    [InlineData("MediaServer", DeviceType.Unknown)]
    [InlineData("DimmableLight", DeviceType.SmartDevice)]
    public void DeviceDetection_UsesAdvertisedUpnpType(string type, DeviceType expected)
    {
        var result = DeviceClassifier.Classify(new(null, $"urn:schemas-upnp-org:device:{type}:1",
            null, null, null), null);
        Assert.Equal(expected, result.Type);
    }

    [Theory]
    [InlineData("_ipp._tcp.local", DeviceType.Printer)]
    [InlineData("_ipps._tcp.local", DeviceType.Printer)]
    [InlineData("_googlecast._tcp.local", DeviceType.MediaDevice)]
    [InlineData("_hap._tcp.local", DeviceType.SmartDevice)]
    [InlineData("_airplay._tcp.local", DeviceType.Unknown)]
    [InlineData("_smb._tcp.local", DeviceType.Unknown)]
    [InlineData("_ssh._tcp.local", DeviceType.Unknown)]
    public void Services_AreDeviceCluesNotOsProof(string service, DeviceType expected)
    {
        var result = DeviceClassifier.Classify(null, new([service]));
        Assert.Equal(expected, result.Type);
        Assert.Equal(DeviceOperatingSystem.Unknown, result.OperatingSystem);
    }

    [Theory]
    [InlineData("iPhone15,2", DeviceType.Phone, DeviceOperatingSystem.IOS)]
    [InlineData("iPad13,4", DeviceType.Tablet, DeviceOperatingSystem.IOS)]
    [InlineData("MacBookPro18,1", DeviceType.Computer, DeviceOperatingSystem.MacOS)]
    [InlineData("Macmini9,1", DeviceType.Computer, DeviceOperatingSystem.MacOS)]
    [InlineData("AppleTV6,2", DeviceType.MediaDevice, DeviceOperatingSystem.Unknown)]
    [InlineData("Apple", DeviceType.Unknown, DeviceOperatingSystem.Unknown)]
    public void AdvertisedModel_ProvidesSpecificButBestEffortIdentification(
        string model, DeviceType type, DeviceOperatingSystem os)
    {
        var result = DeviceClassifier.Classify(null, new([], model));
        Assert.Equal(type, result.Type);
        Assert.Equal(os, result.OperatingSystem);
    }

    [Fact]
    public void VendorNameAndHostname_DoNotDetermineClassification()
    {
        var result = DeviceClassifier.Classify(new("Windows Android Linux MacBook iPhone",
            null, "Apple Samsung Microsoft", "Printer", null), null);
        Assert.Equal(DeviceClassification.Unknown, result);
    }

    [Fact]
    public void StrongerDeviceTypeOutweighsServiceClue()
    {
        var result = DeviceClassifier.Classify(new(null, "urn:schemas-upnp-org:device:Printer:1",
            null, null, null), new(["_googlecast._tcp.local"]));
        Assert.Equal(DeviceType.Printer, result.Type);
        Assert.Contains("UPnP", result.TypeEvidence);
    }

    [Fact]
    public void ConflictingServicesAndOs_RemainUnknownWithEvidence()
    {
        var result = DeviceClassifier.Classify(new(null, null, null, null, "Windows/10"),
            new(["_ipp._tcp.local", "_googlecast._tcp.local"], "MacBookPro18,1"));
        Assert.Equal(DeviceOperatingSystem.Unknown, result.OperatingSystem);
        Assert.Contains("Conflicting", result.OperatingSystemEvidence);
        Assert.Equal(DeviceType.Computer, result.Type);

        result = DeviceClassifier.Classify(null, new(["_ipp._tcp.local", "_googlecast._tcp.local"]));
        Assert.Equal(DeviceType.Unknown, result.Type);
        Assert.Contains("Conflicting", result.TypeEvidence);
    }

    [Fact]
    public void SsdpDescription_ReadsRootDeviceNotEmbeddedDevice()
    {
        var document = XDocument.Parse("""
            <root xmlns="urn:schemas-upnp-org:device-1-0"><device>
              <friendlyName> Router </friendlyName><manufacturer>Example</manufacturer>
              <modelName>Model 1</modelName><deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType>
              <deviceList><device><friendlyName>Embedded</friendlyName><deviceType>Printer</deviceType></device></deviceList>
            </device></root>
            """);
        var info = SsdpDiscoveryService.ParseDeviceDescription(document, "Linux/5");
        Assert.NotNull(info);
        Assert.Equal("Router", info.FriendlyName);
        Assert.Equal("Model 1", info.ModelName);
        Assert.Equal(DeviceType.Router, DeviceClassifier.Classify(info, null).Type);
        Assert.Equal(DeviceOperatingSystem.Linux, DeviceClassifier.Classify(info, null).OperatingSystem);
    }

    [Fact]
    public void MultipleSsdpAdvertisements_AreCombinedWithoutArrivalOrderBias()
    {
        SsdpDeviceInfo[] advertisements =
        [
            new("Media server", "urn:schemas-upnp-org:device:MediaServer:1", null, null, null),
            new("TV", "urn:schemas-upnp-org:device:MediaRenderer:1", null, null, "Linux/5")
        ];
        var expected = DeviceClassifier.ClassifyAdvertisements(advertisements, null);
        Assert.Equal(DeviceType.MediaDevice, expected.Type);
        Assert.Equal(DeviceOperatingSystem.Linux, expected.OperatingSystem);
        Assert.Equal(expected, DeviceClassifier.ClassifyAdvertisements(advertisements.Reverse(), null));

        var conflict = DeviceClassifier.ClassifyAdvertisements(
            advertisements.Append(new(null, "urn:schemas-upnp-org:device:Printer:1", null, null, "Windows/10")), null);
        Assert.Equal(DeviceType.Unknown, conflict.Type);
        Assert.Equal(DeviceOperatingSystem.Unknown, conflict.OperatingSystem);
        Assert.Contains("Conflicting", conflict.TypeEvidence);
    }

    [Fact]
    public void BarePorts_DoNotImplyAnOperatingSystem()
    {
        var result = new ScanResult(IPAddress.Loopback, HostStatus.Alive, 1, TimeSpan.Zero,
            OpenPorts: [new(22, "SSH"), new(445, "SMB")]);
        Assert.Equal(DeviceClassification.Unknown, result.DetectedClassification);
    }
}
