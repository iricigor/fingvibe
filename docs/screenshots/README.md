# README screenshot

`devices.png` is a complete, unedited native Devices-page capture, not a mockup.
It was captured on Windows in UI-review mode from release **v1.0.44**, built
from commit `5a62a2ee4ad31f08d2ceb76deaea65a49bf3d2ff`, which is this
documentation change's application-code baseline. The published release was
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
