namespace FingVibe.App;

internal static class DeviceVendorPresentation
{
    internal const string Unknown = "Unknown";
    internal const string Randomized = "Private/Randomized";

    internal static string FilterValue(string? vendor) =>
        string.IsNullOrWhiteSpace(vendor) || vendor == "-"
            || vendor.Equals(Unknown, StringComparison.OrdinalIgnoreCase)
            || vendor.Equals("Private", StringComparison.OrdinalIgnoreCase)
                ? Unknown : vendor;

    internal static bool IsKnown(string? vendor)
    {
        var value = FilterValue(vendor);
        return value != Unknown && !value.Equals(Randomized, StringComparison.OrdinalIgnoreCase);
    }

    internal static string DisplayText(string? vendor)
    {
        var value = FilterValue(vendor);
        return value.Equals(Randomized, StringComparison.OrdinalIgnoreCase) ? "Randomized MAC" : value;
    }

    internal static string Description(string? vendor) =>
        vendor?.Equals(Randomized, StringComparison.OrdinalIgnoreCase) == true
            ? "Locally administered MAC address; it may be randomized or manually assigned. "
                + "This does not prove random generation or rotation, and the manufacturer cannot be determined from this address."
            : vendor?.Equals("Private", StringComparison.OrdinalIgnoreCase) == true
                ? "Manufacturer not identified. The vendor registry lists this prefix as Private; other information may identify the device."
                : FilterValue(vendor) == Unknown
                    ? "Manufacturer not identified from the available information."
                    : FilterValue(vendor);
}
