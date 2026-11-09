# Common problems

Start with the visible error or status message.
Avoid changing several settings at once; one change at a time makes the result
easier to understand.

## Fewer devices than expected

1. Check the selected Wi-Fi/Ethernet adapter and subnet.
2. Wait for the full scan, including background checks, to finish.
3. Clear Devices filters.
4. Check whether missing devices are asleep or on another network.
5. Check guest-network/client-isolation settings if you manage the router.
6. Run another scan and compare device identities, not only totals.

Active devices can ignore ping and ARP. A different application's device count
is not proof that every missing device should answer FingVibe.
Saved and imported devices also affect inventory totals.

Only change firewall or router settings when you understand the effect and have
permission. Do not disable the firewall as a general fix.

## No usable network or the wrong network

Check Windows connection status. VPN, Hyper-V, and other virtual adapters can
appear alongside physical connections. Select the intended directly connected
IPv4 network.

In troubleshooting, use **Refresh adapters** after changes.
A VPN can still affect internet routes even when the LAN picker is correct.
Large scan ranges may exceed the 65,534-address limit.
IPv6-only device discovery is outside this scanner's current IPv4 scope.

## Empty Devices list

Read **Showing N of M devices**.
If the inventory has devices but zero are shown, use **Clear filters**.
Hidden secondary filters still apply.

A remembered **Status: Online** filter may show no rows after restart because
saved observations are historical. Run a scan or include Unknown.
Do not confuse a filter result with loss of saved data.

## Windows asks about firewall access

Windows rules can depend on the executable's full path and network profile.
Moving a portable build can change which rule applies.
An installed fixed-path build and a changing PR-build folder are not equivalent.

Read the prompt and allow access only if you trust the app and understand the
requested network scope. Managed PCs may require an administrator.
Missing devices or a discovery timeout alone does not prove firewall blocking.
FingVibe has no delivered one-click firewall setup feature.

## Saved data cannot be loaded

1. Close all FingVibe instances.
2. Preserve the [whole data folder](data.md#make-a-backup).
3. Record the exact error and app version.
4. Check disk space and folder permissions.
5. Restore a known good backup only after preserving the current copy.
6. Report the problem if the cause remains unclear.

Some editors are disabled after a failed load to protect unreadable data.
Do not overwrite the file with an empty inventory or substitute stale legacy JSON.

If a save reports a conflict from another app instance, close duplicate instances
and reload the current data before retrying. A save error is not success.

## Import skips data

Check that the workbook is `.xlsx`, has the expected sheet/MAC column, and
meets the size limits. All duplicate-MAC rows are skipped.
Missing or ambiguous person/room names skip those assignment fields.

Create or correct the managed entries, then **Analyze again**.
The original IP and Fing state are not Online evidence.
See [Import from Fing](import.md).

## The speed test does not start

Read the WebView2 or connection error.
Check that Microsoft Edge WebView2 Runtime is available and working.
Use Microsoft's official WebView2 download/repair route rather than an
untrusted runtime bundle.

Check access to `speed.cloudflare.com`, and finish other network measurements.
VPNs, proxies, security policy, or connectivity can affect this optional tool.
Retrying a test may consume substantial internet data; review the disclosure.
LAN scanning does not require a successful speed test.

## DNS or traceroute has missing responses

An unanswered router or hop may block diagnostic responses while passing normal
traffic. Windows DNS can answer from cache. A VPN may change the route.
Compare independent checks instead of treating one missing response as proof.

See [Network troubleshooting](network-checks.md).

## A name, OS, or device type is wrong

Inspect **How this device was identified**.
Unknown and likely classifications are intentional when evidence is limited.
Save a manual correction in [Device details](device-details.md).
A generic vendor or open service alone is not reliable OS proof.

## A backdrop or table option looks different

Windows transparency/high-contrast settings can override decorative appearance.
Unsupported materials fall back to Solid.
Check **Compact rows**, visible/combined columns, and Windows text size.
See [Settings](settings.md).

If these steps do not explain the problem, use the
[support checklist](support.md#report-a-problem).
