using System.Net;

namespace FingVibe.Core.Models;

public sealed record PublicNetworkIdentity(
    IPAddress PublicAddress,
    string IspName,
    string? Location = null)
{
    public const string UnknownLocation = "Unknown";

    public string LocationText => string.IsNullOrWhiteSpace(Location) ? UnknownLocation : Location;
}
