using System.ComponentModel;

namespace FingVibe.App;

public sealed class DeviceColumn : INotifyPropertyChanged
{
    public const double MinimumWidth = 56;

    private double _width;
    private bool _isVisible = true;

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
            var width = Math.Max(MinimumWidth, value);
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

    private void OnPropertyChanged(string propertyName) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}

// Column widths and visibility are shared by every row and kept only for the current app session.
public sealed class DeviceColumnLayout : INotifyPropertyChanged
{
    public static DeviceColumnLayout Current { get; } = new();

    public DeviceColumnLayout()
    {
        All = [Name, Address, Vendor, Ports, Status, Response, Mac, OperatingSystem, Type, Person, Room];
        foreach (var column in All)
        {
            column.PropertyChanged += (_, args) =>
            {
                if (args.PropertyName == nameof(DeviceColumn.EffectiveWidth))
                {
                    PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(TotalWidth)));
                }
            };
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public DeviceColumn Name { get; } = new("Name", "Name", 170);
    public DeviceColumn Address { get; } = new("Address", "IP address", 130, canHide: false);
    public DeviceColumn Vendor { get; } = new("Vendor", "Vendor", 160);
    public DeviceColumn Ports { get; } = new("Ports", "Open ports", 150);
    public DeviceColumn Status { get; } = new("Status", "Status", 90);
    public DeviceColumn Response { get; } = new("Response", "Response", 130);
    public DeviceColumn Mac { get; } = new("Mac", "MAC address", 150);
    public DeviceColumn OperatingSystem { get; } = new("OperatingSystem", "OS", 120);
    public DeviceColumn Type { get; } = new("Type", "Device type", 150);
    public DeviceColumn Person { get; } = new("Person", "Person", 90);
    public DeviceColumn Room { get; } = new("Room", "Room", 100);

    public IReadOnlyList<DeviceColumn> All { get; }

    public double TotalWidth => All.Sum(column => column.EffectiveWidth);

    public DeviceColumn? Find(string? key) =>
        All.FirstOrDefault(column => string.Equals(column.Key, key, StringComparison.Ordinal));

    public void Reset()
    {
        foreach (var column in All)
        {
            column.Width = column.DefaultWidth;
            column.IsVisible = true;
        }
    }
}
