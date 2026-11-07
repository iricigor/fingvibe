using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using FingVibe.Core.Models;

namespace FingVibe.Core.Networking;

internal static class FreshArpProbe
{
    private static readonly SemaphoreSlim Slots = new(8, 8);

    internal static async Task<PhysicalAddress?> ResolveAsync(
        IPAddress address, LanNetwork network, CancellationToken cancellationToken)
    {
        if (!OperatingSystem.IsWindows() || address.AddressFamily != AddressFamily.InterNetwork)
            return null;
        if (address.AddressFamily != network.LocalAddress.AddressFamily
            || !SubnetCalculator.GetNetworkAddress(address, network.PrefixLength).Equals(network.NetworkAddress))
            throw new InvalidOperationException("Fresh ARP requires an address on the selected directly connected IPv4 LAN.");
        uint index;
        try
        {
            var adapter = NetworkInterface.GetAllNetworkInterfaces().FirstOrDefault(item =>
                item.Id == network.InterfaceId && item.OperationalStatus == OperationalStatus.Up
                && item.GetIPProperties().UnicastAddresses.Any(unicast =>
                    unicast.Address.Equals(network.LocalAddress) && unicast.PrefixLength == network.PrefixLength));
            if (adapter is null)
                throw new InvalidOperationException("The selected LAN adapter is no longer connected.");
            index = (uint)adapter.GetIPProperties().GetIPv4Properties().Index;
        }
        catch (NetworkInformationException exception)
        {
            throw new InvalidOperationException("The selected LAN adapter could not be read for fresh ARP resolution.", exception);
        }
        var route = GetBestInterface(BitConverter.ToUInt32(address.GetAddressBytes()), out var bestIndex);
        if (route != 0)
            throw new InvalidOperationException($"ARP route lookup for {address} failed ({route}).");
        if (index != bestIndex)
        {
            Debug.WriteLine($"Skipping ARP for {address}: route does not use the selected LAN adapter.");
            return null;
        }

        await Slots.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            // ResolveIpNetEntry2 flushes the entry and performs fresh resolution. Do not read the neighbor cache.
            // Keep the slot until the blocking Windows call returns, including during cancellation.
            var mac = await Task.Run(() => Resolve(address, network.LocalAddress, index), CancellationToken.None)
                .ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            return mac;
        }
        finally { Slots.Release(); }
    }

    private static PhysicalAddress? Resolve(IPAddress address, IPAddress source, uint index)
    {
        var row = new NeighborRow { Address = SocketAddress.From(address), InterfaceIndex = index };
        var sourceAddress = SocketAddress.From(source);
        var error = ResolveIpNetEntry2(ref row, ref sourceAddress);
        if (error is 67 or 1168 or 1231 or 1232 or 1460)
        {
            Debug.WriteLine($"Fresh ARP received no response from {address} ({error}).");
            return null;
        }
        if (error != 0)
            throw new InvalidOperationException($"Fresh ARP resolution for {address} failed ({error}).");
        var bytes = BitConverter.GetBytes(row.PhysicalAddress)[..6];
        return ReadFreshResponse(bytes, row.PhysicalAddressLength, row.State, address);
    }

    internal static PhysicalAddress? ReadFreshResponse(byte[] bytes, uint length, int state, IPAddress address)
    {
        if (length != 6 || state != 5 || !MacAddressResolver.IsUsableNeighbor(bytes, state))
        {
            Debug.WriteLine($"Fresh ARP for {address} returned an invalid or non-reachable neighbor.");
            return null;
        }
        return new PhysicalAddress(bytes);
    }

    [StructLayout(LayoutKind.Explicit, Size = 28)]
    private struct SocketAddress
    {
        [FieldOffset(0)] public ushort Family;
        [FieldOffset(4)] public uint Address;
        public static SocketAddress From(IPAddress address) =>
            new() { Family = 2, Address = BitConverter.ToUInt32(address.GetAddressBytes()) };
    }

    [StructLayout(LayoutKind.Explicit, Size = 88)]
    private struct NeighborRow
    {
        [FieldOffset(0)] public SocketAddress Address;
        [FieldOffset(28)] public uint InterfaceIndex;
        [FieldOffset(40)] public ulong PhysicalAddress;
        [FieldOffset(72)] public uint PhysicalAddressLength;
        [FieldOffset(76)] public int State;
    }

    [DllImport("iphlpapi.dll", ExactSpelling = true)]
    private static extern uint ResolveIpNetEntry2(ref NeighborRow row, ref SocketAddress sourceAddress);

    [DllImport("iphlpapi.dll", ExactSpelling = true)]
    private static extern uint GetBestInterface(uint destination, out uint interfaceIndex);
}
