using System.Net;
using System.Net.NetworkInformation;
using FingVibe.Core.Models;
using Xunit;

namespace FingVibe.Core.Tests;

public sealed class RoomMapLayoutTests
{
    private static readonly LanNetwork Network = new(
        "Ethernet",
        IPAddress.Parse("192.168.50.20"),
        IPAddress.Parse("192.168.50.0"),
        24,
        true,
        IPAddress.Parse("192.168.50.1"),
        "ethernet-test");

    [Fact]
    public void ProjectionGroupsFullInventoryAndKeepsGatewayAndLocalHighlightsExplicit()
    {
        var rootId = Guid.NewGuid();
        var localRoomId = Guid.NewGuid();
        var emptyRoomId = Guid.NewGuid();
        var rooms = new ManagedRoom[]
        {
            new(rootId, "Hall", "H"),
            new(localRoomId, "Office", "O"),
            new(emptyRoomId, "Guest room", "GR")
        };
        var assignments = new Dictionary<string, DeviceAssignment>
        {
            ["001122334401"] = new(RoomId: rootId),
            ["001122334402"] = new(RoomId: localRoomId),
            ["001122334403"] = new(RoomId: localRoomId),
            ["001122334404"] = new(RoomId: localRoomId)
        };
        var data = new DeviceInventoryData(
            Guid.NewGuid(),
            new Dictionary<string, InventoryDevice>
            {
                ["001122334401"] = Device("001122334401", "Gateway", "192.168.50.1", DeviceType.Router, true),
                ["001122334402"] = Device("001122334402", "This PC", "192.168.50.20", DeviceType.Computer, true),
                ["001122334403"] = Device("001122334403", "Printer", "192.168.50.30", DeviceType.Printer, false),
                ["001122334404"] = new("001122334404", new(Name: "Imported tablet", Address: "192.168.50.40"), []),
                ["001122334405"] = Device("001122334405", "Phone", "192.168.50.50", DeviceType.Phone, true),
                ["001122334406"] = Device("001122334406", "Other network", "192.168.60.10", DeviceType.Computer, true,
                    "other-network", "192.168.60.0/24"),
                ["001122334407"] = new("001122334407", new(Name: "Off-subnet import", Address: "10.0.0.10"), [])
            },
            new Dictionary<string, string>(),
            new Dictionary<string, DeviceClassificationOverride>(),
            new PeopleRoomsData([], rooms, assignments));

        var projection = RoomMapProjection.Create(data, Network, "selected-network");

        Assert.Equal(3, projection.Rooms.Count);
        var root = Assert.Single(projection.Rooms, room => room.IsRoot);
        Assert.Equal(rootId, root.Id);
        Assert.True(root.Devices.Single().IsGateway);
        var localRoom = Assert.Single(projection.Rooms, room => room.IsLocalRoom);
        Assert.Equal(localRoomId, localRoom.Id);
        Assert.Contains(localRoom.Devices, device => device.IsLocal && device.Status == RoomMapDeviceStatus.Online);
        Assert.Contains(localRoom.Devices, device => device.Status == RoomMapDeviceStatus.Offline);
        Assert.Contains(localRoom.Devices, device => device.Status == RoomMapDeviceStatus.Unknown);
        var unassigned = Assert.Single(projection.UnassignedDevices);
        Assert.Equal("Phone", unassigned.Name);
        Assert.DoesNotContain(projection.Devices, device => device.Name == "Other network");
        Assert.DoesNotContain(projection.Devices, device => device.Name == "Off-subnet import");
        Assert.Contains(projection.Rooms, room => room.Id == emptyRoomId && room.Devices.Count == 0);
    }

    [Fact]
    public void ProjectionUsesUnresolvedAndUnassignedGatewayRootsWithoutDuplicatingTheGateway()
    {
        var network = Network with { GatewayAddress = IPAddress.Parse("192.168.50.254") };
        var projection = RoomMapProjection.Create(DeviceInventoryData.Empty, network, "selected-network");

        var root = Assert.Single(projection.Rooms);
        Assert.True(root.IsRoot);
        Assert.True(root.IsPlaceholder);
        Assert.Contains("192.168.50.254", root.PlaceholderText);
        Assert.Empty(root.Devices);
        Assert.Empty(projection.UnassignedDevices);

        var gateway = Device("001122334401", "Gateway", "192.168.50.254", DeviceType.Router, true);
        var data = new DeviceInventoryData(
            Guid.NewGuid(),
            new Dictionary<string, InventoryDevice> { [gateway.Mac] = gateway },
            new Dictionary<string, string>(),
            new Dictionary<string, DeviceClassificationOverride>(),
            new PeopleRoomsData());
        projection = RoomMapProjection.Create(data, network, "selected-network");
        root = Assert.Single(projection.Rooms, room => room.IsRoot);
        Assert.Equal("Gateway / no room assigned", root.Name);
        Assert.True(Assert.Single(root.Devices).IsGateway);
        Assert.Empty(projection.UnassignedDevices);
    }

    [Fact]
    public void ProjectionUsesVirtualDeviceAssignmentOnceForRotatingPrivateMacs()
    {
        var room = new ManagedRoom(Guid.NewGuid(), "Office", "O");
        var result = new ScanResult(
            IPAddress.Parse("192.168.50.40"),
            HostStatus.Alive,
            1,
            TimeSpan.Zero,
            MacAddress: PhysicalAddress.Parse("D0C907000001"),
            VendorName: "Private");
        var data = DeviceInventoryData.Empty.ObserveCompletedScan(
            "selected-network",
            new("192.168.50.0/24", DateTimeOffset.UtcNow, [result]));
        var slot = Assert.Single(data.VirtualDevices);
        data = data with
        {
            VirtualDevices = [slot with { Assignment = new(RoomId: room.Id) }],
            PeopleRooms = new PeopleRoomsData([], [room])
        };

        var projection = RoomMapProjection.Create(data, Network, "selected-network");

        var device = Assert.Single(projection.Devices);
        Assert.Equal(slot.Id.ToString("D"), device.IdentityKey);
        Assert.Equal(room.Id, device.RoomId);
        Assert.DoesNotContain(projection.Devices, item => item.IdentityKey == "D0C907000001");
    }

    [Fact]
    public void ProjectionDoesNotMixSameSubnetEvidenceWhenNetworkIdentityIsUnavailable()
    {
        var data = new DeviceInventoryData(
            Guid.NewGuid(),
            new Dictionary<string, InventoryDevice>
            {
                ["001122334401"] = Device(
                    "001122334401", "Other network", "192.168.50.30", DeviceType.Computer, true,
                    "different-network"),
                ["001122334402"] = Device(
                    "001122334402", "Legacy evidence", "192.168.50.40", DeviceType.Computer, false,
                    null, "192.168.50.0/24")
            },
            new Dictionary<string, string>(),
            new Dictionary<string, DeviceClassificationOverride>(),
            new PeopleRoomsData());

        var projection = RoomMapProjection.Create(data, Network, null);

        Assert.DoesNotContain(projection.Devices, device => device.Name == "Other network");
        var legacy = Assert.Single(projection.Devices);
        Assert.Equal("Legacy evidence", legacy.Name);
        Assert.Equal(RoomMapDeviceStatus.Offline, legacy.Status);
    }

    [Fact]
    public void ProjectionDoesNotChooseAnArbitraryDeviceWhenGatewayMatchesAreAmbiguous()
    {
        var data = new DeviceInventoryData(
            Guid.NewGuid(),
            new Dictionary<string, InventoryDevice>
            {
                ["001122334401"] = Device("001122334401", "First match", "192.168.50.1", DeviceType.Router, true),
                ["001122334402"] = Device("001122334402", "Second match", "192.168.50.1", DeviceType.Router, true)
            },
            new Dictionary<string, string>(),
            new Dictionary<string, DeviceClassificationOverride>(),
            new PeopleRoomsData());

        var projection = RoomMapProjection.Create(data, Network, "selected-network");

        var root = Assert.Single(projection.Rooms);
        Assert.True(root.IsPlaceholder);
        Assert.Contains("multiple saved devices", root.PlaceholderText);
        Assert.Equal(2, projection.UnassignedDevices.Count);
        Assert.DoesNotContain(projection.UnassignedDevices, device => device.IsGateway);
    }

    [Fact]
    public void LayoutRepresentsTenRoomsAndOneHundredDevicesWithoutOverlap()
    {
        var rooms = Enumerable.Range(0, 10).Select(roomIndex =>
            new RoomMapRoom(
                Guid.NewGuid(),
                $"Room {roomIndex:D2}",
                $"R{roomIndex}",
                null,
                Enumerable.Range(0, 10).Select(deviceIndex =>
                    DeviceSource(
                        $"{roomIndex:D2}-{deviceIndex:D2}",
                        $"Device {roomIndex:D2}-{deviceIndex:D2}",
                        type: deviceIndex is 0 or 1 ? DeviceType.Router : DeviceType.Computer,
                        roomId: null)).ToArray(),
                roomIndex == 0,
                roomIndex == 2)).ToArray();
        var unassigned = Enumerable.Range(0, 12).Select(index =>
            DeviceSource($"U-{index:D2}", $"Unassigned {index:D2}", DeviceType.Phone)).ToArray();
        var projection = new RoomMapProjection(Network.DisplayLabel, Network, "selected-network", rooms, unassigned);

        var layout = RoomMapLayout.Create(projection, 1024);

        Assert.Equal(10, layout.Rooms.Count);
        Assert.Equal(100, layout.Rooms.Sum(room => room.DeviceCount));
        Assert.Equal(12, layout.UnassignedDevices.Count);
        Assert.All(layout.Rooms, room =>
        {
            Assert.True(room.Bounds.Width > 0);
            Assert.True(room.Bounds.Height >= 128);
            Assert.True(room.Bounds.X >= 0);
            Assert.True(room.Bounds.Right <= layout.Width);
            Assert.True(room.Bounds.Y >= 0);
            Assert.True(room.Bounds.Bottom <= layout.Height);
            Assert.All(room.Devices, device =>
            {
                Assert.True(device.Bounds.X >= room.Bounds.X);
                Assert.True(device.Bounds.Y >= room.Bounds.Y);
                Assert.True(device.Bounds.Right <= room.Bounds.Right);
                Assert.True(device.Bounds.Bottom <= room.Bounds.Bottom);
            });
            Assert.NotEmpty(room.Anchors);
            Assert.All(room.Anchors, anchor =>
            {
                Assert.True(anchor.Bounds.X >= room.Bounds.X);
                Assert.True(anchor.Bounds.Y >= room.Bounds.Y);
                Assert.True(anchor.Bounds.Right <= room.Bounds.Right);
                Assert.True(anchor.Bounds.Bottom <= room.Bounds.Bottom);
            });
        });
        foreach (var left in layout.Rooms)
        {
            foreach (var right in layout.Rooms.Where(room => !ReferenceEquals(room, left)))
            {
                Assert.False(left.Bounds.Intersects(right.Bounds),
                    $"{left.Name} overlaps {right.Name}.");
            }
        }
        Assert.All(layout.UnassignedDevices, device =>
        {
            Assert.True(device.Bounds.X >= layout.UnassignedBounds.X);
            Assert.True(device.Bounds.Y >= layout.UnassignedBounds.Y);
            Assert.True(device.Bounds.Right <= layout.UnassignedBounds.Right);
            Assert.True(device.Bounds.Bottom <= layout.UnassignedBounds.Bottom);
        });
        Assert.All(layout.Rooms.SelectMany(room => room.Devices)
            .SelectMany((device, index) => layout.Rooms.SelectMany(room => room.Devices).Skip(index + 1)
                .Select(other => (device, other))), pair =>
            Assert.False(pair.device.Bounds.Intersects(pair.other.Bounds)));
        var root = Assert.Single(layout.Rooms, room => room.IsRoot);
        Assert.True(root.Bounds.X > layout.Rooms.Where(room => !room.IsRoot).Max(room => room.Bounds.X));
    }

    [Fact]
    public void GlobeStaysOnTheMainGatewayAxis()
    {
        var roomId = Guid.NewGuid();
        var gateway = DeviceSource("gateway", "Gateway", DeviceType.Router, roomId) with { IsGateway = true };
        var projection = new RoomMapProjection(
            Network.DisplayLabel,
            Network,
            "network",
            [new(roomId, "Hall", "H", null, [gateway], true, false)],
            []);

        var layout = RoomMapLayout.Create(projection, 1024);
        var placedGateway = Assert.Single(Assert.Single(layout.Rooms).Devices).Bounds;

        Assert.Equal(placedGateway.X + placedGateway.Width / 2, layout.RootLinkX);
        Assert.Equal(layout.RootLinkX, layout.GlobeBounds.X + layout.GlobeBounds.Width / 2);
    }

    [Fact]
    public void LayoutKeepsGeometryStableWhenOnlyStatusChangesAndScrollsAtNarrowWidths()
    {
        var roomId = Guid.NewGuid();
        var online = DeviceSource("one", "One", DeviceType.Computer, roomId);
        var rooms = new[] { new RoomMapRoom(roomId, "Office", "O", null, [online], true, true) };
        var beforeProjection = new RoomMapProjection(Network.DisplayLabel, Network, "network", rooms, []);
        var afterProjection = beforeProjection with
        {
            Rooms = [rooms[0] with { Devices = [online with { Status = RoomMapDeviceStatus.Offline }] }]
        };

        var before = RoomMapLayout.Create(beforeProjection, 480);
        var after = RoomMapLayout.Create(afterProjection, 480);

        Assert.Equal(720, before.Width);
        Assert.Equal(before.Rooms.Select(room => room.Bounds), after.Rooms.Select(room => room.Bounds));
        Assert.Equal(
            before.Rooms.SelectMany(room => room.Devices).Select(device => device.Bounds),
            after.Rooms.SelectMany(room => room.Devices).Select(device => device.Bounds));
        Assert.Equal(before.UnassignedBounds, after.UnassignedBounds);
        Assert.Equal(before.Height, after.Height);
    }

    [Fact]
    public void CompactRoomKeepsAnEdgeRouterSeparateFromItsInteriorDevice()
    {
        var roomId = Guid.NewGuid();
        var projection = new RoomMapProjection(
            Network.DisplayLabel,
            Network,
            "network",
            [
                new(
                    roomId,
                    "Small room",
                    "S",
                    null,
                    [
                        DeviceSource("router", "Router", DeviceType.Router, roomId),
                        DeviceSource("phone", "Phone", DeviceType.Phone, roomId)
                    ],
                    false,
                    false),
                new(null, "Gateway unavailable", "GW", null, [], true, false, true, "No gateway.")
            ],
            []);

        var layout = RoomMapLayout.Create(projection, 480);
        var room = Assert.Single(layout.Rooms, item => item.Id == roomId);
        Assert.Equal(240, room.Bounds.Width);
        Assert.Equal(2, room.Devices.Count);
        Assert.False(room.Devices[0].Bounds.Intersects(room.Devices[1].Bounds));
    }

    private static InventoryDevice Device(
        string mac,
        string name,
        string address,
        DeviceType type,
        bool present,
        string? networkId = "selected-network",
        string subnet = "192.168.50.0/24") =>
        new(
            mac,
            new(Name: name),
            [
                new(
                    networkId,
                    subnet,
                    address,
                    name,
                    "Synthetic",
                    new(Type: type),
                    [],
                    1,
                    TimeSpan.Zero,
                    new DateTimeOffset(2026, 11, 17, 12, 0, 0, TimeSpan.Zero),
                    new DateTimeOffset(2026, 11, 17, 12, 1, 0, TimeSpan.Zero),
                    new DateTimeOffset(2026, 11, 17, 12, 1, 0, TimeSpan.Zero),
                    present)
            ]);

    private static RoomMapDevice DeviceSource(
        string identity,
        string name,
        DeviceType type,
        Guid? roomId = null) =>
        new(
            identity,
            name,
            $"192.168.50.{(Math.Abs(identity.GetHashCode()) % 250) + 1}",
            type,
            type,
            RoomMapDeviceStatus.Online,
            roomId,
            false,
            false);
}
