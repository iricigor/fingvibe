using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Diagnostics;

namespace FingVibe.Core.Networking;

public sealed class MacAddressResolver
{
    public PhysicalAddress? Resolve(IPAddress address)
    {
        ArgumentNullException.ThrowIfNull(address);

        if (!OperatingSystem.IsWindows() || address.AddressFamily != AddressFamily.InterNetwork)
        {
            return null;
        }

        var destination = BitConverter.ToUInt32(address.GetAddressBytes());
        var routeResult = GetBestInterface(destination, out var interfaceIndex);
        if (routeResult != 0)
        {
            Debug.WriteLine($"MAC route lookup for {address} failed: {routeResult}.");
            return null;
        }
        // A responding host may already have a valid neighbor even when SendARP fails.
        if (ResolveNeighbor(address, interfaceIndex) is { } neighbor) return neighbor;

        var bytes = new byte[6];
        var length = bytes.Length;
        var result = SendARP(destination, 0, bytes, ref length);
        if (result == 0 && length == bytes.Length && IsUsableNeighbor(bytes, 5))
            return new PhysicalAddress(bytes);
        Debug.WriteLine($"SendARP for {address} failed or returned an invalid address: {result}, length {length}.");
        return ResolveNeighbor(address, interfaceIndex);
    }

    private static PhysicalAddress? ResolveNeighbor(IPAddress address, uint interfaceIndex)
    {
        var result = GetIpNetTable2(2, out var table);
        if (result != 0)
        {
            Debug.WriteLine($"IPv4 neighbor lookup failed: {result}.");
            return null;
        }
        try
        {
            var count = Marshal.ReadInt32(table);
            for (var index = 0; index < count; index++)
            {
                var row = Marshal.PtrToStructure<NeighborRow>(IntPtr.Add(table, 8 + index * 88));
                if (row.Family != 2 || row.InterfaceIndex != interfaceIndex || row.PhysicalAddressLength != 6
                    || row.Address != BitConverter.ToUInt32(address.GetAddressBytes()))
                    continue;
                var bytes = new byte[6];
                Marshal.Copy(IntPtr.Add(table, 8 + index * 88 + 40), bytes, 0, bytes.Length);
                if (IsUsableNeighbor(bytes, row.State)) return new PhysicalAddress(bytes);
            }
            return null;
        }
        finally { FreeMibTable(table); }
    }

    public static bool IsUsableNeighbor(byte[] address, int state) =>
        address.Length == 6 && state is >= 2 and <= 6 && (address[0] & 1) == 0
        && address.Any(value => value != 0);

    [StructLayout(LayoutKind.Explicit, Size = 88)]
    private struct NeighborRow
    {
        [FieldOffset(0)] public ushort Family;
        [FieldOffset(4)] public uint Address;
        [FieldOffset(28)] public uint InterfaceIndex;
        [FieldOffset(72)] public uint PhysicalAddressLength;
        [FieldOffset(76)] public int State;
    }

    [DllImport("iphlpapi.dll", ExactSpelling = true)]
    private static extern int GetBestInterface(uint destinationIp, out uint interfaceIndex);

    [DllImport("iphlpapi.dll", ExactSpelling = true)]
    private static extern int GetIpNetTable2(ushort family, out IntPtr table);

    [DllImport("iphlpapi.dll", ExactSpelling = true)]
    private static extern void FreeMibTable(IntPtr table);

    public static bool IsPrivateOrRandomized(PhysicalAddress address)
    {
        ArgumentNullException.ThrowIfNull(address);
        var bytes = address.GetAddressBytes();
        return bytes.Length > 0 && (bytes[0] & 0x02) != 0;
    }

    [DllImport("iphlpapi.dll", ExactSpelling = true, SetLastError = true)]
    private static extern int SendARP(
        uint destinationIp,
        uint sourceIp,
        [Out] byte[] macAddress,
        ref int physicalAddressLength);
}
