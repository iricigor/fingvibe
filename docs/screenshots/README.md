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

### Troubleshooting and complete network diagram

[network-troubleshooting.png](network-troubleshooting.png) is the **1920x971**
native screenshot supplied by iricigor on **2026-11-01**, showing Connection
and checks together with the complete network diagram, including both public
providers. It has no top-right test-build ribbon. The capture's application
version and source commit were not supplied; they are not inferred from the
other images.

This is an actual adapter context, not UI-review sample data. With the user's
explicit approval, seven opaque regions redact network-specific addresses:
the adapter/subnet picker, selected adapter/subnet summary, gateway summary,
WAN input, and the PC LAN, router LAN, and router WAN diagram labels. The
loopback address and public Cloudflare/Google probe targets remain visible.
All pixels outside those regions are preserved; no results or topology were
edited or fabricated. The screenshot says **Ready. No checks have run.**

To replace this image, supply a wide native capture with the connection card
and complete diagram visible together. Dismiss the build ribbon if present.
Use review data or obtain approval to redact all network-specific addresses
before publication, including repeated values in the diagram. Do not upload
an unredacted local-network capture to the repository.

### Other tool images

The other tool images come from native Windows captures in
[GitHub Actions run 41331134450](https://github.com/iricigor/fingvibe/actions/runs/41331134450),
attempt 1, artifact `fingvibe-ui-review-pr-156-attempt-1`, version **v0.0.156**,
built from commit `638e4d230cd003c22569960e8117975b49a2ae13`. That revision
contains the delivered tool icons and build timestamp UI. This documentation
task makes no application changes. The About page identifies the captured test
build; it does not claim it is an official release. Speed test and import are
cropped to their tool content to remove the top-right test-build ribbon, not
retouched to simulate a release.

| Committed image | Artifact source | Dimensions and edits |
| --- | --- | --- |
| [fing-import.png](fing-import.png) | `fing-import/fing-import-ready.png` | 680x422 crop at x=312, y=262; synthetic review cards and import controls. |
| [speed-test.png](speed-test.png) | `fingvibe-speed-test.png` | 680x499 crop at x=312, y=213; ready state before a Cloudflare test. |
| [about.png](about.png) | `build-identity/Test-about.png` | 640x480, unchanged; native About regression capture with no visible ribbon. |

The speed/import source images are 1024x720 physical pixels. Their retained
pixels are unchanged; only the crop removes window chrome, navigation, and
the ribbon. Scrollable content can extend beyond the viewport: speed gauges
continue below, and import file selection/analysis are above. Captions describe
the visible state. None of the images are stitched screenshots or mockups.

UI-review mode uses safe loopback/sample identity and synthetic import data.
It does not expose private LAN addresses or load/save router WAN preferences;
diagnostic probes are disabled. The speed-test screenshot is captured without
starting a test, so no Cloudflare measurements or result reporting occur.

**Capture-run limitation:** The dedicated build-identity/About, troubleshooting,
and import regression checks passed. The broader capture sequence failed twice
because its driver could not see the About card on the Tools landing page.
The About image above comes from the successful dedicated native check, not
that failed sequence. The three selected Actions images were individually inspected;
this is not a claim that the full UI workflow passed.

### Reproduce tool captures without desktop automation locally

Use the existing **Pull request build** workflow's manual dispatch on the
matching source revision with `additional_scenarios` set to
`SpeedTest,About,FingImport`. The workflow builds the Windows
application, runs on the GitHub-hosted Windows desktop with
`FINGVIBE_UI_REVIEW=1`, and uploads the `fingvibe-ui-review-...` artifact.
The import and build-identity checks supply their native regression captures.
Download the artifact before it expires, apply the listed speed/import crops,
and retain the About image unchanged.

Inspect every image for the expected page, legibility, safe sample identity,
and absence of private data. When replacing a capture, update its source run,
commit, dimensions, and caption if the visible state changes. The committed
images remain available after the Actions artifact expires.
