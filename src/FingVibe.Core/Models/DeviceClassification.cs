namespace FingVibe.Core.Models;

public enum DeviceOperatingSystem
{
    Unknown,
    Windows,
    Android,
    Linux,
    MacOS,
    IOS,
    Other
}

public enum DeviceType
{
    Unknown,
    Computer,
    Phone,
    Tablet,
    Router,
    Printer,
    MediaDevice,
    Storage,
    GameConsole,
    SmartDevice
}

public sealed record DeviceClassification(
    DeviceOperatingSystem OperatingSystem = DeviceOperatingSystem.Unknown,
    DeviceType Type = DeviceType.Unknown,
    string OperatingSystemEvidence = "No reliable OS evidence advertised.",
    string TypeEvidence = "No reliable device-type evidence advertised.")
{
    public static DeviceClassification Unknown { get; } = new();
}

public sealed record DeviceClassificationOverride(
    DeviceOperatingSystem? OperatingSystem = null,
    DeviceType? Type = null,
    DeviceType? Icon = null)
{
    public bool IsEmpty => OperatingSystem is null && Type is null && Icon is null;
}

public static class DeviceClassificationLabels
{
    public static string Label(this DeviceOperatingSystem value) => value switch
    {
        DeviceOperatingSystem.MacOS => "macOS",
        DeviceOperatingSystem.IOS => "iOS/iPadOS",
        _ => value.ToString()
    };

    public static string Label(this DeviceType value) => value switch
    {
        DeviceType.Router => "Router/access point",
        DeviceType.MediaDevice => "TV/media device",
        DeviceType.Storage => "NAS/storage",
        DeviceType.GameConsole => "Game console",
        DeviceType.SmartDevice => "IoT/smart device",
        _ => value.ToString()
    };
}
