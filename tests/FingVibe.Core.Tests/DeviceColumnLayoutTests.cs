using FingVibe.App;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class DeviceColumnLayoutTests
{
    [Fact]
    public void Response_DefaultWidthIsCompactAndCanBeResized()
    {
        var layout = new DeviceColumnLayout();

        Assert.Equal(100, layout.Response.Width);
        layout.Response.Width = 160;
        Assert.Equal(160, layout.Response.Width);
        layout.Reset();
        Assert.Equal(100, layout.Response.Width);
    }

    [Fact]
    public void LastVisibleColumn_HasNoSeparatorButRemainsResizable()
    {
        var layout = new DeviceColumnLayout();
        Assert.False(layout.Room.HasFollowingVisibleColumn);
        Assert.True(layout.Person.HasFollowingVisibleColumn);
        var changed = new List<string?>();
        layout.Person.PropertyChanged += (_, args) => changed.Add(args.PropertyName);

        layout.Room.IsVisible = false;

        Assert.False(layout.Person.HasFollowingVisibleColumn);
        Assert.Contains(nameof(DeviceColumn.HasFollowingVisibleColumn), changed);
        layout.Person.Width = 120;
        Assert.Equal(120, layout.Person.Width);
        layout.Reset();
        Assert.True(layout.Person.HasFollowingVisibleColumn);
        Assert.False(layout.Room.HasFollowingVisibleColumn);
    }

    [Fact]
    public void OnlyAddressVisible_HasNoTrailingSeparator()
    {
        var layout = new DeviceColumnLayout();
        foreach (var column in layout.All)
        {
            column.IsVisible = false;
        }

        Assert.True(layout.Address.IsVisible);
        Assert.False(layout.Address.HasFollowingVisibleColumn);
    }

    [Fact]
    public void Width_IsClampedToMinimum()
    {
        var layout = new DeviceColumnLayout();

        layout.Name.Width = 10;

        Assert.Equal(DeviceColumn.MinimumWidth, layout.Name.Width);
    }

    [Fact]
    public void HiddenColumns_DoNotContributeWidth()
    {
        var layout = new DeviceColumnLayout();
        var total = layout.TotalWidth;
        var changed = new List<string?>();
        layout.PropertyChanged += (_, args) => changed.Add(args.PropertyName);

        layout.Vendor.IsVisible = false;

        Assert.Equal(0, layout.Vendor.EffectiveWidth);
        Assert.Equal(total - layout.Vendor.Width, layout.TotalWidth);
        Assert.Contains(nameof(DeviceColumnLayout.TotalWidth), changed);
    }

    [Fact]
    public void ClassificationColumns_CanBeHiddenResizedAndReset()
    {
        var layout = new DeviceColumnLayout();
        Assert.Contains(layout.OperatingSystem, layout.All);
        Assert.Contains(layout.Type, layout.All);
        layout.OperatingSystem.IsVisible = false;
        layout.Type.Width = 250;
        Assert.Equal(0, layout.OperatingSystem.EffectiveWidth);
        Assert.Equal(250, layout.Type.EffectiveWidth);
        layout.Reset();
        Assert.True(layout.OperatingSystem.IsVisible);
        Assert.Equal(layout.Type.DefaultWidth, layout.Type.Width);
    }

    [Fact]
    public void AddressColumn_CannotBeHidden()
    {
        var layout = new DeviceColumnLayout();

        layout.Address.IsVisible = false;

        Assert.True(layout.Address.IsVisible);
    }

    [Fact]
    public void Reset_RestoresDefaultWidthsAndVisibility()
    {
        var layout = new DeviceColumnLayout();
        layout.Mac.Width = 400;
        layout.Ports.IsVisible = false;

        layout.Reset();

        Assert.Equal(layout.Mac.DefaultWidth, layout.Mac.Width);
        Assert.True(layout.Ports.IsVisible);
    }
}
