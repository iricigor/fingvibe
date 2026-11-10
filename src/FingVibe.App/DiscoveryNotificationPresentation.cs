using System.Xml.Linq;
using FingVibe.Core.Models;

namespace FingVibe.App;

public sealed record DiscoveryDevice(string IdentityKey, string Mac, string Name, string Address, string IconGlyph)
{
    public string AutomationId => $"Discovery-{Mac}";
    public string FormattedMac => string.Join("-", Enumerable.Range(0, 6).Select(i => Mac.Substring(i * 2, 2)));
    public string Addresses => Address is "" or "-" ? FormattedMac : $"{Address} \u00b7 {FormattedMac}";

    internal static DiscoveryDevice Capture(DeviceDiscovery discovery, ScanResultRow? row) =>
        new(discovery.IdentityKey, discovery.Mac,
            row is null || string.IsNullOrWhiteSpace(row.NameText) || row.NameText == "-" || row.NameText == row.AddressText
                ? "Unnamed device" : row.NameText,
            row?.AddressText ?? "", row?.IconGlyph ?? "\uE9CE");
}

public sealed record DiscoveryPopupItem(DiscoveryDevice Device, bool DetailsAvailable)
{
    public string AccessibleName => DetailsAvailable
        ? $"Open details for {Device.Name}, {Device.FormattedMac}, {Device.Address}"
        : $"{Device.Name}, {Device.Addresses}. Details unavailable: not in the displayed results.";
    public string DetailsStatus => DetailsAvailable ? "" : "Details unavailable: not in the displayed results";
}

internal sealed record DiscoveryNotificationBatch(Guid Id, DateTimeOffset ExpiresAt, DiscoveryDevice[] Devices);

internal static class DiscoveryNotificationPresentation
{
    internal static string Count(int count) => $"{count} new {(count == 1 ? "device" : "devices")}";
    internal static string Argument(Guid id) => $"discovery={id:D}";

    internal static Guid ParseArgument(string argument) =>
        argument.StartsWith("discovery=", StringComparison.Ordinal)
        && Guid.TryParseExact(argument["discovery=".Length..], "D", out var id)
        && id != Guid.Empty ? id : throw new InvalidDataException("The discovery notification link is invalid.");

    internal static string ToastXml(DiscoveryNotificationBatch batch, string imagePath)
    {
        var single = batch.Devices.Length == 1;
        var preview = string.Join(", ", batch.Devices.Take(3).Select(device =>
        {
            var name = device.Name == "Unnamed device" ? $"{device.Name} \u00b7 {device.Address}" : device.Name;
            return name.Length <= 60 ? name
                : string.Concat(name.EnumerateRunes().Take(59).Select(rune => rune.ToString())) + "\u2026";
        }));
        if (batch.Devices.Length > 3) preview += $" (+{batch.Devices.Length - 3} more)";
        var argument = Argument(batch.Id);
        return new XElement("toast", new XAttribute("launch", argument),
            new XElement("visual", new XElement("binding", new XAttribute("template", "ToastGeneric"),
                new XElement("image", new XAttribute("placement", "appLogoOverride"),
                    new XAttribute("src", new Uri(imagePath).AbsoluteUri),
                    new XAttribute("alt", "Unfamiliar device: review its details")),
                new XElement("text", single ? "Unknown device detected" : Count(batch.Devices.Length)),
                new XElement("text", single
                    ? "A new device appeared on your network. Review its details."
                    : "New devices appeared on your network. Review their details."),
                new XElement("text", single ? $"1 new device \u00b7 {preview}" : preview))),
            new XElement("actions", new XElement("action",
                new XAttribute("content", single ? "Review device" : "Review devices"),
                new XAttribute("arguments", argument), new XAttribute("activationType", "foreground"))))
            .ToString(SaveOptions.DisableFormatting);
    }
}

// Only completed, successfully persisted discoveries enter here. Restoration and activation never send.
internal sealed class DiscoveryNotificationState(
    Action<IReadOnlyList<DiscoveryDevice>, bool> show,
    Action<DiscoveryNotificationBatch> notify,
    TimeProvider? timeProvider = null)
{
    private readonly TimeProvider _time = timeProvider ?? TimeProvider.System;
    private IReadOnlyList<DiscoveryDevice> _pending = [];

    internal void CompleteScan(IReadOnlyList<DiscoveryDevice> devices, bool minimized)
    {
        if (devices.Count == 0) return;
        if (minimized) _pending = Merge(_pending, devices);
        else show(devices, false);
        notify(new(Guid.NewGuid(), _time.GetUtcNow().AddDays(1), devices.ToArray()));
    }

    internal void Restore()
    {
        if (_pending.Count == 0) return;
        var devices = _pending;
        _pending = [];
        show(devices, true);
    }

    internal void Activate(IReadOnlyList<DiscoveryDevice> devices)
    {
        // A toast opens its own scan, not unrelated accumulated discoveries. Leave those for restoration.
        var identities = devices.Select(device => device.IdentityKey).ToHashSet(StringComparer.Ordinal);
        _pending = _pending.Where(device => !identities.Contains(device.IdentityKey)).ToArray();
        show(devices, false);
    }

    private static IReadOnlyList<DiscoveryDevice> Merge(
        IReadOnlyList<DiscoveryDevice> pending, IReadOnlyList<DiscoveryDevice> added) =>
        pending.Concat(added).DistinctBy(device => device.IdentityKey).ToArray();
}
