namespace FingVibe.Core.Models;

public sealed record DeviceColumnSettings(double Width, bool IsVisible);

public sealed record DeviceTableSettings(
    Dictionary<string, DeviceColumnSettings> Columns,
    bool CombineNameType = true,
    bool CombineAddresses = true,
    bool CombineStatusResponse = true,
    bool CombinePersonRoom = false,
    bool EnlargedCellPreviews = true,
    bool CombineVendorOs = false,
    bool CompactRows = true,
    int DensityVersion = 0);
