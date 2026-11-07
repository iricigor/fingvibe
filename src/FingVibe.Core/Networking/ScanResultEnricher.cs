using System.Net;
using System.Net.NetworkInformation;

namespace FingVibe.Core.Networking;

public sealed class ScanResultEnricher : IScanResultEnricher
{
    private readonly DeviceNameResolver _nameResolver;
    private readonly PortScannerService _portScanner;
    private readonly MacAddressResolver _macAddressResolver;
    private readonly IeeeVendorRegistry _vendorRegistry;
    private readonly ServiceBannerProbe _bannerProbe;

    public ScanResultEnricher(
        DeviceNameResolver? nameResolver = null,
        PortScannerService? portScanner = null,
        MacAddressResolver? macAddressResolver = null,
        IeeeVendorRegistry? vendorRegistry = null,
        ServiceBannerProbe? bannerProbe = null)
    {
        _nameResolver = nameResolver ?? new DeviceNameResolver();
        _portScanner = portScanner ?? new PortScannerService();
        _macAddressResolver = macAddressResolver ?? new MacAddressResolver();
        _vendorRegistry = vendorRegistry ?? new IeeeVendorRegistry();
        _bannerProbe = bannerProbe ?? new ServiceBannerProbe();
    }

    public async Task<ScanEnrichment> EnrichAsync(
        IPAddress address,
        Task<ScanDiscovery> discoveryTask,
        CancellationToken cancellationToken,
        int? responseTtl = null) =>
        await EnrichAsync(address, discoveryTask, cancellationToken, responseTtl, null).ConfigureAwait(false);

    public async Task<ScanEnrichment> EnrichAsync(
        IPAddress address, Task<ScanDiscovery> discoveryTask, CancellationToken cancellationToken,
        int? responseTtl, PhysicalAddress? confirmedMac)
    {
        var portsTask = _portScanner.ScanAsync(address, cancellationToken);
        var bannersTask = ProbeBannersAsync(address, portsTask, cancellationToken);
        var macAddress = confirmedMac ?? _macAddressResolver.Resolve(address);
        var vendorTask = _vendorRegistry.ResolveAsync(macAddress, cancellationToken);
        var discovery = await discoveryTask.ConfigureAwait(false);
        var ssdpNames = SsdpDiscoveryService.GetDisplayNames(discovery.SsdpDevices);
        var mdns = discovery.MdnsDevices.GetValueOrDefault(address);
        var nameTask = _nameResolver.ResolveAsync(address, ssdpNames, cancellationToken,
            mdns?.HostName, queryMdns: false);
        await Task.WhenAll(portsTask, vendorTask, nameTask, bannersTask).ConfigureAwait(false);

        return new ScanEnrichment(
            nameTask.Result,
            macAddress,
            vendorTask.Result,
            portsTask.Result,
            DeviceClassifier.ClassifyAdvertisements(discovery.SsdpDevices.GetValueOrDefault(address) ?? [],
                mdns, nameTask.Result, vendorTask.Result, portsTask.Result, bannersTask.Result, responseTtl));
    }

    private async Task<IReadOnlyList<ServiceBanner>> ProbeBannersAsync(IPAddress address,
        Task<IReadOnlyList<Models.OpenPort>> portsTask, CancellationToken cancellationToken) =>
        await _bannerProbe.ProbeAsync(address, await portsTask.ConfigureAwait(false), cancellationToken)
            .ConfigureAwait(false);
}
