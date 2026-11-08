# Scheduled scans and discoveries

Scheduled scans are optional. They are **off by default**.
They use the network selected in the shared **Network:** picker.

## Enable a schedule

1. Select the intended network.
2. Open **Settings**.
3. Find **Scheduled scans**.
4. Turn scheduling on.
5. Choose **15 minutes**, **30 minutes**, **1 hour**, **2 hours**, or **4 hours**.
6. Read the status sentence for the next approximate scan time.

The default interval is one hour.
The first scheduled scan waits one full interval after enabling or loading.
Changing the interval restarts that wait; it does not immediately run a scan.

## Keep the app open

Scheduling works while FingVibe is open, including when minimized.
There is no separate Windows service, tray worker, or closed-app scheduler.
Closing the app stops scheduling.

Windows sleep pauses scheduling. After resume, the app waits a full interval.
It does not run missed scans to fill the gap.
The shared header explains that scheduling operates while the app is open.

## Cancel or retry

Use **Cancel scan** to stop an active scheduled scan.
Normal user cancellation waits a full interval before the next attempt.
Turning scheduling off or closing the app stops scheduled work.
Already committed checkpoint observations remain saved as incomplete.

LAN scans cannot overlap speed tests, troubleshooting, or device-service probes.
If the app is busy, the network is unavailable, or a scan/save fails, Settings
shows the reason and retry time. Retry waits grow up to the chosen interval.

These scans have the same evidence limits as manual scans.
No response between samples does not establish continuous absence.

## New-device discoveries

After a successfully completed and saved scan, FingVibe can show an in-app
popup for newly observed devices. It links to their details.

The first successful scan of a previously unknown network establishes a baseline
and is quiet. Later first local discoveries can alert, including devices
previously imported as Fing Only. Returning known devices do not repeatedly alert.

Discoveries made while minimized are combined and shown when you restore
FingVibe. There is currently **no Windows notification or notification archive**.
Cancelled, failed, or restored scans do not create discovery alerts.

If Windows network identity is unavailable, FingVibe explains why discoveries
cannot be scoped reliably. A save error also prevents the popup.

The current screenshot set does not show the schedule card or discovery popup.
They require state-specific native captures; see [Visual coverage](screenshots.md#remaining-visual-coverage).
