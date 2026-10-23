using System.Net;
using System.Net.NetworkInformation;
using FingVibe.Core.Models;

namespace FingVibe.Core.Networking;

public interface IScanResultEnricher
{
    Task<ScanEnrichment> EnrichAsync(
        IPAddress address,
        Task<IReadOnlyDictionary<IPAddress, IReadOnlyList<SsdpDeviceInfo>>> ssdpDevicesTask,
        CancellationToken cancellationToken);
}

public sealed record ScanEnrichment(
    string? DeviceName,
    PhysicalAddress? MacAddress,
    string VendorName,
    IReadOnlyList<OpenPort> OpenPorts,
    DeviceClassification? Classification = null);
