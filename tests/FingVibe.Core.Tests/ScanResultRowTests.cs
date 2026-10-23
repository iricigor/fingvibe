using System.Net;
using System.Net.NetworkInformation;
using FingVibe.App;
using FingVibe.Core.Models;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class ScanResultRowTests
{
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
        Assert.Equal(row.Result.AddressText, row.AddressPrefix + row.AddressHost);
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
        var named = new ScanResultRow(fallback.Result with { DeviceName = "Router", VendorName = "Vendor" }, 24);
        var addressName = new ScanResultRow(fallback.Result with { DeviceName = fallback.Result.AddressText }, 24);

        Assert.True(fallback.NameOpacity < 1);
        Assert.True(addressName.NameOpacity < 1);
        Assert.True(fallback.VendorOpacity < 1);
        Assert.Equal(1, named.NameOpacity);
        Assert.Equal(1, named.VendorOpacity);
    }

    [Fact]
    public void CustomName_OverridesDisplayWithoutChangingDiscoveredName()
    {
        var discovered = CreateRow();
        var row = new ScanResultRow(discovered.Result with { DeviceName = "router.local" }, 24, "Kitchen router");

        Assert.Equal("Kitchen router", row.NameText);
        Assert.Equal("router.local", row.Result.NameText);

        row.SetCustomName(null);

        Assert.Equal("router.local", row.NameText);
    }

    [Fact]
    public void MacParts_PreserveAllBytesAndSeparators()
    {
        var row = CreateRow();
        row = new ScanResultRow(row.Result with { MacAddress = PhysicalAddress.Parse("00-11-22-AB-CD-EF") }, 24);

        Assert.Equal("00-11-22", row.MacOui);
        Assert.Equal("-AB-CD-EF", row.MacNic);
        Assert.Equal(row.Result.MacAddressText, row.MacOui + row.MacNic);
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
