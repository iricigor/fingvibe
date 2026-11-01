# Documentation screenshots

## Devices screenshot

`devices.png` is a complete, unedited native Devices-page capture, not a mockup.
It was captured on Windows in UI-review mode from release **v1.0.44**, built
from commit `5a62a2ee4ad31f08d2ceb76deaea65a49bf3d2ff`, the application-code
baseline for the original Devices documentation capture. The published release was
used because the capture machine has no .NET SDK; no application code changed.

The image is **1550x780 physical pixels**. It shows eight deterministic sample
devices loaded from [devices-fixture.json](devices-fixture.json), using the
documentation-only IPv4 range `192.0.2.0/24` and invented locally administered
MACs. Names, vendors, OS/types, ports, and response times are illustrative,
not detection claims or real inventory.

## Reproduce

1. Extract the matching Windows x64 release, keeping all files together.
2. Copy the fixture to a temporary file and update `completedAt` to the capture
   time. Set `FINGVIBE_UI_REVIEW=1` and `FINGVIBE_UI_REVIEW_SNAPSHOT` to that
   temporary file's absolute path before launching `FingVibe.App.exe`.
3. Open Devices. Verify **8 devices** and the sample names. Use a wide window
   so the device and service columns remain visible.
4. Capture the complete foreground window with
   `.github\scripts\UiReviewScreenshot.ps1` from the repository root.
   `Save-UiReviewWindowScreenshot` validates the window bounds and rejects
   clipped, unfocused, or blank captures.
5. Close that app instance, restore the two environment variables, and delete
   the temporary fixture. Do not run a real scan or edit saved user data.

UI-review mode supplies a loopback network and sample public identity instead
of reading a real LAN identity. The different-target warning is genuine:
the sample snapshot is `192.0.2.0/24`, while the safe review scan target is
`127.0.0.1/32`. It is intentionally not edited out of the screenshot.

## Tool screenshots

The tool images are unedited native Windows captures from
[GitHub Actions run 41331134450](https://github.com/iricigor/fingvibe/actions/runs/41331134450),
attempt 1, artifact `fingvibe-ui-review-pr-156-attempt-1`, version **v0.0.156**,
built from commit `638e4d230cd003c22569960e8117975b49a2ae13`. That revision
contains the delivered tool icons and build timestamp UI. This documentation
task makes no application changes. The About page and diagonal ribbon identify
the captured test build; they do not claim it is an official release.

| Committed image | Artifact source | State |
| --- | --- | --- |
| [fing-import.png](fing-import.png) | `fing-import/fing-import-ready.png` | Reviewed synthetic changes and final import controls. |
| [speed-test.png](speed-test.png) | `fingvibe-speed-test.png` | Ready, before starting a Cloudflare test. |
| [network-troubleshooting.png](network-troubleshooting.png) | `fingvibe-troubleshooting.png` | Loopback context, no probes or saved WAN data. |
| [lan-diagram.png](lan-diagram.png) | `troubleshooting/troubleshooting-diagram.png` | Untested LAN portion, scrolled into view by native regression checks. |
| [about.png](about.png) | `build-identity/Test-about.png` | Version and build identity from the native About regression check. |

Four images are **1024x720 physical pixels**; `about.png` is **640x480**.
The window is captured in full,
but scrollable page content can extend beyond its viewport. In particular,
the LAN diagram's public-provider branch is to the right, the speed gauges
continue below, and import file selection/analysis are above. Captions describe the visible state;
these are not stitched screenshots, mockups, or live network measurements.

UI-review mode uses safe loopback/sample identity and synthetic import data.
It does not expose private LAN addresses or load/save router WAN preferences;
diagnostic probes are disabled. The speed-test screenshot is captured without
starting a test, so no Cloudflare measurements or result reporting occur.

**Capture-run limitation:** The dedicated build-identity/About, troubleshooting,
and import regression checks passed. The broader capture sequence failed twice
because its driver could not see the About card on the Tools landing page.
The About image above comes from the successful dedicated native check, not
that failed sequence. The five selected images were individually inspected;
this is not a claim that the full UI workflow passed.

### Reproduce tool captures without desktop automation locally

Use the existing **Pull request build** workflow's manual dispatch on the
matching source revision with `additional_scenarios` set to
`SpeedTest,Troubleshooting,About,FingImport`. The workflow builds the Windows
application, runs on the GitHub-hosted Windows desktop with
`FINGVIBE_UI_REVIEW=1`, and uploads the `fingvibe-ui-review-...` artifact.
Its native troubleshooting checks capture the LAN diagram after scrolling
to the relevant card; the import and build-identity checks supply the other
two native regression captures. Download the artifact before it expires and copy only the
listed PNGs, unchanged, into this directory.

Inspect every image for the expected page, legibility, safe sample identity,
and absence of private data. When replacing a capture, update its source run,
commit, dimensions, and caption if the visible state changes. The committed
images remain available after the Actions artifact expires.
