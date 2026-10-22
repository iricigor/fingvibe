using FingVibe.Core.Models;

namespace FingVibe.Core.Networking;

public static class NetworkIdentityFormatter
{
    public static string FormatSummary(
        LanNetwork network,
        PublicNetworkIdentity? publicIdentity,
        int? onlineDeviceCount = null)
    {
        ArgumentNullException.ThrowIfNull(network);

        var ispName = publicIdentity?.IspName ?? "ISP unavailable";
        var summary = $"{ispName}, {network.Cidr}";
        if (onlineDeviceCount is null)
        {
            return summary;
        }

        var deviceLabel = onlineDeviceCount == 1 ? "device" : "devices";
        return $"{summary}, {onlineDeviceCount:N0} online {deviceLabel}";
    }
}
