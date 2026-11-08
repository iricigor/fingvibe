# Screenshot sources

Screenshots in this manual are real native Windows captures, not mockups.
They are illustrative UI evidence, not a real user's LAN or measurements.

## Initial manual captures

The new `docs/screenshots/manual/` images come from
[Actions run 42532149572, attempt 1](https://github.com/iricigor/fingvibe/actions/runs/42532149572),
artifact **native-Full-capture-42532149572-attempt-1**.
The capture execution succeeded on a disposable Windows runner on 2026-11-08.

Application source: `6082b982af7ca5892072c9c09d6a8e9d8e8ff744`.
Validation harness source: `2ed22d5293c485aff171304bf561e90a7bbbfa48`.
These are different revisions and are not presented as one source.
There is no application-source difference between the capture's revision and
release **v1.1.107** (`0dbac6d9ee20dffba2015e4e4096b9482183e3dc`).

The executable was stamped as **v0.0.9 TEST**, not an official release.
The title, amber ribbon, About version, runner hostname, and test status messages
are left visible. Do not infer a release version from their displayed values.
The screen state follows baseline scan/cancellation/filter checks.

Every new image is **1280 x 800 pixels**, copied unchanged.
The safe context uses loopback `127.0.0.1`, invented MAC data, sample public IP
`203.0.113.10`, and synthetic people/import information.
No real LAN was scanned or private inventory loaded for this manual.
No Cloudflare speed measurement was started.

| Manual image | Artifact image | Visible state |
| --- | --- | --- |
| `overview.png` | `fingvibe-overview.png` | Summary of retained sample results. |
| `network.png` | `fingvibe-network.png` | Sample network/provider identity. |
| `devices.png` | `fingvibe-ui-review.png` | One responding review device; expanded filters. |
| `devices-empty.png` | `fingvibe-devices-empty.png` | Search with no matching rows. |
| `device-details.png` | `fingvibe-device-details.png` | Address/identity and assignment/category cards. |
| `people.png` | `fingvibe-people.png` | Synthetic person entry. |
| `person-details.png` | `fingvibe-person-details.png` | Synthetic entry with no assigned devices. |
| `settings.png` | `fingvibe-settings.png` | Appearance and upper table options. |
| `import.png` | `fingvibe-fing-import.png` | Synthetic workbook and analysis, not final import success. |
| `sql.png` | `fingvibe-sql-editor.png` | Query ready to run, not a completed report. |
| `network-checks.png` | `fingvibe-troubleshooting.png` | Ready-state controls; review-mode probes disabled. |
| `speed-test.png` | `fingvibe-speed-test.png` | Gauges waiting for measurements. |
| `about.png` | `fingvibe-about.png` | Test-build identity and source links. |

All selected images were inspected for readable page content, safe sample data,
and the state described above. They remain committed after the artifact expires.

## Earlier diagram image

The complete troubleshooting diagram uses the existing
`docs/screenshots/network-troubleshooting.png`, a **1920 x 971** native capture
supplied by iricigor on 2026-11-01.
Its application version/source commit were not supplied and remain unknown.

Seven opaque regions redact network-specific values with the user's approval.
All other pixels are preserved. It is a ready state: no checks had run.
The diagram is illustrative, not discovered physical topology.

Detailed earlier-image provenance remains in the
[original screenshot record](https://github.com/iricigor/fingvibe/blob/main/docs/screenshots/README.md).

## Remaining visual coverage

The initial set shows the main pages and tool entry workflows.
It does not show every scroll position or interaction:

| Gap | Why it is not illustrated yet |
| --- | --- |
| Schedule controls and discovery popup | The available complete capture set does not include these state-specific views. |
| Lower identification editor, service results, and history summary | They are below the device-details screenshot's viewport; a separate scoped capture is needed. |
| Import conflict decisions and completed SQL rows | Available new images show initial analysis/ready states, not those later states. |
| Room editing and combined-column/schedule Settings controls | The selected images focus on representative upper content rather than every equivalent control. |
| Completed internet measurements | A live speed test consumes data and reports results; no such run was performed for documentation. |
| Activity grid and completed-observation table | These controls are disabled in the documented release and must not be illustrated as currently usable. |

Text instructions cover available behavior in these areas.
Do not fabricate result images to fill a gap.

## Reproduce or replace

Use disposable Windows CI and the repository's native capture tooling.
Request appropriate scenarios such as Devices, Overview, Network, DeviceDetails,
People, PersonDetails, Settings, FingImport, SqlEditor, Troubleshooting, SpeedTest,
and About. Use synthetic fixtures and keep measurements stopped.

Inspect the downloaded image, commit only the intended safe PNG, and update this
record and the page caption with the actual source revision/run/state.
Do not assume a newer screenshot automatically depicts a released feature.
