using System.Net;
using System.Net.Sockets;
using FingVibe.Core.Import;
using FingVibe.Core.Networking;

namespace FingVibe.Core.Models;

public enum RoomMapDeviceStatus
{
    Online,
    Offline,
    Unknown
}

public sealed record RoomMapDevice(
    string IdentityKey,
    string Name,
    string Address,
    DeviceType Type,
    DeviceType Icon,
    RoomMapDeviceStatus Status,
    Guid? RoomId,
    bool IsGateway,
    bool IsLocal)
{
    public bool IsRouter => Type == DeviceType.Router;
    public string StatusText => Status switch
    {
        RoomMapDeviceStatus.Online => "Online",
        RoomMapDeviceStatus.Offline => "Offline",
        _ => "No local scan evidence"
    };
    public string CompactStatusText => Status == RoomMapDeviceStatus.Unknown ? "Unknown" : StatusText;
    public string AccessibleName => $"{Name}, {StatusText}, {Address}";
}

public sealed record RoomMapRoom(
    Guid? Id,
    string Name,
    string ShortName,
    string? IconId,
    IReadOnlyList<RoomMapDevice> Devices,
    bool IsRoot,
    bool IsLocalRoom,
    bool IsPlaceholder = false,
    string? PlaceholderText = null)
{
    public int OnlineCount => Devices.Count(device => device.Status == RoomMapDeviceStatus.Online);
    public string CountText => $"{Devices.Count} {(Devices.Count == 1 ? "device" : "devices")} · {OnlineCount} online";
}

public sealed record RoomMapProjection(
    string NetworkLabel,
    LanNetwork? Network,
    string? NetworkId,
    IReadOnlyList<RoomMapRoom> Rooms,
    IReadOnlyList<RoomMapDevice> UnassignedDevices)
{
    public RoomMapRoom? RootRoom => Rooms.FirstOrDefault(room => room.IsRoot);
    public IReadOnlyList<RoomMapDevice> Devices =>
        Rooms.SelectMany(room => room.Devices).Concat(UnassignedDevices).ToArray();

    public static RoomMapProjection Create(
        DeviceInventoryData data,
        LanNetwork? network,
        string? networkId)
    {
        ArgumentNullException.ThrowIfNull(data);
        if (network is null)
        {
            return new("No active IPv4 network", null, networkId, [], []);
        }

        var projected = ProjectDevices(data, network, networkId);
        var gatewayMatches = projected.Where(device => device.IsGateway).ToArray();
        var ambiguousGateway = gatewayMatches.Length > 1;
        var devices = ambiguousGateway
            ? projected.Select(device => device.IsGateway ? device with { IsGateway = false } : device).ToArray()
            : projected;
        var gateway = gatewayMatches.Length == 1 ? gatewayMatches[0] : null;
        var localRoomId = devices.FirstOrDefault(device => device.IsLocal)?.RoomId;
        var rooms = data.PeopleRooms.Rooms.Select(room =>
        {
            var roomDevices = devices.Where(device => device.RoomId == room.Id)
                .OrderByDescending(device => device.IsGateway)
                .ThenByDescending(device => device.Type == DeviceType.Router)
                .ThenBy(device => device.Name, StringComparer.OrdinalIgnoreCase)
                .ThenBy(device => device.IdentityKey, StringComparer.Ordinal).ToArray();
            return new RoomMapRoom(
                room.Id, room.Name, room.ShortName, room.IconId, roomDevices,
                gateway?.RoomId == room.Id, localRoomId == room.Id);
        }).ToList();

        if (gateway is null)
        {
            rooms.Add(new(
                null,
                network.HasGateway ? "Gateway not identified" : "Gateway unavailable",
                "GW",
                "room",
                [],
                true,
                false,
                true,
                ambiguousGateway
                    ? $"Gateway {network.GatewayAddress} matches multiple saved devices; choose one explicitly elsewhere before treating either as the root."
                    : network.HasGateway
                    ? $"No saved device matches gateway {network.GatewayAddress}."
                    : "Windows did not report a gateway for this interface."));
        }
        else if (gateway.RoomId is null || !rooms.Any(room => room.Id == gateway.RoomId))
        {
            rooms.Add(new(
                null,
                "Gateway / no room assigned",
                "GW",
                "room",
                [gateway],
                true,
                gateway.IsLocal,
                false,
                gateway.Address));
        }

        var unassigned = devices.Where(device => device.RoomId is null && !device.IsGateway)
            .OrderBy(device => device.Name, StringComparer.OrdinalIgnoreCase)
            .ThenBy(device => device.IdentityKey, StringComparer.Ordinal).ToArray();
        var roomIds = rooms.Where(room => room.Id.HasValue).Select(room => room.Id!.Value).ToHashSet();
        var orderedUnassigned = unassigned.Concat(devices.Where(device =>
                device.RoomId is { } roomId && !roomIds.Contains(roomId)))
            .OrderBy(device => device.Name, StringComparer.OrdinalIgnoreCase)
            .ThenBy(device => device.IdentityKey, StringComparer.Ordinal).ToArray();

        return new(network.DisplayLabel, network, networkId, rooms, orderedUnassigned);
    }

    private static IReadOnlyList<RoomMapDevice> ProjectDevices(
        DeviceInventoryData data,
        LanNetwork network,
        string? networkId)
    {
        var virtualDevices = data.VirtualDevices.Where(slot =>
                string.Equals(slot.Subnet, network.Cidr, StringComparison.OrdinalIgnoreCase)
                && networkId is not null
                && string.Equals(slot.NetworkId, networkId, StringComparison.Ordinal))
            .ToArray();
        var representedMacs = virtualDevices.SelectMany(slot => slot.History.Select(item => item.Mac))
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var devices = new List<RoomMapDevice>();

        foreach (var (mac, inventoryDevice) in data.Devices.OrderBy(pair => pair.Key, StringComparer.OrdinalIgnoreCase))
        {
            if (representedMacs.Contains(mac))
            {
                continue;
            }

            var observation = inventoryDevice.Observations
                .Where(item => string.Equals(item.Subnet, network.Cidr, StringComparison.OrdinalIgnoreCase)
                    && (networkId is null
                        ? item.NetworkId is null
                        : string.Equals(item.NetworkId, networkId, StringComparison.Ordinal)))
                .OrderByDescending(item => item.LastChecked)
                .ThenByDescending(item => item.Present)
                .ThenByDescending(item => item.LastSeen)
                .ThenBy(item => item.Address, StringComparer.Ordinal)
                .FirstOrDefault();
            var importedAddress = ParseAddress(inventoryDevice.Imported.Address);
            if (observation is null && importedAddress is not null &&
                !MatchesSubnet(importedAddress, network))
            {
                continue;
            }
            if (observation is null && importedAddress is null)
            {
                continue;
            }

            var address = observation?.Address ?? importedAddress!.ToString();
            var correction = data.Classifications.GetValueOrDefault(mac);
            var type = correction?.Type
                ?? FingClassificationMapper.Type(inventoryDevice.Imported.Type)
                ?? observation?.Classification.Type
                ?? DeviceType.Unknown;
            var icon = correction?.Icon ?? type;
            var assignment = data.PeopleRooms.Assignments.GetValueOrDefault(mac);
            var name = FirstText(
                data.Names.GetValueOrDefault(mac),
                inventoryDevice.Imported.Name,
                observation?.Hostname,
                inventoryDevice.Imported.Hostname,
                address);
            devices.Add(new(
                mac,
                name,
                address,
                type,
                icon,
                observation is null
                    ? RoomMapDeviceStatus.Unknown
                    : observation.Present ? RoomMapDeviceStatus.Online : RoomMapDeviceStatus.Offline,
                assignment?.RoomId,
                IsAddress(network.GatewayAddress, address),
                IsAddress(network.LocalAddress, address)));
        }

        foreach (var slot in virtualDevices.OrderBy(item => item.AutomaticName, StringComparer.OrdinalIgnoreCase)
                     .ThenBy(item => item.Id))
        {
            var observation = slot.LatestConnection.Observation;
            var type = slot.Classification?.Type ?? observation.Classification.Type;
            var icon = slot.Classification?.Icon ?? type;
            devices.Add(new(
                slot.Id.ToString("D"),
                FirstText(slot.Name, slot.AutomaticName, observation.Hostname, observation.Address),
                observation.Address,
                type,
                icon,
                slot.Present ? RoomMapDeviceStatus.Online : RoomMapDeviceStatus.Offline,
                slot.Assignment?.RoomId,
                IsAddress(network.GatewayAddress, observation.Address),
                IsAddress(network.LocalAddress, observation.Address)));
        }

        return devices;
    }

    private static string FirstText(params string?[] values) =>
        values.FirstOrDefault(value => !string.IsNullOrWhiteSpace(value))?.Trim()
        ?? throw new InvalidOperationException("A Room map device requires a display name or address.");

    private static IPAddress? ParseAddress(string? address) =>
        IPAddress.TryParse(address, out var parsed) && parsed.AddressFamily == AddressFamily.InterNetwork
            ? parsed
            : null;

    private static bool MatchesSubnet(IPAddress address, LanNetwork network) =>
        SubnetCalculator.GetNetworkAddress(address, network.PrefixLength).Equals(network.NetworkAddress);

    private static bool IsAddress(IPAddress? expected, string actual) =>
        expected is not null && IPAddress.TryParse(actual, out var parsed) && expected.Equals(parsed);
}

public readonly record struct RoomMapBounds(double X, double Y, double Width, double Height)
{
    public double Right => X + Width;
    public double Bottom => Y + Height;
    public double CenterX => X + Width / 2;
    public double CenterY => Y + Height / 2;
    public bool Intersects(RoomMapBounds other) =>
        X < other.Right && Right > other.X && Y < other.Bottom && Bottom > other.Y;
}

public sealed record RoomMapDevicePlacement(RoomMapDevice Device, RoomMapBounds Bounds);

public sealed record RoomMapAnchorPlacement(string Kind, RoomMapBounds Bounds, string? DeviceIdentity = null);

public enum RoomMapConnectionKind
{
    Room,
    Router,
    RootRouter,
    Unassigned
}

public readonly record struct RoomMapPoint(double X, double Y);

public sealed record RoomMapConnection(
    string SourceId,
    string TargetId,
    RoomMapConnectionKind Kind,
    IReadOnlyList<RoomMapPoint> Points)
{
    public bool IsDashed => Kind == RoomMapConnectionKind.Unassigned;
}

public sealed record RoomMapRoomPlacement(
    Guid? Id,
    string Name,
    string ShortName,
    string? IconId,
    bool IsRoot,
    bool IsLocalRoom,
    bool IsPlaceholder,
    string? PlaceholderText,
    int OnlineCount,
    int DeviceCount,
    RoomMapBounds Bounds,
    IReadOnlyList<RoomMapDevicePlacement> Devices,
    IReadOnlyList<RoomMapAnchorPlacement> Anchors);

public sealed record RoomMapLayout(
    double Width,
    double Height,
    RoomMapProjection Projection,
    IReadOnlyList<RoomMapRoomPlacement> Rooms,
    RoomMapBounds GlobeBounds,
    double RootLinkX,
    double RootLinkStartY,
    double RootLinkEndY,
    RoomMapBounds UnassignedBounds,
    IReadOnlyList<RoomMapDevicePlacement> UnassignedDevices,
    IReadOnlyList<RoomMapConnection> Connections)
{
    private const double MinimumWidth = 720;
    private const double Margin = 8;
    private const double ColumnGap = 24;
    private const double RowGap = 32;
    private const double RootWidth = 320;
    private const double RootGutter = 32;
    private const double DeviceWidth = 112;
    private const double EdgeDeviceWidth = 88;
    private const double DeviceGap = 8;
    private const double MaximumTextScale = 3;

    // Text-bearing heights grow with the Windows text scale; widths and icons keep their normal size.
    private sealed record Metrics(double DeviceHeight, double HeaderHeight, double UnassignedHeaderHeight)
    {
        public static Metrics For(double textScale)
        {
            var scale = double.IsFinite(textScale) ? Math.Clamp(textScale, 1, MaximumTextScale) : 1;
            return new(24 + 28 * scale, 40 + 56 * scale, 20 + 28 * scale);
        }
    }

    public static RoomMapLayout Create(RoomMapProjection projection, double viewportWidth, double textScale = 1)
    {
        ArgumentNullException.ThrowIfNull(projection);
        var metrics = Metrics.For(textScale);
        var width = Math.Max(MinimumWidth, double.IsFinite(viewportWidth) ? Math.Ceiling(viewportWidth) : MinimumWidth);
        var columns = width >= 1160 ? 3 : width >= 900 ? 2 : 1;
        var leftWidth = width - Margin * 2 - RootWidth - RootGutter;
        var cellWidth = (leftWidth - ColumnGap * (columns - 1)) / columns;
        var root = projection.Rooms.FirstOrDefault(room => room.IsRoot);
        var otherRooms = projection.Rooms.Where(room => !room.IsRoot)
            .OrderByDescending(room => SizeTier(room))
            .ThenByDescending(room => room.Devices.Count)
            .ThenBy(room => room.ShortName, StringComparer.OrdinalIgnoreCase)
            .ThenBy(room => room.Id ?? Guid.Empty)
            .ToArray();
        var placements = new List<RoomMapRoomPlacement>();

        if (root is not null)
        {
            var rootBounds = MeasureRoom(root, Margin + leftWidth + RootGutter, 0, RootWidth, metrics);
            placements.Add(PlaceRoom(root, rootBounds.X, rootBounds.Y, rootBounds.Width, rootBounds.Height, metrics));
        }

        var rowTop = 0d;
        for (var index = 0; index < otherRooms.Length;)
        {
            var take = Math.Min(columns, otherRooms.Length - index);
            var rowBounds = new List<RoomMapBounds>(take);
            for (var column = 0; column < take; column++)
            {
                var room = otherRooms[index + column];
                var roomWidth = RoomWidth(SizeTier(room), cellWidth);
                var cellLeft = Margin + column * (cellWidth + ColumnGap);
                var x = cellLeft + (cellWidth - roomWidth) / 2;
                rowBounds.Add(MeasureRoom(room, x, rowTop, roomWidth, metrics));
            }
            var rowHeight = rowBounds.Max(bounds => bounds.Height);
            for (var column = 0; column < take; column++)
            {
                var room = otherRooms[index + column];
                var bounds = rowBounds[column];
                placements.Add(PlaceRoom(
                    room, bounds.X, bounds.Y, bounds.Width, bounds.Height, metrics));
            }
            rowTop += rowHeight + RowGap;
            index += take;
        }

        var rootPlacement = placements.FirstOrDefault(room => room.IsRoot);
        var gatewayPlacement = rootPlacement?.Devices.FirstOrDefault(device => device.Device.IsGateway);
        var rootCenter = gatewayPlacement is not null
            ? gatewayPlacement.Bounds.X + gatewayPlacement.Bounds.Width / 2
            : rootPlacement is null
                ? width - Margin - RootWidth / 2
                : rootPlacement.Bounds.X + rootPlacement.Bounds.Width / 2;
        var rootBottom = rootPlacement?.Bounds.Bottom ?? 0;
        var globeBounds = new RoomMapBounds(rootCenter - 36, rootBottom + 32, 72, 72);
        var contentBottom = Math.Max(
            placements.Select(room => room.Bounds.Bottom).DefaultIfEmpty(0).Max(),
            globeBounds.Bottom);
        var unassignedTop = contentBottom + RowGap;
        var unassignedWidth = width - Margin * 2;
        var unassignedPlacements = PlaceUnassigned(
            projection.UnassignedDevices, Margin, unassignedTop, unassignedWidth, metrics);
        var unassignedHeight = unassignedPlacements.Height;
        var unassignedBounds = new RoomMapBounds(Margin, unassignedTop, unassignedWidth, unassignedHeight);
        var connections = RouteConnections(placements, unassignedBounds, unassignedPlacements.Devices.Count);

        return new(
            width,
            unassignedTop + unassignedHeight + Margin,
            projection,
            placements,
            globeBounds,
            rootCenter,
            rootBottom,
            globeBounds.Y - 4,
            unassignedBounds,
            unassignedPlacements.Devices,
            connections);
    }

    private static int SizeTier(RoomMapRoom room) =>
        room.Devices.Count <= 2 ? 0 : room.Devices.Count <= 6 ? 1 : 2;

    private static double RoomWidth(int tier, double cellWidth) =>
        tier switch
        {
            0 => Math.Min(240, cellWidth),
            1 => Math.Min(280, cellWidth),
            _ => cellWidth
        };

    private static RoomMapBounds MeasureRoom(RoomMapRoom room, double x, double y, double width, Metrics metrics)
    {
        var (deviceHeight, headerHeight) = (metrics.DeviceHeight, metrics.HeaderHeight);
        var edgeDevices = room.Devices.Count(device => device.IsRouter && !device.IsGateway);
        var bodyDevices = room.Devices.Where(device => !device.IsRouter || device.IsGateway).ToArray();
        var edgeReserve = edgeDevices > 0 ? EdgeDeviceWidth + DeviceGap : 0;
        var columns = Math.Max(1, (int)Math.Floor(
            (width - 32 - edgeReserve + DeviceGap) / (DeviceWidth + DeviceGap)));
        var bodyRows = (int)Math.Ceiling((double)Math.Max(bodyDevices.Length, 0) / columns);
        var bodyHeight = bodyRows > 0 ? bodyRows * (deviceHeight + DeviceGap) - DeviceGap : 0;
        var edgeHeight = edgeDevices > 0 ? edgeDevices * (deviceHeight + DeviceGap) - DeviceGap : 0;
        var contentHeight = Math.Max(bodyHeight, edgeHeight);
        return new(x, y, width, Math.Max(32 + headerHeight, headerHeight + contentHeight + 16));
    }

    private static RoomMapRoomPlacement PlaceRoom(
        RoomMapRoom room,
        double x,
        double y,
        double width,
        double height,
        Metrics metrics)
    {
        var (deviceHeight, headerHeight) = (metrics.DeviceHeight, metrics.HeaderHeight);
        var edgeDevices = room.Devices.Where(device => device.IsRouter && !device.IsGateway)
            .OrderBy(device => device.Name, StringComparer.OrdinalIgnoreCase)
            .ThenBy(device => device.IdentityKey, StringComparer.Ordinal).ToArray();
        var bodyDevices = room.Devices.Where(device => !device.IsRouter || device.IsGateway)
            .OrderByDescending(device => device.IsGateway)
            .ThenBy(device => device.Name, StringComparer.OrdinalIgnoreCase)
            .ThenBy(device => device.IdentityKey, StringComparer.Ordinal).ToArray();
        var edgeReserve = edgeDevices.Length > 0 ? EdgeDeviceWidth + DeviceGap : 0;
        var columns = Math.Max(1, (int)Math.Floor(
            (width - 32 - edgeReserve + DeviceGap) / (DeviceWidth + DeviceGap)));
        var placements = new List<RoomMapDevicePlacement>();
        var anchors = new List<RoomMapAnchorPlacement>();
        if (room.IsRoot)
        {
            anchors.Add(new("root-entry", new(x + 8, y + headerHeight + 18, 8, 8)));
        }
        for (var index = 0; index < bodyDevices.Length; index++)
        {
            var device = bodyDevices[index];
            var bounds = new RoomMapBounds(
                x + 16 + index % columns * (DeviceWidth + DeviceGap),
                y + headerHeight + index / columns * (deviceHeight + DeviceGap),
                DeviceWidth,
                deviceHeight);
            placements.Add(new(device, bounds));
            if (room.IsRoot && device.IsGateway)
            {
                anchors.Add(new(
                    "gateway-entry",
                    new(bounds.X - 4, bounds.CenterY - 4, 8, 8),
                    device.IdentityKey));
            }
        }
        for (var index = 0; index < edgeDevices.Length; index++)
        {
            var deviceBounds = new RoomMapBounds(
                x + width - EdgeDeviceWidth - 16,
                y + headerHeight + index * (deviceHeight + DeviceGap),
                EdgeDeviceWidth,
                deviceHeight);
            placements.Add(new(edgeDevices[index], deviceBounds));
            anchors.Add(new(
                "router",
                new(deviceBounds.Right - 4, deviceBounds.Y + deviceHeight / 2 - 4, 8, 8),
                edgeDevices[index].IdentityKey));
        }
        if (!room.IsRoot && edgeDevices.Length == 0)
        {
            anchors.Add(new("room-wall", new(x + width - 12, y + headerHeight + 18, 8, 8)));
        }

        return new(
            room.Id,
            room.Name,
            room.ShortName,
            room.IconId,
            room.IsRoot,
            room.IsLocalRoom,
            room.IsPlaceholder,
            room.PlaceholderText,
            room.OnlineCount,
            room.Devices.Count,
            new(x, y, width, height),
            placements,
            anchors);
    }

    private static IReadOnlyList<RoomMapConnection> RouteConnections(
        IReadOnlyList<RoomMapRoomPlacement> rooms,
        RoomMapBounds unassignedBounds,
        int unassignedDeviceCount)
    {
        var root = rooms.FirstOrDefault(room => room.IsRoot);
        var rootEntry = root?.Anchors.FirstOrDefault(anchor => anchor.Kind == "root-entry");
        if (root is null || rootEntry is null)
        {
            return [];
        }

        var trunkX = root.Bounds.X - RootGutter / 2;
        var target = Center(rootEntry.Bounds);
        var connections = new List<RoomMapConnection>();
        foreach (var room in rooms.Where(room => !room.IsRoot))
        {
            var routerAnchors = room.Anchors.Where(anchor => anchor.Kind == "router").ToArray();
            if (routerAnchors.Length == 0)
            {
                var wall = room.Anchors.FirstOrDefault(anchor => anchor.Kind == "room-wall");
                if (wall is not null)
                {
                    connections.Add(RouteToRootEntry(
                        $"room:{room.Id?.ToString("D") ?? room.Name}",
                        "root-entry",
                        RoomMapConnectionKind.Room,
                        Center(wall.Bounds),
                        room,
                        rooms,
                        trunkX,
                        target));
                }
                continue;
            }

            foreach (var anchor in routerAnchors)
            {
                connections.Add(RouteToRootEntry(
                    anchor.DeviceIdentity ?? $"router:{room.Name}",
                    "root-entry",
                    RoomMapConnectionKind.Router,
                    Center(anchor.Bounds),
                    room,
                    rooms,
                    trunkX,
                    target));
            }
        }

        var gatewayEntry = root.Anchors.FirstOrDefault(anchor => anchor.Kind == "gateway-entry");
        if (gatewayEntry is not null)
        {
            foreach (var anchor in root.Anchors.Where(anchor => anchor.Kind == "router"))
            {
                connections.Add(new(
                    anchor.DeviceIdentity ?? $"router:{root.Name}",
                    gatewayEntry.DeviceIdentity ?? "gateway",
                    RoomMapConnectionKind.RootRouter,
                    RouteRootRouter(anchor.Bounds, root.Bounds, trunkX, gatewayEntry.Bounds)));
            }
        }

        if (unassignedDeviceCount > 0)
        {
            var source = new RoomMapPoint(unassignedBounds.Right - 4, unassignedBounds.Y + 12);
            var exitY = unassignedBounds.Y - RowGap / 2;
            connections.Add(new(
                "unassigned",
                "root-entry",
                RoomMapConnectionKind.Unassigned,
                Orthogonal([source, new(source.X, exitY), new(trunkX, exitY), new(trunkX, target.Y), target])));
        }

        return connections;
    }

    private static RoomMapConnection RouteToRootEntry(
        string sourceId,
        string targetId,
        RoomMapConnectionKind kind,
        RoomMapPoint source,
        RoomMapRoomPlacement room,
        IReadOnlyList<RoomMapRoomPlacement> rooms,
        double trunkX,
        RoomMapPoint target) =>
        new(
            sourceId,
            targetId,
            kind,
            RouteOutsideRoom(source, room, rooms, trunkX, target));

    private static IReadOnlyList<RoomMapPoint> RouteOutsideRoom(
        RoomMapPoint source,
        RoomMapRoomPlacement sourceRoom,
        IReadOnlyList<RoomMapRoomPlacement> rooms,
        double trunkX,
        RoomMapPoint target)
    {
        var laneX = sourceRoom.Bounds.Right + 8;
        var horizontalMin = Math.Min(laneX, trunkX);
        var horizontalMax = Math.Max(laneX, trunkX);
        var direct = rooms.All(room =>
            ReferenceEquals(room, sourceRoom) ||
            !IntersectsHorizontalCorridor(room.Bounds, horizontalMin, horizontalMax, source.Y));
        if (direct)
        {
            return Orthogonal(
            [
                source,
                new(laneX, source.Y),
                new(trunkX, source.Y),
                new(trunkX, target.Y),
                target
            ]);
        }

        var rowGapY = sourceRoom.Bounds.Bottom + RowGap / 2;
        return Orthogonal(
        [
            source,
            new(laneX, source.Y),
            new(laneX, rowGapY),
            new(trunkX, rowGapY),
            new(trunkX, target.Y),
            target
        ]);
    }

    private static bool IntersectsHorizontalCorridor(
        RoomMapBounds bounds,
        double left,
        double right,
        double y) =>
        y > bounds.Y && y < bounds.Bottom && right > bounds.X && left < bounds.Right;

    private static IReadOnlyList<RoomMapPoint> RouteRootRouter(
        RoomMapBounds sourceBounds,
        RoomMapBounds root,
        double trunkX,
        RoomMapBounds targetBounds)
    {
        var source = Center(sourceBounds);
        var outsideX = root.Right + 4;
        var laneY = root.Bottom + RowGap / 2;
        var target = Center(targetBounds);
        return Orthogonal(
        [
            source,
            new(outsideX, source.Y),
            new(outsideX, laneY),
            new(trunkX, laneY),
            new(trunkX, target.Y),
            target
        ]);
    }

    private static RoomMapPoint Center(RoomMapBounds bounds) =>
        new(bounds.CenterX, bounds.CenterY);

    private static IReadOnlyList<RoomMapPoint> Orthogonal(IEnumerable<RoomMapPoint> points)
    {
        var orthogonal = new List<RoomMapPoint>();
        foreach (var point in points)
        {
            if (orthogonal.Count == 0)
            {
                orthogonal.Add(point);
                continue;
            }
            var previous = orthogonal[^1];
            if (Math.Abs(point.X - previous.X) < 0.001 && Math.Abs(point.Y - previous.Y) < 0.001)
            {
                continue;
            }
            orthogonal.Add(point);
        }
        return orthogonal;
    }

    private static (
        double Height,
        IReadOnlyList<RoomMapDevicePlacement> Devices) PlaceUnassigned(
            IReadOnlyList<RoomMapDevice> devices,
            double x,
            double y,
            double width,
            Metrics metrics)
    {
        var (deviceHeight, headerHeight) = (metrics.DeviceHeight, metrics.UnassignedHeaderHeight);
        var columns = Math.Max(1, (int)Math.Floor(
            (width - 32 + DeviceGap) / (DeviceWidth + DeviceGap)));
        var placements = devices.Select((device, index) => new RoomMapDevicePlacement(
            device,
            new(
                x + 16 + index % columns * (DeviceWidth + DeviceGap),
                y + headerHeight + 4 + index / columns * (deviceHeight + DeviceGap),
                DeviceWidth,
                deviceHeight))).ToArray();
        var rows = (int)Math.Ceiling((double)devices.Count / columns);
        var height = Math.Max(
            68 + headerHeight,
            headerHeight + 16
            + (rows > 0 ? rows * (deviceHeight + DeviceGap) - DeviceGap : 0));
        return (height, placements);
    }
}
