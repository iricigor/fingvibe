# Deco local inspector

Standalone Windows WPF/WebView2 inspector for
Deco devices with compatible local web firmware (originally tested on X50).
Its default target is `https://192.168.0.100/webpages/index.html#networkMap`. It is not integrated into
FingVibe and never imports clients or writes the inventory database.
Requires .NET 8 Desktop Runtime and Microsoft Edge WebView2 Runtime.

```powershell
dotnet run --project tools\DecoX50Inspector\DecoX50Inspector.csproj
```

## Router address and client-mode repair

Enter the device's dotted **Router IP** and click **Connect**, for example
`192.168.0.111`. Startup retains the original `.100` default in the input but
does not contact a router until **Connect**, so you can choose another starting
IP without first approving the default device's certificate. The selected address
applies to subsequent navigation, Forced refresh, repair and exported source
metadata. Invalid IPs are rejected visibly. Changing devices clears browser
profile data and the in-memory password before opening the new endpoint.
The previous completed snapshot remains available, labeled with its original URL.
Addresses are not remembered across launches.

Some client-mode Deco devices do not show the usual Basic page after sign-in.
Use **Go to client-list URL** to navigate directly to
`https://<selected-IP>/webpages/index.html#networkMap`. This repair keeps the
current device's authenticated session and does not clear cache. A visible,
non-loading connected-client grid, including **No Entries in this table.**,
is successful navigation; a populated Clients tile is not required.
Use **Capture connected clients** afterward to verify and save the contents.
An explicit empty row on this known grid/route can produce a verified empty
capture without Basic-page count/scope controls. Missing, loading, ambiguous or
unrecognized markup cannot. Populated lists still require the existing All Decos
scope and count checks; other firmware layouts are not assumed compatible.

## Sign-in and certificate trust

When Windows cannot validate the router certificate, the inspector displays its
subject, issuer, validity dates and SHA-256 fingerprint. Confirm only after
checking that it is your Deco certificate. Approval is restricted to that exact
certificate on HTTPS `<selected-IP>:443`; other hosts,
ports and HTTP downgrade are blocked. A changed certificate requires a new
decision. The approved SHA-256 fingerprint is saved locally in
`%LOCALAPPDATA%\FingVibe-DecoX50Inspector\approved-certificate.sha256` and loaded
before connection on future launches, so the same certificate needs no popup
after restarting. Only that fingerprint is persisted, not a raw certificate,
password or browser session. No Windows certificate store or global validation
setting is changed. Remove that specific file while the inspector is closed
to forget the approval.
The original `.100` endpoint keeps that existing file; other IPs use
`approved-certificate-<IP>.sha256` in the same directory. Approvals are not
automatically shared across devices, even if they present the same certificate.
Unreadable/corrupt saved approval blocks connection with a visible repair message;
a failed save blocks the certificate request and reports the failure rather
than claiming the approval was remembered.
A declined certificate stays blocked until **Connect**, **Forced refresh** or restart.

Sign in using the embedded router page or the separate local-password panel.
Never put passwords in chat. The known local form uses the router's own keyup
Enter handler and encryption code; cloud login, account setup and password-reset
controls are not automated. **Remember only until this inspector closes** keeps
an ordinary password string in process memory, not guaranteed secure erasure.
**Password...** can remember a password while already signed in without sending
it. **Forget password** clears memory without logging out the router.
The inspector does not persist passwords or upload data.

## Capture and compare

**Capture connected clients** signs in if necessary, keeps the authenticated
page and clicks its **Clients** control to read **Connected Clients (All Deco's)**.
It does not reopen the supplied URL on each capture. If the grid does not appear
within three seconds, it clicks **Internet**, then **Clients**, allowing up to
15 seconds for that fallback to open the grid. **Connect** and explicit **Forced
refresh** open the configured router URL. If Clients is absent but the repaired
grid is already visible, capture reads that grid directly.
This firmware renders all rows, including those below the viewport, in
the grid's stable `connected-clients-grid` CSS class; extraction does not depend
on screenshot scrolling. The framework prefixes widget IDs with view namescopes,
so navigation, grid and the known local-login card use stable classes rather
than assuming the unrendered template's IDs.
The All Decos selection, unique grid, rendered client count, MAC/IP fields and
explicit connection labels are checked. Hidden responsive duplicates are ignored.
The scope label is read from Deco's auto-width combobox span (or an input on
other layouts), not the stale checkbox copies used to populate its global popup.
Two complete, consistent observations of names/MACs/IPs/connections are required;
changing live transfer rates are neither read nor used for stability.

Captured connection values include Wired and Wireless (2.4G/5G); recognized
6G/MLO, Zigbee and Bluetooth labels are preserved if supplied by firmware.
A router blank or `-` IP is retained as unavailable, not guessed. A `-`
connection is Unknown. Other malformed IP values fail with the client MAC
and offending field text so an unsupported format can be investigated precisely.
Names remain separate from FingVibe names. Different MACs sharing an IP remain
separate identities, and absence from this client view does not prove offline.
The capture time is an observation time, not an atomic router snapshot.

Each capture gets five attempts total, with two-second backoff for transient
timeouts/session expiry. Each retry repeats Clients navigation, reauthenticating
with an in-process remembered password when available. Sign-in waits at most
two minutes for user interaction; a submitted login has a 15-second limit.
Content/navigation waits are limited to 15 seconds and script/cache calls to
five seconds. Wrong passwords, locked or unsupported forms, malformed or
ambiguous content and unsupported pagination stop rather than retrying.
Missing/lazy-loaded rows never pass the count check; future paginated firmware
is explicitly unsupported instead of silently truncated.
The safety limit is 10,000 clients.

**Click delay (ms)** sets the minimum gap between navigation/login submissions,
default 500, range 0-10000. It is fixed during a capture. Readiness checks remain
mandatory. **Cancel** interrupts capture/login/backoff waits. **Forced refresh**
cancels pending capture work, clears browser cache and reopens the router,
retaining the previous completed snapshot, remembered password and approved
certificate. Errors/cancellation never replace a completed capture with a
partial one. Already-dispatched browser requests cannot be undone.

Expand **FingVibe database (read-only)**, load
`%LOCALAPPDATA%\FingVibe\device-inventory.sqlite`, and select the saved network/
subnet matching this Deco. A single scope is preselected; multiple scopes
require explicit selection. **Compare** uses the EX220 inspector's existing
strictly read-only SQLite comparer, preserving custom/displayed names, latest
network-scoped local IPs and eligible virtual-device associations.
Same/Different/Not in DB/Cannot compare remain distinct; database failures are
visible rather than reported as missing devices. Captures compare automatically
when a database scope is selected. **Hide Same in DB** affects only the grid.

## JSON export

**Export full snapshot (JSON)...** explicitly saves the entire last successful
capture, regardless of the grid filter or comparison state. It is disabled
before the first successful capture. Verified empty captures can be exported.
The JSON uses camelCase and contains:

- `schemaVersion` (1), `router`, `sourceUrl`, `capturedAtUtc` (UTC), `clientCount`.
- `clients`: `name`, normalized colon-separated `mac`, `ip`, and `connection`.

No database baseline, credentials, cookies, tokens, raw HTML, live rates or
other page content are exported. Export writes a temporary sibling file before
replacing the chosen destination; cancellation/failure before replacement keeps
the previous file. Write/cleanup failures are reported. Exports contain personal
device names and LAN identities: keep them local or redact before sharing.

## Browser isolation and limits

Browser password saving/autofill, downloads, popups and permissions are disabled.
Navigation and network requests are limited to this Deco HTTPS endpoint;
inline `data:` resources are allowed. The embedded configuration controls remain
live: do not click Save/Apply, reboot, reset, or other configuration commands.
Inspector automation clicks only the known local login and Clients navigation.
The explicit repair action also opens the selected device's networkMap URL.

A unique temporary `FingVibe-DecoX50-*` profile holds router session state.
Normal close shuts down the browser and removes that specific profile; cleanup
failures show its path. A crash/forced termination can leave cookies there.
Remove only that specific folder after its browser processes exit.
The inspector's saved exact-certificate pin is independent of these temporary
profiles. It is not shared with other applications or normal browser profiles.

## Focused checks and evidence

```powershell
dotnet build tools\DecoX50Inspector\DecoX50Inspector.csproj -c Release
dotnet test tests\FingVibe.Core.Tests\FingVibe.Core.Tests.csproj --filter "FullyQualifiedName~DecoInspector|FullyQualifiedName~Ex220"
node --test tools\DecoX50Inspector\ExtractDecoClients.Tests.cjs
```

The router's unauthenticated, locally served module markup/controller was
inspected to establish the grid class, responsive name/MAC/IP classes, connection
column, All Decos default, Clients control and local-login keyup handler.
No raw API decryption or authenticated request replay is used.
Live accessibility inspection successfully activated the Clients tile and
exposed 19 distinct MAC identities across the rendered page. This uncovered the
framework's namescoped widget IDs and parenthesized `(All Deco's)` selection
label, now covered by regression checks. The user subsequently confirmed normal
sign-in, capture and JSON export on the actual Deco. The supplied export contains
20 unique normalized MAC identities, four wired and 16 wireless clients, a UTC
capture time and one correctly retained unavailable IP. The earlier 19-client
view was a different observation, not a fixed expected count.

The previously approved certificate fingerprint was persisted using the
inspector's store. A fresh native launch then reached the actual router's local
sign-in page without a certificate popup, and the saved approval remained after
graceful close and temporary-browser-profile cleanup. Focused checks also cover
recreated stores, different certificates/origins, malformed/unreadable approval,
failed replacement preserving the previous pin and temporary-file cleanup.

Forced session-expiry/retry recovery, future firmware variants and live database
comparison have not been separately demonstrated. Focused fixtures cover
capture stability/cancellation, terminal errors, read-only comparison, navigation
fallback, export and exact-certificate trust; they are not substitutes for those
remaining real-router scenarios.
Configurable-IP/client-mode handling is covered by focused fixtures and a local
build, not a new live-device demonstration. The supplied client-mode screenshot
shows the empty-table message but does not establish its DOM structure; layouts
outside the recognized connected-client grid will report failure for investigation.
