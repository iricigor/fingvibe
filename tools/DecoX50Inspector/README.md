# Deco X50 local inspector

Standalone Windows WPF/WebView2 inspector for
`https://192.168.0.100/webpages/index.html#networkMap`. It is not integrated into
FingVibe and never imports clients or writes the inventory database.
Requires .NET 8 Desktop Runtime and Microsoft Edge WebView2 Runtime.

```powershell
dotnet run --project tools\DecoX50Inspector\DecoX50Inspector.csproj
```

## Sign-in and certificate trust

When Windows cannot validate the router certificate, the inspector displays its
subject, issuer, validity dates and SHA-256 fingerprint. Confirm only after
checking that it is your Deco certificate. Approval is restricted to that exact
certificate on HTTPS `192.168.0.100:443` in this inspector session; other hosts,
ports and HTTP downgrade are blocked. A changed certificate requires a new
decision. No Windows certificate store or global validation setting is changed.
A declined certificate stays blocked until **Forced refresh** or restart.

Sign in using the embedded router page or the separate local-password panel.
Never put passwords in chat. The known local form uses the router's own keyup
Enter handler and encryption code; cloud login, account setup and password-reset
controls are not automated. **Remember only until this inspector closes** keeps
an ordinary password string in process memory, not guaranteed secure erasure.
**Password...** can remember a password while already signed in without sending
it. **Forget password** clears memory without logging out the router.
The inspector does not persist passwords or upload data.

## Capture and compare

**Capture connected clients** signs in if necessary, reloads Network Map,
activates its Clients control and reads **Connected Clients (All Deco's)**.
This firmware renders all rows, including those below the viewport, in
`connected-clients-grid`; extraction does not depend on screenshot scrolling.
The All Decos selection, unique grid, rendered client count, MAC/IP fields and
explicit connection labels are checked. Hidden responsive duplicates are ignored.
Two complete, consistent observations of names/MACs/IPs/connections are required;
changing live transfer rates are neither read nor used for stability.

Captured connection values include Wired and Wireless (2.4G/5G); recognized
6G/MLO, Zigbee and Bluetooth labels are preserved if supplied by firmware.
A router `-` IP or connection is shown as unavailable/Unknown, not guessed.
Names remain separate from FingVibe names. Different MACs sharing an IP remain
separate identities, and absence from this client view does not prove offline.
The capture time is an observation time, not an atomic router snapshot.

Each capture gets five attempts total, with two-second backoff for transient
timeouts/session expiry. Each retry reloads the client page, reauthenticating
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

A unique temporary `FingVibe-DecoX50-*` profile holds router session state.
Normal close shuts down the browser and removes that specific profile; cleanup
failures show its path. A crash/forced termination can leave cookies there.
Remove only that specific folder after its browser processes exit.
Per-certificate decisions are not shared with other browser profiles.

## Focused checks and evidence

```powershell
dotnet build tools\DecoX50Inspector\DecoX50Inspector.csproj -c Release
dotnet test tests\FingVibe.Core.Tests\FingVibe.Core.Tests.csproj --filter "FullyQualifiedName~DecoInspector|FullyQualifiedName~Ex220"
node --test tools\DecoX50Inspector\ExtractDecoClients.Tests.cjs
```

The router's unauthenticated, locally served module markup/controller was
inspected to establish the grid ID, responsive name/MAC/IP classes, connection
column, All Decos default, Clients control and local-login keyup handler.
No raw API decryption or authenticated request replay is used.
Fixture checks do not establish successful authentication or completeness on
the live router. User-assisted real-device sign-in, capture/count agreement,
certificate decision and export verification remain required.
