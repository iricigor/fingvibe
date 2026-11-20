# Screenshot sources

The current manual uses real native Windows captures from disposable GitHub
Actions runners. They show controlled review data, not a user's LAN, real
equipment availability or internet speed measurements.

## Current captures: v1.4.223 documentation

[Actions run 44808427805, attempt 1](https://github.com/iricigor/fingvibe/actions/runs/44808427805)
captured the images on **2026-11-20**.
Application and capture-harness source:
[`9d89749fa41acf9ffa4307460a719419c9a68a6d`](https://github.com/iricigor/fingvibe/commit/9d89749fa41acf9ffa4307460a719419c9a68a6d).
That revision contains only an empty documentation-task bootstrap commit over
release **v1.4.223**
([`abb11b9199e5672d2061588056181218669a7f87`](https://github.com/iricigor/fingvibe/commit/abb11b9199e5672d2061588056181218669a7f87)):
its application source, capture helpers and test fixtures are unchanged.

The executable is stamped **v0.0.979 TEST**, built **2026-11-20 20:07:56 UTC**.
That test identity, the amber ribbon, runner hostname, focus outlines and
test-only messages remain visible. It is not presented as an official release.

All 21 refreshed/new PNGs below are copied **unchanged**, with no cropping,
stitching, retouching or fabricated results. They use Standard Dark.
Most are **1280 x 800 pixels**; size exceptions are listed.
Every selected image was inspected for readable intended content and safe data.

### Main-page artifact

Artifact: **`fingvibe-ui-review-pr-979-attempt-1`**.
The capture job passed with a completed 19-scenario manifest; its capture step
reported **80.8 seconds**. This is the capture step, not the whole workflow.
The selected images are:

| Manual image | Artifact image | Visible state |
| --- | --- | --- |
| `first-scan.png` | `fingvibe-ui-review.png` | One loopback responder after a completed scan, with a saved review name. |
| `overview.png` | `fingvibe-overview.png` | Summary of that completed loopback scan. |
| `network.png` | `fingvibe-network.png` | Sample public IP `203.0.113.10`, Example City/Country and review ISP. |
| `device-details.png` | `fingvibe-device-details.png` | Overview tab, observation summary, usage category and unassigned Person/Room controls. |
| `people.png` | `fingvibe-people.png` | Combined People & rooms page with invented entries and no assignments. |
| `person-details.png` | `fingvibe-person-details.png` | Empty equipment state; Assign devices is below the viewport. |
| `import.png` | `fingvibe-fing-import.png` | Synthetic workbook analysis and missing assignment warnings, not an import completion. |
| `network-checks.png` | `fingvibe-network-health.png` | Monitoring off, Service status and empty Incident history; no diagnostic results. |
| `speed-test.png` | `fingvibe-speed-test.png` | Stopped Cloudflare ready state and gauges awaiting measurements. |
| `about.png` | `fingvibe-about.png` | Connected home icon, exact test identity and the non-release Updates explanation. |

No real LAN was scanned. UI-review mode uses loopback `127.0.0.1/32`, invented
MAC metadata and a sample public identity. No Cloudflare speed measurement
was started. These are UI examples, not detection or measurement claims.

**Selection limitation:** the optional Database backups capture had no isolated
inventory fixture and showed the expected review-only error. Its later Settings
and empty-Devices captures inherited that status. Those images are not used;
Settings and backups below come from their successful isolated suites.

### Focused regression artifacts

All are from the same run, attempt, executable and source revision above.
Each selected suite passed on its first attempt.
The `pr-979` artifact suffix is the manual workflow's run number, not PR #979.

| Manual image | Artifact (`fingvibe-ui-regression-...-pr-979-attempt-1`) | Path inside artifact | State / size exception |
| --- | --- | --- | --- |
| `devices.png` | `devices-presentation` | `attempt-1/devices/devices-Standard Dark.png` | Expanded filters and 80 synthetic saved devices; 1280 x 720. |
| `settings.png` | `sidebar-preferences-scheduling` | `attempt-1/sidebar/settings-collapsed.png` | Three collapsed preference sections and About; 1280 x 720. |
| `scheduled-scans.png` | `sidebar-preferences-scheduling` | `attempt-1/sidebar/scheduled-scans-Standard Dark.png` | Scheduling on, four-hour choice, independent monitoring off; 1280 x 720. |
| `device-history.png` | `details-activity` | `attempt-1/activity/activity-Standard-Dark-1280.png` | Activity with two synthetic response/nonresponse squares and unknown gaps. |
| `scan-observations.png` | `details-observations` | `attempt-1/observations/history-table-standard-dark.png` | Five synthetic completed scan observations, not continuous live status. |
| `sql.png` | `tools-device-data` | `attempt-1/sql-editor/sql-results-standard-dark.png` | Completed SELECT returning one invented device name. |
| `import-conflicts.png` | `tools-utilities` | `attempt-1/fing-import/fing-import-name-emoji.png` | Synthetic name conflict with Keep existing; the proposed name has a selected emoji. |
| `import-review.png` | `tools-utilities` | `attempt-1/fing-import/fing-import-ready.png` | Skipped Person/Room fields and final import controls; no import was performed. |
| `database-backups.png` | `tools-utilities` | `attempt-1/database-backups/backups-expanded-daily.png` | Two consistent copies of an isolated fixture database, with one daily representative. |
| `assignments.png` | `devices-columns-sorting` | `attempt-1/devices/devices-assignments-True-True.png` | Selected synthetic device with combined Person/Room labels and Last seen; 1880 x 720. |
| `virtual-device.png` | `devices-row-expansion` | `attempt-1/devices/devices-mac-expansion-wide.png` | Expanded inferred identity with three earlier MACs and an additional-count summary; 1280 x 720. |

The Devices fixture contains invented names/MACs, loopback addresses and
illustrative response times. Its saved `127.0.0.0/24` context differs from the
safe selected `127.0.0.1/32` target. The visible different-target warning is
intentional, not edited out, and does not indicate a real LAN scan.

The scheduler suite accelerates waits only in its isolated review fixture;
the visible interval is still four hours. Activity and observation suites seed
known history, including fixed historical timestamps. Their colors/counts are
test evidence, not measured uptime. The backup path belongs to the runner's
temporary fixture, not the normal user's data folder.

## Initial manual captures

The initial November 8 manual captures and their v1.1.107 comparison remain
documented in the
[historical source record](https://github.com/iricigor/fingvibe/blob/abb11b9199e5672d2061588056181218669a7f87/docs/manual/screenshots.md).
The unchanged `devices-empty.png` from that set is retained as historical
evidence, not used to illustrate the current Devices instructions.
The older README/tool images retain their separate
[original provenance](https://github.com/iricigor/fingvibe/blob/main/docs/screenshots/README.md).

The unused old `docs/screenshots/overview.png` was removed after verifying no
remaining source references. The current Overview image is
`docs/screenshots/manual/overview.png`; the deleted asset remains in Git history.

## Earlier diagram image

The complete earlier troubleshooting diagram remains
`docs/screenshots/network-troubleshooting.png`, a **1920 x 971** native capture
supplied by iricigor on 2026-11-01. Its version/source commit remain unknown.
Seven opaque regions redact network-specific values with the user's approval;
all other pixels are preserved. It is labeled historical, with no checks run,
and is not presented as the current page layout or discovered physical topology.

## Remaining visual coverage

| Gap | Boundary |
| --- | --- |
| Windows discovery toast and in-app popup | Text explains delivered behavior; no new state-specific notification capture is claimed. |
| Complete current diagnostics diagram | The available new view clips public providers; retain the clearly historical complete diagram rather than imply completeness. |
| Stable-build update checks/download/install | About shows the actual Test build's no-check state; stable workflow steps come from released source, not a fabricated update screenshot. |
| Completed internet measurements | A live speed test consumes data and reports results; no such run was approved or performed. |

## Reproduce or replace

Use disposable Windows CI, never a working user's desktop.
Dispatch **Pull request build** on the intended immutable source with
`additional_scenarios` selecting the main-page scenarios. Existing focused
regression suites own their own fixtures, setup, readiness and cleanup; retrieve
their artifacts for SQL results, imports, assignments, Settings and history.
Do not change assertions or fixture ownership simply to obtain a picture.

Inspect each selected PNG and retain only the intended safe image. Record its
actual source, run, artifact, dimensions, edits and visible state here and keep
the page caption consistent. Commit the PNGs before artifacts expire.
Newer screenshots alone do not prove that a feature has shipped.
