using FingVibe.Core.Networking;
using Xunit;
using Xunit.Abstractions;

namespace FingVibe.Core.Tests;

public sealed class WindowsFreshArpTests(ITestOutputHelper output)
{
    [DisposableWindowsFact]
    public async Task FreshResolutionUsesTheSelectedAdapterAndRejectsADifferentAdapterIdentity()
    {
        var network = new NetworkDiscoveryService().GetAvailableNetworks().FirstOrDefault(item =>
            item.GatewayAddress is { } gateway
            && !gateway.Equals(item.LocalAddress)
            && SubnetCalculator.GetNetworkAddress(gateway, item.PrefixLength).Equals(item.NetworkAddress));
        Assert.NotNull(network);
        var gateway = network.GatewayAddress!;
        await Assert.ThrowsAsync<InvalidOperationException>(() => FreshArpProbe.ResolveAsync(
            gateway, network with { InterfaceId = Guid.NewGuid().ToString() }, CancellationToken.None));
        var mac = await FreshArpProbe.ResolveAsync(gateway, network, CancellationToken.None);
        Assert.NotNull(mac);
        Assert.True(MacAddressResolver.IsUsableNeighbor(mac.GetAddressBytes(), 5));
        // Repeat with an existing neighbor: resolution must still use the fresh API, never a table lookup.
        var second = await FreshArpProbe.ResolveAsync(gateway, network, CancellationToken.None);
        Assert.Equal(mac, second);
        output.WriteLine($"Fresh ARP verified: adapter {network.InterfaceId}, source {network.LocalAddress}, target {gateway}, MAC {mac}.");
    }
}

internal sealed class DisposableWindowsFactAttribute : FactAttribute
{
    public DisposableWindowsFactAttribute()
    {
        if (!OperatingSystem.IsWindows() || Environment.GetEnvironmentVariable("GITHUB_ACTIONS") != "true")
            Skip = "Native ARP integration runs only on the disposable Windows GitHub Actions runner, not the user's LAN.";
    }
}
