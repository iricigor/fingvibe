# Saved data and backups

FingVibe saves data under:

```text
%LOCALAPPDATA%\FingVibe
```

Press **Win+R**, enter that path, and press **Enter** to open the folder.
It is different from the installer folder under
`%LOCALAPPDATA%\Programs\FingVibe`.

## Important files

| File | Purpose |
| --- | --- |
| `device-inventory.sqlite` | Authoritative inventory, names, identification corrections, people/rooms, assignments, virtual identities, history, and discovery baselines. |
| `latest-scan.json` | Separate saved-scan cache. SQLite checkpoints are authoritative when present. |
| `appearance.json` | Appearance choices. |
| `device-table.json` | Column choices, widths, row density, previews, and Status filtering. |
| `navigation.json` | Wide-window navigation width/collapse preferences. |
| `periodic-scan.json` | Scheduled-scan choice and interval. |
| `router-wan.json` | Optional WAN values by Windows network profile. |

The folder can also contain cached vendor registries and older migration inputs.
Do not edit the SQLite database or remove individual records with another tool
as a normal way to change app data. Use FingVibe's own editors.

## Make a backup

There is no automatic backup feature in the version covered by this manual.
Make a manual copy:

1. Close **all** FingVibe instances.
2. Wait until the app has finished closing.
3. Open `%LOCALAPPDATA%\FingVibe`.
4. Copy the **whole folder** to a separate, dated backup location.
5. Keep the copy private.

Copying the whole folder preserves database sidecar files if any remain, as well
as preferences. Do not copy only an open database while the app is saving.
The SQL editor's report output is not a complete backup.

History is retained without automatic age/count trimming.
The database and backups can grow over time.

## Restore a backup

1. Close all FingVibe instances.
2. Make a separate copy of the current data folder first.
3. Move the current folder aside rather than merging files into it.
4. Restore the complete backup as `%LOCALAPPDATA%\FingVibe`.
5. Start a compatible current FingVibe release.
6. Check saved names, assignments, and preferences.
7. Run a new scan when you need current presence evidence.

Restoration replaces the saved state with the backup's state.
It does not merge later edits into an older copy.
Historical results are not live Online evidence.
If the restored database cannot be loaded, stop and keep both copies for diagnosis.

## Older JSON files

Earlier versions stored inventory and metadata in JSON.
Supported legacy files are migration input, not synchronized copies of SQLite.
Original legacy files are left intact during migration.

Once SQLite is authoritative, editing old JSON does not update the app.
An invalid existing SQLite database does not safely fall back to stale JSON.
See [Common problems](problems.md#saved-data-cannot-be-loaded).

## Remove saved data

!!! warning "This removes your saved state"
    Removing this folder discards inventory, history, names, corrections,
    people/rooms, assignments, and preferences. Make a backup first.

1. Close all FingVibe instances.
2. Make a backup if you might need the data again.
3. Remove or move aside **only** `%LOCALAPPDATA%\FingVibe`.
4. Start FingVibe to create a new saved state.

Do not remove the broader `%LOCALAPPDATA%` directory.
Uninstalling the app alone preserves this separate data folder.

For errors, preserve the affected files before trying recovery.
Do not delete a damaged database just to hide the error.
