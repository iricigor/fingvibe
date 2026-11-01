using FingVibe.Core.Models;

namespace FingVibe.App;

public sealed record ManagedPersonListRow(ManagedPerson Person, string DeviceCountText, string RespondedCountText)
{
    public string ActionsLabel => $"Actions for {Person.Name}";
}

public sealed record ManagedRoomListRow(ManagedRoom Room, string DeviceCountText, string RespondedCountText)
{
    public string ActionsLabel => $"Actions for {Room.Name}";
}

public sealed record AssignedDeviceListRow(string MacAddress, ScanResultRow? ScanResult)
{
    public string NameText => ScanResult?.NameText ?? "Not observed in the last scan";
    public string AddressText => ScanResult?.AddressText ?? "-";
    public string StatusText => ScanResult?.StatusLabel ?? "Historical assignment";
    public string StatusContext => ScanResult?.StatusContext ?? "No local observation or imported inventory record.";
    public string MacAddressText => ScanResult?.MacAddressText
        ?? string.Join("-", Enumerable.Range(0, 6).Select(index => MacAddress.Substring(index * 2, 2)));
}
