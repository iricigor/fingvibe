using System.Net;
using System.Net.NetworkInformation;
using FingVibe.App;
using FingVibe.Core.Models;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class ScanResultRowTests
{
    [Fact]
    public void AlternateRow_NotifiesOnlyWhenVisibleParityChanges()
    {
        var row = new ScanResultRow(new ScanResult(
            System.Net.IPAddress.Parse("192.0.2.1"), HostStatus.Alive, 2, TimeSpan.FromMilliseconds(2)), 24);
        var changes = new List<string?>();
        row.PropertyChanged += (_, args) => changes.Add(args.PropertyName);

        Assert.False(row.IsAlternateRow);
        row.IsAlternateRow = true;
        row.IsAlternateRow = true;
        row.IsAlternateRow = false;

        Assert.Equal(new[]
        {
            nameof(ScanResultRow.IsAlternateRow), nameof(ScanResultRow.HasStripe),
            nameof(ScanResultRow.IsAlternateRow), nameof(ScanResultRow.HasStripe)
        }, changes);
    }

    [Fact]
    public void Stripe_YieldsToHoverAndSelection()
    {
        var row = new ScanResultRow(new ScanResult(
            System.Net.IPAddress.Parse("192.0.2.1"), HostStatus.Alive, 2, TimeSpan.FromMilliseconds(2)), 24)
        {
            IsAlternateRow = true
        };

        Assert.True(row.HasStripe);
        row.IsPointerOver = true;
        Assert.False(row.HasStripe);
        row.IsSelected = true;
        row.IsPointerOver = false;
        Assert.False(row.HasStripe);
        row.IsSelected = false;
        Assert.True(row.HasStripe);
    }

    [Theory]
    [InlineData(24, "192.168.0.", "100")]
    [InlineData(16, "192.168.", "0.100")]
    [InlineData(20, "192.168.", "0.100")]
    [InlineData(25, "192.168.0.", "100")]
    [InlineData(32, "192.168.0.", "100")]
    [InlineData(0, "", "192.168.0.100")]
    public void AddressEmphasis_UsesOnlyCompleteNetworkOctets(int prefix, string network, string host)
    {
        var row = CreateRow(prefix: prefix);

        Assert.Equal(network, row.AddressPrefix);
        Assert.Equal(host, row.AddressHost);
        Assert.Equal(row.AddressText, row.AddressPrefix + row.AddressHost);
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(33)]
    public void InvalidPrefix_IsRejected(int prefix) =>
        Assert.Throws<ArgumentOutOfRangeException>(() => CreateRow(prefix: prefix));

    [Fact]
    public void FallbackNameAndUnknownVendor_AreMuted()
    {
        var fallback = CreateRow();
        var result = Assert.IsType<ScanResult>(fallback.Result);
        var named = new ScanResultRow(result with { DeviceName = "Router", VendorName = "Vendor" }, 24);
        var addressName = new ScanResultRow(result with { DeviceName = fallback.AddressText }, 24);

        Assert.True(fallback.NameOpacity < 1);
        Assert.True(addressName.NameOpacity < 1);
        Assert.True(fallback.VendorOpacity < 1);
        Assert.Equal(1, named.NameOpacity);
        Assert.Equal(1, named.VendorOpacity);
    }

    [Fact]
    public void AssignmentOpacity_MutesOnlyUnassignedValuesAndNotifiesOnChanges()
    {
        var row = CreateRow();
        var notifications = new List<string?>();
        row.PropertyChanged += (_, args) => notifications.Add(args.PropertyName);

        Assert.Equal("-", row.PersonShortName);
        Assert.Equal("-", row.RoomShortName);
        Assert.Equal(0.65, row.PersonOpacity);
        Assert.Equal(0.65, row.RoomOpacity);

        var personId = Guid.NewGuid();
        row.SetPeopleRoomAssignments(personId, "II", "Igor Iric", null, null, null);
        Assert.Equal(1, row.PersonOpacity);
        Assert.Equal(0.65, row.RoomOpacity);
        Assert.Contains(nameof(ScanResultRow.PersonOpacity), notifications);
        Assert.Contains(nameof(ScanResultRow.RoomOpacity), notifications);

        notifications.Clear();
        row.SetPeopleRoomAssignments(null, null, null, Guid.NewGuid(), "LR", "Living Room");
        Assert.Equal(0.65, row.PersonOpacity);
        Assert.Equal(1, row.RoomOpacity);
        Assert.Equal("-", row.PersonShortName);
        Assert.Equal("Living Room", row.RoomFullName);
        Assert.Contains(nameof(ScanResultRow.PersonOpacity), notifications);
        Assert.Contains(nameof(ScanResultRow.RoomOpacity), notifications);
    }

    [Fact]
    public void CustomName_OverridesDisplayWithoutChangingDiscoveredName()
    {
        var discovered = CreateRow();
        var row = new ScanResultRow(Assert.IsType<ScanResult>(discovered.Result) with { DeviceName = "router.local" }, 24, "Kitchen router");

        Assert.Equal("Kitchen router", row.NameText);
        Assert.Equal("router.local", row.HostnameText);

        row.SetCustomName(null);

        Assert.Equal("router.local", row.NameText);
    }

    [Theory]
    [InlineData(DeviceOperatingSystem.Unknown, DeviceType.Unknown, 0.65, 0.65)]
    [InlineData(DeviceOperatingSystem.Windows, DeviceType.Computer, 1, 1)]
    [InlineData(DeviceOperatingSystem.Unknown, DeviceType.Phone, 0.65, 1)]
    [InlineData(DeviceOperatingSystem.Android, DeviceType.Unknown, 1, 0.65)]
    [InlineData(DeviceOperatingSystem.Other, DeviceType.SmartDevice, 1, 1)]
    public void ClassificationOpacity_MutesOnlyUnknownValues(
        DeviceOperatingSystem os, DeviceType type, double osOpacity, double typeOpacity)
    {
        var row = new ScanResultRow(Assert.IsType<ScanResult>(CreateRow().Result) with
        {
            Classification = new(os, type)
        }, 24);

        Assert.Equal(osOpacity, row.OperatingSystemOpacity);
        Assert.Equal(typeOpacity, row.DeviceTypeOpacity);
    }

    [Fact]
    public void ClassificationOpacity_UpdatesWhenOverridesAreSavedAndReset()
    {
        var row = CreateRow();
        var notifications = new List<string?>();
        row.PropertyChanged += (_, args) => notifications.Add(args.PropertyName);

        row.SetClassificationOverride(new(DeviceOperatingSystem.Android, DeviceType.Phone));

        Assert.Equal(1, row.OperatingSystemOpacity);
        Assert.Equal(1, row.DeviceTypeOpacity);
        Assert.Contains(nameof(ScanResultRow.OperatingSystemOpacity), notifications);
        Assert.Contains(nameof(ScanResultRow.DeviceTypeOpacity), notifications);

        row.SetClassificationOverride(null);

        Assert.Equal(0.65, row.OperatingSystemOpacity);
        Assert.Equal(0.65, row.DeviceTypeOpacity);

        var detected = new ScanResultRow(Assert.IsType<ScanResult>(row.Result) with
        {
            Classification = new(DeviceOperatingSystem.Android, DeviceType.Phone)
        }, 24);
        detected.SetClassificationOverride(new(DeviceOperatingSystem.Unknown, DeviceType.Unknown));
        Assert.Equal(0.65, detected.OperatingSystemOpacity);
        Assert.Equal(0.65, detected.DeviceTypeOpacity);
        detected.SetClassificationOverride(null);
        Assert.Equal(1, detected.OperatingSystemOpacity);
        Assert.Equal(1, detected.DeviceTypeOpacity);
    }

    [Fact]
    public void ClassificationOverrides_AreIndependentOfAutomaticEvidenceAndResettable()
    {
        var classification = new DeviceClassification(DeviceOperatingSystem.Linux, DeviceType.Printer,
            "SSDP SERVER advertises Linux.", "UPnP printer.");
        var row = new ScanResultRow(Assert.IsType<ScanResult>(CreateRow().Result) with { Classification = classification }, 24);
        var notifications = new List<string?>();
        row.PropertyChanged += (_, args) => notifications.Add(args.PropertyName);
        var originalIcon = row.IconGlyph;

        row.SetClassificationOverride(new(DeviceOperatingSystem.Windows, DeviceType.Computer));
        Assert.Equal("Windows", row.OperatingSystemText);
        Assert.Equal("Computer", row.DeviceTypeText);
        Assert.NotEqual(originalIcon, row.IconGlyph);
        Assert.Contains("User-selected", row.OperatingSystemSource);
        Assert.Contains("Linux", row.OperatingSystemSource);
        Assert.Equal(classification, Assert.IsType<ScanResult>(row.Result).Classification);
        Assert.Contains(nameof(ScanResultRow.IconGlyph), notifications);
        Assert.Contains(nameof(ScanResultRow.OperatingSystemText), notifications);

        row.SetClassificationOverride(new(Type: DeviceType.Phone, Icon: DeviceType.Storage));
        var customIcon = row.IconGlyph;
        row.SetClassificationOverride(new(Type: DeviceType.Tablet, Icon: DeviceType.Storage));
        Assert.Equal(customIcon, row.IconGlyph);
        Assert.Contains("User-selected", row.IconSource);

        row.SetClassificationOverride(null);
        Assert.Equal("Linux", row.OperatingSystemText);
        Assert.Equal("Printer", row.DeviceTypeText);
        Assert.Equal(originalIcon, row.IconGlyph);
        Assert.DoesNotContain("User-selected", row.DeviceTypeSource);
    }

    [Fact]
    public void InferredClassifications_AreVisiblyMarkedUntilManuallyOverridden()
    {
        var row = new ScanResultRow(Assert.IsType<ScanResult>(CreateRow().Result) with
        {
            Classification = new(DeviceOperatingSystem.Android, DeviceType.MediaDevice,
                "Discovered Android hostname.", "Media product identity.",
                OperatingSystemIsInferred: true, TypeIsInferred: true)
        }, 24);
        Assert.Equal("Android (likely)", row.OperatingSystemText);
        Assert.Equal("TV/media device (likely)", row.DeviceTypeText);
        Assert.Equal(1, row.OperatingSystemOpacity);
        Assert.Equal(1, row.DeviceTypeOpacity);
        row.SetClassificationOverride(new(DeviceOperatingSystem.Android, DeviceType.MediaDevice));
        Assert.Equal("Android", row.OperatingSystemText);
        Assert.Equal("TV/media device", row.DeviceTypeText);
        row.SetClassificationOverride(null);
        Assert.Equal("Android (likely)", row.OperatingSystemText);
    }

    [Fact]
    public void ClassificationChoices_SurviveAddressChangeWhenReappliedByMac()
    {
        var mac = PhysicalAddress.Parse("001122334455");
        var choice = new DeviceClassificationOverride(DeviceOperatingSystem.Android, DeviceType.Phone);
        var first = new ScanResultRow(Assert.IsType<ScanResult>(CreateRow().Result) with { MacAddress = mac }, 24,
            classificationOverride: choice);
        var second = new ScanResultRow(Assert.IsType<ScanResult>(first.Result) with { Address = IPAddress.Parse("192.168.0.101") }, 24,
            classificationOverride: choice);
        Assert.Equal(first.OperatingSystemText, second.OperatingSystemText);
        Assert.Equal(first.IconGlyph, second.IconGlyph);
    }

    [Fact]
    public void Filter_FindsEffectiveAndDetectedClassifications()
    {
        var row = new ScanResultRow(Assert.IsType<ScanResult>(CreateRow().Result) with
        {
            Classification = new(DeviceOperatingSystem.Linux, DeviceType.Storage)
        }, 24, classificationOverride: new(DeviceOperatingSystem.MacOS, DeviceType.GameConsole));
        Assert.True(row.MatchesFilter(" MACos "));
        Assert.True(row.MatchesFilter("game console"));
        Assert.True(row.MatchesFilter("Linux"));
        Assert.True(row.MatchesFilter("NAS"));
        Assert.False(row.MatchesFilter("Android"));
    }

    [Fact]
    public void AllDeviceTypes_HaveDistinctBuiltInIcons()
    {
        var row = CreateRow();
        var icons = Enum.GetValues<DeviceType>().Select(type =>
        {
            row.SetClassificationOverride(new(Icon: type));
            return row.IconGlyph;
        }).ToArray();
        Assert.All(icons, glyph => Assert.Single(glyph));
        Assert.Equal(icons.Length, icons.Distinct().Count());
    }

    [Fact]
    public void MacParts_PreserveAllBytesAndSeparators()
    {
        var row = CreateRow();
        row = new ScanResultRow(Assert.IsType<ScanResult>(row.Result) with { MacAddress = PhysicalAddress.Parse("00-11-22-AB-CD-EF") }, 24);

        Assert.Equal("00-11-22", row.MacOui);
        Assert.Equal("-AB-CD-EF", row.MacNic);
        Assert.Equal(row.MacAddressText, row.MacOui + row.MacNic);
        Assert.Equal("-", CreateRow().MacOui);
        Assert.Equal("", CreateRow().MacNic);
    }

    [Theory]
    [InlineData(0, 0, 100, 20)]
    [InlineData(10, 10, 100, 20)]
    [InlineData(55, 10, 100, 60)]
    [InlineData(100, 10, 100, 100)]
    [InlineData(0, 0, 0, 20)]
    [InlineData(10, 10, 10, 20)]
    public void LatencyFill_MapsFastestToTwentyAndSlowestToOneHundred(long latency, long minimum, long maximum, double fill)
    {
        var row = CreateRow(latency);

        row.UpdateLatencyRange(minimum, maximum);

        Assert.Equal(fill, row.LatencyFill);
        Assert.Equal($"{latency} ms", row.LatencyLabel);
    }

    [Fact]
    public void ChangingLatencyRange_NotifiesBindingsAndRescalesExistingRows()
    {
        var row = CreateRow(50);
        var notifications = new List<string?>();
        row.PropertyChanged += (_, e) => notifications.Add(e.PropertyName);
        row.UpdateLatencyRange(0, 50);
        Assert.Equal(100, row.LatencyFill);

        row.UpdateLatencyRange(0, 100);

        Assert.Equal(60, row.LatencyFill);
        Assert.Contains(nameof(ScanResultRow.LatencyFraction), notifications);
        Assert.Contains(nameof(ScanResultRow.LatencyFill), notifications);
        notifications.Clear();
        row.UpdateLatencyRange(0, 100);
        Assert.Empty(notifications);
    }

    [Theory]
    [InlineData(HostStatus.Unreachable, null)]
    [InlineData(HostStatus.Unreachable, 100L)]
    [InlineData(HostStatus.Alive, null)]
    [InlineData(HostStatus.Alive, -1L)]
    public void MissingOrOfflineLatency_HasNoBar(HostStatus status, long? latency)
    {
        var row = CreateRow(latency, status: status);
        row.UpdateLatencyRange(0, 100);

        Assert.False(row.HasLatency);
        Assert.Equal(0, row.LatencyFill);
        Assert.Equal("-", row.LatencyLabel);
        Assert.Equal(status == HostStatus.Alive ? "Online" : "Offline", row.StatusLabel);
    }

    [Theory]
    [InlineData(-1, 1)]
    [InlineData(10, 1)]
    public void InvalidLatencyBounds_AreRejected(long minimum, long maximum) =>
        Assert.Throws<ArgumentOutOfRangeException>(() => CreateRow().UpdateLatencyRange(minimum, maximum));

    private static ScanResultRow CreateRow(long? latency = 0, int prefix = 24, HostStatus status = HostStatus.Alive) =>
        new(new ScanResult(IPAddress.Parse("192.168.0.100"), status, latency, TimeSpan.Zero), prefix);
}
