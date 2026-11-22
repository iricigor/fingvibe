namespace FingVibe.Core.Storage;

public sealed record ReportingView(string Name, string Title, string Description, string Columns, string SelectSql)
{
    public string DisplayName => $"{Title} ({Name})";
}

public sealed record ReportingTable(string Name, string Description, string Columns);

public sealed record ReportingExample(string Name, string Level, string Purpose, string Sql)
{
    public string DisplayName => $"{Name} ({Level})";
}

public static class InventoryReportingSchema
{
    public static IReadOnlyList<ReportingTable> Tables { get; } =
    [
        new("devices", "Saved MAC identities, imported metadata and aggregate observations as JSON.", "id, data"),
        new("virtual_devices", "Saved virtual identities and their embedded connections as JSON.", "id, data"),
        new("names", "Manual MAC-device names as JSON strings.", "id, data"),
        new("classifications", "Manual MAC-device classification overrides as JSON.", "id, data"),
        new("people", "Saved people and their descriptive fields as JSON.", "id, data"),
        new("rooms", "Saved rooms and their descriptive fields as JSON.", "id, data"),
        new("assignments", "Current MAC-device person and room assignments as JSON.", "id, data"),
        new("baselines", "Saved network discovery baselines as JSON.", "id, data"),
        new("scan_history", "Completed-scan states. scan_id and virtual_id require inventory format 3.",
            "kind, id, sequence, completed_at, network_id, subnet, present, completed_ticks, scan_id, virtual_id")
    ];

    internal static readonly string[] EntityTables = Tables
        .Where(table => table.Name != "scan_history").Select(table => table.Name).ToArray();

    private const string ObservationSource = """
        SELECT 'mac' AS device_kind, d.id AS device_id, o.key AS observation_index,
               d.id AS mac, NULL AS inferred, o.value AS observation
        FROM main.devices d, json_each(d.data, '$.observations') o
        UNION ALL
        SELECT 'virtual', d.id, c.key, json_extract(c.value, '$.mac'),
               json_extract(c.value, '$.inferred'), json_extract(c.value, '$.observation')
        FROM main.virtual_devices d, json_each(d.data, '$.history') c
        """;

    private static string Fields(string value, params (string Column, string Path)[] fields) =>
        string.Join(", ", fields.Select(field => $"json_extract({value}, '$.{field.Path}') AS {field.Column}"));

    private static readonly (string, string)[] ClassificationFields =
    [
        ("operating_system", "operatingSystem"), ("device_type", "type"), ("icon", "icon"),
        ("brand", "brand"), ("family", "family"), ("model", "model")
    ];

    public static IReadOnlyList<ReportingView> Views { get; } =
    [
        new("r_devices", "Devices and imported details", "One row per saved MAC identity. Imported fields are not local observations.",
            "device_id, imported_name, imported_hostname, imported_type, imported_brand, imported_family, imported_model, imported_os, imported_os_version, imported_address",
            "SELECT id AS device_id, " + Fields("data",
                ("imported_name", "imported.name"), ("imported_hostname", "imported.hostname"),
                ("imported_type", "imported.type"), ("imported_brand", "imported.brand"),
                ("imported_family", "imported.family"), ("imported_model", "imported.model"),
                ("imported_os", "imported.operatingSystem"), ("imported_os_version", "imported.operatingSystemVersion"),
                ("imported_address", "imported.address")) + " FROM main.devices"),
        new("r_virtual_devices", "Virtual devices", "One row per saved virtual identity; present is the last persisted observation, not current presence.",
            "device_id, network_id, subnet, prefix, number, last_active_mac, last_checked, present",
            "SELECT id AS device_id, " + Fields("data", ("network_id", "networkId"), ("subnet", "subnet"),
                ("prefix", "prefix"), ("number", "number"), ("last_active_mac", "lastActiveMac"),
                ("last_checked", "lastChecked"), ("present", "present")) + " FROM main.virtual_devices"),
        new("r_observations", "Observations", "One row per saved MAC observation or embedded virtual connection. Key: device_kind + device_id + observation_index (zero-based, snapshot-local). Virtual values come from that connection, not the current MAC record.",
            "device_kind, device_id, observation_index, mac, inferred, network_id, subnet, address, hostname, vendor, operating_system, device_type, os_evidence, type_evidence, os_inferred, type_inferred, latency_ms, probe_duration, first_seen, last_seen, last_checked, present",
            "SELECT device_kind, device_id, observation_index, mac, inferred, " + Fields("observation",
                ("network_id", "networkId"), ("subnet", "subnet"), ("address", "address"),
                ("hostname", "hostname"), ("vendor", "vendor"),
                ("operating_system", "classification.operatingSystem"), ("device_type", "classification.type"),
                ("os_evidence", "classification.operatingSystemEvidence"), ("type_evidence", "classification.typeEvidence"),
                ("os_inferred", "classification.operatingSystemIsInferred"), ("type_inferred", "classification.typeIsInferred"),
                ("latency_ms", "latency"), ("probe_duration", "probeDuration"), ("first_seen", "firstSeen"),
                ("last_seen", "lastSeen"), ("last_checked", "lastChecked"), ("present", "present"))
                + $" FROM ({ObservationSource})"),
        new("r_ports", "Ports per observation", "Zero or more saved endpoints per observation. Join using all three observation key columns; port_index is zero-based.",
            "device_kind, device_id, observation_index, port_index, port, service_name, protocol",
            "SELECT o.device_kind, o.device_id, o.observation_index, p.key AS port_index, "
                + Fields("p.value", ("port", "port"), ("service_name", "serviceName"), ("protocol", "protocol"))
                + $" FROM ({ObservationSource}) o, json_each(o.observation, '$.ports') p"),
        new("r_udp_evidence", "UDP checks per observation", "Zero or more saved UDP outcomes per observation; no-response is inconclusive, not a closed port. Join on all three observation key columns.",
            "device_kind, device_id, observation_index, evidence_index, port, service_name, state, detail",
            "SELECT o.device_kind, o.device_id, o.observation_index, u.key AS evidence_index, "
                + Fields("u.value", ("port", "port"), ("service_name", "serviceName"), ("state", "state"), ("detail", "detail"))
                + $" FROM ({ObservationSource}) o, json_each(o.observation, '$.udpObservations') u WHERE u.type <> 'null'"),
        new("r_names", "Manual device names", "Saved manual names; MAC and virtual identities remain separate. No inferred display names.",
            "device_kind, device_id, name",
            """
            SELECT 'mac' AS device_kind, id AS device_id, json_extract(data, '$') AS name FROM main.names
            UNION ALL
            SELECT 'virtual', id, json_extract(data, '$.name') FROM main.virtual_devices
            WHERE json_extract(data, '$.name') IS NOT NULL
            """),
        new("r_classification_overrides", "Manual classification corrections", "Saved manual corrections, not automatically merged with observed/imported classification.",
            "device_kind, device_id, operating_system, device_type, icon, brand, family, model",
            "SELECT 'mac' AS device_kind, id AS device_id, " + Fields("data", ClassificationFields)
                + " FROM main.classifications UNION ALL SELECT 'virtual', id, "
                + Fields("json_extract(data, '$.classification')", ClassificationFields)
                + " FROM main.virtual_devices WHERE json_type(data, '$.classification') = 'object'"),
        new("r_people", "People", "One row per saved person. Assignments describe equipment, not human presence.",
            "person_id, name, short_name, notes, icon_id",
            "SELECT id AS person_id, " + Fields("data", ("name", "name"), ("short_name", "shortName"),
                ("notes", "notes"), ("icon_id", "iconId")) + " FROM main.people"),
        new("r_rooms", "Rooms", "One row per saved room.",
            "room_id, name, short_name, notes, icon_id",
            "SELECT id AS room_id, " + Fields("data", ("name", "name"), ("short_name", "shortName"),
                ("notes", "notes"), ("icon_id", "iconId")) + " FROM main.rooms"),
        new("r_assignments", "Device assignments", "At most one saved assignment per device_kind + device_id. Join person_id/room_id to people/rooms. These are current saved assignments, not event-time history.",
            "device_kind, device_id, person_id, room_id",
            """
            SELECT 'mac' AS device_kind, id AS device_id,
                   json_extract(data, '$.personId') AS person_id, json_extract(data, '$.roomId') AS room_id
            FROM main.assignments
            UNION ALL
            SELECT 'virtual', id, json_extract(data, '$.assignment.personId'), json_extract(data, '$.assignment.roomId')
            FROM main.virtual_devices WHERE json_type(data, '$.assignment') = 'object'
            """),
        new("r_discovery_baselines", "Discovery baselines", "One saved baseline per network_id + subnet. Not a notification archive.",
            "network_id, subnet",
            "SELECT " + Fields("data", ("network_id", "networkId"), ("subnet", "subnet")) + " FROM main.baselines"),
        new("r_scan_history", "Completed-scan history", "One completed-scan state per device_kind + device_id + sequence. Sequence is zero-based and append-only. Network/subnet and timestamp retain their stored meaning; absent network identity is NULL.",
            "device_kind, device_id, sequence, completed_at, network_id, subnet, present, completed_ticks",
            """
            SELECT kind AS device_kind, id AS device_id, sequence, completed_at, network_id, subnet, present, completed_ticks
            FROM main.scan_history
            """)
    ];

    // Ordered from simple to advanced; loading an example never runs it.
    public static IReadOnlyList<ReportingExample> Examples { get; } =
    [
        new("Rooms by name", "Simple", "List saved rooms alphabetically with their short names.", """
            SELECT name, short_name
            FROM r_rooms
            ORDER BY name;
            """),
        new("Device, person and room", "Medium",
            "Show the person and room currently assigned to each device; assignments are not presence.", """
            SELECT a.device_kind, a.device_id, p.name AS person, r.name AS room
            FROM r_assignments a
            LEFT JOIN r_people p ON p.person_id = a.person_id
            LEFT JOIN r_rooms r ON r.room_id = a.room_id;
            """),
        new("Device metadata", "Medium",
            "Combine manual names with the details imported for each saved MAC identity.", """
            SELECT d.device_id, n.name AS manual_name, d.imported_name, d.imported_model
            FROM r_devices d
            LEFT JOIN r_names n ON n.device_kind = 'mac' AND n.device_id = d.device_id
            ORDER BY d.device_id;
            """),
        new("Completed-scan aggregation", "Advanced",
            "Count recorded and responding devices per completed scan, newest first.", """
            SELECT network_id, subnet, completed_at, device_kind,
                   COUNT(*) AS recorded_devices, SUM(present) AS responding_devices
            FROM r_scan_history
            GROUP BY network_id, subnet, completed_at, device_kind
            ORDER BY MAX(completed_ticks) DESC;
            """),
        new("Observation endpoints", "Advanced",
            "List the saved ports of each observation by joining on all three observation key columns.", """
            SELECT o.device_kind, o.device_id, o.address, o.last_seen, p.port, p.service_name
            FROM r_observations o
            JOIN r_ports p ON p.device_kind = o.device_kind AND p.device_id = o.device_id
                         AND p.observation_index = o.observation_index;
            """)
    ];
}
