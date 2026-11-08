using FingVibe.App;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class DeviceColumnLayoutTests
{
    [Fact]
    public void Density_DefaultsToCompactPersistsIndependentlyAndSurvivesColumnReset()
    {
        var layout = new DeviceColumnLayout();
        Assert.True(layout.CompactRows);
        Assert.False(layout.CombineVendorOs);
        Assert.Equal(36, layout.RowMinimumHeight);
        Assert.Equal(1, layout.RowVerticalPadding);
        Assert.Equal(1, layout.RowSpacing);
        Assert.Equal(2, layout.HeaderVerticalPadding);
        Assert.Equal(1, layout.HeaderButtonVerticalPadding);
        var changes = 0;
        layout.SettingsChanged += (_, _) => changes++;
        layout.CompactRows = false;
        layout.CompactRows = false;
        Assert.Equal(1, changes);
        Assert.Equal(40, layout.RowMinimumHeight);
        Assert.Equal(4, layout.RowVerticalPadding);
        Assert.Equal(3, layout.RowSpacing);
        Assert.Equal(2, layout.AssignmentSpacing);
        Assert.Equal(4, layout.HeaderVerticalPadding);
        Assert.Equal(3, layout.HeaderButtonVerticalPadding);
        var restored = new DeviceColumnLayout();
        restored.Restore(layout.Capture());
        Assert.False(restored.CompactRows);
        restored.Reset();
        Assert.False(restored.CompactRows);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void Density_UsesOnlyVisibleStackedColumnsForEveryCombination(bool compact)
    {
        for (var flags = 0; flags < 8192; flags++)
        {
            var layout = new DeviceColumnLayout
            {
                CompactRows = compact,
                CombineNameType = (flags & 1) != 0,
                CombineAddresses = (flags & 2) != 0,
                CombineVendorOs = (flags & 4) != 0,
                CombinePersonRoom = (flags & 8) != 0,
                CombineStatusResponse = (flags & 16) != 0
            };
            layout.Type.IsVisible = (flags & 32) != 0;
            layout.Mac.IsVisible = (flags & 64) != 0;
            layout.Vendor.IsVisible = (flags & 128) != 0;
            layout.OperatingSystem.IsVisible = (flags & 256) != 0;
            layout.Person.IsVisible = (flags & 512) != 0;
            layout.Room.IsVisible = (flags & 1024) != 0;
            layout.Response.IsVisible = (flags & 2048) != 0;
            layout.UsageCategory.IsVisible = (flags & 4096) != 0;

            var stacked = (layout.CombineNameType && layout.Type.IsVisible)
                || (layout.CombineAddresses && layout.Mac.IsVisible)
                || (layout.CombineVendorOs && layout.Vendor.IsVisible && layout.OperatingSystem.IsVisible)
                || (layout.CombinePersonRoom && layout.Person.IsVisible && layout.Room.IsVisible)
                || layout.UsageCategory.IsVisible;
            Assert.Equal(stacked, layout.HasStackedColumns);
            Assert.Equal(compact ? (stacked ? 36 : 30) : (stacked ? 40 : 34), layout.RowMinimumHeight);
            Assert.Equal(compact ? 1 : 4, layout.RowVerticalPadding);
        }
    }

    [Fact]
    public void Density_RefreshesOnVisibilityMergeAndPreferenceChangesAndRestores()
    {
        var layout = new DeviceColumnLayout
        {
            CombineNameType = false,
            CombineAddresses = false
        };
        var changed = new List<string?>();
        layout.UsageCategory.IsVisible = false;
        layout.PropertyChanged += (_, args) => changed.Add(args.PropertyName);

        void AssertRefreshed(double minimum)
        {
            Assert.Contains(null, changed);
            Assert.Equal(minimum, layout.RowMinimumHeight);
            changed.Clear();
        }

        Assert.False(layout.HasStackedColumns);
        Assert.Equal(30, layout.RowMinimumHeight);
        layout.CombineVendorOs = true;
        AssertRefreshed(36);
        layout.OperatingSystem.IsVisible = false;
        AssertRefreshed(30);
        layout.OperatingSystem.IsVisible = true;
        AssertRefreshed(36);
        layout.CombineVendorOs = false;
        AssertRefreshed(30);
        layout.CompactRows = false;
        AssertRefreshed(34);

        var restored = new DeviceColumnLayout();
        restored.Restore(layout.Capture());
        Assert.False(restored.HasStackedColumns);
        Assert.Equal(34, restored.RowMinimumHeight);
        restored.Reset();
        Assert.True(restored.HasStackedColumns);
        Assert.Equal(40, restored.RowMinimumHeight);
        Assert.False(restored.CompactRows);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void LegacyDensity_MigratesOnceWithoutChangingOtherPreferences(bool compact)
    {
        var saved = new FingVibe.Core.Models.DeviceTableSettings(
            new() { ["Name"] = new(250, true) }, CombineVendorOs: true, CompactRows: compact);
        var layout = new DeviceColumnLayout();
        layout.Restore(saved);
        Assert.True(layout.CompactRows);
        Assert.True(layout.CombineVendorOs);
        Assert.Equal(250, layout.Name.Width);
        Assert.Equal(1, layout.Capture().DensityVersion);
        layout.CompactRows = false;
        var nextLaunch = new DeviceColumnLayout();
        nextLaunch.Restore(layout.Capture());
        Assert.False(nextLaunch.CompactRows);
        Assert.True(nextLaunch.CombineVendorOs);
        Assert.Equal(250, nextLaunch.Name.Width);
    }

    [Theory]
    [InlineData(false, false)]
    [InlineData(false, true)]
    [InlineData(true, false)]
    [InlineData(true, true)]
    public void VendorOs_MergesOnlyVisibleMembersAndPreservesIndependentWidths(bool vendor, bool os)
    {
        var layout = new DeviceColumnLayout();
        layout.Vendor.Width = 210;
        layout.OperatingSystem.Width = 140;
        layout.CombineVendorOs = true;
        layout.VendorOs.Width = 190;
        layout.Vendor.IsVisible = vendor;
        layout.OperatingSystem.IsVisible = os;
        Assert.Equal(vendor && os, layout.ShowMergedOs);
        Assert.Equal(os && !vendor, layout.ShowSeparateOs);
        Assert.Equal(os && !vendor ? 140 : 0, layout.SeparateOsWidth);
        Assert.Equal(vendor && os ? "VendorOs" : "Vendor", layout.VendorOs.Key);
        Assert.Equal(layout.Name.EffectiveWidth + layout.Addresses.EffectiveWidth
            + layout.VendorOs.EffectiveWidth + layout.Ports.EffectiveWidth + layout.Connection.EffectiveWidth
            + layout.SeparateResponseWidth + layout.SeparateMacWidth + layout.SeparateOsWidth
            + layout.SeparateTypeWidth + layout.Assignments.EffectiveWidth + layout.SeparateRoomWidth
            + layout.UsageCategory.EffectiveWidth + layout.LastSeen.EffectiveWidth, layout.TotalWidth);

        var restored = new DeviceColumnLayout();
        restored.Restore(layout.Capture());
        Assert.True(restored.CombineVendorOs);
        Assert.Equal(layout.Capture().Columns, restored.Capture().Columns);
        restored.Vendor.IsVisible = restored.OperatingSystem.IsVisible = true;
        Assert.Equal(190, restored.VendorOs.Width);
        restored.CombineVendorOs = false;
        Assert.Equal(210, restored.Vendor.Width);
        Assert.Equal(140, restored.OperatingSystem.Width);
        restored.CombineVendorOs = true;
        Assert.Equal(190, restored.VendorOs.Width);
        restored.Reset();
        Assert.False(restored.CombineVendorOs);
        restored.CombineVendorOs = true;
        Assert.Equal(160, restored.VendorOs.Width);
    }

    [Fact]
    public void VendorOs_SeparatorTracksPhysicalColumnsWithoutEmptyOsAllocation()
    {
        var layout = new DeviceColumnLayout { CombineVendorOs = true };
        foreach (var column in layout.All.Where(column =>
            column.CanHide && column != layout.Vendor && column != layout.OperatingSystem))
            column.IsVisible = false;
        Assert.False(layout.VendorOs.HasFollowingVisibleColumn);
        Assert.Equal(layout.Name.Width + layout.Addresses.Width + layout.VendorOs.Width, layout.TotalWidth);
        layout.Vendor.IsVisible = false;
        Assert.False(layout.OperatingSystem.HasFollowingVisibleColumn);
        Assert.Equal(layout.Name.Width + layout.Addresses.Width + layout.OperatingSystem.Width, layout.TotalWidth);
    }

    [Fact]
    public void CellPreviewPreference_IsDefaultOnNotifiesAndSurvivesColumnReset()
    {
        var layout = new DeviceColumnLayout();
        Assert.True(layout.EnlargedCellPreviews);
        var changes = 0;
        layout.SettingsChanged += (_, _) => changes++;
        layout.EnlargedCellPreviews = false;
        layout.EnlargedCellPreviews = false;
        Assert.Equal(1, changes);
        var restored = new DeviceColumnLayout();
        restored.Restore(layout.Capture());
        Assert.False(restored.EnlargedCellPreviews);
        restored.Reset();
        Assert.False(restored.EnlargedCellPreviews);
    }

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
        Assert.False(layout.LastSeen.HasFollowingVisibleColumn);
        Assert.True(layout.Room.HasFollowingVisibleColumn);
        Assert.True(layout.Person.HasFollowingVisibleColumn);
        var changed = new List<string?>();
        layout.Room.PropertyChanged += (_, args) => changed.Add(args.PropertyName);

        layout.LastSeen.IsVisible = false;

        Assert.False(layout.Room.HasFollowingVisibleColumn);
        Assert.Contains(nameof(DeviceColumn.HasFollowingVisibleColumn), changed);
        changed.Clear();
        layout.Person.PropertyChanged += (_, args) => changed.Add(args.PropertyName);
        layout.Room.IsVisible = false;
        Assert.False(layout.Person.HasFollowingVisibleColumn);
        Assert.Contains(nameof(DeviceColumn.HasFollowingVisibleColumn), changed);
        layout.Person.Width = 120;
        Assert.Equal(120, layout.Person.Width);
        layout.Reset();
        Assert.True(layout.Person.HasFollowingVisibleColumn);
        Assert.True(layout.Room.HasFollowingVisibleColumn);
        Assert.False(layout.LastSeen.HasFollowingVisibleColumn);
    }

    [Fact]
    public void LastSeen_IsAHideableResizableTrailingColumnThatDefaultsVisibleForOlderSettings()
    {
        var layout = new DeviceColumnLayout();
        Assert.Same(layout.LastSeen, layout.All[^1]);
        Assert.Same(layout.LastSeen, layout.Find("LastSeen"));
        Assert.Equal("Last seen", layout.LastSeen.Header);
        Assert.True(layout.LastSeen.CanHide);
        Assert.True(layout.LastSeen.IsVisible);
        Assert.Equal(130, layout.LastSeen.Width);
        var total = layout.TotalWidth;
        layout.LastSeen.Width = 190;
        Assert.Equal(total + 60, layout.TotalWidth);
        layout.LastSeen.IsVisible = false;
        Assert.Equal(total - 130, layout.TotalWidth);

        var restored = new DeviceColumnLayout();
        restored.Restore(layout.Capture());
        Assert.False(restored.LastSeen.IsVisible);
        Assert.Equal(190, restored.LastSeen.Width);
        restored.Reset();
        Assert.True(restored.LastSeen.IsVisible);
        Assert.Equal(130, restored.LastSeen.Width);

        var older = layout.Capture();
        older.Columns.Remove("LastSeen");
        var upgraded = new DeviceColumnLayout();
        upgraded.Restore(older);
        Assert.True(upgraded.LastSeen.IsVisible);
        Assert.Equal(130, upgraded.LastSeen.Width);
        Assert.Equal(layout.Room.Width, upgraded.Room.Width);
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
        Assert.Contains(null, changed);
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
        Assert.Equal(layout.Name.Width + layout.Addresses.Width + layout.Vendor.Width + layout.Ports.Width
            + width + layout.OperatingSystem.Width + layout.UsageCategory.Width + layout.Person.Width + layout.Room.Width + layout.LastSeen.Width,
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
        Assert.Contains(null, changed);
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
        foreach (var column in new[] { layout.Mac, layout.OperatingSystem, layout.UsageCategory, layout.Person, layout.Room, layout.LastSeen })
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

    [Fact]
    public void EveryCombination_UsesExactlyTheDisplayedColumnWidths()
    {
        for (var flags = 0; flags < 2048; flags++)
        {
            var layout = new DeviceColumnLayout
            {
                CombineNameType = (flags & 1) != 0,
                CombineAddresses = (flags & 2) != 0,
                CombineStatusResponse = (flags & 4) != 0,
                CombinePersonRoom = (flags & 8) != 0
            };
            layout.Type.IsVisible = (flags & 16) != 0;
            layout.Mac.IsVisible = (flags & 32) != 0;
            layout.Status.IsVisible = (flags & 64) != 0;
            layout.Response.IsVisible = (flags & 128) != 0;
            layout.Person.IsVisible = (flags & 256) != 0;
            layout.Room.IsVisible = (flags & 512) != 0;
            layout.LastSeen.IsVisible = (flags & 1024) != 0;
            Assert.Equal(layout.Name.EffectiveWidth + layout.Addresses.EffectiveWidth
                + layout.Vendor.EffectiveWidth + layout.Ports.EffectiveWidth + layout.Connection.EffectiveWidth
                + layout.SeparateResponseWidth + layout.SeparateMacWidth + layout.OperatingSystem.EffectiveWidth
                + layout.SeparateTypeWidth + layout.Assignments.EffectiveWidth + layout.SeparateRoomWidth
                + layout.UsageCategory.EffectiveWidth + layout.LastSeen.EffectiveWidth, layout.TotalWidth);
            Assert.Equal(layout.Type.IsVisible, layout.ShowMergedType || layout.ShowSeparateType);
            Assert.Equal(layout.Mac.IsVisible, layout.ShowMergedMac || layout.ShowSeparateMac);
            Assert.Equal(layout.Response.IsVisible, layout.ShowConnectionResponse || layout.ShowSeparateResponse);
            Assert.Equal(layout.Room.IsVisible, layout.ShowAssignmentRoom || layout.ShowSeparateRoom);
            Assert.Equal(layout.Person.IsVisible, layout.ShowMergedRoom || layout.ShowSeparatePerson);
            Assert.Equal(layout.Room.IsVisible, layout.ShowMergedRoom || layout.ShowRoomOnly || layout.ShowSeparateRoom);
            Assert.False(layout.ShowMergedRoom && (layout.ShowSeparatePerson || layout.ShowRoomOnly || layout.ShowSeparateRoom));
        }
    }

    [Fact]
    public void CaptureRestore_PreservesEveryWidthVisibilityAndCombination()
    {
        var source = new DeviceColumnLayout
        {
            CombineNameType = false, CombineAddresses = false,
            CombineStatusResponse = false, CombinePersonRoom = true
        };
        source.Name.Width = 237;
        source.Mac.IsVisible = false;
        source.Assignments.Width = 177;
        source.Connection.Width = 103;
        var restored = new DeviceColumnLayout();
        restored.Restore(source.Capture());
        Assert.Equal(source.Capture().Columns, restored.Capture().Columns);
        Assert.False(restored.CombineNameType);
        Assert.False(restored.CombineAddresses);
        Assert.False(restored.CombineStatusResponse);
        Assert.True(restored.CombinePersonRoom);
        restored.Reset();
        Assert.True(restored.CombineNameType);
        Assert.True(restored.CombineAddresses);
        Assert.True(restored.CombineStatusResponse);
        Assert.False(restored.CombinePersonRoom);
        Assert.Equal(restored.Name.DefaultWidth, restored.Name.Width);
    }
}
