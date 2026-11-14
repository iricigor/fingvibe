using System.ComponentModel;
using FingVibe.Core.Models;

namespace FingVibe.App;

public sealed class DeviceColumn : INotifyPropertyChanged
{
    public const double MinimumWidth = 56;

    private double _width;
    private bool _isVisible = true;
    private bool _hasFollowingVisibleColumn;

    public DeviceColumn(string key, string header, double defaultWidth, bool canHide = true)
    {
        Key = key;
        Header = header;
        DefaultWidth = defaultWidth;
        CanHide = canHide;
        _width = defaultWidth;
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public string Key { get; }
    public string Header { get; }
    public double DefaultWidth { get; }
    public bool CanHide { get; }
    public string ResizeLabel => $"Resize {Header} column";

    public double Width
    {
        get => _width;
        set
        {
            var width = double.IsFinite(value) ? Math.Clamp(value, MinimumWidth, 4096) : _width;
            if (width == _width)
            {
                return;
            }

            _width = width;
            OnPropertyChanged(nameof(Width));
            OnPropertyChanged(nameof(EffectiveWidth));
        }
    }

    public bool IsVisible
    {
        get => _isVisible;
        set
        {
            var isVisible = value || !CanHide;
            if (isVisible == _isVisible)
            {
                return;
            }

            _isVisible = isVisible;
            OnPropertyChanged(nameof(IsVisible));
            OnPropertyChanged(nameof(EffectiveWidth));
        }
    }

    public double EffectiveWidth => IsVisible ? Width : 0;

    public bool HasFollowingVisibleColumn
    {
        get => _hasFollowingVisibleColumn;
        internal set
        {
            if (_hasFollowingVisibleColumn == value)
            {
                return;
            }

            _hasFollowingVisibleColumn = value;
            OnPropertyChanged(nameof(HasFollowingVisibleColumn));
        }
    }

    private void OnPropertyChanged(string propertyName) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}

public sealed class DeviceColumnLayout : INotifyPropertyChanged
{
    public static DeviceColumnLayout Current { get; } = new();

    public DeviceColumnLayout()
    {
        All = [Name, Address, Vendor, Ports, Status, Response, Mac, OperatingSystem, Type, UsageCategory, Person, Room, LastSeen];
        foreach (var column in All)
        {
            column.PropertyChanged += (_, args) =>
            {
                if (args.PropertyName == nameof(DeviceColumn.EffectiveWidth))
                {
                    Refresh();
                    SettingsChanged?.Invoke(this, EventArgs.Empty);
                }
            };
        }
        foreach (var column in new[] { _combinedConnection, _combinedAddresses, _combinedAssignments, _combinedVendorOs })
        {
            column.PropertyChanged += (_, args) =>
            {
                if (args.PropertyName == nameof(DeviceColumn.EffectiveWidth))
                {
                    Refresh();
                    SettingsChanged?.Invoke(this, EventArgs.Empty);
                }
            };
        }
        UpdateSeparators();
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    public event EventHandler? SettingsChanged;

    private readonly DeviceColumn _combinedConnection = new("Connection", "Status / response", 180);
    private readonly DeviceColumn _combinedAddresses = new("Addresses", "IP / MAC", 170, canHide: false);
    private readonly DeviceColumn _combinedAssignments = new("Assignments", "Person / room", 130);
    private readonly DeviceColumn _combinedVendorOs = new("VendorOs", "Vendor / OS", 160);
    private bool _combineNameType = true;
    private bool _combineAddresses = true;
    private bool _combineStatusResponse = true;
    private bool _combinePersonRoom;
    private bool _combineVendorOs;
    private bool _compactRows = true;
    private bool _enlargedCellPreviews = true;

    public bool EnlargedCellPreviews
    {
        get => _enlargedCellPreviews;
        set
        {
            if (_enlargedCellPreviews == value) return;
            _enlargedCellPreviews = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(EnlargedCellPreviews)));
            SettingsChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    public bool CombineNameType { get => _combineNameType; set => SetCombination(ref _combineNameType, value); }
    public bool CombineAddresses { get => _combineAddresses; set => SetCombination(ref _combineAddresses, value); }
    public bool CombineStatusResponse { get => _combineStatusResponse; set => SetCombination(ref _combineStatusResponse, value); }
    public bool CombinePersonRoom { get => _combinePersonRoom; set => SetCombination(ref _combinePersonRoom, value); }
    public bool CombineVendorOs { get => _combineVendorOs; set => SetCombination(ref _combineVendorOs, value); }
    public bool CompactRows { get => _compactRows; set => SetCombination(ref _compactRows, value); }
    public bool HasStackedColumns => ShowMergedType || ShowMergedMac || ShowMergedOs || ShowMergedRoom;
    public double RowMinimumHeight => CompactRows ? (HasStackedColumns ? 36 : 30) : (HasStackedColumns ? 40 : 34);
    public double RowVerticalPadding => CompactRows ? 1 : 4;
    public double RowSpacing => CompactRows ? 1 : 3;
    public double AssignmentSpacing => CompactRows ? 1 : 2;
    public double HeaderVerticalPadding => CompactRows ? 2 : 4;
    public double HeaderButtonVerticalPadding => CompactRows ? 1 : 3;
    public double HeaderLabelTopMargin => CompactRows ? 1 : 6;
    public double HeaderSecondaryMargin => CompactRows ? 1 : 3;

    private void SetCombination(ref bool field, bool value)
    {
        if (field == value) return;
        field = value;
        Refresh();
        SettingsChanged?.Invoke(this, EventArgs.Empty);
    }

    private void Refresh()
    {
        UpdateSeparators();
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
    }

    public DeviceColumn Name { get; } = new("Name", "Name", 210, canHide: false);
    public DeviceColumn Address { get; } = new("Address", "IP address", 130, canHide: false);
    public DeviceColumn Vendor { get; } = new("Vendor", "Vendor", 160);
    public DeviceColumn Ports { get; } = new("Ports", "Open ports", 150);
    public DeviceColumn Status { get; } = new("Status", "Status", 90);
    public DeviceColumn Response { get; } = new("Response", "Response", 100);
    public DeviceColumn Mac { get; } = new("Mac", "MAC address", 150);
    public DeviceColumn OperatingSystem { get; } = new("OperatingSystem", "OS", 120);
    public DeviceColumn Type { get; } = new("Type", "Device type", 150);
    public DeviceColumn UsageCategory { get; } = new("UsageCategory", "Usage category", 120);
    public DeviceColumn Person { get; } = new("Person", "Person", 90);
    public DeviceColumn Room { get; } = new("Room", "Room", 100);
    public DeviceColumn LastSeen { get; } = new("LastSeen", "Last seen", 130);

    public IReadOnlyList<DeviceColumn> All { get; }

    public DeviceColumn Connection => CombineStatusResponse && Status.IsVisible && Response.IsVisible
        ? _combinedConnection : Status.IsVisible ? Status : Response;
    public DeviceColumn Addresses => CombineAddresses && Mac.IsVisible ? _combinedAddresses : Address;
    public DeviceColumn Assignments => CombinePersonRoom && Person.IsVisible && Room.IsVisible
        ? _combinedAssignments : Person.IsVisible ? Person : Room;
    public DeviceColumn VendorOs => ShowMergedOs ? _combinedVendorOs : Vendor;
    public bool ShowMergedOs => CombineVendorOs && Vendor.IsVisible && OperatingSystem.IsVisible;
    public bool ShowSeparateOs => OperatingSystem.IsVisible && !ShowMergedOs;
    public double SeparateOsWidth => ShowSeparateOs ? OperatingSystem.Width : 0;
    public bool ShowMergedType => CombineNameType && Type.IsVisible;
    public bool ShowSeparateType => !CombineNameType && Type.IsVisible;
    public bool ShowMergedMac => CombineAddresses && Mac.IsVisible;
    public bool ShowSeparateMac => !CombineAddresses && Mac.IsVisible;
    public bool ShowSeparateResponse => !CombineStatusResponse && Status.IsVisible && Response.IsVisible;
    public bool ShowConnectionResponse => Response.IsVisible && !ShowSeparateResponse;
    public bool ShowMergedRoom => CombinePersonRoom && Person.IsVisible && Room.IsVisible;
    public bool ShowSeparatePerson => Person.IsVisible && !ShowMergedRoom;
    public bool ShowRoomOnly => Room.IsVisible && !Person.IsVisible;
    public bool ShowSeparateRoom => !CombinePersonRoom && Room.IsVisible && Person.IsVisible;
    public bool ShowAssignmentPerson => Person.IsVisible;
    public bool ShowAssignmentRoom => Room.IsVisible && (CombinePersonRoom || !Person.IsVisible);
    public double SeparateMacWidth => ShowSeparateMac ? Mac.Width : 0;
    public double SeparateTypeWidth => ShowSeparateType ? Type.Width : 0;
    public double SeparateResponseWidth => ShowSeparateResponse ? Response.Width : 0;
    public double SeparateRoomWidth => ShowSeparateRoom ? Room.Width : 0;

    private DeviceColumn[] TableColumns => [
        Name, Addresses, VendorOs, Ports, Connection,
        .. ShowSeparateResponse ? new[] { Response } : Array.Empty<DeviceColumn>(),
        .. ShowSeparateMac ? new[] { Mac } : Array.Empty<DeviceColumn>(),
        .. ShowSeparateOs ? new[] { OperatingSystem } : Array.Empty<DeviceColumn>(),
        .. ShowSeparateType ? new[] { Type } : Array.Empty<DeviceColumn>(),
        UsageCategory, Assignments,
        .. ShowSeparateRoom && Person.IsVisible ? new[] { Room } : Array.Empty<DeviceColumn>(),
        LastSeen];

    public double TotalWidth => TableColumns.Where(column => column.IsVisible).Sum(column => column.Width);

    public DeviceColumn? Find(string? key) =>
        All.FirstOrDefault(column => string.Equals(column.Key, key, StringComparison.Ordinal));

    private void UpdateSeparators()
    {
        foreach (var column in All.Concat(new[] { _combinedConnection, _combinedAddresses, _combinedAssignments, _combinedVendorOs }))
            column.HasFollowingVisibleColumn = false;
        var columns = TableColumns;
        var hasFollowingVisibleColumn = false;
        for (var index = columns.Length - 1; index >= 0; index--)
        {
            columns[index].HasFollowingVisibleColumn = hasFollowingVisibleColumn;
            hasFollowingVisibleColumn |= columns[index].IsVisible;
        }
    }

    public void Reset()
    {
        CombineNameType = true;
        CombineAddresses = true;
        CombineStatusResponse = true;
        CombinePersonRoom = false;
        CombineVendorOs = false;
        _combinedConnection.Width = _combinedConnection.DefaultWidth;
        _combinedAddresses.Width = _combinedAddresses.DefaultWidth;
        _combinedAssignments.Width = _combinedAssignments.DefaultWidth;
        _combinedVendorOs.Width = _combinedVendorOs.DefaultWidth;
        foreach (var column in All)
        {
            column.Width = column.DefaultWidth;
            column.IsVisible = true;
        }
    }

    public DeviceTableSettings Capture() => new(
        All.Concat(new[] { _combinedConnection, _combinedAddresses, _combinedAssignments, _combinedVendorOs })
            .ToDictionary(column => column.Key, column => new DeviceColumnSettings(column.Width, column.IsVisible)),
        CombineNameType, CombineAddresses, CombineStatusResponse, CombinePersonRoom, EnlargedCellPreviews,
        CombineVendorOs, CompactRows, DensityVersion: 1);

    public void Restore(DeviceTableSettings settings)
    {
        foreach (var column in All.Concat(new[] { _combinedConnection, _combinedAddresses, _combinedAssignments, _combinedVendorOs }))
        {
            if (settings.Columns.TryGetValue(column.Key, out var saved))
            {
                column.Width = saved.Width;
                if (All.Contains(column)) column.IsVisible = saved.IsVisible;
            }
        }
        CombineNameType = settings.CombineNameType;
        CombineAddresses = settings.CombineAddresses;
        CombineStatusResponse = settings.CombineStatusResponse;
        CombinePersonRoom = settings.CombinePersonRoom;
        EnlargedCellPreviews = settings.EnlargedCellPreviews;
        CombineVendorOs = settings.CombineVendorOs;
        CompactRows = settings.DensityVersion == 0 || settings.CompactRows;
    }
}
