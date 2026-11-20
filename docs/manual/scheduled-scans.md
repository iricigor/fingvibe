# Background activity and discoveries

Scheduled scans are optional. They are **off by default**.
They use the network selected in the shared **Network:** picker.
The independent **Monitor network health** option is also off by default.

## Enable a schedule

1. Select the intended network.
2. Open **Settings**.
3. Expand **Background activity**.
4. Turn scheduling on.
5. Choose **15 minutes**, **30 minutes**, **1 hour**, **2 hours**, or **4 hours**.
6. Read the status sentence for the next approximate scan time.

The default interval is one hour.
The first scheduled scan waits one full interval after enabling or loading.
Changing the interval restarts that wait; it does not immediately run a scan.

## Monitor network health in the background

Turn **Monitor network health** on in the same Background activity section
when you want raw connectivity observations while FingVibe is open. Enabling
monitoring does not enable scheduled LAN scans, and enabling scheduled scans
does not enable monitoring.

The first monitoring cycle waits 60 seconds. Every subsequent cycle is due
on the same minute cadence, or every 30 seconds while FingVibe verifies or
tracks a suspected problem. Each cycle sends five ICMP requests to the selected
network's gateway, `1.1.1.1`, and `8.8.8.8`, with starts for each target spaced
one second apart and the normal 1.5-second probe timeout. It then resolves
`example.com` through Windows DNS (including its cache), Cloudflare DNS, and
Google DNS. The resulting raw state contract keeps per-target timings,
responses, failures, cancellation detail, and DNS source labels. FingVibe judges
completed checks with fixed rules; the header dot, **Network health** and the
Network page show the resulting verdict and the latest raw results; see
[Network health](network-checks.md#monitoring-state-and-health-verdicts).

Manual LAN scans, speed tests, network diagnostics, and device-service scans
take priority. They cancel an active monitoring cycle and start only after it
has stopped, so measurements do not overlap. A conflict or cancellation is
reported as skipped or cancelled, not as a connectivity failure.

Windows sleep pauses both scheduled scans and monitoring. Disabling monitoring,
changing the selected network, and closing FingVibe cancel an in-flight cycle
and wait for it to stop. A re-enabled monitor or refreshed network starts with
a new full 60-second wait; stale observations from the previous context are
rejected.

## Keep the app open

Background activity works while FingVibe is open, including when minimized.
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

LAN scans cannot overlap monitoring, speed tests, network diagnostics, or device-service probes.
If the app is busy, the network is unavailable, or a scan/save fails, Settings
shows the reason and retry time. Retry waits grow up to the chosen interval.

These scans have the same evidence limits as manual scans.
No response between samples does not establish continuous absence.

## New-device discoveries

After a successfully completed and saved scan, FingVibe can show an in-app
popup for newly observed devices. Its count-first header and name-first rows
show each device's icon, MAC and IP address. Select a row to open its details;
devices absent from the displayed results remain listed as **Details unavailable**.
Large lists scroll without moving the header or **Saved locally / Dismiss** footer.

The first successful scan of a previously unknown network establishes a baseline
and is quiet. Later first local discoveries can alert, including devices
previously imported as Fing Only. Returning known devices do not repeatedly alert.

Discoveries made while minimized are combined and shown when you restore
FingVibe. Every qualifying manual or scheduled scan also requests one grouped
native Windows notification, even when FingVibe is visible. The toast previews
device names and an additional-device count. Its amber shield/question-mark
image means "unfamiliar: review", not a confirmed threat.
Select the notification or **Review device(s)** to restore FingVibe and open
that scan's discovery list, without rescanning or resending the notification.
Windows settings and Do Not Disturb control banner delivery; the in-app popup
does not depend on Windows displaying a banner. Integration failures appear in
the shared scan status. There is no notification archive or closed-app scanning.
Cancelled, failed, or restored scans do not create discovery alerts.

Notification activation lists expire after 24 hours. Short-lived local payloads
allow a retained toast to reopen its list after FingVibe restarts; expired files
are removed on the next qualifying notification request. They do not replace
the inventory or scan history.

If Windows network identity is unavailable, FingVibe explains why discoveries
cannot be scoped reliably. A save error also prevents the popup.

The current screenshot set does not show the schedule card or discovery popup.
They require state-specific native captures; see [Visual coverage](screenshots.md#remaining-visual-coverage).
