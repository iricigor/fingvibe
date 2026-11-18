using System.Text;

namespace FingVibe.Core.Models;

public enum ReportedDeviceValueKind
{
    SsdpName,
    MdnsName,
    NetBiosName,
    ReverseDnsName,
    UpnpUuid,
    GoogleCastId,
    HomeKitId,
    AirPlayDeviceId,
    PrinterUuid
}

public sealed record ReportedDeviceValue(ReportedDeviceValueKind Kind, string Value);

public sealed record ObservedDeviceValue(ReportedDeviceValueKind Kind, string Value, DateTimeOffset LastReceivedAt);

public static class DeviceReportedValues
{
    public const int MaximumLength = 128;
    public const int MaximumPerKind = 4;

    public static string? Normalize(ReportedDeviceValueKind kind, string? value)
    {
        if (!Enum.IsDefined(kind) || value is null) return null;
        value = value.Trim();
        if (kind == ReportedDeviceValueKind.UpnpUuid)
        {
            if (value.StartsWith("uuid:", StringComparison.OrdinalIgnoreCase)) value = value[5..].Trim();
            value = value.ToLowerInvariant();
        }
        return value.Length is 0 or > MaximumLength || value.Any(char.IsControl)
            || value.EnumerateRunes().Any(rune => rune.Value == 0xFFFD)
            ? null : value;
    }

    public static IReadOnlyList<ReportedDeviceValue> Collect(IEnumerable<ReportedDeviceValue> values)
    {
        var result = new List<ReportedDeviceValue>();
        foreach (var item in values)
        {
            if (item is null || Normalize(item.Kind, item.Value) is not { } value) continue;
            if (result.Count(saved => saved.Kind == item.Kind) >= MaximumPerKind ||
                result.Any(saved => saved.Kind == item.Kind && string.Equals(saved.Value, value, StringComparison.OrdinalIgnoreCase)))
                continue;
            result.Add(new(item.Kind, value));
        }
        return result.OrderBy(item => item.Kind).ThenBy(item => item.Value, StringComparer.OrdinalIgnoreCase).ToArray();
    }

    public static bool IsValid(IReadOnlyList<ReportedDeviceValue>? values)
    {
        if (values is null) return false;
        if (values.Count == 0) return true;
        return values.Count <= Enum.GetValues<ReportedDeviceValueKind>().Length * MaximumPerKind
            && values.All(item => item is not null && Normalize(item.Kind, item.Value) == item.Value)
            && Collect(values).Count == values.Count;
    }

    public static IReadOnlyList<ObservedDeviceValue> Retain(IReadOnlyList<ObservedDeviceValue> previous,
        IReadOnlyList<ReportedDeviceValue> received, DateTimeOffset completedAt)
    {
        if (received.Count == 0) return previous;
        var incoming = Collect(received);
        if (incoming.Count == 0) return previous;
        var replaced = incoming.Select(item => item.Kind).ToHashSet();
        return previous.Where(item => !replaced.Contains(item.Kind))
            .Concat(incoming.Select(item => new ObservedDeviceValue(item.Kind, item.Value, completedAt)))
            .OrderBy(item => item.Kind).ThenBy(item => item.Value, StringComparer.OrdinalIgnoreCase).ToArray();
    }

    public static string Label(this ReportedDeviceValueKind kind) => kind switch
    {
        ReportedDeviceValueKind.SsdpName => "SSDP friendly name",
        ReportedDeviceValueKind.MdnsName => "mDNS host name",
        ReportedDeviceValueKind.NetBiosName => "NetBIOS name",
        ReportedDeviceValueKind.ReverseDnsName => "Reverse-DNS name",
        ReportedDeviceValueKind.UpnpUuid => "UPnP device UUID",
        ReportedDeviceValueKind.GoogleCastId => "Google Cast ID",
        ReportedDeviceValueKind.HomeKitId => "HomeKit ID",
        ReportedDeviceValueKind.AirPlayDeviceId => "AirPlay device ID",
        ReportedDeviceValueKind.PrinterUuid => "Printer UUID",
        _ => throw new ArgumentOutOfRangeException(nameof(kind))
    };
}
