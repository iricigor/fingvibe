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

    private static IEnumerable<LanNetwork> CreateNetworks(NetworkInterface networkInterface)
    {
        var properties = networkInterface.GetIPProperties();
        var hasGateway = properties.GatewayAddresses.Any(gateway =>
            gateway.Address.AddressFamily == AddressFamily.InterNetwork
            && !gateway.Address.Equals(System.Net.IPAddress.Any));

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
                hasGateway);
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
