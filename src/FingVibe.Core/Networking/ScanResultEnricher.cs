using System.Net;

namespace FingVibe.Core.Networking;

public sealed class ScanResultEnricher : IScanResultEnricher
{
    private readonly DeviceNameResolver _nameResolver;
    private readonly PortScannerService _portScanner;
    private readonly MacAddressResolver _macAddressResolver;
    private readonly IeeeVendorRegistry _vendorRegistry;
    private readonly MdnsDeviceDiscoveryService _mdnsDiscovery;

    public ScanResultEnricher(
        DeviceNameResolver? nameResolver = null,
        PortScannerService? portScanner = null,
        MacAddressResolver? macAddressResolver = null,
        IeeeVendorRegistry? vendorRegistry = null,
        MdnsDeviceDiscoveryService? mdnsDiscovery = null)
    {
        _nameResolver = nameResolver ?? new DeviceNameResolver();
        _portScanner = portScanner ?? new PortScannerService();
        _macAddressResolver = macAddressResolver ?? new MacAddressResolver();
        _vendorRegistry = vendorRegistry ?? new IeeeVendorRegistry();
        _mdnsDiscovery = mdnsDiscovery ?? new MdnsDeviceDiscoveryService();
    }

    public async Task<ScanEnrichment> EnrichAsync(
        IPAddress address,
        Task<IReadOnlyDictionary<IPAddress, IReadOnlyList<SsdpDeviceInfo>>> ssdpDevicesTask,
        CancellationToken cancellationToken)
    {
        var portsTask = _portScanner.ScanAsync(address, cancellationToken);
        var mdnsTask = _mdnsDiscovery.DiscoverAsync(address, cancellationToken);
        var macAddress = _macAddressResolver.Resolve(address);
        var vendorTask = _vendorRegistry.ResolveAsync(macAddress, cancellationToken);
        var ssdpDevices = await ssdpDevicesTask.ConfigureAwait(false);
        var ssdpNames = SsdpDiscoveryService.GetDisplayNames(ssdpDevices);
        var nameTask = _nameResolver.ResolveAsync(address, ssdpNames, cancellationToken);
        await Task.WhenAll(portsTask, vendorTask, nameTask, mdnsTask).ConfigureAwait(false);

        return new ScanEnrichment(
            nameTask.Result,
            macAddress,
            vendorTask.Result,
            portsTask.Result,
            DeviceClassifier.ClassifyAdvertisements(ssdpDevices.GetValueOrDefault(address) ?? [], mdnsTask.Result));
    }
}
