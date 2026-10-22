using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;

namespace FingVibe.Core.Networking;

internal static class MacAddressResolver
{
    public static string? TryResolve(IPAddress address)
    {
        if (!OperatingSystem.IsWindows() || address.AddressFamily != AddressFamily.InterNetwork)
        {
            return null;
        }

        var destination = BitConverter.ToUInt32(address.GetAddressBytes());
        var addressBytes = new byte[6];
        var addressLength = addressBytes.Length;

        var result = SendARP(destination, 0, addressBytes, ref addressLength);
        return result == 0 && addressLength > 0
            ? string.Join("-", addressBytes.Take(addressLength).Select(value => value.ToString("X2")))
            : null;
    }

    [DllImport("iphlpapi.dll", SetLastError = true)]
    private static extern int SendARP(
        uint destinationAddress,
        uint sourceAddress,
        [Out] byte[] physicalAddress,
        ref int physicalAddressLength);
}
