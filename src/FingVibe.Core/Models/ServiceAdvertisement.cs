using System.Text.RegularExpressions;

namespace FingVibe.Core.Models;

public enum ServiceDiscoveryProtocol
{
    Mdns,
    Ssdp
}

// TCP verification of an advertised endpoint; advertisements alone never count as open ports.
public enum AdvertisedEndpointState
{
    NotApplicable,
    Open,
    NoResponse,
    NotChecked
}

// One advertisement received from a responder during a scan. It is response evidence for that scan,
// not a verified physical identity, hostname or exact hardware model.
public sealed record ServiceAdvertisement(
    ServiceDiscoveryProtocol Protocol,
    string ServiceType,
    string ServiceLabel,
    string? Role,
    string? InstanceName,
    string? Host,
    int? Port,
    EndpointProtocol? Transport,
    string? AdvertisedName,
    string? Manufacturer,
    string? Model,
    DateTimeOffset ObservedAt,
    AdvertisedEndpointState Verification = AdvertisedEndpointState.NotApplicable)
{
    public const int MaximumPerResult = 32;
    public const int MaximumTextLength = 256;

    public string ProtocolText => Protocol == ServiceDiscoveryProtocol.Mdns ? "mDNS/DNS-SD" : "SSDP/UPnP";

    public string EndpointText => Port is { } port
        ? $"{Host ?? "advertised host"}:{port}/{(Transport ?? EndpointProtocol.Tcp).ToString().ToUpperInvariant()}"
        : "No endpoint advertised";

    public string VerificationText => Verification switch
    {
        AdvertisedEndpointState.Open => "TCP verified: open",
        AdvertisedEndpointState.NoResponse => "TCP verified: no response - not counted as open",
        AdvertisedEndpointState.NotChecked => "TCP not checked: per-scan verification limit reached",
        _ => Transport == EndpointProtocol.Udp ? "UDP endpoint - not probed" : "No TCP endpoint to verify"
    };

    public string Summary => Role is null ? ServiceLabel : $"{ServiceLabel} ({Role})";

    public static bool IsValid(IReadOnlyList<ServiceAdvertisement>? items) =>
        items is not null && items.Count <= MaximumPerResult && items.All(item => item is not null
            && Enum.IsDefined(item.Protocol) && Enum.IsDefined(item.Verification)
            && (item.Transport is null || Enum.IsDefined(item.Transport.Value))
            && ValidText(item.ServiceType, required: true) && ValidText(item.ServiceLabel, required: true)
            && ValidText(item.Role) && ValidText(item.InstanceName) && ValidText(item.Host)
            && ValidText(item.AdvertisedName) && ValidText(item.Manufacturer) && ValidText(item.Model)
            && item.Port is null or (>= 1 and <= 65_535) && item.ObservedAt != default
            && (item.Verification is AdvertisedEndpointState.NotApplicable
                || item.Port is not null && item.Transport == EndpointProtocol.Tcp));

    private static bool ValidText(string? value, bool required = false) => value is null
        ? !required
        : value.Length is > 0 and <= MaximumTextLength && value.Trim().Length == value.Length
            && !value.Any(char.IsControl);
}

// Interprets service types as evidence-backed roles; a service type is never an exact hardware model.
public static class ServiceDiscoveryCatalog
{
    public const string EnumerationName = "_services._dns-sd._udp.local";

    private static readonly Regex ServiceTypePattern = new(
        @"^_[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\._(?:tcp|udp)\.local$",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    private static readonly IReadOnlyDictionary<string, (string Label, string? Role)> Known =
        new Dictionary<string, (string, string?)>(StringComparer.OrdinalIgnoreCase)
        {
            ["_spotify-connect._tcp.local"] = ("Spotify Connect", "Spotify Connect playback endpoint"),
            ["_hue._tcp.local"] = ("Philips Hue", "Hue bridge service"),
            ["_home-assistant._tcp.local"] = ("Home Assistant", "Home Assistant server"),
            ["_matter._tcp.local"] = ("Matter", "Matter operational node"),
            ["_matterc._udp.local"] = ("Matter", "Matter commissionable device"),
            ["_matterd._udp.local"] = ("Matter", "Matter commissioner"),
            ["_googlecast._tcp.local"] = ("Google Cast", "Cast receiver"),
            ["_airplay._tcp.local"] = ("AirPlay", "AirPlay receiver"),
            ["_raop._tcp.local"] = ("AirPlay audio", "AirPlay audio receiver"),
            ["_ipp._tcp.local"] = ("IPP printing", "Printer"),
            ["_ipps._tcp.local"] = ("IPP printing over TLS", "Printer"),
            ["_printer._tcp.local"] = ("LPD printing", "Printer"),
            ["_hap._tcp.local"] = ("HomeKit", "HomeKit accessory"),
            ["_smb._tcp.local"] = ("SMB file sharing", null),
            ["_adisk._tcp.local"] = ("Time Machine disk", null),
            ["_workstation._tcp.local"] = ("Workstation", null),
            ["_device-info._tcp.local"] = ("Device information", null),
            ["_androidtvremote._tcp.local"] = ("Android TV remote", "Android TV device"),
            ["_androidtvremote2._tcp.local"] = ("Android TV remote", "Android TV device"),
            ["_adb-tls-connect._tcp.local"] = ("Android debugging", null),
            ["_mqtt._tcp.local"] = ("MQTT", "MQTT broker"),
            ["_http._tcp.local"] = ("HTTP", null)
        };

    public static bool IsServiceType(string? name) => name is not null && ServiceTypePattern.IsMatch(name);

    public static (string Label, string? Role) Describe(string serviceType) =>
        Known.TryGetValue(serviceType, out var known) ? known : (serviceType.ToLowerInvariant(), null);

    public static EndpointProtocol TransportOf(string serviceType) =>
        serviceType.EndsWith("._udp.local", StringComparison.OrdinalIgnoreCase) ? EndpointProtocol.Udp : EndpointProtocol.Tcp;
}
