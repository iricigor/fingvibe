using System.Net;

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
    Room
}

internal static class DeviceResultSort
{
    internal static int Compare(ScanResultRow left, ScanResultRow right, ResultSortColumn column, bool ascending)
    {
        // Assignment absence is independent of direction; do not reverse it with the keys.
        var assignmentPresence = column switch
        {
            ResultSortColumn.Person => (left.PersonId is null).CompareTo(right.PersonId is null),
            ResultSortColumn.Room => (left.RoomId is null).CompareTo(right.RoomId is null),
            _ => 0
        };
        if (assignmentPresence != 0) return assignmentPresence;

        var comparison = column switch
        {
            ResultSortColumn.Name => CompareText(left.NameText, right.NameText),
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
