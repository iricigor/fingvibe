using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using FingVibe.Core.Models;
using Xunit;
using Xunit.Abstractions;

namespace FingVibe.Core.Tests;

public sealed class RoomMapLayoutTests(ITestOutputHelper output)
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

    [Theory]
    [InlineData(1d)]
    [InlineData(2d)]
    [InlineData(3d)]
    public void LayoutRepresentsTenRoomsAndOneHundredDevicesWithoutOverlap(double textScale)
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

        var layout = RoomMapLayout.Create(projection, 1024, textScale);
        var normal = RoomMapLayout.Create(projection, 1024);

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

        // Enlarged text gets taller headers and tiles; widths and the room arrangement are unchanged.
        var devices = layout.Rooms.SelectMany(room => room.Devices).ToArray();
        var normalDevices = normal.Rooms.SelectMany(room => room.Devices).ToArray();
        Assert.Equal(normalDevices.Select(device => device.Bounds.Width), devices.Select(device => device.Bounds.Width));
        Assert.Equal(normal.Rooms.Select(room => (room.Bounds.X, room.Bounds.Width)), layout.Rooms.Select(room => (room.Bounds.X, room.Bounds.Width)));
        Assert.All(devices, device => Assert.Equal(24 + 28 * textScale, device.Bounds.Height, 3));
        Assert.All(layout.Rooms, room => Assert.All(room.Devices, device =>
            Assert.True(device.Bounds.Y - room.Bounds.Y >= 40 + 56 * textScale - 0.001, $"{room.Name} header space is too small.")));
        if (textScale == 1) Assert.Equal(normal.Height, layout.Height);
        else Assert.True(layout.Height > normal.Height);
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
        Assert.Equal(
            before.Connections.Select(connection =>
                (connection.SourceId, connection.TargetId, connection.Kind, connection.Points)),
            after.Connections.Select(connection =>
                (connection.SourceId, connection.TargetId, connection.Kind, connection.Points)));
    }

    [Fact]
    public void LayoutRoutesEveryRouterAndFallbackRoomThroughReservedGutters()
    {
        var rootId = Guid.NewGuid();
        var routerRoomId = Guid.NewGuid();
        var wallRoomId = Guid.NewGuid();
        var gateway = DeviceSource("gateway", "Gateway", DeviceType.Router, rootId) with { IsGateway = true };
        var localRouter = DeviceSource("root-router", "Root access point", DeviceType.Router, rootId);
        var rooms = new RoomMapRoom[]
        {
            new(rootId, "Hall", "H", null, [gateway, localRouter], true, false),
            new(
                routerRoomId,
                "Router room",
                "RR",
                null,
                [
                    DeviceSource("router-one", "Router one", DeviceType.Router, routerRoomId),
                    DeviceSource("router-two", "Router two", DeviceType.Router, routerRoomId),
                    DeviceSource("computer", "Computer", DeviceType.Computer, routerRoomId)
                ],
                false,
                false),
            new(
                wallRoomId,
                "Quiet room",
                "QR",
                null,
                [DeviceSource("phone", "Phone", DeviceType.Phone, wallRoomId)],
                false,
                false)
        };
        var projection = new RoomMapProjection(
            Network.DisplayLabel,
            Network,
            "network",
            rooms,
            [DeviceSource("unassigned", "Unassigned", DeviceType.Phone)]);

        var layout = RoomMapLayout.Create(projection, 1024);

        Assert.Equal(5, layout.Connections.Count);
        Assert.Equal(2, layout.Connections.Count(connection => connection.Kind == RoomMapConnectionKind.Router));
        Assert.Single(layout.Connections, connection => connection.Kind == RoomMapConnectionKind.Room);
        Assert.Single(layout.Connections, connection => connection.Kind == RoomMapConnectionKind.RootRouter);
        var unassigned = Assert.Single(
            layout.Connections, connection => connection.Kind == RoomMapConnectionKind.Unassigned);
        Assert.True(unassigned.IsDashed);
        Assert.DoesNotContain(layout.Connections, connection => connection.SourceId == gateway.IdentityKey);
        Assert.All(layout.Connections, connection =>
        {
            Assert.True(connection.Points.Count >= 4);
            Assert.All(
                connection.Points.Zip(connection.Points.Skip(1)),
                segment => Assert.True(
                    Math.Abs(segment.First.X - segment.Second.X) < 0.001 ||
                    Math.Abs(segment.First.Y - segment.Second.Y) < 0.001,
                    $"{connection.Kind} connection contains a diagonal segment."));
        });
        Assert.All(layout.Connections, connection =>
        {
            var interiorSegments = connection.Points
                .Zip(connection.Points.Skip(1))
                .Skip(1)
                .SkipLast(1);
            Assert.All(interiorSegments, segment =>
                Assert.DoesNotContain(
                    layout.Rooms,
                    room => IntersectsInterior(segment.First, segment.Second, room.Bounds)));
        });
        Assert.All(layout.Connections.Where(connection => connection.Kind is not RoomMapConnectionKind.RootRouter),
            connection => Assert.Equal("root-entry", connection.TargetId));
        Assert.Equal(localRouter.IdentityKey,
            Assert.Single(layout.Connections, connection => connection.Kind == RoomMapConnectionKind.RootRouter).SourceId);
        Assert.Equal(gateway.IdentityKey,
            Assert.Single(layout.Connections, connection => connection.Kind == RoomMapConnectionKind.RootRouter).TargetId);
    }

    [Fact]
    public void LayoutRoutesUnresolvedGatewayRootsWithoutInventingADevice()
    {
        var roomId = Guid.NewGuid();
        var projection = new RoomMapProjection(
            Network.DisplayLabel,
            Network,
            "network",
            [
                new(
                    roomId,
                    "Office",
                    "O",
                    null,
                    [DeviceSource("router", "Router", DeviceType.Router, roomId)],
                    false,
                    false),
                new(null, "Gateway unavailable", "GW", null, [], true, false, true, "No gateway.")
            ],
            []);

        var layout = RoomMapLayout.Create(projection, 720);

        var connection = Assert.Single(layout.Connections);
        Assert.Equal(RoomMapConnectionKind.Router, connection.Kind);
        Assert.Equal("root-entry", connection.TargetId);
        var placeholder = Assert.Single(layout.Rooms, room => room.IsRoot);
        Assert.True(connection.Points[^1].X >= placeholder.Bounds.X);
        Assert.Empty(placeholder.Devices);
    }

    [Theory]
    [InlineData(true, 1d, 1024d)]
    [InlineData(true, 2d, 1024d)]
    [InlineData(true, 3d, 720d)]
    [InlineData(false, 1d, 720d)]
    [InlineData(false, 2d, 1024d)]
    [InlineData(false, 3d, 1024d)]
    public void ScaleLayoutLinksEveryRouterAndRoomWithoutCrossingRoomsDevicesOrText(
        bool gatewayResolved,
        double textScale,
        double width)
    {
        var projection = SkewedScaleProjection(gatewayResolved);
        var layout = RoomMapLayout.Create(projection, width, textScale);

        Assert.Equal(88, layout.Rooms.Where(room => !room.IsPlaceholder).Sum(room => room.DeviceCount));
        Assert.Equal(12, layout.UnassignedDevices.Count);
        var root = Assert.Single(layout.Rooms, room => room.IsRoot);
        Assert.Equal(!gatewayResolved, root.IsPlaceholder);

        var routers = projection.Rooms.SelectMany(room => room.Devices)
            .Where(device => device.IsRouter && !device.IsGateway)
            .Select(device => device.IdentityKey)
            .ToArray();
        var routerFreeRooms = layout.Rooms
            .Where(room => !room.IsRoot && room.Devices.All(device => !device.Device.IsRouter))
            .ToArray();
        Assert.NotEmpty(routerFreeRooms);
        Assert.Equal(routers.Length + routerFreeRooms.Length + 1, layout.Connections.Count);
        Assert.All(routers, identity =>
            Assert.Single(layout.Connections, connection => connection.SourceId == identity));
        Assert.All(routerFreeRooms, room => Assert.Single(layout.Connections, connection =>
            connection.Kind == RoomMapConnectionKind.Room && connection.SourceId == $"room:{room.Id:D}"));
        Assert.DoesNotContain(layout.Connections, connection =>
            projection.Rooms.SelectMany(room => room.Devices)
                .Any(device => device.IsGateway && device.IdentityKey == connection.SourceId));
        Assert.Equal(gatewayResolved ? 2 : 0,
            layout.Connections.Count(connection => connection.Kind == RoomMapConnectionKind.RootRouter));
        Assert.True(Assert.Single(layout.Connections,
            connection => connection.Kind == RoomMapConnectionKind.Unassigned).IsDashed);

        // Room bounds contain their header text and device tiles; the unassigned strip contains its heading and tiles.
        var devices = layout.Rooms.SelectMany(room => room.Devices).Concat(layout.UnassignedDevices).ToArray();
        foreach (var connection in layout.Connections)
        {
            var source = devices.FirstOrDefault(device => device.Device.IdentityKey == connection.SourceId);
            var sourceRoom = layout.Rooms.FirstOrDefault(room =>
                room.Devices.Any(device => device.Device.IdentityKey == connection.SourceId) ||
                connection.SourceId == $"room:{room.Id:D}");
            var segments = connection.Points.Zip(connection.Points.Skip(1)).ToArray();
            for (var index = 0; index < segments.Length; index++)
            {
                var (start, end) = segments[index];
                Assert.True(Math.Abs(start.X - end.X) < 0.001 || Math.Abs(start.Y - end.Y) < 0.001,
                    $"{connection.SourceId} contains a diagonal segment.");
                // The first segment deliberately leaves the source room, and the last one enters the root room.
                var deliberate = index == 0 ? sourceRoom : index == segments.Length - 1 ? root : null;
                var room = layout.Rooms.FirstOrDefault(room =>
                    !ReferenceEquals(room, deliberate) && IntersectsInterior(start, end, room.Bounds));
                Assert.True(room is null, $"{connection.SourceId} segment {index} crosses room {room?.Name}.");
                var device = devices.FirstOrDefault(device =>
                    !ReferenceEquals(device, source) && IntersectsInterior(start, end, device.Bounds));
                Assert.True(device is null,
                    $"{connection.SourceId} segment {index} crosses device {device?.Device.Name}.");
                Assert.False(connection.Kind != RoomMapConnectionKind.Unassigned &&
                    IntersectsInterior(start, end, layout.UnassignedBounds),
                    $"{connection.SourceId} segment {index} crosses the unassigned strip.");
                Assert.False(IntersectsInterior(start, end, layout.GlobeBounds),
                    $"{connection.SourceId} segment {index} crosses the Internet globe.");
            }
        }
    }

    [Fact]
    public void ScaleLayoutReportsInitialStatusAndMembershipUpdateCosts()
    {
        var projection = SkewedScaleProjection(gatewayResolved: true);
        var statusOnly = projection with
        {
            Rooms = projection.Rooms.Select(room => room with
            {
                Devices = room.Devices.Select((device, index) => index % 3 == 0
                    ? device with { Status = RoomMapDeviceStatus.Offline }
                    : device).ToArray()
            }).ToArray()
        };
        var moved = projection.Rooms[1].Devices[^1] with { RoomId = projection.Rooms[2].Id };
        var membership = projection with
        {
            Rooms = projection.Rooms.Select((room, index) => index switch
            {
                1 => room with { Devices = room.Devices.Take(room.Devices.Count - 1).ToArray() },
                2 => room with { Devices = [.. room.Devices, moved] },
                _ => room
            }).ToArray()
        };
        _ = RoomMapLayout.Create(projection, 1024);

        var (initialMs, initial) = MeasureLayout(projection);
        var (statusMs, status) = MeasureLayout(statusOnly);
        var (membershipMs, relayout) = MeasureLayout(membership);
        output.WriteLine(
            $"Room map layout and routing for 10 rooms, 100 devices: initial {initialMs:F3} ms, "
            + $"status-only update {statusMs:F3} ms, membership update {membershipMs:F3} ms "
            + $"(mean of 20 runs; {initial.Connections.Count} connections).");

        Assert.Equal(Geometry(initial), Geometry(status));
        Assert.NotEqual(Geometry(initial), Geometry(relayout));
        Assert.All(new[] { initialMs, statusMs, membershipMs }, cost =>
            Assert.True(cost < 250, $"Room map layout must stay interactive; measured {cost:F1} ms."));
    }

    private static (double Milliseconds, RoomMapLayout Layout) MeasureLayout(RoomMapProjection projection)
    {
        const int runs = 20;
        RoomMapLayout? layout = null;
        var clock = Stopwatch.StartNew();
        for (var run = 0; run < runs; run++)
        {
            layout = RoomMapLayout.Create(projection, 1024);
        }
        clock.Stop();
        return (clock.Elapsed.TotalMilliseconds / runs, layout!);
    }

    private static string Geometry(RoomMapLayout layout) => string.Join("|",
        layout.Rooms.SelectMany(room => room.Devices.Select(device => $"{device.Device.IdentityKey}@{device.Bounds}"))
            .Concat(layout.Rooms.Select(room => $"{room.Name}@{room.Bounds}"))
            .Concat(layout.Connections.Select(connection =>
                $"{connection.SourceId}:{string.Join(";", connection.Points)}")));

    // 88 room devices with skewed membership plus 12 unassigned devices: 100 relevant devices in total.
    private static RoomMapProjection SkewedScaleProjection(bool gatewayResolved)
    {
        int[] sizes = [28, 18, 12, 9, 6, 5, 4, 3, 2, 1];
        int[] routerCounts = [3, 2, 1, 0, 2, 0, 1, 0, 1, 0];
        var rooms = new List<RoomMapRoom>();
        for (var roomIndex = 0; roomIndex < sizes.Length; roomIndex++)
        {
            var roomId = new Guid($"00000000-0000-0000-0000-{roomIndex + 1:D12}");
            var isRoot = gatewayResolved && roomIndex == 0;
            var devices = Enumerable.Range(0, sizes[roomIndex]).Select(deviceIndex =>
            {
                var router = deviceIndex < routerCounts[roomIndex];
                var device = DeviceSource(
                    $"{roomIndex:D2}-{deviceIndex:D2}",
                    $"{(router ? "Router" : "Device")} {roomIndex:D2}-{deviceIndex:D2}",
                    router ? DeviceType.Router : DeviceType.Computer,
                    roomId);
                return isRoot && deviceIndex == 0 ? device with { IsGateway = true } : device;
            }).ToArray();
            rooms.Add(new(roomId, $"Room {roomIndex:D2}", $"R{roomIndex}", null, devices, isRoot, roomIndex == 3));
        }
        if (!gatewayResolved)
        {
            rooms.Add(new(null, "Gateway unavailable", "GW", null, [], true, false, true, "No gateway."));
        }
        var unassigned = Enumerable.Range(0, 12).Select(index =>
            DeviceSource($"U-{index:D2}", $"Unassigned {index:D2}", DeviceType.Phone)).ToArray();
        return new RoomMapProjection(Network.DisplayLabel, Network, "selected-network", rooms, unassigned);
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

    private static bool IntersectsInterior(RoomMapPoint start, RoomMapPoint end, RoomMapBounds bounds)
    {
        if (Math.Abs(start.Y - end.Y) < 0.001)
        {
            return start.Y > bounds.Y + 0.001 &&
                start.Y < bounds.Bottom - 0.001 &&
                Math.Max(start.X, end.X) > bounds.X + 0.001 &&
                Math.Min(start.X, end.X) < bounds.Right - 0.001;
        }
        if (Math.Abs(start.X - end.X) < 0.001)
        {
            return start.X > bounds.X + 0.001 &&
                start.X < bounds.Right - 0.001 &&
                Math.Max(start.Y, end.Y) > bounds.Y + 0.001 &&
                Math.Min(start.Y, end.Y) < bounds.Bottom - 0.001;
        }
        return false;
    }
}
