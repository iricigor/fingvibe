using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using Windows.Networking.Connectivity;

namespace FingVibe.App;

[SupportedOSPlatform("windows")]
internal static class UpdateConnectionCost
{
    public static bool IsMeteredOrUnknown()
    {
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 10240)) return true;
        try
        {
            var profile = NetworkInformation.GetInternetConnectionProfile();
            return profile is null ||
                profile.GetConnectionCost().NetworkCostType != NetworkCostType.Unrestricted;
        }
        catch (Exception exception) when (exception is COMException or InvalidOperationException or UnauthorizedAccessException)
        {
            Trace.TraceWarning($"Update connection cost could not be determined: {exception}");
            return true;
        }
    }
}
