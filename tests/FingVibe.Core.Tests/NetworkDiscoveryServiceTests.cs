using System.Net;
using FingVibe.Core.Models;
using FingVibe.Core.Networking;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class NetworkDiscoveryServiceTests
{
    private static readonly LanNetwork Selected = new("Ethernet",
        IPAddress.Parse("192.0.2.123"), IPAddress.Parse("192.0.2.0"), 24, true,
        IPAddress.Parse("192.0.2.1"), "{7C4A50DD-8191-438E-BED4-E2B80DC1CC42}");

    [Fact]
    public void AddressRenewalRefreshesTheSourceWithoutChangingTheSelectedAdapterOrSubnet()
    {
        var renewed = Selected with { LocalAddress = IPAddress.Parse("192.0.2.105") };
        Assert.Same(renewed, NetworkDiscoveryService.RefreshSelectedNetwork([renewed], Selected));
    }

    [Fact]
    public void ExistingSourceIsPreferredWhenTheAdapterHasMultipleAddresses()
    {
        var alias = Selected with { LocalAddress = IPAddress.Parse("192.0.2.105") };
        Assert.Same(Selected, NetworkDiscoveryService.RefreshSelectedNetwork([alias, Selected], Selected));
    }

    [Fact]
    public void AdapterIdentifiersAreComparedWithoutCaseSensitivity()
    {
        var candidate = Selected with { InterfaceId = Selected.InterfaceId!.ToLowerInvariant() };
        Assert.Same(candidate, NetworkDiscoveryService.RefreshSelectedNetwork([candidate], Selected));
    }

    [Fact]
    public void DifferentAdapterSubnetOrPrefixCannotReplaceTheSelectedLan()
    {
        var otherAdapter = Selected with { InterfaceId = Guid.NewGuid().ToString() };
        var otherSubnet = Selected with { NetworkAddress = IPAddress.Parse("192.0.3.0") };
        var otherPrefix = Selected with { PrefixLength = 25 };
        Assert.Throws<InvalidOperationException>(() =>
            NetworkDiscoveryService.RefreshSelectedNetwork([otherAdapter, otherSubnet, otherPrefix], Selected));
        Assert.Throws<InvalidOperationException>(() =>
            NetworkDiscoveryService.RefreshSelectedNetwork([], Selected));
    }

    [Fact]
    public void MissingAdapterIdentityDoesNotFallBackToTheDisplayName()
    {
        Assert.Throws<InvalidOperationException>(() =>
            NetworkDiscoveryService.RefreshSelectedNetwork([Selected], Selected with { InterfaceId = null }));
    }
}
