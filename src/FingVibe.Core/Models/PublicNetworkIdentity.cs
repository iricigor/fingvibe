using System.Net;

namespace FingVibe.Core.Models;

public sealed record PublicNetworkIdentity(IPAddress PublicAddress, string IspName);
