# Read-only SQL reporting

Open **Tools > SQL editor**, enter one SQLite SELECT (including CTEs), and choose
**Run**. **Cancel**, leaving Tools, returning to the Tools landing page, and closing
the window stop the query and release its connection. The result shows column
names, rows, elapsed milliseconds, and explicit error or truncation feedback.
Run and Cancel share a row with the right-aligned status. Results fill the page
content width on a theme-aware surface; wide results scroll horizontally.
**Schema and examples** lists every reporting view and its columns, explains its
keys, and supplies examples that can be copied into the editor with **Use example**.
Its **List of tables** separately shows the supported underlying tables with
short descriptions; selecting one displays its columns. This list uses the
query service's existing allowlist, not the database's unrestricted schema.
Prefer reporting views: underlying JSON tables remain internal storage details.

Queries read a consistent snapshot of **persisted** `device-inventory.sqlite`,
not unsaved edits, live scanner objects, or a cache. A committed partial scan can
already have updated aggregate observations, but only completed scans contribute
to `r_scan_history`. No automatic save, migration, or database creation is
performed by the query service. Missing inventory, unsupported formats, malformed
JSON (even outside a query's selected rows), invalid SQL and contention are errors,
not empty results. Load/migrate the inventory normally before querying it.

## Safety and limits

Each run uses its own non-pooled, read-only SQLite connection and temporary views.
`query_only`, SQLite's authorizer and native statement-readonly checks enforce the
boundary; there is no SQL prefix check or SQL rewriting. Writes, DDL, transaction
commands, PRAGMAs, database attachment, extension loading and filesystem functions
are rejected. Only the reporting views and their eight inventory entity backing
tables plus `scan_history` are readable. The backing JSON tables are an internal
storage detail, not the stable reporting contract; use the `r_` views below.
Schema/system/PRAGMA tables and unrelated database objects are not exposed.
SQLite scalar, aggregate, window, date/time and JSON functions use an explicit
allowlist; unknown functions are rejected.

| Limit | Behavior |
| --- | --- |
| One executable statement | A second statement is rejected before the first executes. Trailing whitespace/comments are allowed. |
| 5 seconds | Includes setup, JSON validation and execution. Timeout produces an error, not a purported complete partial result. |
| 1,000 returned rows | The next row is probed; exactly 1,000 is complete only if no additional row exists. Otherwise results are explicitly truncated. |
| 1 MiB returned payload | Includes UTF-8 column names and cell values; NULL counts as four bytes, and blobs as hexadecimal (two bytes per input byte). The next whole row is omitted if it would exceed the limit. |
| 64 result columns; 64 KiB UTF-8 SQL | Oversized requests fail explicitly. SQL containing NUL is rejected. |
| 8 MiB per SQLite value/row | Bounds intermediate SQLite values, including stored JSON. Oversized entities/expressions fail explicitly; no silent JSON truncation. |
| 100 ms busy wait | Contention returns an explicit SQLite locked/busy error; retry after the save finishes. |
| Bounded statement complexity | SQLite limits expression depth to 100, compound SELECT terms to 50 and compiled VM instructions to 250,000. |
| UI previews | Long cell previews stop at 4,096 characters and headings at 120, visibly marked as truncated. The status identifies preview truncation separately from query completeness. Rows are virtualized and columns scroll horizontally. |

Database work runs off the UI thread. Cancellation uses both SQLite interruption
and a VM progress handler. Reads hold one snapshot only for the bounded run; they
never take the inventory writer's application lock, advance its revision, modify
saved schema, or normalize JSON. An inventory save may briefly wait for a read;
cancellation/termination closes the read transaction promptly. Time limits are
execution bounds, not hard real-time guarantees during OS/disk stalls.

## Types, identities and timestamps

Missing optional fields are SQL **NULL**, displayed as `NULL`; an actual text
value containing `NULL` remains text in SQL. Empty collections produce no child
rows. Booleans are stored integers `0`/`1`. Blobs display as hexadecimal.
Columns use SQLite's dynamic scalar types; JSON strings/numbers are not converted
into invented display/current-state facts.

`device_kind` is `mac` or `virtual`. MAC `device_id` values are the saved uppercase,
separator-free six-byte MAC strings. Virtual IDs, person IDs and room IDs are
saved GUID strings. Do not equate MAC and virtual identities or sum both kinds
as distinct logical devices: virtual associations can overlap MAC evidence.

`observation_index`, `port_index` and `evidence_index` are zero-based JSON array
positions in this **read snapshot**, not persistent event IDs. Use all three
columns `(device_kind, device_id, observation_index)` when joining observation
children. Joining only by MAC or device ID multiplies/mismatches different
addresses and networks. Port and UDP rows have an additional child index.
The inventory aggregates are not an unlimited per-probe event log; the separate
completed-scan history is append-only.

Stored timestamps retain their ISO 8601 offset; SQLite `datetime()`, `date()` and
`strftime()` normalize offset-bearing values to UTC. Lexical ordering of raw
timestamps with different offsets is not chronological. `completed_ticks` is the
stored .NET UTC tick value (100 ns since 0001-01-01), not Unix time. `probe_duration`
retains the saved .NET TimeSpan string; `latency_ms` is milliseconds or NULL.
`present`, `last_checked`, `first_seen` and `last_seen` are saved observation facts,
not continuous availability, physical connection times, or current Online status.

Enum columns retain their persisted numeric codes:

- Operating system: 0 Unknown, 1 Windows, 2 Android, 3 Linux, 4 MacOS, 5 IOS, 6 Other.
- Device type/icon: 0 Unknown, 1 Computer, 2 Phone, 3 Tablet, 4 Router, 5 Printer,
  6 MediaDevice, 7 Storage, 8 GameConsole, 9 SmartDevice.
- Endpoint protocol: 0 TCP, 1 UDP.
- UDP state: 0 Responded, 1 NoResponse (inconclusive), 2 Error.

## Reporting views

| View | Columns and cardinality |
| --- | --- |
| `r_devices` | One row per MAC `device_id`; `imported_name`, `imported_hostname`, `imported_type`, `imported_brand`, `imported_family`, `imported_model`, `imported_os`, `imported_os_version`, `imported_address`. These are original imported fields, never merged with observation values. |
| `r_virtual_devices` | One row per virtual `device_id`; `network_id`, `subnet`, `prefix`, `number`, `last_active_mac`, `last_checked`, `present`. No computed automatic name/current status. |
| `r_observations` | One row per saved MAC aggregate or virtual embedded connection. `device_kind`, `device_id`, `observation_index`, `mac`, `inferred` (NULL for normal MAC observations), `network_id`, `subnet`, `address`, `hostname`, `vendor`, `operating_system`, `device_type`, `os_evidence`, `type_evidence`, `os_inferred`, `type_inferred`, `latency_ms`, `probe_duration`, `first_seen`, `last_seen`, `last_checked`, `present`. Virtual rows always use their **embedded** observation, not mutable latest MAC fields. |
| `r_ports` | Zero or more endpoints per observation: `device_kind`, `device_id`, `observation_index`, `port_index`, `port`, `service_name`, `protocol`. |
| `r_udp_evidence` | Zero or more UDP outcomes per observation: `device_kind`, `device_id`, `observation_index`, `evidence_index`, `port`, `service_name`, `state`, `detail`. A null/missing UDP collection yields no rows. |
| `r_names` | One saved manual name per `device_kind`, `device_id`: `name`. Virtual names come from the virtual identity. |
| `r_classification_overrides` | One saved override object per `device_kind`, `device_id`: `operating_system`, `device_type`, `icon`, `brand`, `family`, `model`. Unspecified corrections are NULL, not inferred defaults. |
| `r_people` | `person_id`, `name`, `short_name`, `notes`, `icon_id`. One row per saved person. |
| `r_rooms` | `room_id`, `name`, `short_name`, `notes`, `icon_id`. One row per saved room. |
| `r_assignments` | At most one saved assignment per `device_kind`, `device_id`: `person_id`, `room_id`. Includes embedded virtual assignments. Join to people/rooms by their IDs, retaining NULL with LEFT JOIN. These are current saved assignments, not historical ownership at each scan. |
| `r_discovery_baselines` | One row per `(network_id, subnet)`. Not a notification archive. |
| `r_scan_history` | One recorded completed-scan state per `(device_kind, device_id, sequence)`: `completed_at`, `network_id`, `subnet`, `present`, `completed_ticks`. Sequence is zero-based, append-only within that identity. NULL network identity is not inferred from subnet. |

## Examples

Manual versus imported device metadata:

```sql
SELECT d.device_id, n.name AS manual_name, d.imported_name, d.imported_model
FROM r_devices d
LEFT JOIN r_names n ON n.device_kind = 'mac' AND n.device_id = d.device_id
ORDER BY d.device_id;
```

Equipment assignments (not human presence):

```sql
SELECT a.device_kind, a.device_id, p.name AS person, r.name AS room
FROM r_assignments a
LEFT JOIN r_people p ON p.person_id = a.person_id
LEFT JOIN r_rooms r ON r.room_id = a.room_id;
```

Completed-scan aggregation, preserving identity kind and network scope:

```sql
SELECT network_id, subnet, completed_at, device_kind,
       COUNT(*) AS recorded_devices, SUM(present) AS responding_devices
FROM r_scan_history
GROUP BY network_id, subnet, completed_at, device_kind
ORDER BY MAX(completed_ticks) DESC;
```

Observation/endpoint joins, including historical embedded virtual evidence:

```sql
SELECT o.device_kind, o.device_id, o.address, o.last_seen, p.port, p.service_name
FROM r_observations o
JOIN r_ports p ON p.device_kind = o.device_kind AND p.device_id = o.device_id
             AND p.observation_index = o.observation_index
WHERE o.network_id = 'your-saved-network-id';
```

`InventoryQueryTests`, `SqliteInventoryTests` and `SqliteHistoryQueryTests` use
isolated synthetic databases. The Windows Tools regression suite also runs
`SqlEditor.Ui.Tests.ps1`, with explicit isolated inventory/snapshot paths, and
checks single-row controls, full-width/empty/overflow results, keyboard schema
and example selection, limits/cancellation, narrow layout, and light/dark/high
contrast captures with phase diagnostics. That script refuses to automate a
non-disposable desktop. `SqlEditor.Script.Tests.ps1` checks geometry and delayed,
hidden, disabled, missing, and failing automation peers without driving a
desktop; missing controls retain bounded timeout failures. It also checks that
schema controls revealed by the expander are awaited before keyboard selection
and that Settings is reached by name. Result width is re-read until layout
settles, and a mismatch reports the last editor, result, page and window bounds. The `SqlEditor`
capture scenario covers the page and navigation in the existing UI review;
screenshot evidence and remote checks must still be reviewed before delivery.
