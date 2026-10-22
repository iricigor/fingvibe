using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;

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

        var bytes = new byte[6];
        var length = bytes.Length;
        var destination = BitConverter.ToUInt32(address.GetAddressBytes());
        var result = SendARP(destination, 0, bytes, ref length);

        return result == 0 && length == bytes.Length
            ? new PhysicalAddress(bytes)
            : null;
    }

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
