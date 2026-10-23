using System.Net;
using System.Runtime.InteropServices;
using System.Xml.Linq;
using System.Xml;
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
    public void ConflictingProductIdentities_DoNotDetermineClassification()
    {
        var result = DeviceClassifier.Classify(new("Windows Android Linux MacBook iPhone",
            null, "Apple Samsung Microsoft", "Printer", null), null);
        Assert.Equal(DeviceOperatingSystem.Unknown, result.OperatingSystem);
        Assert.Equal(DeviceType.Unknown, result.Type);
        Assert.Contains("Conflicting", result.OperatingSystemEvidence);
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
    public void StorageProductIdentity_RecognizesMyCloudWithoutGuessingOs()
    {
        var result = DeviceClassifier.ClassifyAdvertisements([], null,
            "WDMyCloud", "WESTERN DIGITAL", [new(22, "SSH"), new(445, "SMB")]);
        Assert.Equal(DeviceType.Storage, result.Type);
        Assert.True(result.TypeIsInferred);
        Assert.Equal(DeviceOperatingSystem.Unknown, result.OperatingSystem);
        Assert.Contains("WESTERN DIGITAL", result.TypeEvidence);
    }

    [Theory]
    [InlineData(127, true, DeviceOperatingSystem.Windows)]
    [InlineData(128, true, DeviceOperatingSystem.Windows)]
    [InlineData(64, true, DeviceOperatingSystem.Unknown)]
    [InlineData(129, true, DeviceOperatingSystem.Unknown)]
    [InlineData(128, false, DeviceOperatingSystem.Unknown)]
    [InlineData(0, true, DeviceOperatingSystem.Unknown)]
    public void WindowsHeuristic_RequiresBothObservedWindowsStyleTtlAndSmb(
        int ttl, bool smb, DeviceOperatingSystem expected)
    {
        var result = DeviceClassifier.ClassifyAdvertisements([], null,
            openPorts: smb ? [new(445, "SMB")] : [], responseTtl: ttl);
        Assert.Equal(expected, result.OperatingSystem);
        Assert.Equal(expected == DeviceOperatingSystem.Windows, result.OperatingSystemIsInferred);
        if (expected == DeviceOperatingSystem.Windows)
        {
            Assert.Equal(DeviceType.Computer, result.Type);
            Assert.True(result.TypeIsInferred);
            Assert.Contains($"TTL {ttl}", result.OperatingSystemEvidence);
        }
    }

    [Fact]
    public void WindowsHeuristic_DoesNotOverrideNasIdentityOrContradictoryEvidence()
    {
        var nas = DeviceClassifier.ClassifyAdvertisements([], null, "WDMyCloud", "WESTERN DIGITAL",
            [new(445, "SMB")], responseTtl: 128);
        Assert.Equal(DeviceType.Storage, nas.Type);
        Assert.Equal(DeviceOperatingSystem.Unknown, nas.OperatingSystem);
        var conflict = DeviceClassifier.ClassifyAdvertisements([], null, openPorts: [new(445, "SMB")],
            banners: [new("HTTP", "Linux Windows")], responseTtl: 128);
        Assert.Equal(DeviceOperatingSystem.Unknown, conflict.OperatingSystem);
    }

    [Fact]
    public async Task UpnpDescription_ReadIsSizeBoundedAndCancellable()
    {
        using var oversized = new MemoryStream(new byte[1_000_001]);
        await Assert.ThrowsAsync<XmlException>(() =>
            SsdpDiscoveryService.ReadDescriptionAsync(oversized, "Linux", CancellationToken.None));
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        using var content = new MemoryStream();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            SsdpDiscoveryService.ReadDescriptionAsync(content, "Linux", cancellation.Token));
    }

    [Theory]
    [InlineData("Philips Lighting BV")]
    [InlineData("Signify Netherlands B.V.")]
    [InlineData("Tuya Smart Inc.")]
    public void SmartHomeVendors_ProvideExplicitlyInferredDeviceType(string vendor)
    {
        var result = DeviceClassifier.ClassifyAdvertisements([], null,
            "bridge.local", vendor, [new(80, "HTTP"), new(443, "HTTPS")]);
        Assert.Equal(DeviceType.SmartDevice, result.Type);
        Assert.True(result.TypeIsInferred);
        Assert.Equal(DeviceOperatingSystem.Unknown, result.OperatingSystem);
    }

    [Theory]
    [InlineData("TP-Link Systems Inc.")]
    [InlineData("Amazon Technologies Inc.")]
    [InlineData("Apple, Inc.")]
    [InlineData("Private/Randomized")]
    public void GeneralPurposeVendorAndOpenPorts_DoNotInventAnOsOrDeviceType(string vendor)
    {
        var result = DeviceClassifier.ClassifyAdvertisements([], null,
            "device.local", vendor, [new(22, "SSH"), new(445, "SMB"), new(80, "HTTP")]);
        Assert.Equal(DeviceClassification.Unknown, result);
    }

    [Theory]
    [InlineData("Android-2.local", DeviceOperatingSystem.Android)]
    [InlineData("Android_ABC123.local", DeviceOperatingSystem.Android)]
    [InlineData("iPhone.local", DeviceOperatingSystem.IOS)]
    [InlineData("MacBook-Pro.local", DeviceOperatingSystem.MacOS)]
    public void OsSpecificDiscoveredNames_AreHintsNotDefinitiveOsEvidence(
        string name, DeviceOperatingSystem expected)
    {
        var result = DeviceClassifier.ClassifyAdvertisements([], null, name);
        Assert.Equal(expected, result.OperatingSystem);
        Assert.True(result.OperatingSystemIsInferred);
        Assert.Contains("Likely", result.OperatingSystemEvidence);
        if (expected == DeviceOperatingSystem.Android)
        {
            Assert.Equal(DeviceType.Unknown, result.Type);
        }
    }

    [Theory]
    [InlineData("HTTP", "Microsoft-IIS/10.0", DeviceOperatingSystem.Windows)]
    [InlineData("HTTP", "Microsoft-HTTPAPI/2.0", DeviceOperatingSystem.Windows)]
    [InlineData("SSH", "SSH-2.0-OpenSSH_for_Windows_9.5", DeviceOperatingSystem.Windows)]
    [InlineData("SSH", "SSH-2.0-OpenSSH_9.2p1 Debian-2", DeviceOperatingSystem.Linux)]
    [InlineData("HTTP", "Apache/2.4.52 (Ubuntu)", DeviceOperatingSystem.Linux)]
    [InlineData("HTTP", "nginx/1.22", DeviceOperatingSystem.Unknown)]
    [InlineData("SSH", "SSH-2.0-OpenSSH_9.5", DeviceOperatingSystem.Unknown)]
    public void ServiceBanners_RequirePlatformSpecificContent(
        string source, string value, DeviceOperatingSystem expected)
    {
        var result = DeviceClassifier.ClassifyAdvertisements([], null, banners: [new(source, value)]);
        Assert.Equal(expected, result.OperatingSystem);
    }

    [Fact]
    public void AndroidTvService_DoesNotDependOnItsHostnameOrManufacturer()
    {
        var result = DeviceClassifier.Classify(null, new(["_androidtvremote2._tcp.local"]));
        Assert.Equal(DeviceOperatingSystem.Android, result.OperatingSystem);
        Assert.Equal(DeviceType.MediaDevice, result.Type);
    }

    [Fact]
    public void LocalComputerAndGateway_AreIdentifiedFromNetworkContext()
    {
        var network = new LanNetwork("Example", IPAddress.Parse("192.0.2.10"),
            IPAddress.Parse("192.0.2.0"), 24, true, IPAddress.Parse("192.0.2.1"));
        var local = DeviceClassifier.ApplyNetworkContext(DeviceClassification.Unknown,
            network.LocalAddress, network);
        var expected = RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? DeviceOperatingSystem.Windows
            : RuntimeInformation.IsOSPlatform(OSPlatform.OSX) ? DeviceOperatingSystem.MacOS
            : RuntimeInformation.IsOSPlatform(OSPlatform.Linux) ? DeviceOperatingSystem.Linux
            : DeviceOperatingSystem.Other;
        Assert.Equal(expected, local.OperatingSystem);
        Assert.Equal(DeviceType.Computer, local.Type);
        Assert.False(local.OperatingSystemIsInferred);
        Assert.False(local.TypeIsInferred);

        var gateway = DeviceClassifier.ApplyNetworkContext(DeviceClassification.Unknown,
            network.GatewayAddress!, network);
        Assert.Equal(DeviceType.Router, gateway.Type);
        Assert.Equal(DeviceOperatingSystem.Unknown, gateway.OperatingSystem);
        Assert.Equal(DeviceClassification.Unknown, DeviceClassifier.ApplyNetworkContext(
            DeviceClassification.Unknown, IPAddress.Parse("192.0.2.2"), network));
    }

    [Fact]
    public void Fallbacks_DoNotOverwriteExplicitOrConflictingEvidence()
    {
        var explicitPrinter = DeviceClassifier.ClassifyAdvertisements(
            [new(null, "urn:schemas-upnp-org:device:Printer:1", null, null, "Linux/5")], null,
            "Android-2.local", "Philips Lighting BV");
        Assert.Equal(DeviceType.Printer, explicitPrinter.Type);
        Assert.Equal(DeviceOperatingSystem.Linux, explicitPrinter.OperatingSystem);
        Assert.False(explicitPrinter.TypeIsInferred);

        var conflict = DeviceClassifier.ClassifyAdvertisements([], null, "Android-2.local",
            banners: [new("HTTP", "Linux Windows")]);
        Assert.Equal(DeviceOperatingSystem.Unknown, conflict.OperatingSystem);
        Assert.Contains("Conflicting", conflict.OperatingSystemEvidence);
    }

    [Fact]
    public void BarePorts_DoNotImplyAnOperatingSystem()
    {
        var result = new ScanResult(IPAddress.Loopback, HostStatus.Alive, 1, TimeSpan.Zero,
            OpenPorts: [new(22, "SSH"), new(445, "SMB")]);
        Assert.Equal(DeviceClassification.Unknown, result.DetectedClassification);
    }
}
