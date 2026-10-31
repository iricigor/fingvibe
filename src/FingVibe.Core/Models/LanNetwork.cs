using System.Net;

namespace FingVibe.Core.Models;

public sealed record LanNetwork(
    string InterfaceName,
    IPAddress LocalAddress,
    IPAddress NetworkAddress,
    int PrefixLength,
    bool HasGateway,
    IPAddress? GatewayAddress = null,
    string? InterfaceId = null)
{
    public string Cidr => $"{NetworkAddress}/{PrefixLength}";

    public string DisplayLabel => $"{InterfaceName} - {LocalAddress} ({Cidr})";
}
