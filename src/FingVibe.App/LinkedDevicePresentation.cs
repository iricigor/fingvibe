using System.Globalization;
using FingVibe.Core.Models;

namespace FingVibe.App;

public enum MergeSectionState { NoSuggestions, PossibleMatches, Linked, LinkedWithMatches, Unavailable }

/// <summary>The collapsed header: a count (and, for a linked device with suggestions, a separate match count).</summary>
public sealed record MergeSectionHeader(MergeSectionState State, string CountText, string Explanation, string? MatchText = null)
{
    public string Text => MatchText is null ? CountText : $"{CountText} · {MatchText}";
}

public enum LinkedField { Name, DeviceType, OperatingSystem, Vendor, Family, Model, Icon, Person, Room, UsageCategory }

public enum LinkedFieldChoice { None, ThisDevice, OtherDevice, Typed }

/// <summary>A record or linked device offered by the picker; suggestions carry their reason.</summary>
public sealed record LinkCandidate(string Mac, ScanResultRow Row, DeviceMatchSuggestion? Suggestion, bool Declined, int MacCount = 1)
{
    public bool IsSuggested => Suggestion is not null;
    public bool IsLinkedDevice => MacCount > 1;
}

public sealed record LinkedMemberLine(string Mac, string Address, string AdapterVendor, string Status, DateTimeOffset LinkedAt, bool IsShownInDevices)
{
    public string Text => $"{FormatMac(Mac)} · {Address} · "
        + $"{AdapterVendor} · {Status} · linked {LinkedAt.ToLocalTime().ToString("d", CultureInfo.CurrentCulture)}"
        + (IsShownInDevices ? " · Shown in Devices" : string.Empty);

    public static string FormatMac(string mac) =>
        string.Join("-", Enumerable.Range(0, mac.Length / 2).Select(index => mac.Substring(index * 2, 2)));
}

/// <summary>One row of "Choose the shared device data"; a differing value needs an explicit choice.</summary>
public sealed class LinkedFieldDraft
{
    private readonly object? _thisValue;
    private readonly object? _otherValue;

    internal LinkedFieldDraft(LinkedField field, string label, string thisText, object? thisValue,
        string otherText, object? otherValue, bool differs)
    {
        Field = field;
        Label = label;
        ThisText = thisText;
        OtherText = otherText;
        _thisValue = thisValue;
        _otherValue = otherValue;
        Differs = differs;
    }

    public LinkedField Field { get; }
    public string Label { get; }
    public string ThisText { get; }
    public string OtherText { get; }
    public bool Differs { get; }
    public bool CanType => Field == LinkedField.Name;
    public LinkedFieldChoice Choice { get; private set; }
    public string TypedName { get; private set; } = string.Empty;

    public bool IsResolved => Choice switch
    {
        LinkedFieldChoice.ThisDevice or LinkedFieldChoice.OtherDevice => true,
        LinkedFieldChoice.Typed => !string.IsNullOrWhiteSpace(TypedName),
        _ => !Differs
    };

    public string ResultText => Choice switch
    {
        LinkedFieldChoice.ThisDevice => ThisText,
        LinkedFieldChoice.OtherDevice => OtherText,
        LinkedFieldChoice.Typed when IsResolved => TypedName.Trim(),
        _ => Differs ? "Choose a value" : ThisText
    };

    internal object? Result => Choice switch
    {
        LinkedFieldChoice.OtherDevice => _otherValue,
        LinkedFieldChoice.Typed => TypedName.Trim(),
        _ => _thisValue
    };

    public void Choose(LinkedFieldChoice choice)
    {
        if (choice == LinkedFieldChoice.Typed) throw new ArgumentException("Type a name instead.", nameof(choice));
        if (!Differs && choice != LinkedFieldChoice.None)
            throw new InvalidOperationException("Matching values are kept without a choice.");
        Choice = choice;
    }

    /// <summary>Types the shared name; clearing the text returns to the earlier unresolved state.</summary>
    public void TypeName(string? text)
    {
        if (!CanType) throw new InvalidOperationException("Only the name can be typed.");
        TypedName = text ?? string.Empty;
        if (!string.IsNullOrWhiteSpace(TypedName)) Choice = LinkedFieldChoice.Typed;
        else if (Choice == LinkedFieldChoice.Typed) Choice = LinkedFieldChoice.None;
    }
}

/// <summary>The draft shared values for linking two records. Nothing is saved until <see cref="ToChoices"/> is used.</summary>
public sealed class LinkedDeviceDraft
{
    private LinkedDeviceDraft(ScanResultRow device, ScanResultRow other, IReadOnlyList<LinkedFieldDraft> fields)
    {
        Device = device;
        Other = other;
        Fields = fields;
    }

    public ScanResultRow Device { get; }
    public ScanResultRow Other { get; }
    public IReadOnlyList<LinkedFieldDraft> Fields { get; }
    public int UnresolvedCount => Fields.Count(field => !field.IsResolved);
    public bool CanMerge => UnresolvedCount == 0;
    public LinkedFieldDraft? this[LinkedField field] => Fields.FirstOrDefault(item => item.Field == field);

    public static LinkedDeviceDraft Create(ScanResultRow device, ScanResultRow other)
    {
        var fields = new List<LinkedFieldDraft>
        {
            Same(LinkedField.Name, "Name", device.NameText, device.NameText, other.NameText, other.NameText),
            Same(LinkedField.DeviceType, "Device type", device.DeviceTypeText, device.Type, other.DeviceTypeText, other.Type),
            Same(LinkedField.OperatingSystem, "Operating system", device.OperatingSystemText, device.OperatingSystem,
                other.OperatingSystemText, other.OperatingSystem),
            Same(LinkedField.Vendor, "Vendor / manufacturer", device.BrandText, Optional(device.BrandText),
                other.BrandText, Optional(other.BrandText))
        };
        if (device.FamilyText != "-" || other.FamilyText != "-")
            fields.Add(Same(LinkedField.Family, "Family", device.FamilyText, Optional(device.FamilyText),
                other.FamilyText, Optional(other.FamilyText)));
        if (device.ModelText != "-" || other.ModelText != "-")
            fields.Add(Same(LinkedField.Model, "Model", device.ModelText, Optional(device.ModelText),
                other.ModelText, Optional(other.ModelText)));
        if (device.ClassificationOverride?.Icon is not null || other.ClassificationOverride?.Icon is not null)
            fields.Add(Same(LinkedField.Icon, "Device icon", device.IconText, device.ClassificationOverride?.Icon,
                other.IconText, other.ClassificationOverride?.Icon));
        fields.Add(Same(LinkedField.Person, "Person", device.PersonFullName, device.PersonId, other.PersonFullName, other.PersonId));
        fields.Add(Same(LinkedField.Room, "Room", device.RoomFullName, device.RoomId, other.RoomFullName, other.RoomId));
        fields.Add(new(LinkedField.UsageCategory, "Usage category", UsageText(device), Usage(device),
            UsageText(other), Usage(other), device.EffectiveUsageCategory != other.EffectiveUsageCategory));
        return new(device, other, fields);
    }

    public LinkedDeviceChoices ToChoices()
    {
        if (!CanMerge) throw new InvalidOperationException("Choose every differing value before merging.");
        T? Value<T>(LinkedField field) where T : struct => (T?)this[field]?.Result;
        string? Text(LinkedField field) => this[field]?.Result as string;
        var usage = (UsageChoice)this[LinkedField.UsageCategory]!.Result!;
        var other = (UsageChoice)Usage(Other)!;
        // Matching automatic categories stay automatic; any manual or chosen category becomes the shared override.
        var shared = !this[LinkedField.UsageCategory]!.Differs && usage.Override is null && other.Override is null
            ? null : usage.Effective;
        var person = Value<Guid>(LinkedField.Person);
        var room = Value<Guid>(LinkedField.Room);
        return new(Text(LinkedField.Name)!,
            new DeviceClassificationOverride(Value<DeviceOperatingSystem>(LinkedField.OperatingSystem),
                Value<DeviceType>(LinkedField.DeviceType), Value<DeviceType>(LinkedField.Icon),
                Text(LinkedField.Vendor), Text(LinkedField.Family), Text(LinkedField.Model)),
            person is null && room is null ? null : new DeviceAssignment(person, room), shared);
    }

    private sealed record UsageChoice(DeviceUsageCategory? Effective, DeviceUsageCategory? Override);

    private static object? Usage(ScanResultRow row) => new UsageChoice(row.EffectiveUsageCategory, row.UsageCategoryOverride);

    private static string UsageText(ScanResultRow row) => row.EffectiveUsageCategory is not { } category ? "Unavailable"
        : $"{category} - {(row.UsageCategoryOverride is not null ? "Manual" : "Auto")}";

    private static string? Optional(string text) => text == "-" ? null : text;

    private static LinkedFieldDraft Same(LinkedField field, string label, string thisText, object? thisValue,
        string otherText, object? otherValue) =>
        new(field, label, thisText, thisValue, otherText, otherValue, !Equals(thisValue, otherValue));
}

public static class LinkedDevicePresentation
{
    public const string VirtualExplanation =
        "A virtual device groups changing private MAC addresses automatically, so it can't be linked. "
        + "You can still name it and assign it to a person or room.";

    public const string LinkedExplanation =
        "Linked by you. Edit the shared name, identification, Person, Room and usage category in their own sections.";

    public const string SeparateRecords =
        "MAC addresses, adapter vendors, IPs, ports and scan histories stay separate. No source records are deleted.";

    public const string PickerFooter = "Virtual devices can't be linked and aren't listed.";

    public static MergeSectionHeader Header(ScanResultRow row, DeviceInventoryData data)
    {
        var mac = row.MacAddress?.GetAddressBytes().Length == 6 ? row.MacAddress.ToString() : null;
        if (row.IsVirtualIdentity || mac is not null && data.VirtualGroupedMacs().Contains(mac))
            return new(MergeSectionState.Unavailable, "Not available for virtual devices", VirtualExplanation);
        if (mac is null || !data.Devices.ContainsKey(mac))
            return new(MergeSectionState.Unavailable, "Not available without a saved MAC address",
                "Linking needs a saved MAC address record. IP addresses can change.");
        if (data.FindLinkedDevice(mac) is { } linked)
            return row.MatchSuggestions.Count == 0
                ? new(MergeSectionState.Linked, $"{linked.Members.Count} MAC addresses", LinkedExplanation)
                : new(MergeSectionState.LinkedWithMatches, $"{linked.Members.Count} MAC addresses", LinkedExplanation,
                    MatchCount(row.MatchSuggestions.Count));
        return row.MatchSuggestions.Count switch
        {
            0 => new(MergeSectionState.NoSuggestions, "No suggestions",
                "No other record looks like this device. Choose a device to link it manually."),
            var count => new(MergeSectionState.PossibleMatches, MatchCount(count), string.Empty)
        };
    }

    private static string MatchCount(int count) => count == 1 ? "1 possible match" : $"{count} possible matches";

    /// <summary>
    /// Suggestions first (strongest first), then every other record or linked device outside virtual devices. A linked
    /// device is offered once with its MAC count; the open device's own members are never offered.
    /// </summary>
    public static IReadOnlyList<LinkCandidate> Candidates(ScanResultRow device, IEnumerable<ScanResultRow> rows,
        DeviceInventoryData data, string? search = null)
    {
        var mac = device.MacAddress?.ToString() ?? throw new ArgumentException("A MAC address is required.", nameof(device));
        var own = data.LinkUnit(mac).ToHashSet(StringComparer.Ordinal);
        var grouped = data.VirtualGroupedMacs();
        var declined = data.DeclinedMatches.Select(item => item.Key).ToHashSet(StringComparer.Ordinal);
        var eligible = new List<(string Mac, ScanResultRow Row, IReadOnlyList<string> Unit)>();
        foreach (var row in rows.Where(row => row.VirtualDevice is null && row.MacAddress?.GetAddressBytes().Length == 6))
        {
            var rowMac = row.MacAddress!.ToString();
            if (own.Contains(rowMac) || !data.Devices.ContainsKey(rowMac) || grouped.Contains(rowMac)) continue;
            var linked = data.FindLinkedDevice(rowMac);
            if (linked is not null && !row.IsLinkedDeviceRow) continue;
            if (eligible.Any(item => item.Unit.Contains(rowMac))) continue;
            eligible.Add((rowMac, row, linked is null ? [rowMac] : data.LinkUnit(rowMac)));
        }
        var suggested = device.MatchSuggestions
            .Select(item => (Suggestion: item, Entry: eligible.FirstOrDefault(entry => entry.Unit.Contains(item.OtherMac))))
            .Where(item => item.Entry.Row is not null)
            .DistinctBy(item => item.Entry.Mac)
            .Select(item => new LinkCandidate(item.Suggestion.OtherMac, item.Entry.Row, item.Suggestion, false, item.Entry.Unit.Count))
            .ToArray();
        var others = eligible.Where(entry => suggested.All(item => item.Row != entry.Row))
            .OrderBy(entry => entry.Row.NameText, StringComparer.CurrentCultureIgnoreCase)
            .ThenBy(entry => entry.Mac, StringComparer.Ordinal)
            .Select(entry => new LinkCandidate(entry.Mac, entry.Row, null,
                own.All(first => entry.Unit.All(second => declined.Contains(DeclinedDeviceMatch.Create(first, second).Key))),
                entry.Unit.Count));
        return suggested.Concat(others).Where(item => Matches(item, search)).ToArray();
    }

    public static IReadOnlyList<LinkedMemberLine> Members(LinkedDevice linked, DeviceInventoryData data, string? shownMac) =>
        linked.Members.Select(member =>
        {
            var device = data.Devices.GetValueOrDefault(member.Mac);
            var observation = device?.LatestObservation;
            var status = device?.Status switch
            {
                InventoryDeviceStatus.Online => "Online",
                InventoryDeviceStatus.Offline => "Offline",
                InventoryDeviceStatus.FingOnly => "Fing Only",
                _ => "Unknown"
            };
            return new LinkedMemberLine(member.Mac, observation?.Address ?? device?.Imported.Address ?? "-",
                DeviceVendorPresentation.DisplayText(observation?.Vendor ?? "Unknown"),
                status, member.LinkedAt, member.Mac == shownMac);
        }).ToArray();

    public static string CandidateText(LinkCandidate candidate) =>
        $"{candidate.Row.NameText} · {candidate.Row.AddressText} · {candidate.Row.MacAddressText}"
        + (candidate.IsLinkedDevice ? $" · {candidate.MacCount} MAC addresses" : string.Empty)
        + (candidate.Suggestion is { } suggestion ? $" · {suggestion.ShortReason}" : string.Empty)
        + (candidate.Declined ? " · Declined" : string.Empty);

    private static bool Matches(LinkCandidate candidate, string? search)
    {
        var text = search?.Trim();
        if (string.IsNullOrEmpty(text)) return true;
        var row = candidate.Row;
        var compact = text.Replace("-", string.Empty).Replace(":", string.Empty);
        return row.NameText.Contains(text, StringComparison.CurrentCultureIgnoreCase)
            || row.AddressText.Contains(text, StringComparison.OrdinalIgnoreCase)
            || row.MacAddressText.Contains(text, StringComparison.OrdinalIgnoreCase)
            || compact.Length > 0 && candidate.Mac.Contains(compact, StringComparison.OrdinalIgnoreCase)
            || row.VendorDisplayText.Contains(text, StringComparison.CurrentCultureIgnoreCase)
            || candidate.IsLinkedDevice && row.MatchesEarlierMac(text);
    }
}
