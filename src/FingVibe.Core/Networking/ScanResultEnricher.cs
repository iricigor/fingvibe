using System.Net;
using System.Net.NetworkInformation;
using FingVibe.Core.Models;

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
        var nameTask = _nameResolver.ResolveWithEvidenceAsync(address, ssdpNames, cancellationToken,
            mdns?.HostName, queryMdns: false);
        await Task.WhenAll(portsTask, vendorTask, nameTask, bannersTask).ConfigureAwait(false);

        return new ScanEnrichment(
            nameTask.Result.DisplayName,
            macAddress,
            vendorTask.Result,
            portsTask.Result,
            DeviceClassifier.ClassifyAdvertisements(discovery.SsdpDevices.GetValueOrDefault(address) ?? [],
                mdns, nameTask.Result.DisplayName, vendorTask.Result, portsTask.Result, bannersTask.Result, responseTtl))
        {
            ReportedValues = CollectReportedValues(discovery.SsdpDevices.GetValueOrDefault(address) ?? [],
                mdns, nameTask.Result.Candidates),
            ServiceAdvertisements = CollectAdvertisements(discovery.SsdpDevices.GetValueOrDefault(address) ?? [], mdns)
        };
    }

    internal static IReadOnlyList<ServiceAdvertisement> CollectAdvertisements(
        IReadOnlyList<SsdpDeviceInfo> ssdp, MdnsDeviceInfo? mdns)
    {
        static string? Bounded(string? value) =>
            value?.Trim() is { Length: > 0 and <= ServiceAdvertisement.MaximumTextLength } text && !text.Any(char.IsControl)
                ? text : null;
        var advertisements = new List<ServiceAdvertisement>(mdns?.Advertisements ?? []);
        foreach (var device in ssdp)
        {
            if (device.ObservedAt is not { } observedAt) continue;
            var deviceType = Bounded(device.DeviceType);
            var shortType = deviceType?.Split(':') is { Length: >= 2 } parts ? Bounded(parts[^2]) : null;
            advertisements.Add(new ServiceAdvertisement(
                ServiceDiscoveryProtocol.Ssdp, deviceType ?? "upnp:rootdevice", "UPnP device",
                shortType is null ? null : $"UPnP {shortType}", null, null, null, null,
                Bounded(device.FriendlyName), Bounded(device.Manufacturer), Bounded(device.ModelName), observedAt));
        }
        return advertisements
            .DistinctBy(item => (item.Protocol, item.ServiceType, item.InstanceName, item.Port, item.AdvertisedName))
            .Take(ServiceAdvertisement.MaximumPerResult).ToArray();
    }

    internal static IReadOnlyList<ReportedDeviceValue> CollectReportedValues(
        IReadOnlyList<SsdpDeviceInfo> ssdp, MdnsDeviceInfo? mdns, IReadOnlyList<DeviceNameCandidate> names)
    {
        var values = new List<ReportedDeviceValue>(mdns?.ReportedValues ?? []);
        foreach (var device in ssdp)
        {
            if (device.FriendlyName is { } name) values.Add(new(ReportedDeviceValueKind.SsdpName, name));
            if (device.DeviceUuid is { } uuid) values.Add(new(ReportedDeviceValueKind.UpnpUuid, uuid));
        }
        foreach (var candidate in names)
        {
            var kind = candidate.Source switch
            {
                DeviceNameSource.Ssdp => ReportedDeviceValueKind.SsdpName,
                DeviceNameSource.Mdns => ReportedDeviceValueKind.MdnsName,
                DeviceNameSource.NetBios => ReportedDeviceValueKind.NetBiosName,
                DeviceNameSource.ReverseDns => ReportedDeviceValueKind.ReverseDnsName,
                _ => throw new ArgumentOutOfRangeException(nameof(names))
            };
            values.Add(new(kind, candidate.Name));
        }
        return DeviceReportedValues.Collect(values);
    }

    private async Task<IReadOnlyList<ServiceBanner>> ProbeBannersAsync(IPAddress address,
        Task<IReadOnlyList<Models.OpenPort>> portsTask, CancellationToken cancellationToken) =>
        await _bannerProbe.ProbeAsync(address, await portsTask.ConfigureAwait(false), cancellationToken)
            .ConfigureAwait(false);
}
