using System.Net.NetworkInformation;
using System.Net.Sockets;
using FingVibe.Core.Models;

namespace FingVibe.Core.Networking;

public sealed class NetworkDiscoveryService
{
    public IReadOnlyList<LanNetwork> GetAvailableNetworks() =>
        NetworkInterface.GetAllNetworkInterfaces()
            .Where(networkInterface =>
                networkInterface.OperationalStatus == OperationalStatus.Up
                && networkInterface.NetworkInterfaceType is not NetworkInterfaceType.Loopback
                && networkInterface.NetworkInterfaceType is not NetworkInterfaceType.Tunnel)
            .SelectMany(CreateNetworks)
            .OrderByDescending(network => network.HasGateway)
            .ThenByDescending(network => IsPrivate(network.LocalAddress))
            .ThenBy(network => network.InterfaceName, StringComparer.OrdinalIgnoreCase)
            .ToArray();

    public static LanNetwork RefreshSelectedNetwork(IReadOnlyList<LanNetwork> available, LanNetwork selected)
    {
        ArgumentNullException.ThrowIfNull(available);
        ArgumentNullException.ThrowIfNull(selected);
        if (string.IsNullOrWhiteSpace(selected.InterfaceId))
            throw new InvalidOperationException("The selected LAN has no adapter identifier; select an available LAN again.");
        var candidates = available.Where(candidate =>
            string.Equals(candidate.InterfaceId, selected.InterfaceId, StringComparison.OrdinalIgnoreCase)
            && candidate.NetworkAddress.Equals(selected.NetworkAddress)
            && candidate.PrefixLength == selected.PrefixLength).ToArray();
        return candidates.FirstOrDefault(candidate => candidate.LocalAddress.Equals(selected.LocalAddress))
            ?? candidates.FirstOrDefault()
            ?? throw new InvalidOperationException(
                $"{selected.InterfaceName} no longer reports the selected LAN ({selected.Cidr}); reconnect or select an available LAN.");
    }

    internal static IEnumerable<LanNetwork> CreateNetworks(NetworkInterface networkInterface)
    {
        var properties = networkInterface.GetIPProperties();
        var gatewayAddress = properties.GatewayAddresses.FirstOrDefault(gateway =>
            gateway.Address.AddressFamily == AddressFamily.InterNetwork
            && !gateway.Address.Equals(System.Net.IPAddress.Any))?.Address;

        foreach (var unicastAddress in properties.UnicastAddresses)
        {
            if (unicastAddress.Address.AddressFamily != AddressFamily.InterNetwork
                || System.Net.IPAddress.IsLoopback(unicastAddress.Address))
            {
                continue;
            }

            var prefixLength = unicastAddress.PrefixLength;
            yield return new LanNetwork(
                networkInterface.Name,
                unicastAddress.Address,
                SubnetCalculator.GetNetworkAddress(unicastAddress.Address, prefixLength),
                prefixLength,
                gatewayAddress is not null,
                gatewayAddress,
                networkInterface.Id);
        }
    }

    private static bool IsPrivate(System.Net.IPAddress address)
    {
        var bytes = address.GetAddressBytes();
        return bytes[0] == 10
            || bytes[0] == 172 && bytes[1] is >= 16 and <= 31
            || bytes[0] == 192 && bytes[1] == 168;
    }
}
