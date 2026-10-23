using System.Net;
using System.Net.NetworkInformation;
using FingVibe.Core.Models;

namespace FingVibe.Core.Networking;

public interface IScanResultEnricher
{
    Task<ScanEnrichment> EnrichAsync(
        IPAddress address,
        Task<ScanDiscovery> discoveryTask,
        CancellationToken cancellationToken,
        int? responseTtl = null);
}

public sealed record ScanDiscovery(
    IReadOnlyDictionary<IPAddress, IReadOnlyList<SsdpDeviceInfo>> SsdpDevices,
    IReadOnlyDictionary<IPAddress, MdnsDeviceInfo> MdnsDevices);

public sealed record ScanEnrichment(
    string? DeviceName,
    PhysicalAddress? MacAddress,
    string VendorName,
    IReadOnlyList<OpenPort> OpenPorts,
    DeviceClassification? Classification = null);
