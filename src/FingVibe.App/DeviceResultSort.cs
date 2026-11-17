using System.Globalization;
using System.Net;
using System.Text;

namespace FingVibe.App;

internal enum ResultSortColumn
{
    Address,
    Status,
    Response,
    MacAddress,
    OperatingSystem,
    DeviceType,
    Name,
    Vendor,
    OpenPorts,
    Person,
    Room,
    LastSeen,
    UsageCategory
}

internal static class DeviceResultSort
{
    internal static int Compare(ScanResultRow left, ScanResultRow right, ResultSortColumn column, bool ascending,
        bool ignoreNameEmoji = false)
    {
        // Missing assignments and last-seen values stay last in both directions; do not reverse them with the keys.
        var assignmentPresence = column switch
        {
            ResultSortColumn.Person => (left.PersonId is null).CompareTo(right.PersonId is null),
            ResultSortColumn.Room => (left.RoomId is null).CompareTo(right.RoomId is null),
            ResultSortColumn.LastSeen => MissingLastSeenRank(left.LastSeen).CompareTo(MissingLastSeenRank(right.LastSeen)),
            ResultSortColumn.UsageCategory => (left.EffectiveUsageCategory is null).CompareTo(right.EffectiveUsageCategory is null),
            _ => 0
        };
        if (assignmentPresence != 0) return assignmentPresence;

        var comparison = column switch
        {
            ResultSortColumn.Name => ignoreNameEmoji
                ? CompareText(WithoutEmoji(left.NameText), WithoutEmoji(right.NameText))
                : CompareText(left.NameText, right.NameText),
            ResultSortColumn.Vendor => CompareText(left.VendorDisplayText, right.VendorDisplayText),
            ResultSortColumn.OpenPorts => left.OpenPortItems.Count.CompareTo(right.OpenPortItems.Count),
            ResultSortColumn.Person => CompareText(left.PersonFullName, right.PersonFullName),
            ResultSortColumn.Room => CompareText(left.RoomFullName, right.RoomFullName),
            ResultSortColumn.OperatingSystem => CompareText(left.OperatingSystemText, right.OperatingSystemText),
            ResultSortColumn.DeviceType => CompareText(left.DeviceTypeText, right.DeviceTypeText),
            ResultSortColumn.Address => CompareAddresses(left.AddressText, right.AddressText),
            ResultSortColumn.Status => left.Status.CompareTo(right.Status),
            ResultSortColumn.Response => Nullable.Compare(left.LatencyMilliseconds, right.LatencyMilliseconds),
            ResultSortColumn.MacAddress => CompareText(left.MacAddressText, right.MacAddressText),
            ResultSortColumn.LastSeen => Nullable.Compare(left.LastSeen.Timestamp, right.LastSeen.Timestamp),
            ResultSortColumn.UsageCategory => CompareText(left.UsageCategoryText, right.UsageCategoryText),
            _ => throw new ArgumentOutOfRangeException(nameof(column), column, "Unknown Devices sort column.")
        };

        if (comparison == 0)
            comparison = string.Compare(left.MacAddressText, right.MacAddressText, StringComparison.Ordinal);
        if (comparison == 0)
            comparison = CompareAddresses(left.AddressText, right.AddressText);

        return ascending ? Math.Sign(comparison) : -Math.Sign(comparison);
    }

    private static int CompareText(string left, string right) =>
        string.Compare(left, right, StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Comparison key that drops complete emoji sequences (grapheme clusters) anywhere in the text and collapses
    /// the whitespace they leave behind. Digits, punctuation and non-emoji symbols are kept; the source is unchanged.
    /// </summary>
    internal static string WithoutEmoji(string? text)
    {
        if (string.IsNullOrEmpty(text)) return string.Empty;
        var key = new StringBuilder(text.Length);
        var pendingSpace = false;
        var elements = StringInfo.GetTextElementEnumerator(text);
        while (elements.MoveNext())
        {
            var element = elements.GetTextElement();
            if (IsEmojiSequence(element)) continue;
            foreach (var rune in element.EnumerateRunes())
            {
                if (IsEmojiComponent(rune.Value)) continue;
                if (Rune.IsWhiteSpace(rune))
                {
                    pendingSpace = key.Length > 0;
                    continue;
                }
                if (pendingSpace) key.Append(' ');
                pendingSpace = false;
                key.Append(rune.ToString());
            }
        }
        return key.ToString();
    }

    private static bool IsEmojiSequence(string element)
    {
        var runes = element.EnumerateRunes().ToArray();
        var first = runes[0];
        if (IsEmojiPresentation(first.Value) || IsRegionalIndicator(first.Value) || IsSkinTone(first.Value))
            return true;
        var keycap = runes.Any(rune => rune.Value == 0x20E3);
        if (keycap) return first.Value is '#' or '*' or (>= '0' and <= '9');
        var emojiVariation = runes.Any(rune => rune.Value == 0xFE0F);
        // Text-presentation symbols (for example a bare ©) stay; the emoji variation selector makes them emoji.
        return emojiVariation && !Rune.IsLetterOrDigit(first) && !Rune.IsWhiteSpace(first);
    }

    // Stray modifiers, selectors, keycap marks and tags that are not part of a complete sequence.
    private static bool IsEmojiComponent(int value) =>
        value is 0xFE0F or 0x20E3 || IsSkinTone(value) || value is >= 0xE0020 and <= 0xE007F;

    private static bool IsRegionalIndicator(int value) => value is >= 0x1F1E6 and <= 0x1F1FF;

    private static bool IsSkinTone(int value) => value is >= 0x1F3FB and <= 0x1F3FF;

    // Default emoji presentation in the BMP plus the Extended_Pictographic ranges of the supplementary plane.
    private static bool IsEmojiPresentation(int value) => value switch
    {
        0x231A or 0x231B or (>= 0x23E9 and <= 0x23EC) or 0x23F0 or 0x23F3 or 0x25FD or 0x25FE
            or 0x2614 or 0x2615 or (>= 0x2648 and <= 0x2653) or 0x267F or 0x2693 or 0x26A1 or 0x26AA or 0x26AB
            or 0x26BD or 0x26BE or 0x26C4 or 0x26C5 or 0x26CE or 0x26D4 or 0x26EA or 0x26F2 or 0x26F3 or 0x26F5
            or 0x26FA or 0x26FD or 0x2705 or 0x270A or 0x270B or 0x2728 or 0x274C or 0x274E
            or (>= 0x2753 and <= 0x2755) or 0x2757 or (>= 0x2795 and <= 0x2797) or 0x27B0 or 0x27BF
            or 0x2B1B or 0x2B1C or 0x2B50 or 0x2B55 => true,
        (>= 0x1F000 and <= 0x1F0FF) or (>= 0x1F10D and <= 0x1F10F) or 0x1F12F or (>= 0x1F16C and <= 0x1F171)
            or 0x1F17E or 0x1F17F or 0x1F18E or (>= 0x1F191 and <= 0x1F19A) or (>= 0x1F1AD and <= 0x1F1E5)
            or (>= 0x1F201 and <= 0x1F20F) or 0x1F21A or 0x1F22F or (>= 0x1F232 and <= 0x1F23A)
            or (>= 0x1F23C and <= 0x1F23F) or (>= 0x1F249 and <= 0x1F3FA) or (>= 0x1F400 and <= 0x1F53D)
            or (>= 0x1F546 and <= 0x1F64F) or (>= 0x1F680 and <= 0x1F6FF) or (>= 0x1F774 and <= 0x1F77F)
            or (>= 0x1F7D5 and <= 0x1F7FF) or (>= 0x1F80C and <= 0x1F80F) or (>= 0x1F848 and <= 0x1F84F)
            or (>= 0x1F85A and <= 0x1F85F) or (>= 0x1F888 and <= 0x1F88F) or (>= 0x1F8AE and <= 0x1F8FF)
            or (>= 0x1F90C and <= 0x1F93A) or (>= 0x1F93C and <= 0x1F945) or (>= 0x1F947 and <= 0x1FAFF)
            or (>= 0x1FC00 and <= 0x1FFFD) => true,
        _ => false
    };

    private static int MissingLastSeenRank(DeviceLastSeen lastSeen) => lastSeen switch
    {
        { Timestamp: not null } => 0,
        { Kind: DeviceLastSeenKind.NeverLocally } => 2,
        _ => 1
    };

    private static int CompareAddresses(string left, string right)
    {
        var hasLeft = IPAddress.TryParse(left, out var leftAddress);
        var hasRight = IPAddress.TryParse(right, out var rightAddress);
        if (!hasLeft || !hasRight) return hasLeft.CompareTo(hasRight);

        var leftBytes = leftAddress!.GetAddressBytes();
        var rightBytes = rightAddress!.GetAddressBytes();
        var familyComparison = leftBytes.Length.CompareTo(rightBytes.Length);
        if (familyComparison != 0) return familyComparison;
        for (var index = 0; index < leftBytes.Length; index++)
        {
            var comparison = leftBytes[index].CompareTo(rightBytes[index]);
            if (comparison != 0) return comparison;
        }
        return 0;
    }
}
