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
    public void MandatoryColumnsRemainVisible_WithNoTrailingSeparator()
    {
        var layout = new DeviceColumnLayout();
        foreach (var column in layout.All)
        {
            column.IsVisible = false;
        }

        Assert.True(layout.Address.IsVisible);
        Assert.True(layout.Name.IsVisible);
        Assert.True(layout.Name.HasFollowingVisibleColumn);
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
    public void TypeVisibility_DoesNotAddAStandaloneColumn()
    {
        var layout = new DeviceColumnLayout();
        Assert.Contains(layout.OperatingSystem, layout.All);
        Assert.Contains(layout.Type, layout.All);
        layout.OperatingSystem.IsVisible = false;
        var width = layout.TotalWidth;
        layout.Type.IsVisible = false;
        layout.Type.Width = 250;
        Assert.Equal(0, layout.OperatingSystem.EffectiveWidth);
        Assert.Equal(width, layout.TotalWidth);
        layout.Reset();
        Assert.True(layout.OperatingSystem.IsVisible);
        Assert.Equal(layout.Type.DefaultWidth, layout.Type.Width);
    }

    [Theory]
    [InlineData(true, true, "Connection", 180)]
    [InlineData(true, false, "Status", 90)]
    [InlineData(false, true, "Response", 100)]
    [InlineData(false, false, "Response", 0)]
    public void Connection_UsesOnePhysicalColumnForEveryVisibilityCombination(
        bool status, bool response, string key, double width)
    {
        var layout = new DeviceColumnLayout();
        layout.Status.IsVisible = status;
        layout.Response.IsVisible = response;
        Assert.Equal(key, layout.Connection.Key);
        Assert.Equal(width, layout.Connection.EffectiveWidth);
        Assert.Equal(layout.Name.Width + layout.Address.Width + layout.Vendor.Width + layout.Ports.Width
            + width + layout.Mac.Width + layout.OperatingSystem.Width + layout.Person.Width + layout.Room.Width,
            layout.TotalWidth);
    }

    [Fact]
    public void Connection_ResizesAndResetsWithoutLosingSingleMetricWidths()
    {
        var layout = new DeviceColumnLayout();
        var changed = new List<string?>();
        layout.PropertyChanged += (_, args) => changed.Add(args.PropertyName);
        layout.Connection.Width = 220;
        layout.Response.IsVisible = false;
        layout.Connection.Width = 120;
        layout.Response.IsVisible = true;
        Assert.Equal(220, layout.Connection.Width);
        Assert.Equal(120, layout.Status.Width);
        Assert.Contains(nameof(DeviceColumnLayout.Connection), changed);
        Assert.Contains(nameof(DeviceColumnLayout.TotalWidth), changed);
        layout.Reset();
        Assert.Equal(180, layout.Connection.Width);
        Assert.Equal(90, layout.Status.Width);
    }

    [Theory]
    [InlineData(true, true)]
    [InlineData(true, false)]
    [InlineData(false, true)]
    public void ConnectionSeparator_TracksPhysicalColumns(bool status, bool response)
    {
        var layout = new DeviceColumnLayout();
        foreach (var column in new[] { layout.Mac, layout.OperatingSystem, layout.Person, layout.Room })
        {
            column.IsVisible = false;
        }
        layout.Status.IsVisible = status;
        layout.Response.IsVisible = response;
        Assert.False(layout.Connection.HasFollowingVisibleColumn);
        Assert.True(layout.Ports.HasFollowingVisibleColumn);
        layout.Status.IsVisible = false;
        layout.Response.IsVisible = false;
        Assert.False(layout.Ports.HasFollowingVisibleColumn);
        Assert.False(layout.Type.HasFollowingVisibleColumn);
    }

    [Fact]
    public void AddressColumn_CannotBeHidden()
    {
        var layout = new DeviceColumnLayout();

        layout.Address.IsVisible = false;

        Assert.True(layout.Address.IsVisible);
        layout.Name.IsVisible = false;
        Assert.True(layout.Name.IsVisible);
        Assert.False(layout.Name.CanHide);
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
