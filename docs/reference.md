# FingVibe reference

[Back to the README](../README.md) · [Contributing](../CONTRIBUTING.md)

Detailed usage, limitations, persistence, build identity, and contributor checks.
For the optional internet speed test, see [Cloudflare speed test](speed-test.md).
The desktop interface is native WinUI 3; WebView2 is restricted to the local
Cloudflare speed-test host. Tools uses matching 48-DIP Segoe Fluent icons beside
the names inside its existing landing buttons and beside individual page titles:
a speedometer for Speed test, a repair wrench for Network troubleshooting, an
information symbol for About FingVibe, and an import arrow for Import from Fing.
The icons follow the theme's primary text color, including Windows high contrast;
titles wrap at narrow widths. Icons are decorative, so button names and keyboard
navigation remain unchanged. Each individual tool places its secondary
**← Tools** action at the right of the title row, vertically centered with the
heading. **Run checks** and **Start test** use the same accent-button styling;
**Import all** retains its existing emphasis. Supporting actions stay neutral.

- [Run locally and scan behavior](#run-locally)
- [Device identification](#device-identification)
- [People and rooms](#people-and-rooms)
- [Inventory and Fing import](#inventory-and-fing-import)
- [Read-only SQL editor](sql-reporting.md)
- [Tests](#test)
- [Download builds](#download-builds)
- [Pull request review gates](#pull-request-review-gates)

## Run locally

Drag the right edge of the left navigation to resize it, up to 320 DIPs.
The default expanded width is 216 DIPs. Below 160 DIPs it snaps to the native
icon-only rail; drag the edge wider to restore labels. The menu toggle reopens
the last expanded width. The brand stays on one line, including at the minimum
expanded width. A subtle divider appears near the pointer, while dragging, or
with keyboard focus. Below the expansion threshold, the drag guide still follows
the pointer while navigation stays icon-only; releasing returns the guide to the
compact rail. The divider also supports Left/Right arrow keys
(8-DIP steps, or 32 DIPs with Shift); Right from the icon rail expands to
160 DIPs. Small windows retain native overlay
navigation; the divider is hidden when a minimal-mode pane is closed.
The last expanded width and whether you left navigation icon-only in a wide
window are saved to `%LOCALAPPDATA%\FingVibe\navigation.json` and restored at
the next launch. Automatic collapse in small windows is not saved. Missing,
unreadable, or invalid data uses the 216-DIP expanded default; out-of-range
widths are clamped to 160–320 DIPs. Save failures do not interrupt navigation.
UI-review mode does not read or write this file unless a review-specific
`FINGVIBE_UI_REVIEW_NAVIGATION` path is supplied.

Prerequisites:

- Windows 11
- .NET 8 SDK
- Visual Studio 2022 with the **Windows application development** workload, or the equivalent Windows SDK build tools

```powershell
dotnet restore FingVibe.sln
dotnet run --project src\FingVibe.App\FingVibe.App.csproj -p:Platform=x64
```

The scanner uses fresh ICMP echo replies and fresh ARP responses on the selected directly connected IPv4 LAN. Devices that answer neither can remain undetected; no fixed device count is guaranteed.

Manual and scheduled scans first ping every usable address with a 700 ms timeout and up to 256 concurrent probes, then attempt fresh ARP resolution once for each ping miss on the selected adapter. Windows `ResolveIpNetEntry2` flushes the entry and requests fresh resolution; cached, stale or permanent neighbor membership is never Online evidence. The ARP MAC is preserved for enrichment, without inventing an ICMP latency or TTL.

Background ARP uses up to 32 concurrent requests independently of the ICMP concurrency setting, refilling each available scan slot as its work finishes without a fixed launch delay. The same shared limit caps in-flight blocking native ARP calls at 32 process-wide, including across scans. Windows controls the native response timeout; the higher bound does not guarantee a fixed speedup or responder count. Cancellation drains in-flight calls before releasing the measurement lease and rejects their late responses. `WindowsFreshArpTests` verifies native resolution and adapter scoping against the disposable Windows CI runner's directly connected gateway; it is skipped locally to avoid probing the user's LAN.

After initial ICMP probing and enrichment, confirmed observations are durably checkpointed and become browsable before ARP starts. Background ARP checks the initial ping misses and checkpoints its recovered observations. Only addresses still unconfirmed are then pinged after a cancellable ten-second wait, and again after another ten-second wait following that retry phase. Confirmed addresses are never retried or downgraded. No remaining misses means no further work or wait; misses remaining through both rounds add at least twenty seconds plus ARP, probing, enrichment and persistence time. There are at most three ICMP attempts and one ARP fallback per address. A changed source IPv4 can be refreshed only on the same selected adapter and subnet; it does not change a device's MAC identity. A disconnected adapter, different subnet, or changed Windows network profile cannot silently substitute another LAN.

SQLite inventory and the latest logical checkpoint commit in one transaction with explicit Pending, Complete or Incomplete state. Checkpoints do not infer Offline, append completed history, establish a discovery baseline or emit discovery alerts until finalization. Each completed scan adds history and discovery alerts only once. The separate `latest-scan.json` cache is atomically replaced after the database commit; SQLite is authoritative on restart, including when a cache update failed. Save failures are visible and stop retries rather than claiming an unsaved checkpoint is durable. Normal close or cancellation drains checkpoint writes and retains the last committed observations as incomplete. Forced termination can lose observations since the last committed checkpoint. Restart treats saved observations as historical, not current Online evidence, and never resumes old retry timers.

On first use, vendor detection downloads the official IEEE MA-L, MA-M, and MA-S registries and caches them under the current user's local application data for 30 days.

Overview shows the selected interface as the network name, with subnet and available ISP information beneath it. Every page shares a compact **Network:** header. On Devices, **Scan LAN** sits beside the selector and is replaced in the same slot by **Cancel scan** while scanning; the disabled Scan LAN action is not shown. Cancellation remains available when navigating to another page during a scan. Narrow windows stack the controls without hiding them. Smaller displayed-scan freshness sits beneath the selector; operational text, target warnings, errors and progress stay together below it and wrap rather than being clipped. The freshness indicator describes the displayed scan, not continuous monitoring, and refreshes periodically. Displayed results retain their subnet and observation time; selecting another network explicitly identifies results from a different scan target. Progress appears only during a scan. The completed segment is 8 DIPs thick (including the native indicator's minimum height, not just its outer container), retaining the actual measured fraction. Its 10-DIP outer height also accommodates the native high-contrast outline without clipping the fill. A repeating color pulse travels only through the completed portion and stops on completion, cancellation or failure; Windows animation preferences and high contrast use static progress instead. Keyboard-initiated scans transfer focus to cancellation and back to the idle action. Before the first scan, Overview provides guidance rather than unknown counts.

Successful scans leave no persistent completion message in the shared header, including on Devices. The message area collapses when no other status remains. Displayed-scan freshness, Devices scan duration, and Overview's online-device count remain available; live progress, cancellation feedback, scan/save errors, and selected-target warnings remain visible globally.

Select the online-device or open-port summary card to open the corresponding Devices results. This clears stale search/summary filters; the visible **With open ports** toggle chip can be cleared to return to other devices and combines with text search and People/Rooms filters. Open ports describe observed services, not a security verdict. Overview does not count unused addresses as offline devices. Inventory retains local observations and per-device scan history, not a physical-availability timeline. The compact **About FingVibe** card opens **Tools > About FingVibe** directly. About is also available from the Tools landing page and contains version/build details and links to the repository and creator's website (opened in the external browser).

The running version is visible near the top of Overview and in the window title. Official release builds have no ribbon. PR artifacts show their PR number and an amber diagonal **TEST BUILD** ribbon; local builds show **DEV**, and manually dispatched non-PR CI builds show **TEST**. A smaller second line visibly shows the UTC build date/time (for example, **Built Nov 1, 12:20 UTC**). The tooltip and About show the full timestamp, including year and seconds, and commit information when recorded. Click or keyboard-activate the ribbon to acknowledge it until the app closes. The title and About details retain the build identity after acknowledgment. The ribbon floats above the page at the top-right client-area corner below the unchanged native title bar, extending continuously to the top and right edges. The header keeps a consistent right-hand clearance in every build, so showing or acknowledging the ribbon never shifts or resizes page content. The ribbon uses system colors in Windows high contrast.

Build identity is stamped into assembly metadata using `BuildKind` (`Release`, `PullRequest`, `Test`, or `Development`), `PullRequestNumber`, `BuildCommit`, `BuildUrl`, and `BuildTimestamp`. The CI and release workflows set these alongside the numeric `Version`; local builds default to `Development`, even when compiled with the Release configuration. `BuildTimestamp` defaults to the actual UTC build time in invariant ISO 8601 round-trip format (`yyyy-MM-ddTHH:mm:ss.fffffffZ`); CI and release workflows supply the same UTC format at second precision. To preserve an artifact's identity for repeatable builds, explicitly supply `-p:BuildTimestamp=2026-11-01T12:20:35Z` (or `/property:BuildTimestamp=...` with MSBuild). The override is preserved verbatim; parsing accepts zero to seven fractional-second digits before `Z`. Timestamps without an explicit UTC `Z` are invalid. Missing or malformed timestamps visibly show **Build time unavailable**, and malformed metadata emits a trace diagnostic; executable dates and launch time are never used. About shows PR and GitHub Actions run links when available. Unknown build kinds remain visibly non-release, and missing version metadata is displayed as unavailable rather than as an official version.

`tests\BuildIdentity.Ui.Tests.ps1 -AppPath <published-exe> -Version <numeric-version> -BuildKind <kind> -BuildTimestamp <stamped-UTC-time> -BuildCommit <commit>` checks the native title, Overview version, both visible ribbon lines, full tooltip/About details, ribbon acknowledgment (including mouse hit-testing, keyboard activation, and restoration after relaunch), narrow-window layout, and both About entry points. Omit the timestamp/commit arguments only when that metadata is absent. For PR builds, also supply `-PullRequestNumber <number>`. Run it on an interactive Windows desktop; the script launches and closes its own app instances and temporarily resizes them. Prefer GitHub Actions rather than interrupting a working desktop. The UI review workflow runs it against its stamped artifact, captures normal/narrow ribbon and About evidence, and temporarily enables high contrast on the disposable CI desktop, restoring the previous setting afterward.

`pwsh -File tests\BuildIdentity.Metadata.Tests.ps1` verifies current UTC stamping for every build kind and verbatim override preservation through MSBuild evaluation. Supply `-AppDirectory <published-directory> -BuildTimestamp <expected-time> -Version <numeric-version>` to also verify the actual compiled assembly metadata, including that the informational version shown by About/the title and the file version match the generated version; CI and release publishing perform this check before uploading artifacts.

Without a saved theme preference, FingVibe starts with Standard Light or Standard Dark to match the Windows app mode. **Settings > Appearance** separates **Mode** (Light or Dark), **Theme**, and **Window backdrop**. Light offers Standard, Warm, and Colorful; Dark offers Standard, True Black (OLED), and Colorful. Switching modes retains Standard or Colorful; Warm and True Black map to each other. Colorful uses pale blue/violet surfaces in Light and deep indigo surfaces in Dark without replacing semantic status colors. Solid shows the palette most faithfully; backdrop materials can soften its colors.

Appearance choices apply immediately and are saved to `%LOCALAPPDATA%\FingVibe\appearance.json` for the next launch; existing saved themes remain compatible and take precedence over Windows app mode. Ordinary Windows light/dark changes do not switch the theme while FingVibe is running. Unsupported backdrop materials fall back to a solid theme background without discarding your selection. Material rendering also follows Windows transparency settings; Windows high contrast takes precedence and uses system colors instead.

Settings places the appearance selectors side by side when space permits and stacks them in narrower windows. Appearance feedback is one sentence in normal operation; save failures, unavailable materials, and high contrast remain explicit. The **Devices page** card starts with matching **Compact rows** and **Cell hover previews** switches in one row, stacking them in narrow windows. Both use rounded-rectangle tracks and thumbs while retaining native Windows toggle, keyboard, focus, and theme behavior. Compact off selects Standard/relaxed rows; hover off uses ordinary tooltips. Visible and combined column choices share the same up-to-three-column layout and responsive thresholds. Name and IP address are always shown. Column visibility, combination choices, individual/combined widths and the Status filter are saved atomically in `%LOCALAPPDATA%\FingVibe\device-table.json`. **Reset columns** restores visibility, widths and combination defaults but preserves both switches and the Status selection. Load failures are shown in Settings and prevent overwriting the unreadable file; save failures keep the current layout and report that it could not be saved. UI-review mode uses table preferences only through an explicit isolated fixture path, never the user's saved file. The page remains scrollable for small windows and larger text.

Public IP and ISP details are retrieved from `ipwho.is`. This optional display depends on internet access and sends the connection's public IP to that provider as part of the HTTPS request. LAN discovery and scanning continue to work when the lookup is unavailable.

**Settings > Devices page > Cell hover previews** is enabled by default.
Hovering a Devices name, IP, MAC, vendor, person or room immediately emphasizes
its text with a brighter theme-aware foreground, without moving or enlarging it.
Pause for about half a second over a truncated or abbreviated value to reveal
its full text at normal size in a quiet, text-aligned surface. Fitting values
do not produce redundant previews; person/room short labels reveal full names.
Keyboard focus on a row exposes the same full values together;
accessible cell names and row help text also retain them. Explanatory icon,
status, response, OS, device-type and header tooltips remain unchanged. Turning
the option off immediately dismisses previews and restores ordinary value
tooltips. This preference shares `device-table.json` and its load/save error
handling (including the existing saved choice); **Reset columns** leaves the preview choice unchanged. Previews have
no animation and use system-aware colors, including Windows high contrast.

Configured builds also show an ISP logo on the Network page, loaded asynchronously from Logo.dev using the original ISP name. Logo.dev receives that name and the caller's public IP, but no LAN addresses, device inventory, or scan results. Missing configuration, unavailable images, and failed or slow requests leave a generic network icon; the ISP text and scanning remain available. Name matching selects the provider's top result and can identify the wrong brand. UI-review mode never requests logos. See [ISP logo configuration](isp-logos.md) for build setup and provider limitations.

The Overview network card shows A, B, or C for /8, /16, or /24 sizes; other sizes show their CIDR prefix. Network details explain all prefixes from /0 through /32, including class-size multiples/divisions and point-to-point or single-host networks. Counts below one million are exact; larger counts use M with two significant digits. Ordinary subnet counts exclude network/broadcast addresses, with a reserved suffix for /17 through /30; /31 assumes point-to-point use and /32 identifies one host. These capacity figures do not change the scanner's 65,534-address safety limit. Scope checks cover the whole subnet, distinguish private and special-purpose ranges (including APIPA/link-local), and flag mixed scopes. "Standard-size private" means a private /8, /16, or /24 subnet, not that other private prefix lengths are invalid.

Results dim complete network-prefix octets using the scanned subnet's CIDR; partially masked octets remain emphasized because they also identify hosts. Latency bars share one scale across the displayed scan's responding devices and keep that scale when filtering or sorting. Outside a scan, select a row with the pointer or keyboard to highlight it; sorting preserves the selection. Hover over service icons for port numbers and service names.

For IPv4 addresses belonging to the currently selected network, the host-containing
suffix is also approximately 10% larger without reducing the prefix font size:
/24-/32 emphasizes the last octet, /16-/23 the last two, /8-/15 the last three,
and /0-/7 all four. Addresses remain continuous and accessible as their original
full text; IPv6 and addresses outside the selected subnet retain their presentation.
This emphasis follows network selection, including retained inventory from other subnets.

In current device details, **Scan additional ports** checks a curated preset of
exactly 100 additional TCP ports, covering file sharing/storage, remote access,
mail, directory/authentication, databases/caches, messaging, web administration,
home automation/media, infrastructure, and printing. The automatic LAN scan
still checks only its original 10 TCP ports. The additional scan uses at most
16 simultaneous connections with 400 ms per-connection deadlines.

Device details places **Network overview** at the top left and **Assignments**
at the top right (roughly 60/40), with aligned bottom edges and the assignments
explanation anchored at the bottom. They stack at natural height in narrow windows. A full-width,
read-first **Device identification** card follows, then **Ports & services**.
Identification uses up to three field columns, and endpoints use up to two
columns, reducing to one as width and text scaling require. **Rename** in the
identity header reveals the existing name editor only when requested. **Ports & services**
has its own container for endpoints, scan controls, independent TCP/UDP feedback,
and UDP observations. Discovered hostname belongs to the network overview;
the collapsed **Imported Fing data** section sits inside **Device identification**,
immediately below **How this device was identified**. It contains only populated
original fields and explicitly labels historical imported IPs.

Hover beside a populated identity, network, identification, imported, or endpoint
value to reveal its copy icon immediately after the value (not at the field's
far edge), or Tab to the same button to reveal and activate it
with the keyboard. Copy writes only that value (endpoint addresses include their
port), never the label/source, and reports success or clipboard errors in a
non-layout-shifting flyout. Missing-value placeholders have no copy action.
Confirmed current TCP endpoints on 80/443 show the address itself as a native
browser hyperlink with an external-link arrow. Ports 8080/8443 retain a plain
address plus a nearby **Try HTTP/HTTPS** text link with the same arrow, since
port numbers do not verify the protocol. Copy is always a separate adjacent
action, and neither browser treatment uses a boxed button.
Links use the selected current address, preserve alternate ports, and launch the
default browser only on activation. Failures are shown in details. Historical-only
addresses, UDP observations and arbitrary non-web endpoints have no browser action;
no extra scanning or protocol verification is performed.

**Include UDP service checks** starts unchecked. Opting in sends only one
non-recursive DNS question to 53/UDP and one standard NTP client request to
123/UDP on the selected device, bound to the selected interface. Both checks
can run concurrently, with a 2-second deadline each, a 512-byte reply limit,
and no retries. Confirmed TCP results appear individually as each connection
finishes, without waiting for the remaining TCP probes or UDP; each protocol
has its own progress/status. The same button
becomes **Cancel additional scan** while running; leaving details also cancels.
Completed results remain available and are saved locally, including when the
other phase is canceled. Historical and imported-only addresses are not probed.

Only a matching valid reply confirms a responding UDP endpoint; valid DNS error
replies count as responses, not successful name resolution. UDP observations
are shown separately: **Responded**, **No response - inconclusive**, or **Error**
with details. Silence never establishes open/closed/filtered and does not add
an endpoint to the open-port filter or summary. Malformed replies and
operational failures are errors. Matching valid NTP kiss-of-death or
unsynchronized replies confirm that the service responded, but their details
explicitly warn that no usable time was supplied; no retry is sent.
These small read-only requests can still trigger device logs or security alerts.

Endpoint labels include protocol, for example **1883/TCP - MQTT** or
**123/UDP - NTP**, so TCP and UDP sharing a port number remain distinct.
Monochrome service-family icons are shared by the list and details with
descriptive tooltips and accessible names. Port names/icons describe common
or likely uses, not verified products; MQTT never implies RabbitMQ. UDP
observations are not used as TCP banner or device-classification evidence.
Existing saved entries without a protocol retain their TCP meaning.

`tests\AdditionalServices.Ui.Tests.ps1 -AppPath <published-exe>
-ScreenshotDirectory <output-directory>` exercises the default/opt-in controls,
independent progress, TCP-before-UDP completion, confirmed/inconclusive/error
states, cancellation, saved protocol identity, and service icons in all six
app themes. It uses synthetic loopback-only TCP/DNS/NTP responders and is wired
into GitHub Actions UI capture. Run it only on a disposable interactive desktop,
not a working user's desktop; it requires free loopback ports 1883/TCP, 53/UDP,
and 123/UDP and fails explicitly when they are unavailable. On disposable
GitHub Actions runners only, it temporarily stops Windows Time if running to
release 123/UDP and restores the service afterward. The application itself
needs no new administrator rights.

Devices shows the persistent inventory, including previously observed and imported-only devices. Unused addresses never become device records. The status filter distinguishes Online, Offline, Unknown, and Fing Only; retained observations without current scan evidence are Unknown, while last-seen information remains in details. The Devices title sits above the rounded inventory card, matching Network's page-title styling. Inside the card, compact status totals, **Showing N devices** or **Showing N of M devices**, and **Scan duration 6.5s** share one summary row at wide widths. Summary metadata moves below the totals when needed in narrower windows. Freshness and scan/save errors live only in the shared shell header rather than being repeated in the inventory card.

The primary filter row contains **Search devices**, multi-select **Status**, and
a far-right connected funnel/reset control. The funnel reveals **Device type**, **Operating system**,
**Vendor**, **Person**, **Room**, and **Ports** in exactly one second row, initially
collapsed. **Usage category** is the seventh secondary filter. Hiding that row
preserves its restrictions; the funnel displays the
number of active secondary categories, excluding Status and search.

Status selections, including multiple categories or the unrestricted selection,
are saved with the existing table preferences and restored after restart.
Dropdown changes, status summary chips, Overview shortcuts and Clear filters
use the same persisted selection. Search and other filter categories are not
restored. Remembering **Status: Online** does not preserve Online evidence:
restored observations are historical, so that filter can initially show no rows
until fresh ICMP results are checkpointed. Starting a scan retains the displayed
rows until that checkpoint; later stages update the current scan's evidence.
UI-review mode reads/writes table settings only when an explicit isolated
`FINGVIBE_UI_REVIEW_DEVICE_TABLE` fixture path is supplied, never the user's
normal preferences. Native restart coverage uses and removes that fixture.

Category dropdowns contain native checkboxes and stay open while selecting
multiple values. Selections combine with OR inside a category and AND between
categories and search; no selections means no restriction. Person/Room include
**Unassigned**, and type/OS include **Unknown**, selectable alongside other values.
Type/OS match the effective classification shown in the table, including saved
corrections and mapped Fing metadata; Vendor choices come from the full inventory,
not just filtered results. Ports currently contains only **With open ports**.
Selected values are retained across inventory/assignment refreshes, even if a
selected value temporarily has no matching devices.

### Device usage categories

The visible-by-default **Usage category** column shows Permanent, Personal,
Guest, or muted Unclassified on one line. A small pin identifies a manual
override; an information indicator identifies limited automatic evidence or
an unavailable result. The source is not repeated on a second line. Hover,
accessible help text, or keyboard focus and Enter/Space expose the reason,
responded/eligible counts, observation period and specific missing evidence.
It can be hidden, resized, searched and sorted with the existing table controls.
Its filter matches the effective category, including manual overrides. Loading
and failed evidence remain explicitly Loading/Unavailable, not a fabricated
Unclassified result; a saved override stays visible and is not marked provisional
merely because its underlying automatic recommendation has limited evidence.

Automatic classification uses only the selected network identity and subnet,
today and the previous six local dates, clipped to the device's first reliable
local sighting and the current time. Completed eligible scans and reliable
explicit legacy observations count; pending/incomplete scans, unknown responses,
imported aggregates and unrelated networks do not become nonresponses. Rules
run in order using exact counts before display rounding:

1. No eligible evidence: Unclassified.
2. At least 80% responded: Permanent.
3. At most 10% responded: Guest.
4. Otherwise, Personal requires at least 60% overnight/weekend responses,
   at least 20 percentage points above weekday daytime, with evidence in both.
5. Otherwise: Unclassified.

Overnight means 18:00–06:00 local time; all Saturday/Sunday scans join that group
without double counting. Weekday daytime is Monday–Friday 06:00–18:00.
Fewer than seven observed dates or 30 eligible scans produces **Limited
evidence**; Personal also requires at least ten scans in each comparison group
to remove that warning. This warning never suppresses a provisional category.
For example, 12/14 responses gives Permanent, displayed as 86%, with limited
evidence. Estimates depend on when scans run: they do not establish device
ownership, visitors or human presence.

Device details' **Assignments** card shows the saved effective category, automatic
recommendation, exact counts, dates, timezone and sampling caveat. Choosing a
category creates a draft; **Save category** and **Cancel** affect only that draft,
independently of Person/Room's existing save-on-change behavior. Assistive
technology announces the category button as **Cancel category changes**, so it
is distinct from the identification editor's **Cancel**. **Automatic**
removes the override and recomputes from current evidence. Normal overrides
belong to the MAC; private-prefix virtual overrides belong to the stable virtual
identity through changing MACs. Both are stored in the existing inventory
metadata, without rewriting scan history or changing legacy migration inputs.
Save failures retain the draft and last saved effective value; concurrent changes
require explicit **Reload saved category** before retrying. Reload discards that
category draft and refreshes saved metadata without overwriting another writer.

Evidence reads and classification run off the UI thread. Saved evidence,
network/view changes, local date/timezone changes and explicit refresh invalidate
the result; cancelled/stale queries cannot replace newer state. There is no
waiting gate, hysteresis or extension into older dates to fill missing evidence.

**Any** is an exclusive any-known-value filter mode, not a snapshot of checked
items or a synonym for clearing the category. It appears immediately after
Unknown, Unassigned or Unclassified when at least two distinct known choices
are offered. Selecting a specific/missing value exits Any; clearing includes
all values again. Any Person/Room means assigned; Any Usage category excludes
Unclassified and unavailable results. Any Vendor excludes both Unknown (including
the raw Private registry result) and Randomized MAC; neither placeholder counts
toward its two-choice threshold. Newly available known values match automatically.
If choices shrink, an active Any restriction remains visible in the dropdown
summary and can still be cleared rather than silently broadened.
The existing Status preference stores this mode separately from explicit
status selections; older settings default to the previous selection behavior.
Other filter selections remain session-only.

Status retains its one-DIP stronger neutral stroke and 210-DIP width. The six
secondary dropdowns share available width equally and shrink rather than wrapping
into further rows; truncated labels and selections have full-value tooltips.
Opened checkbox lists remain independently readable. Dropdowns retain 4-DIP
corners. Search expands with the window and retains 180 DIPs before
Status wraps beneath it. Native
checkboxes expose keyboard focus and checked states, and the funnel announces
expanded/collapsed state and active-category count. Filtered counts show visible
versus total devices.

Settings groups the Devices table options inside one card: **Visible columns** contains the twelve independent visibility choices; a subtle theme-aware divider separates **Combined columns**, its explanatory text and five independent combination switches. Name and IP are marked **always shown**. Both groups wrap at narrow widths without changing saved preferences. **Name/Type**, **IP/MAC** and **Status/Response** are combined by default; **Person/Room** and **Vendor/OS** are separate by default. Turning off a combination restores standalone columns. When only one member is visible, it occupies a normal column; when neither is visible, the group is omitted. **Name** and **IP address** remain mandatory. Combined columns have one resize boundary, retain each applicable sort action, and remember their widths separately from standalone columns. Type appears beneath Name only when known; IP appears above the two-color monospaced MAC. Combined Person/Room shows muted person/home icons beside assigned values, omits unassigned lines, and shows one muted `-` when both are unassigned. Two assigned values stack without increasing row height; each line is horizontally centered and the complete group vertically centered. Its header also stacks Person above Room. Category/full-name tooltips and accessible labels distinguish the assignments. Separate columns retain their existing presentation. Combined Status/Response overlaps the two metrics' horizontal footprints: status at the upper left, right-aligned time at the upper right, and one shared full-width response bar beneath both, retaining the scan-wide latency scale.

The four inventory status totals are compact, borderless colored-dot/text toggles,
not rectangular button surfaces; hover and selected underlines plus native focus
retain visible interaction states. They remain keyboard-accessible. Toggling
one adds or removes that status without replacing other selections, staying
synchronized with the Status checkboxes and retaining every other restriction.
Counts always describe the full inventory, including zero-match results.
The **Clear filters** icon appears as the right-hand segment of the funnel's
shared rounded outline, separated by a divider, whenever search or any restriction
is active (including hidden categories and Unassigned). With no restriction, only
the rounded funnel segment remains. Clear filters resets search and every category without
changing sorting, device data, or the second row's visibility. Overview shortcuts
clear stale restrictions before showing Online devices or Online devices with
open ports.

Every Devices data-column header is sortable: click to select ascending order,
then click again to reverse it. Name (including saved custom names), Vendor,
OS, and Device type use case-insensitive displayed text; unknown/missing text
retains ordinary lexical ordering. IP addresses sort numerically, Status by
inventory status, Response by latency (missing first ascending), and Open ports
by the number of observed port entries (zero first ascending). Person and Room
sort by case-insensitive **full names**, not short labels or emoji, with
unassigned devices last in both directions. Last seen sorts by its timestamp
(a current response uses the displayed scan time); Unavailable and then Never
stay last in both directions. Equal primary keys use MAC address,
then numeric IP; tie keys follow the selected direction. Merged columns retain
independent clickable subheaders and arrows. Filtering, clearing filters,
metadata edits, and incoming results retain the selected sort; a selected
device remains selected while it is still visible.

Opt-in **Vendor + OS** places vendor above known OS in secondary text, retaining
inference qualifiers, the OS source tooltip and header sort action. Unknown OS
leaves the second line blank. Standalone OS consumes no width while merged;
visibility and separate/combined widths are preserved when switching back.
Virtual identities default to a multiple-PC icon in the device icon position,
both in the Devices list and device-details header, with the explanation
**Virtual device - inferred identity across changing MAC addresses.**
An explicitly selected icon takes precedence; clearing that correction restores
the virtual-device icon, rather than following the device type. There is no
separate marker beside the name, and genuine names and user-entered symbols are
preserved. This marks existing inferred identities, not virtual machines or
every private MAC; it changes no grouping or classification rules.

**Devices row density** defaults to **Compact**. Existing density preferences,
including explicitly saved Standard, migrate to Compact once; subsequent saved
Standard or Compact choices are respected. Standard (relaxed) uses 4-DIP
top/bottom padding and existing line gaps; Compact uses 1-DIP top/bottom padding
and 1-DIP line gaps. With visible stacked columns, the minimum heights are
36 DIP in Compact and 40 DIP in Standard; without them, they are 30 and 34 DIP.
Stacking is determined by enabled Name/Type, IP/MAC, Vendor/OS, and Person/Room
combinations with both members visible. Hidden secondary members do not count;
the side-by-side Status/Response combination and one-line Usage category do not count either.
The policy applies across the table, not separately to devices with missing
metadata or assignments. Fonts, icons, and horizontal spacing are unchanged.
Column titles follow the same setting through tighter vertical
padding and spacing, retaining font sizes and sort/resize actions.
Both modes allow growth for accessible text sizes. Density and
Vendor/OS merge are saved in `device-table.json`; changing density preserves
selection, filters, sorting and columns. **Reset columns** resets Vendor/OS merge
but leaves density and hover-preview preferences unchanged.

Both modes retain 13px primary names/latencies and a 20px far-left type icon within the content-driven row envelope. Smaller monospaced MAC addresses use contrasting prefix/suffix colors; muted metadata preserves name hierarchy. Missing metadata uses a muted dash, except meaningful Unknown status/vendor labels. **Randomized MAC** labels a locally administered address, not a proven randomized address or known manufacturer; accessible help and its tooltip explain the limitation. A raw **Private** registry vendor is displayed as **Unknown**, with the source limitation explained; raw values, meaningful corrections/imported brands and identity grouping are unchanged. Unassigned People/Rooms cannot display stale labels, while valid assigned digits and emoji are preserved. Green Online, neutral Offline/Unknown, and amber Fing Only badges pair text with a dot. Subtle theme-aware zebra stripes follow the displayed row order, with native hover, selection, and focus indicators taking precedence; decorative stripes are disabled in Windows high contrast. A 1px theme-aware line below the contrasting column headers separates them from the rows, using system colors in high contrast. The final visible column retains its right-edge divider and resize handle, making unused trailing space distinct without changing configured widths or viewport layout.

IPv4 MAC enrichment first checks Windows' neighbor table for the exact IP on the route-selected interface, accepting only valid unicast six-byte addresses in usable states. If absent, it attempts `SendARP` once and rechecks the table. It never substitutes a gateway MAC or an unrelated interface's neighbor; a ping response can still lack a resolvable MAC.

Starting a scan retains the displayed list while initial ICMP results are collected. After that durable checkpoint, browsing, filtering, sorting and device details become available before background ARP. Later checkpoints update the table quietly while preserving selection, without moving focus or showing a retry popup. Scan LAN remains unavailable and Cancel scan remains accessible until the logical scan finishes or stops. Initial ICMP progress is unnumbered. Background status keeps **Initial results shown** visible and names five ordered stages: **(1/5) Background ARP**, **(2/5) Waiting 10 seconds before ICMP attempt 2**, **(3/5) Background ICMP attempt 2**, **(4/5) Waiting 10 seconds before ICMP attempt 3**, and **(5/5) Background ICMP attempt 3**. Each probing stage counts its own remaining addresses, including ARP nonresponses; waits are explicitly distinguished from active probes. Silent addresses can make bounded ARP substantially longer than ICMP, but the initial results remain usable throughout. Confirming every address skips the remaining stages and finalizes immediately. Cancellation or failure retains the last committed checkpoint, without making silent devices Offline.

Manual and scheduled scans share one execution path. It holds the app's single network-activity slot for the whole scan, so LAN scans never overlap speed tests, troubleshooting or device-service scans; a busy request is rejected, not queued. If the Windows network identity changes during a scan, its observations are saved unscoped and no device is marked Offline.

### Scheduled scans

**Settings > Scheduled scans** is off by default. Turning it on scans the network selected in the shared header every 15 minutes, 30 minutes, 1 hour (default), 2 hours, or 4 hours while FingVibe is open, including when it is minimized. There is no tray, service, background task, or catch-up scan: the first scheduled scan runs one full interval after you enable it, FingVibe finishes loading, or Windows resumes, and changing the interval restarts that wait. Closing FingVibe or turning scheduling off cancels scheduled work and drains any pending checkpoint write; committed observations are retained as incomplete.

Scheduled scans use the same execution path, progress, cancellation, retained-result, inventory, history and discovery handling as **Scan LAN**. Their progress and outcomes are labeled **Scheduled scan**, and **Cancel scan** stays available on every page. A scan you cancel waits a full interval before the next attempt; cancellation by disabling, sleep or closing is reported as stopped with nothing saved. Busy network activity, an unavailable LAN, or a failed scan or save is retried after one minute (or the interval if shorter), doubling up to the chosen interval, with the reason shown in Settings. Scheduling pauses while Windows reports sleep, cancelling any in-progress scheduled scan; on resume, it waits a full interval.

Settings explains the current state in one sentence: off, waiting for loading, in progress, next approximate time, or a paused, skipped, or failed attempt and its retry time. While scheduling is on, the shared header's freshness line ends with **Scheduled every** *interval* **while app is open** (or **Scheduled scans paused**/**retrying**). Each scheduled scan samples which devices answer at that moment; missed responses between scans are not proof that a device was offline, and FingVibe does not record a continuous availability timeline.

Newly observed devices from a scheduled scan use the same in-app discovery popup. Discoveries made while FingVibe is minimized are combined and shown once the window is restored, noting that they were found while minimized.

The choice is saved atomically to `%LOCALAPPDATA%\FingVibe\periodic-scan.json`; unsupported intervals load as 1 hour. An unreadable file leaves scheduling off, is never overwritten, and is reported in Settings, as are save failures. UI-review mode reads and writes this setting only when `FINGVIBE_UI_REVIEW_PERIODIC_SCAN` names a file, and `FINGVIBE_UI_REVIEW_PERIODIC_SCAN_TIME_SCALE` (greater than 1) shortens the scheduled waits for automation while Settings continues to show unscaled times. `tests\SidebarNavigation.Tests.ps1` exercises the controls, keyboard toggle, responsive layout, themes, cancellation, disabling, completion and restart restoration; `tests\DeviceDiscovery.Ui.Tests.ps1` checks minimized discovery deferral. Never run native UI automation on a working user's desktop.

### First local discovery

After a completed manual or scheduled scan saves inventory/history successfully, a single
in-app popup lists newly observed devices with a count-first heading, device
icons, prominent friendly names (or **Unnamed device**), secondary MAC/IP
addresses and full-row details actions. Its list scrolls independently of the
header and **Saved locally / Dismiss** footer. An identity absent from the
displayed results remains visible with **Details unavailable**, never a link
to a different device.

Each qualifying manual or scheduled scan also requests one grouped native Windows
toast, whether FingVibe is visible or minimized. It includes a bounded name preview,
an additional-device count and a device silhouette with an amber shield/question
mark: unfamiliar equipment merits review, not a threat verdict. Clicking its body
or **Review device(s)** restores FingVibe and opens that scan's discovery list.
Restoration/activation never scans or sends another notification. Windows settings
and Do Not Disturb can suppress banners; in-app presentation remains independent.
Registration, request and activation failures appear in the shared scan status.
Successful API acceptance does not claim that Windows displayed a banner.

The existing Windows App SDK registers the unpackaged executable, with FingVibe's
sender name/icon separate from the caution image; no MSIX migration is required.
Short-lived activation payloads under
`%LOCALAPPDATA%\FingVibe\discovery-notifications` preserve the corresponding
list after restart. Toasts and their payloads expire after 24 hours; expired files
are pruned on the next qualifying request. This is not a notification archive or
an authoritative inventory store. A moved/deleted portable executable cannot
receive activation through its old registered path; run the new copy to register
it. No closed-app scanning is added.
Returning devices and repeated scans, including after restart, do not alert.
Existing virtual identities suppress separate alerts for associated MACs,
including a new MAC assigned to an already known virtual device.

Discovery is scoped to the current identified network and subnet. Existing
durable local observations establish its baseline on upgrade; imported Fing
metadata does not. The first successful scan of a previously unknown scope is
quiet, including an empty scan, and saves its baseline in the inventory.
Imported-only devices qualify on their first local discovery after that baseline.
Unknown network identity suppresses both alerts and baseline establishment with
a visible explanation. Cancelled/failed scans and saved-scan restoration never
alert. Inventory/history save failures withhold the popup and remain visible;
unsaved in-memory observations are not used as durable duplicate suppression.

`tests\DeviceDiscovery.Ui.Tests.ps1` exercises synthetic baseline/upgrade,
normal/virtual discovery, imported-only discovery, each details link, repeat and
return scans, restart, MAC rotation, network scope, cancellation/failure, and
save-failure/retry behavior through the existing Windows CI device-details review.
Its completed-scan and network fixtures are enabled only in UI-review mode.
It also checks long-name/unnamed/large-list presentation, fixed header/footer,
unavailable details, keyboard dismissal, light/dark/high-contrast appearance and saved-list
activation/error states. `--review-discovery=<id>` exercises the native
activation handler's saved-list path only in UI-review mode; it is not evidence
of a real Windows banner or click. Native notification registration/delivery is
disabled by default for isolated UI-review fixtures. Opt in with
`FINGVIBE_UI_REVIEW_NOTIFICATIONS=1` on a disposable supported Windows desktop;
verify real notification-center/banner and body/button activation separately
for installed and portable copies, including settings/DND suppression.
A retained Windows history entry or a direct native COM activation probe does
not replace checking the displayed notification and its body/button actions.
Never run native UI automation on a working user's desktop.

### Device activity

Device details shows **Activity** at the top of its **History** tab, above the
scan-history context. Choose
**Last 7 days**, **Last 30 days**, or **30 days by weekday**, and group each local
date into midnight-aligned 1, 2, 3 or 4-hour cells. Three-hour groups run
00:00-03:00 through 21:00-24:00. The displayed Windows timezone and query time
define the window; today includes only evidence collected so far.

Green means at least one reliable response, even if other scans in the cell
had no response. Slate means eligible observations with no response; hatching
means unknown evidence, not offline. No state is interpolated between scans.
Weekday numbers count responding dates; green strength divides by **all
applicable dates**, including unknown ones. Three responding Wednesdays and one
unknown therefore show 3, 75% green and hatching, not 100%. Entirely unknown
cells show no zero or percentage. Skipped DST hours are not applicable and are
excluded from that cell's denominator; repeated hours combine both instants.

Select or focus a cell for exact response, nonresponse, unknown and date counts.
Arrow keys move within the grid; Home/End move within its row. Narrow grids
scroll horizontally instead of shrinking cells; 30-day rows scroll vertically.
High contrast uses system colors and R/N/? symbols alongside accessible text.
Changing device, network, period or hour grouping cancels older queries; leaving
the page or closing the window cancels pending work. Refresh failures clear old
results and expose **Retry**. Existing scan history and category editing remain
independent. While no grid is shown, the window line names the selected period
and grouping, the detail line prompts for a cell, and the legend stays visible.

Activity reports one observable state through the grid's UI Automation item
status: `Loading`, `Ready`, `Empty` or `Error` with an increasing request number
and the selected period and grouping (for example
`Ready (request 4): Last 30 days, 1-hour cells`), or `Idle` when the page is not
shown. `Ready` follows rendering and layout. The WinUI-free `AsyncSurfaceSession`
owns cancellation, replacement, stale-completion rejection and Retry; see
[asynchronous surfaces](../CONTRIBUTING.md#asynchronous-surfaces).

Activity reads the selected window off the UI thread through the shared SQLite
evidence query. Imported aggregates, incomplete scans, pre-sighting gaps and
ambiguous mappings cannot manufacture nonresponse. Core `DeviceActivity` output
retains aligned identities, original contributing scan evidence, counts, union
contributors and exact/partial/unknown coverage for later aggregate consumers;
it contains no inferred uptime or scalar duration estimates.

### Network activity

The Network page retains its existing information cards and adds **Device
activity** below them. The 7-day, 30-day and weekday modes use the same local
calendar, 1-4 hour grouping, keyboard navigation and scrollable grid as Device
Activity. Daily values count the union of distinct logical devices across scans,
not summed responses or the maximum simultaneous count. Weekday values average
only exact daily counts, including known zero, and display up to one decimal;
cell details retain the exact sum, denominator and contributing daily counts.

Room, device type and usage category filters apply together using **current**
metadata. All rooms/types/categories, Unassigned, Unknown type and Unclassified
remain explicit choices. Current automatic categories reuse the seven-date
classifier; manual overrides take precedence. Saved metadata changes, completed
scans, network/period/filter changes, returning to the page and local date/timezone
rollover refresh the evidence. No historical assignment reconstruction is used.

Green intensity and its numeric legend rescale to the current filtered grid.
Slate is known zero; hatching is unavailable or incomplete evidence. `N+` means
**at least N**, including `0+`, and incomplete daily counts never enter an exact
weekday mean. Imported-only or ambiguous contributors are disclosed rather than
treated as offline. A zero-only grid has no invented positive range; an entirely
unknown grid reports unavailable. Today is explicitly partial and skipped DST
hours are excluded from applicable dates.

The page uses `AsyncSurfaceSession`, publishing its state and selection on
`NetworkActivityScroll`. Loading and errors clear old cells; Retry starts a new
request, and selection, navigation and close cancel obsolete work. Query,
classification, filtering and aggregation run off the UI thread against the
same captured saved revision. All Activity surfaces share the grid renderer;
their different count/response semantics remain separate.

`NetworkActivityTests` covers count unions, exact means, filters, lower bounds,
zero/unknown, current normal/virtual metadata, identity deduplication, network
isolation and calendar boundaries. The disposable native `NetworkActivity.Ui`
module uses an isolated 1,000-device fixture and verifies all periods/groupings,
filter combinations, 720-cell reachability, keyboard/light/dark/narrow layout, loading,
replacement/cancellation, error/Retry and empty history. It runs in the existing
`details-identity` job when Network is selected, using that job's budget
headroom; full validation includes it.
`tests\NetworkActivity.Script.Tests.ps1` verifies that fixture and its production
query without desktop automation. The shared renderer also retains the existing
Device Activity light/dark/high-contrast native coverage. No native test runs on
the user's working desktop.

### Person equipment activity

Person details shows **Equipment activity** above Assigned devices, preserving
Edit, Delete, Assign, Unassign and device navigation. The 7/30-date and weekday
views reuse Network's distinct-device counts, exact daily-count means, local
calendar/DST rules, 1-4 hour groups, numeric legend and keyboard-accessible cells.
Current assignments apply to historical evidence, not reconstructed ownership.
Cell details name responding and unavailable equipment, and weekday details
retain exact numerator/denominator and excluded dates. The assigned list shows
the current effective usage category and Auto/Manual source.

The latest logical scan in the **selected network and subnet** supplies
Equipment online only with complete eligible equipment evidence and at least
one response, or No equipment responded when all eligible equipment was checked
with no response. Missing/incomplete evidence stays Unknown even with partial
positive responses. No assignments shows No equipment assigned, without a grid
estimate. Counts, network and scan age remain visible; age strictly greater than
two hours adds Older scan without changing the evidence state. Age refreshes
every 30 seconds while the page is active, without probing or background scans.
These are equipment observations, never human-presence claims.

Assignment/person/network/revision/period changes, navigation and close cancel
obsolete requests through `AsyncSurfaceSession`; `EquipmentActivityScroll`
publishes the observable selection/state. Loading and errors clear old results;
Retry runs a fresh request. Queries read only selected equipment history,
deduplicate existing virtual associations in storage, and retain out-of-network
assignments as unknown contributors. Imported-only devices are not offline.
Queries, counts and classification run off the UI thread.

`EquipmentActivityTests` covers exact means/zero/partial evidence, latest scan
eligibility, strict age boundaries, current assignments, virtual deduplication,
network isolation and obsolete results. `EquipmentActivity.Script.Tests.ps1`
checks the three-equipment/1,000-device production-query fixture without a
desktop. The focused `EquipmentActivity.Ui` module runs in `details-summary`
when PersonDetails is selected, retaining existing summary coverage. It covers
all periods and groupings, contributor details, category source, loading and
cancellation, no equipment/no history, error/Retry, light/dark/narrow layouts
and retained action reachability on disposable CI desktops. Shared renderer
high-contrast checks remain in Device Activity; Sidebar retains the full
People/Rooms editing/assignment flows. Desktop-free helper regressions cover
Person control lookups across asynchronous waits and completed-observation
viewer positioning when focus alone leaves the nested viewer clipped,
including clipped UI Automation bounds and fractional scroll corrections
that preserve the full viewport margin.
Final-head affected-job durations are
delivery evidence, not inferred from these coverage mappings.

### Device scan history

First/last seen, last-observed/since and network scope appear in the Overview
tab's **Saved observation summary**; the History tab repeats the scope with the
latest-scan explanation. Devices Last seen, virtual MAC/address information,
discovery, usage categories and all other device details are unchanged. Scans
continue collecting and retaining evidence; no stored data is deleted.
The CI `details-summary` suite invokes `DeviceScanHistory.Ui.Tests.ps1 -SummaryOnly`,
preserving summary/Last seen, network scope, normal/virtual/imported/legacy,
restart, scan outcomes, persistence errors and light/dark/narrow summary checks.
The `details-observations` suite runs the independent `-ObservationsOnly`
path: normal/virtual/imported/legacy rendering, themes/narrow layout, exhaustive
205-row physical reachability, exact page count/order/state, reverse paging,
page-error recovery and selection reset; `details-activity` runs Activity. Neither
feature changes the other's enablement. The `details-observations` path also checks keyboard tab switching,
retained identification drafts and observation pages, **View device history**,
and that opening a device starts on Overview.

Device details uses local **Overview** and **History** tabs (`SelectorBar`)
below the device name and rename editor. Overview holds
network overview, assignments and usage category, identification, ports and
the saved observation summary; History holds Activity, scan history with
Completed Scan Observations, and virtual MAC/address history. The header, tabs
and both panels share one scroll viewer (`DeviceDetailsScroll`); hidden tabs stay
loaded so drafts, expanders and paging survive switches. Switching tabs keeps the
current scroll position, and **View device history** focuses the History tab.
Opening a device always selects Overview at the top. UI review captures the
History tab as `fingvibe-device-history.png` (`DeviceHistory` scenario).

Device details shows a **Scan history** summary for normal MAC-based devices and
existing virtual devices. First/last-seen timestamps display in local time with
relative ages, refreshed while the page is visible and rounded to the nearest
whole minute, hour, day, month (approximately 30 days), or year (365 days).
**Last observed: Present/Absent** pairs a semantic green/red dot with text; it is
not live status. Missing evidence and historical aggregates remain explicit.

The **Completed Scan Observations** section starts collapsed each time a device
is opened. Expand it for the current-network context, latest-scan explanation,
observation semantics, and a scrollable newest-first table with **Date**,
**Time (local)**, and **Status** columns. Zebra stripes and subtle separators
help track rows; status combines a green/red dot with **Present/Absent** text.
Network identity and subnet appear once above the table, not on every row.
Timestamp tooltips expose the full local timestamp and UTC offset to distinguish
repeated daylight-saving times. Storage remains UTC. Each relevant completed manual
or scheduled scan contributes one observation. Pending or incomplete checkpoints
are not completed history and do not establish current live presence after restart.
Repeated unchanged
scans remain separate rows. Multiple responding addresses or associated MACs
do not duplicate a virtual device's row; its history follows its existing
virtual identity when the active MAC changes. Existing association rules are
unchanged.

History is fetched in bounded 100-observation pages. **Older scans** and
**Newer scans** reach every retained observation; each page remains scrollable,
and the page indicator reports the displayed range and scoped total. Only one
page is held by the view. Equal-time observations keep their insertion order.
The bounded page uses a native ScrollViewer and passive ItemsControl rather than
a selectable ListView. Its stable rows expose the UI Automation DataItem role,
the same complete timestamp/state names, and ScrollItem bring-into-view support.
This avoids selector focus/recycling changing the viewport during read-only
traversal. The viewport is a keyboard tab stop; rows do not add 100 tab stops.
Every row must be physically reachable at full height; enumerated offscreen or
clipped peers do not establish visibility. Focusing the viewport brings it
inside the outer details page.
The expander publishes the page's Loading/Ready/Empty/Error request state through
UI Automation ItemStatus, after layout completes.
A traversal captures a saved sequence boundary, so scans appended meanwhile
cannot shift pages, skip observations, or duplicate rows. Reopening the device
or refreshing its network context starts at the newest page and includes new
observations; changing devices/networks discards the previous traversal.
Page-load errors remain visible and can be retried without replacing a valid page.

The list and its **First seen**, **Last seen**, and **Observed online/offline since**
summary use only the selected current network identity and subnet, shown above
the summary. Changing networks never falls back to another network's evidence;
unavailable identity or missing matching evidence explains unavailable values.
Other-network history remains saved. First/last seen use presence observations;
absence does not advance last seen. Since is the first scan in the latest
recorded run of the same state, so repeated states preserve it and a return
starts a new run. Observation gaps do not imply continuous availability.
Matching legacy first/last-seen aggregates remain available with an explicit
historical-aggregate label when their individual scans are unavailable; they
never supply a since value or fabricated history rows. Restart preserves these
timestamps without treating the saved state as current live presence.

Absence is recorded only for previously locally observed devices covered by a
successful scan of the same identified network and subnet. Presence without a
network identity is retained but excluded from current-network history and cannot establish later
absence. Scans of other networks, unused addresses, failed/cancelled scans,
additional port checks, and reopening saved data do not fabricate observations.
These are scan results, not proof of uninterrupted physical availability or
the actual time a device connected/disconnected.

The analytics foundation also retains a small historical scan-evidence ledger
in the same SQLite transaction as device history, the latest checkpoint and the
inventory revision. Logical scan IDs keep repeated saves/finalization from
counting twice, including completed scans with no responses or no devices.
Pending and incomplete records retain only identity, network/subnet, time and
coverage metadata; they never finalize absence. No second snapshot store,
scanner change or retention policy is introduced. SQLite format 3 adds nullable
scan and explicit virtual-association links to existing history. Upgrades keep
older rows intact and do not invent completed ledger entries from old checkpoints,
imported metadata or aggregate first/last-seen timestamps. Replaying a historical
finalization with appended duplicate history is rejected transactionally.

`DeviceInventoryStore.QueryAnalyticsAsync` takes network ID **and** subnet,
a captured query time, 7 or 30 local calendar dates, a `TimeZoneInfo`, the expected
inventory revision, and optional logical MAC/virtual identities. A null selection
means the network's current logical roster (including imported-only identities
with unavailable evidence); an empty selection remains empty. Querying requires
loading/upgrading an existing inventory first. Reads run off the UI thread in a
read-only snapshot, use indexed selected-window history plus first reliable
local sighting and latest-scan lookups, and never materialize retained history.

The result aligns every scan's response/nonresponse/unknown array with its device
identity array. It retains scan IDs, UTC instants, local completion times,
completion state, exact/partial/unknown coverage, unidentified responses, first
reliable sightings and the data revision. `Scans` contains only the requested
calendar window; `LatestScan` is the latest selected-network logical scan at or
before query time, even if it is incomplete or predates the window. No scan is
an unknown gap, not a synthetic zero. A null scan ID denotes explicit legacy
device evidence with incomplete group coverage, never a reconstructed full scan.
Missing device rows, imported-only identities and pre-first-sighting history
remain unknown. Explicit per-scan virtual associations prevent double-counting
MAC copies after naming/identity presentation changes; ambiguous older mappings
are not reconstructed. Existing paged history and identity allocation are unchanged.

The window starts at local midnight 6 or 29 dates before today and includes
evidence through the captured query instant. Local completion timestamps preserve
both UTC offsets in a repeated DST hour; a skipped hour has no invented
observation. Consumers own midnight-aligned buckets, skipped-hour applicability,
classification and rendering; this foundation adds none of those screens.
Consumers must cancel obsolete work and compare the returned revision and their
current selection before displaying it. Invalid requests, malformed storage,
contention and stale revisions fail explicitly; cancellation throws
`OperationCanceledException`, not an empty successful result.

The Devices table's optional **Last seen** column, visible by default as the
final column, applies the same selected network identity/subnet scope and the
details page's last-seen evidence, so the two never disagree. A device that
responded in the displayed live scan shows muted **Online**, meaning a response
in that scan rather than continuous availability; otherwise the column shows
the newest local presence as a compact relative age, so absence never advances
it. Ages use whole elapsed units: `< 1 min. ago`, `N min. ago`, `N h ago`, then
`1 day ago`/`N days ago`, 30-day `month(s)`, and 365-day `year(s)`. A saved
timestamp later than the current clock (for example after a clock change) shows
its `yyyy-MM-dd HH:mm` local time instead of a negative age.
Missing, other-network, or unreadable evidence shows muted **Unavailable**, and
imported-only devices show muted **Never** (never observed by a local scan, not
never present on any network); neither substitutes Fing timestamps. The
full-value preview, row values, and accessible name give the exact local
timestamp with UTC offset, legacy historical-aggregate provenance, or the
unavailable/never explanation. Evidence is calculated when rows are rebuilt or
the network changes, not while filtering. While Devices is shown, ages refresh
every 60 seconds and immediately when the page is shown again or receives rows;
the refresh stops while another page is shown. It changes only the age text:
never Online, status, timestamps, selection, ordering, or saved data, and it
neither scans nor writes. Restart shows saved history rather than live presence.
Saved settings without this column show it at its default width.

All scan observations are retained indefinitely in `device-inventory.sqlite`,
with no age/count limit, automatic truncation, or new history-clearing control.
The database can grow over time. JSON inventory formats 1-4 migrate without
changing the originals. Legacy aggregates and imported Fing timestamps are never
expanded into invented scan rows. Imported-only devices and older saved
devices explain their empty history. Restart retains history but does not
make it fresh evidence of live presence. Load errors disable inventory edits;
save errors visibly report that inventory and scan history were not saved.

`tests\DeviceScanHistory.Ui.Tests.ps1` verifies synthetic normal/virtual history and
scoped summaries and the matching Devices **Last seen** values through repeated presence, absence, and return,
empty imported history, restart, successful repeated scans, cancellation,
205-row page boundaries, forward/backward reachability and selection changes,
failure, and visible persistence errors on the disposable Windows CI desktop.
The parallel summary and history jobs run complementary `-SummaryOnly` and
`-ObservationsOnly` paths when the capture plan requires device details;
running without either switch exercises both. Never run it on a working
user's desktop. Its explicit `FINGVIBE_UI_REVIEW_INVENTORY` path isolates saved
fixtures from real user data, like the existing review snapshot override.

The expanded sidebar uses a compact 216-DIP Windows Settings-style layout with colored navigation icons and a wrapping FingVibe header. The sidebar and main page share one background, including when a backdrop material is selected. Collapsing the pane keeps an icon rail; narrow windows use native overlay navigation, with Tools above Settings at the bottom. While an overlay is open, both backgrounds temporarily use the same solid theme color to keep the menu readable without a contrasting pane tint; closing it restores the selected material. Windows high contrast replaces decorative icon colors with system colors.

### Device identification

Devices show a native Segoe Fluent device icon beside their name. **OS** is a sortable, resizable, optional column. **Device type** is an optional secondary line within the mandatory Name column, with a separate type-sort action in its header. Both detected and manually selected classifications are included in text filtering. Device details show the identification evidence and whether a value is user-selected. Unknown OS, device type, and vendor metadata use muted dashes in the list; details retain descriptive classification text.

The identification card reads as values by default. Its single pencil + **Edit**
button switches all six fields inline: device type, OS, brand, family, model and
icon. It focuses device type and keeps **Save changes** / **Cancel** beneath the
inputs. Cancel discards drafts; successful Save returns to read mode; a failed
Save keeps entered values and displays the error. Blank brand/family/model
inputs inherit the original/default value (shown as placeholder text), rather
than hiding it. Saved corrections take precedence over original Fing values,
then automatic evidence where available. **Reset saved identification** clears
all six overrides, not device names, assignments or imported evidence.
**How this device was identified** discloses the technical evidence separately.

Identification is best-effort and local. SSDP discovery uses the selected interface, and one shared multicast DNS-SD discovery window follows service announcements through SRV, TXT, and IPv4 address records to collect models without confusing proxy responses with the responding device. It listens for multicast replies as well as requested unicast replies. SSDP `SERVER` advertisements and bounded HTTP/SSH banner reads on already-open ports can identify OS-specific platform information. Merely running SSH, SMB, nginx, or Apache is not OS proof. The computer running the scanner is identified directly from its OS, and the selected interface's configured gateway is identified as a router.

Explicit device types/models outweigh service-only clues. When explicit evidence is absent, narrow product/manufacturer clues can suggest categories such as WD My Cloud/Synology/QNAP storage, Philips Lighting/Signify/Tuya smart devices, media devices, or game consoles. OS-specific discovered names, such as `Android-...`, are hints, not proof that the device is a phone. These inferred values are visibly marked **(likely)** in the list and details, with the supporting evidence shown in details. A generic TP-Link, Amazon, or Apple vendor, randomized MAC, or open SMB port alone does not determine an OS or device category. Conflicting or unsupported results remain **Unknown**; silent devices may still require manual correction. No fingerprinting cloud API is contacted; the existing vendor-registry downloads and optional public-network lookup are unchanged.

For otherwise unidentified SMB hosts, an observed ICMP response TTL of 127 or 128 together with open TCP 445 can suggest **Windows (likely)** and **Computer (likely)**. This is a combined heuristic, not definitive OS fingerprinting: it does not apply to known routers, NAS appliances, smart devices, or contradictory OS evidence. TTL alone, SMB alone, and Linux/macOS-style TTL values do not produce an OS guess.

In the inline editor, **Automatic** restores detection for an individual field
when no mapped Fing metadata is available; otherwise that option explicitly says
**Use imported Fing OS/type**. The icon follows the effective device type unless
an explicit icon is selected. Available types include Computer, Phone, Tablet,
Router/access point, Printer, TV/media device, NAS/storage, Game console,
IoT/smart device, and Unknown. Categories without reliable discovery evidence
can be assigned manually; OS also offers Other.

Corrections are stored separately from automatic evidence within `%LOCALAPPDATA%\FingVibe\device-inventory.sqlite`, keyed by MAC address, and apply after rescans, IP changes, and restarts. Existing `device-classifications.json` data is migrated without deleting or rewriting the legacy file. Saving requires a six-byte MAC address, including an imported MAC. Private/randomized MACs may change and therefore lose their association with saved corrections. Load/save errors are shown in details; a failed load disables edits rather than overwriting existing corrections. Completed scan snapshots preserve automatic evidence and inferred-value markers. Older snapshots remain readable, but are not re-enriched when opening a new build: run **Scan LAN** again to collect current detection evidence.

For private-prefix virtual devices, corrections instead belong to the persistent virtual identity and follow its inferred MAC changes; underlying MAC-specific corrections are preserved separately.

### People and rooms

Each person and room can select a predefined monochrome **Icon** in Add/Edit.
People offers person silhouettes; Rooms offers room, home, bedroom (sleep),
kitchen (cup), living room (TV), office (briefcase), garage (car), and garden
(leaf) symbols. The selected icon appears at 16 DIP beside the name in the
People/Rooms list and at 48 DIP above the short name in its detail header.
Icons follow theme text colors, including high contrast, and do not replace
names or accessible labels. They are decorative: assignments, device tables,
assignment pickers, search, sorting, and response counts are unchanged.
Choices are saved with each entry as stable IDs. Existing entries use a generic
person or room icon; an unavailable saved ID displays the generic icon with a
diagnostic and remains preserved unless a different choice is selected.

Short-name limits count visible characters, so a multi-code-point emoji such as `0️⃣` counts as one. Room short-name inputs, the room list and details, and Devices room assignments use Segoe UI Emoji for consistent color-emoji rendering; saving preserves the original Unicode sequence.

The **People** and **Rooms** pages manage manually named people and locations. Each entry has a full name, a unique 1–3-character short name within its category, and optional notes. New entries suggest initials from the first two words as you type (`Igor` → `I`, `Igor Iric` → `II`, `Living Room` → `LR`); editing the short name manually stops automatic updates. Device details can assign one person and one room independently; either can remain unassigned. The Devices table shows plain short-name text in optional **Person** and **Room** columns, with muted dashes for unassigned values, while filters and search match both short and full names. Hover over a short name or keyboard-focus it to access its full-name tooltip and accessible label.

People, rooms, and their assignments are saved separately from scan snapshots within `%LOCALAPPDATA%\FingVibe\device-inventory.sqlite`. Existing `people-rooms.json` data is migrated without deleting or rewriting the legacy file. Assignments require a six-byte MAC address, including an imported MAC, and never use an IP address alone. Private or randomized MAC addresses may change, so their assignments are only retained when the same MAC is observed again. Deleting a person or room clears only that category's assignments; it does not delete devices or scan history. Last-scan response counts report devices that answered ICMP or fresh ARP during the displayed scan, not human presence; no response does not prove a device is powered off. Load and save errors are displayed, and a failed load disables changes to protect the saved file.

Assignments edited on a private-prefix virtual device belong to its persistent identity and follow inferred MAC changes, rather than being copied to its member MACs.

## Inventory and Fing import

**Tools > Import from Fing** accepts one local `.xlsx` workbook through Browse or
drag-and-drop. Export help is collapsed initially. Fing's current
[Network View documentation](https://help.fing.com/hc/en-us/articles/26652272065820-Network-View)
describes the Web App's network Setup > Export > Send workflow, delivering an
Excel spreadsheet by email. Desktop/mobile menus and availability vary with
version and subscription; CSV, PDF, text exports, and arbitrary spreadsheets
are not supported. The supported workbook has one Devices sheet and a MAC
header, with the optional Name, Hostname, Type, Brand, Family, Model, OS,
OS Version, Owner, Location, and IP columns. Limits are 10 MB compressed,
64 MB uncompressed, and 20,000 device rows. Formulas are not executed or trusted.

Analysis is read-only and groups People, Rooms, private/randomized MACs,
skipped records/fields, and a combined **Device type / OS classification** warning
group. People/Rooms groups have
standard management buttons at the top-right of their cards and confirm when
all referenced entries match or none are referenced.
Expanded details identify affected devices by available name or formatted MAC,
showing the first 10 per detail followed by an omitted-count notice when needed.
Diagnostic references retain worksheet rows; skipped records without a retained
device identity show their row instead. Counts remain complete and text wraps.
The filename gains an Excel-inspired green chip and outline in every light/dark
appearance after successful analysis and returns to
neutral when analysis is cleared or invalidated; this does not approve every field.
Windows high-contrast mode retains system colors.
Excluded Fing data and historical-IP semantics appear as an informational note,
not a warning. The separate **3 Changes and conflicts** container groups the preview by device/MAC, with compact additions,
explicit before/after conflicts, and reasons for skipped fields; absent fields
are omitted and unchanged devices are collapsed. Existing names, imported metadata, manual classifications,
and assignments are kept unless their individual conflict choice is changed
to Replace. Empty fields never erase saved data. Detailed Fing types and OS
strings remain available in details even without a reliable category mapping;
uncertain mappings produce warnings. Manual corrections take precedence over
imported classifications, which take precedence over automatic detection.
Name precedence is user name > imported name > local hostname > imported
hostname > last-known local/imported IP; IP fallback names are subdued.

Device-card headers have a subtle theme-aware background band and put bold names and MACs alongside normal-weight change counts;
nonzero conflicts have a critical-color indicator. Compact rows group identity,
hardware, operating-system/address, and assignment fields. Non-interactive label
chips distinguish field names from values without creating false button actions.
Labels, values, and conflict controls are center-aligned within each wrapping field unit.
Device cards use 6-unit outer vertical padding and 2-unit padding on each side
of the header/details join, with 4-unit spacing between detail rows.
Names use Segoe UI Emoji for supported color emoji sequences, preserving their text.
**Fing IP** is the historical exported address, used as display/search context and
a final name fallback only; it never identifies a device or authorizes a probe.
Private/locally administered MACs appear as informational notices, not warnings.
Affected cards recommend leaving unrecognized devices unchecked in Select devices
mode; they remain importable, and Import all still includes every eligible device.
New devices containing only MAC/historical Fing IP receive a **Limited information**
recommendation to skip them unless recognized. Useful metadata, assignment references,
or existing saved information prevent that recommendation. It does not exclude
devices automatically or disable importing them.
Cards sort by conflicts, then additions, then skipped fields, all descending.
Exact ties sort by MAC ascending; changing choices/importing refreshes the ordering.

Owner matches a managed person's full name and Location a managed room's full
name, after trimming and case-insensitive comparison. Exactly one match is
required. Missing/ambiguous entries skip only that assignment field, not the
device; use the management buttons, return to Tools, and Analyze again.
Import does not create people/rooms, infer owners, import Group, or migrate
Fing events/timestamps. Invalid MACs and all duplicate-MAC rows are skipped
with explicit warnings. Devices sharing an IP remain distinct by MAC.

Online means a fresh ping or ARP response in this session's latest local scan,
including its checkpointed initial results while background confirmation is pending;
Offline means locally observed previously but absent from a subsequent
successful scan of that same Windows network profile and subnet. Other-network,
cancelled, and failed scans do not infer absence. When network identity is
unavailable or changes during a scan, a warning is shown and absence is not
inferred. Fing Only means the inventory has no local observation of the imported
MAC, regardless of Fing's State field. First local discovery removes that state.
After restart, retained observations are Unknown, not Online or freshly Offline.
Observations outside the latest displayed scan's network/subnet are also
Unknown; their last-seen information is retained. Before an initial checkpoint,
a failed or cancelled refresh leaves the previous results unchanged. After a
checkpoint, it retains those observations as incomplete/historical without
inferring absence. A scan already finalized by a committed Complete checkpoint
remains complete if cancellation races its final cleanup. People/Rooms
live-response summaries do not count imported or restored records. Overview and
Network Online counts count current device identities, not historical members
or duplicate IPs for one MAC. Historical/Fing-only addresses cannot
start an additional port probe until a current local response exists.

### Private-prefix virtual devices

Sparse, globally administered MACs with vendor exactly **Private** are eligible
when they have no meaningful saved/imported name, hostname, device type, OS,
family or model. An IP-only name is not identification. **Private** means an
undisclosed IEEE registrant, not a randomized MAC or a known manufacturer.
Locally administered/randomized MACs and meaningful MAC-specific metadata are
not automatically grouped.

On each successful scan of an identified Windows network profile and subnet,
eligible MACs occupy persistent virtual devices named **Private D0-C9-07**,
**Private D0-C9-07 -2**, etc. Each virtual device has at most one responding MAC,
but that MAC can have several responding IPs. Known returning MACs are reserved
first. New MACs take the lowest-numbered available device; only additional
simultaneous responders beyond the existing capacity create another number.
If previously associated MACs return together, the last-active member has
preference, with MAC order as the deterministic tie-breaker; extra members use
available/new slots. A returning MAC prefers its most recently used association.
Numbers are retained when devices become Offline; they are not renumbered.
Unscoped restored observations and unrelated network/subnet contexts are not
used to infer an association.
Previously unassociated eligible history in that same known context joins the
lowest-numbered virtual device on a successful scan, with an inference notice
and its original first/last-seen times. If only historical members exist, number
1 is created Offline after that scan establishes their absence.

Select a virtual-device row to edit its name, identification or Person/Room
assignments; these belong to the virtual device and follow its MAC changes.
Expand **MAC and address history** for full selectable MAC/IP pairs, first/last
seen times, network/subnet, endpoint evidence and preserved MAC-specific data.
Each numbered device keeps its own history. Association by prefix and available
number is explicitly **inferred**, not proof of one physical device.
Underlying full-MAC records and existing metadata/assignments remain intact;
Fing imports still match full MACs, never virtual device names or prefixes.
If meaningful MAC-specific identification arrives later, that record is shown
normally while the virtual device's prior history is retained.

When one MAC responds at multiple addresses, details offer **Current address
to inspect / probe**. Ports and additional probes in details belong to that
selected responding address; the list's port filter counts the device if any
current address has an endpoint. IP changes do not create another identity.
Search can find virtual devices through historical MACs and addresses.

On Devices, the status filter sits directly beside text search in the filter bar;
its semibold text and stronger theme-aware accent border distinguish it from the
other filters, which retain responsive wrapping at narrower window widths.

`device-inventory.sqlite` contains inventory, local observations, names,
classification corrections, People/Rooms, persistent virtual devices, scan
history and network/subnet discovery baselines. Completed-scan changes commit
together in a SQLite transaction with full synchronous durability and an
optimistic revision check; stale app instances must restart and analyze again.
Scans append history rows, while metadata edits update only changed records and
leave scan history untouched. Startup loads metadata and immutable SQLite-backed
history snapshots rather than all retained observations. Indexed network/subnet/
identity/time queries supply bounded pages, first/last presence, latest observed
state, and the start of its latest state run. Discovery uses bounded durable
presence queries. Routine scans and metadata edits neither enumerate nor copy
saved history. The explicit full-history Core load API remains available for
consumers that deliberately need all observations.

The earlier SQLite schema upgrades transactionally on first load, adding UTC
tick indexes and incrementally maintained per-identity counts while preserving
original timestamp offsets and every observation. This one-time upgrade reads
existing rows; routine startup does not. Interrupted upgrades roll back and can
retry without falling back to JSON.

`SqliteHistoryQueryTests` validates a synthetic million-row fixture (100 devices
with 10,000 observations each, timestamp ties, state changes and multiple
networks). Its predeclared Release-mode interactive-operation ceilings are:
metadata startup 10 seconds / 32 MiB managed allocations; a 100-row page
1 second / 1 MiB; 100 summaries plus discovery, a 100-device scan/save, and a
metadata edit each 5 seconds / 16 MiB. The test records the environment and
actual measurements, verifies query plans, and excludes one-time fixture/index
construction from routine timings. These bounded-memory checks are not an
unlimited-capacity claim; retained database size still grows.

On first load, supported `device-inventory.json` versions 1-4 migrate to a
transactionally initialized temporary database, published only after success.
Without an inventory, existing `device-names.json`, `device-classifications.json`,
and `people-rooms.json` migrate together. Source files remain untouched and are
checked for changes during migration. Interrupted migration can retry the
originals; an invalid existing SQLite database never falls back to stale JSON
or an empty inventory. The successfully published database is authoritative.
Available legacy snapshot observations are restored as historical with unknown
network identity; unavailable older history is not invented. `latest-scan.json`
and appearance settings keep their existing formats. Older app builds do not
read SQLite and may display retained older JSON; their legacy-file edits are not synchronized back
after migration. Load failures disable changes rather than overwriting data.
Use **Import device** to save one device or **Import all** for all eligible changes.
**Select devices** switches to checkboxes and **Import selected (N)**, with
Select all / Deselect all and Cancel selection. Selection starts empty; changing
modes never saves or resets overwrite decisions. Every operation saves only its
requested devices together, completely or not at all. Import all does not approve
overwrites: all operations respect the preview's keep/replace choices.
After success, the remaining preview refreshes and retains valid pending choices.
**Imported this session** records saved progress; devices with preserved conflicts
or skipped assignments retain their remaining items. Imported does not mean every
Fing field was accepted. Save failures do not commit a partial batch.

Changing the file, conflict choices, or relevant saved data invalidates or
refreshes the preview. Import checks that the file bytes are unchanged and that
the saved inventory revision still matches. Another app instance's committed
changes cause an explicit stale-data error rather than an overwrite.

`tests\FingImport.Ui.Tests.ps1 -AppPath "<absolute app path>"` exercises a fully
synthetic preview, management return/re-analysis, completion, inventory counts,
and status filtering on an interactive Windows desktop. UI-review mode keeps
inventory edits in memory and never imports the user's private export.

## Read-only SQL editor

**Tools > SQL editor** queries saved SQLite inventory and scan history through
named reporting views without JSON paths. It provides Run/Cancel, a result table,
elapsed time, explicit errors/limits, and a schema/example browser. See
[SQL reporting](sql-reporting.md) for all columns, observation/virtual-connection
keys, timestamp semantics, read-only enforcement, and the 5-second / 1,000-row /
1-MiB limits. Native SQL results, error/limit states and cancellation are covered
in the existing disposable Windows Tools regression suite.
The SQL lifecycle check opens the collapsed navigation pane at narrow widths
before switching pages and waits for its fixture app to exit before deleting
the isolated inventory. Original assertion errors and secondary cleanup errors
are reported separately. Desktop-free polling, navigation and process-cleanup
regressions run with `pwsh -File tests\SqlEditor.Script.Tests.ps1`.

## Test

Devices and Sidebar regression entry points load focused definitions and
scenario modules from `tests\UiRegression`. `coverage.json` records the immutable
pre-migration revision, original source ranges, function/assertion/capture
mapping and scenario order. Unchanged bodies and representative Devices fixture
data are signature-checked; explicitly listed readiness/lifecycle/setup changes
are covered by desktop-free regressions. This structural inventory supplements,
and does not replace, real native acceptance.
For intentional changes to mapped coverage, retain the original provenance,
explain the refactor in the inventory and add focused behavioral checks; do not
replace baseline signatures merely to hide lost assertions or captures.

```powershell
pwsh -NoProfile -File tests\UiRegression.Helpers.Tests.ps1
powershell.exe -NoProfile -File tests\UiRegression.Helpers.Tests.ps1
```

This check does not launch or automate the desktop. It exercises bounded waits,
stale-owner reacquisition, visible/nonempty controls, process exit/normal/forced
cleanup, isolated fixtures, environment restoration and failure-preserving
capture timing. Migrated native suites create unique temporary fixture
directories and restore their environment/DPI context even if shutdown fails.
Forced shutdown cleans up the supplied PID but fails the suite rather than
pretending normal close succeeded.
Devices' XAML grid does not expose a `DevicesPage` automation peer. Lookup uses
the real `TableViewport`/`SettingsPage` containers; peer-less Devices chrome is
scoped to `MainNavigation` and guarded by a visible, nonempty `DevicesHeading`
page marker. This also works when narrow/overlay navigation items are not
realized. Shell/popup lookup remains separate. Do not infer UIA container
existence from a XAML name or namescope.

Each native scenario emits a setup/behavior phase and every Devices/Sidebar
capture emits a capture phase, with UTC start, elapsed milliseconds and success
in `phases.jsonl` alongside screenshots/transcripts and in the job summary.
Compare repeated runs with the same revision/build provenance, viewport and
selected scenarios against an equivalent baseline; retain failed phases and
report missing evidence. No statistically established flake rate is claimed.
The required aggregate and independently restored Activity/observation coverage are unchanged.

Devices regression runs its behavior modules in three independent groups
(#279), declared in `tests\UiRegression\Devices.Groups.psd1`. Each group is a
separate `ui-regression` matrix job running in parallel on its own disposable
runner:
- `devices-presentation`: Overview, Layout, Appearance and Interaction
- `devices-filters-previews`: Filters, Refinements and Previews
- `devices-columns-sorting`: Columns and Sorting

Each group runs in its own scope. It creates its own fixture, launches its own
app, then runs `Setup` and a `Ready` precondition, which opens the Devices page
at 1280 DIPs with the 80-device fixture listed. Modules within a group keep
their original relative order and shared state. Table settings, people and rooms
are in memory in UI-review mode, so no state carries from one group to the next.

Phases are named `Devices/<group>/<module>`. A failed group saves
`devices-failure-<group>` diagnostics, always cleans up and restores its
environment, and does not stop later groups. The script then fails with an
error that names every failed group.
`Invoke-UiRegression.ps1 -Suite devices` and the default
`DevicesList.Ui.Tests.ps1 -Group All` still run every group in sequence;
Native validation Full mode uses this. The desktop-free foundation check verifies
that:
- the groups cover every original module exactly once, in order
- each group's state stays isolated
- later groups still run after a failure
- each group cleans up and restores its environment

Separate runners shorten the Devices critical path but add per-runner setup,
app launch and billed minutes.

Screenshot publication consumes the capture job's uploaded artifact ID rather
than reconstructing its attempt-specific name. Failed-only publication reruns
therefore reuse the successful capture producer's artifact, even when that
producer ran in an earlier attempt. Missing or expired artifacts still fail
publication; no other run or revision is used as a fallback.

Sidebar and Tools use the same group runner (#314). CI and independent Full
validation dispatch these groups on distinct disposable Windows workers against
one published payload:

| Suite/group | Original behavior modules/checks, in order |
| --- | --- |
| `sidebar-presentation` | Navigation, Settings, Appearance, Responsive |
| `sidebar-scan-flows` | Refresh, Progress, PeopleRooms |
| `sidebar-preferences-scheduling` | Persistence, Scheduled |
| `tools-utilities` | BuildIdentity.Ui, NetworkTroubleshooting.Ui, FingImport.Ui |
| `tools-device-data` | AdditionalServices.Ui, SqlEditor.Ui |

This is the assertion/capture ownership boundary: each original behavior module
or check runs exactly once, unchanged, including its keyboard/accessibility,
theme/responsive, error, persistence and lifecycle assertions. Sidebar keeps the
scan-to-PeopleRooms inventory dependency within one group, Settings-to-Appearance
state within presentation, and restart preference/schedule checks together.
Every Sidebar group has its own synthetic paths, app launch and bounded
`Setup`/`Ready`; no group consumes another's files. Existing Tools checks already
own their synthetic fixtures, app launch/readiness and bounded cleanup, so they
need no duplicated common launch. Their scenario wrappers preserve all original
parameters and capture subdirectories.

Definitions live in `tests\UiRegression\Sidebar.Groups.psd1` and
`Tools.Groups.psd1`. `SidebarNavigation.Tests.ps1 -Group All`,
`Tools.Ui.Tests.ps1 -Group All` and dispatcher suites `sidebar`/`tools` retain
full sequential coverage. Failed groups retain distinct partial diagnostics and
later independent groups still run; the overall invocation fails. Phase logs
include `<suite>/<group>/<module>` and cleanup, including environment restoration.
The existing fail-fast-disabled matrix and fail-closed aggregate remain in
force; missing/failed/cancelled applicable matrix work cannot pass.

The pre-split baseline is current main
`af5bb73e8fffe6b38b3ba7a3cda3b1e954d9247e`,
[run 42920807580, attempt 1](https://github.com/iricigor/fingvibe/actions/runs/42920807580/attempts/1):
Sidebar 345s complete / 321s execution, 74 captures; Tools 264s / 232s,
60 captures. Measured Sidebar presentation was about 163s, scan flows 89s and
preference/schedule behavior 62s before independent setup; Tools utilities 90s
and device data 142s. These measured state-cohesive boundaries leave headroom
below the 240s complete-job design target without reducing fixtures or timing
checks. They are not predicted acceptance results: compare repeated final-source
native jobs, capture inventories, setup/download/cleanup and aggregate runner
consumption with this baseline, keeping queue time and pipeline critical path
separate. See #314 for the fresh Devices prerequisite and delivered measurements.

Device Details regression follows the #262 Overview/History tab boundary
across four independent matrix jobs (#292): `details-summary`
(`DeviceScanHistory.Ui -SummaryOnly`), `details-identity` (`DeviceDiscovery.Ui`,
`UsageCategory.Ui`), `details-observations` (`DeviceScanHistory.Ui -ObservationsOnly`)
and `details-activity` (`DeviceActivity.Ui`). Each job launches its own fixtures and app
instances, is selected by the `DeviceDetails` or `DeviceHistory` capture-plan scenario, and must
dispatch at least one check. `details-identity` also runs the Network page's
`NetworkActivity.Ui` when the `Network` scenario is selected, using that job's
budget headroom. Checks within a script still share sequential
fixture state. History, discovery and usage checks also write
`call-costs.json`: per-phase calls and inclusive/exclusive milliseconds for
lookup, positioning, wait, launch, close and scan categories. Exclusive time
removes nested measured calls, so positioning/wait exclusive time is property
reads, scrolling and polling sleeps. A failure in these checks captures a
failure screenshot, records the open phase as failed, and cleanup errors never
replace the original failure.

Epic Developer must inspect and report the complete GitHub Actions job duration
for every applicable UI-regression job discovered from current workflows and
scenario-selection evidence, including future matrix entries and newly added
regression jobs, not a fixed list of names. Record the current head, run/job
identity, status, setup-inclusive duration and affected-UI rationale from the
diff and coverage, including shared UI changes.
The user-approved budget is at most 240 seconds per job. A job exceeding that
budget must be fixed and revalidated when the implementation modifies the UI it
covers, even if the job was already slow. Jobs at or below the budget, or covering
unchanged UI, require no duration-related remediation. Failing checks still
require repair; missing/failed/skipped/cancelled results are not passing evidence.
Preserve coverage and deliberate timing checks, and surface material scope
blockers rather than waiving the budget. This agent instruction does not add a
CI timeout, matrix job or automatic merge gate.

Dispatcher checks this evidence before routing repair/finalize, even when CI
is green. Over-budget affected jobs share the three-attempt automatic repair
allowance per claim with failed checks/reviews, as approved in #285: targeted
fix, root-cause reassessment, then evidence-backed alternative. Each repair
requires fresh applicable validation; the counter does not reset per job or
revision. Block if the allowance is exhausted or repair is out of scope;
pending or unavailable evidence cannot authorize finalization. Developer's non-coding finalizer
independently checks the rule before its head-bound merge and returns blocked
if repair is needed. Bounded implement/repair runs report affected-job evidence
or pending expectations without waiting for CI. Dispatcher does not merge.
Justified policy-based skips retain their applicability evidence; a skipped job
is not proof that the budget was met.

Follow [the native UI contribution contract](../CONTRIBUTING.md#extending-native-ui-regression-coverage)
for new features: focused scenarios, current-selection readiness, stable
automation IDs/namescopes, isolated representative data, keyboard/accessibility
and rendered/virtualized reachability. Large-data correctness/resource budgets
belong primarily in WinUI-free tests, with native integration still required.
Agree budgets before implementation, preserve intentional elapsed-time checks,
and investigate failures instead of hiding them. Enforced PR coverage
manifests are not delivered by this foundation (#256).
Independent execution modes below do not change those review requirements.

### Independent native validation

`native-comparison.yml` automatically runs an **observational** baseline on
relevant trusted same-repository PR updates, including drafts. Fork and
untrusted-author native execution retain the existing restrictions. It checks
out the exact PR head, publishes one separate Test payload, and uses that same
revision for the feature suites and recorded build identity. The immutable
workflow revision supplies the new execution harness; both source and harness
revisions are recorded so a historical application is not misrepresented as a
new build. Full feature suites, catalog/navigation and non-UI tests come from
the selected source revision. It never consumes
an artifact from a different run or feeds `ui-ux-review`, publishes PR comments,
changes protection, or replaces any authoritative core/script/build/installer,
security, capture, navigation or native requirement. Do not configure its
independent result as a required merge check.

The baseline reuses existing launch, loopback scan, text filtering/reset and
selected-device details checks. It captures Devices, the empty filtered state
and DeviceDetails. Refresh/cancellation, summary navigation, all-page navigation,
assignments, themes/high contrast, layout, scrolling and exhaustive behavior
matrices are omitted, not proven by a passing baseline. Its **60-90-second native
execution target** excludes runner provisioning, checkout, payload/desktop setup,
application build and focused checks; actual timings must be compared, not
assumed. Existing/default PR smoke execution retains all its assertions.

`native-full.yml` automatically requests full validation on every push to
`main`, including merges, and retains manual dispatch without PR metadata.
Automatic runs validate the triggering commit SHA, not a later moving branch
tip; manual runs resolve `main` once before execution. Automatic triggering
starts when the workflow reaches `main`; feature-branch pushes, tags and PR
events do not trigger this standalone workflow. The reusable implementation
forces every catalog capture and all
currently enabled sidebar, Devices, Device Details summary/identity/history and Tools/build
identity suites, plus screenshot-helper, core, speed-test bridge, script,
installer lifecycle, secret and critical dependency checks. It does not inherit
a PR diff that could omit history/discovery. Each native suite has its own
disposable runner and diagnostics; suites within one runner remain sequential,
sidebar retains Windows PowerShell, and matrix fail-fast is disabled.

Full means exhaustive **currently runnable** coverage, not restoration:
Activity and the observation table disabled under #271 remain dormant on
revisions where they are disabled. Their retained tests and assertions are not
deleted. The shared dispatch must include Activity again after #273 is
integrated; the observation table remains #274's separate responsibility.
Do not count closure of abandoned #263 as delivered optimization or revive
its unmerged traversal changes.

For pre-merge evidence, manually dispatch **Native validation comparison
(observational)** on the candidate branch with `mode: Full`. This is explicitly
a candidate rehearsal, not evidence that `main` has that revision. The
production standalone workflow always targets a `main` revision. The optional manual
comparison `revision` input can select `main` or a historical same-repository
commit, using the candidate's immutable execution harness. This permits full
`main` and representative historical baseline evidence before merging the new
workflow, without fabricating source provenance. PR-triggered comparison
always uses its head SHA, ignoring the manual revision input. No PR number is
required for manual runs and there are no merge/release/repair/issue side effects.

Automatic execution is **event-driven**, not nightly: no clock-based schedule
is configured. Results and failures appear under **Actions > Full native
validation (main)**, with the existing final result, logs and artifacts.
Personal email/web notification delivery follows each user's GitHub Actions
notification preferences; no external notification integration is added.
A clock-based schedule still requires a separate cadence/time (UTC) and
notification decision. No local Automation or working-desktop automation is
enabled, and the full workflow neither waits for nor gates the release workflow.

Comparison concurrency uses `native-comparison-<PR>` and may cancel only
superseded comparison runs. Manual rehearsal groups additionally distinguish
branch, mode and source revision, so historical comparisons cannot cancel a
different source or full rehearsal. Standalone full concurrency uses
`native-full-main-<repository>` with cancellation disabled; it is independent
of both comparison and authoritative PR validation. Actions still controls
runner availability and pending-run queuing: an active full run is not cancelled,
but a newer request can replace an older pending request in the same group.
These are not desktop locks.
All new workflows have read-only contents permissions, do not inherit secrets,
and disable checkout credential persistence.

Each run retains per-suite screenshots, capture plan, transcript, execution JSON,
failure captures where available, partial diagnostics and timings for 14 days.
Execution JSON includes source revision, PR number (zero for standalone/rehearsal),
run/attempt, mode, suite, selected scenarios, result and elapsed seconds.
Build and payload/desktop setup are reported separately; full-job durations,
including provisioning/checkout and cleanup, come from Actions job timestamps.
Required missing/failed/cancelled/skipped stages fail the independent final
result; baseline deliberately omits full non-UI/installer stages. Cancellation
can prevent remaining cleanup/artifact steps, so missing diagnostics are not
success evidence.

Compare the same source revision's independent result with authoritative
checks for representative filter/details, restoration/scan and shared-layout
changes. Record run/job identity, full-job and execution durations, failures,
omitted coverage and artifact links. Failures found only by exhaustive checks
are baseline omissions, not baseline successes covering those behaviors.
No comparison evidence authorizes #256's separately approved gate cutover.

The following commands are for a chosen isolated interactive Windows test
environment or disposable CI runner, **not the user's working desktop**:

```powershell
.\.github\scripts\Invoke-NativeValidation.ps1 -Mode Baseline -Suite capture `
  -AppPath artifacts\app\FingVibe.App.exe -ScreenshotDirectory artifacts\baseline
.\.github\scripts\Invoke-NativeValidation.ps1 -Mode Focused -Suite details-summary `
  -AppPath artifacts\app\FingVibe.App.exe -ScreenshotDirectory artifacts\details-summary
.\.github\scripts\Invoke-NativeValidation.ps1 -Mode Focused -Suite capture `
  -Scenarios DeviceDetails,Settings -AppPath artifacts\app\FingVibe.App.exe `
  -ScreenshotDirectory artifacts\focused
# Run each suite once with Full; the Actions workflow also runs non-UI/installer checks.
.\.github\scripts\Invoke-NativeValidation.ps1 -Mode Full -Suite capture `
  -AppPath artifacts\app\FingVibe.App.exe -ScreenshotDirectory artifacts\full-capture
```

Desktop-free execution/dispatch/trust/result contracts are exercised through
`tests\PrValidation.Tests.ps1`, which includes `tests\NativeValidation.Tests.ps1`.

```powershell
dotnet test tests\FingVibe.Core.Tests\FingVibe.Core.Tests.csproj
```

The analytics F1.7 resource test is opt-in because it creates and removes an
isolated approximately 4.6 GiB SQLite fixture in the system temporary directory:

```powershell
$env:FINGVIBE_ANALYTICS_BENCHMARK = '1'
dotnet test tests\FingVibe.Core.Tests\FingVibe.Core.Tests.csproj --configuration Release `
    --filter FullyQualifiedName~AnalyticsEvidenceBenchmark --logger "console;verbosity=detailed"
Remove-Item Env:\FINGVIBE_ANALYTICS_BENCHMARK
```

Run on Windows SSD hardware with at least four logical cores, 16 GiB RAM and
sufficient temporary disk space. The reproducible generator retains 1,000 logical
devices (900 ordinary and 100 virtual, plus their 100 associated MACs), 10 million
device observations and 100,000 scan records across three networks sharing one
subnet. Scan instants are 864 seconds apart over 1,000 days. Each identity has
10,000 rows, 20% negative and 2% unlinked legacy; selected network 0 has 400
logical identities and 130,800/28,800 rows in the selected 30/7-date windows.
Equipment selects 50 of these identities. The exact generator, counts, first-query
result, 20 warm samples after warmup, nearest-rank p95, managed allocations and
process RSS are printed. First-query measurements do not force an OS cache flush.
Additional managed allocation is a conservative total-allocation ceiling, not
process RSS or a claim that native SQLite memory is managed.

The benchmark includes production aligned `DeviceActivity` buckets (and
single-device weekday grouping), the complete Network page query, current
metadata/category filtering and count presentation, the complete Person
equipment query/count/indicator/category presentation for 50 current assignments,
as well as the production
`DeviceUsageClassifier` over all selected devices' seven-date evidence. It enforces
p95 at most 1 second for one device and 2 seconds each for network, equipment and
all selected-device classification evidence; at most 128 MiB additional managed
allocation; and at most 250 ms cancellation including subsequent exclusive-lock
acquisition to verify resource release. Deterministic `AnalyticsEvidenceTests`
run normally and cover shape, zero/unknown/partial, legacy/imported/virtual
evidence, restart/rollback, network isolation, local calendar/DST, stale
revisions and cancellation/contention without touching the working inventory.
`DeviceUsageCategoryTests` additionally covers exact rule boundaries, display
rounding, missing comparators, limited evidence, overnight/weekend/DST behavior,
durable normal/virtual overrides, migration, conflicts, failed drafts and table
integration.

`DeviceActivityTests` covers every hour stop, response-wins/known-zero/unknown,
weekday denominators, explicit legacy evidence, identity union, first-sighting
eligibility, exact time boundaries, DST and cancellation. The disposable Windows
`details-activity` suite invokes
`tests\DeviceActivity.Ui.Tests.ps1` with an isolated
synthetic inventory, exercising all modes/stops, cell keyboard details,
loading/error/no-history states, selection changes, narrow scrolling, themes,
high contrast and access to the retained history summary while leaving
completed observations independently collapsed. It waits for Activity's observable state for each
selection and request, then asserts the rendered grid once, and checks that
identified Activity controls keep their UI Automation peers while loading, after
an error and after Retry. `AsyncSurfaceSessionTests` prove cancellation,
replacement, stale completion, render-before-Ready and Retry without WinUI. It refuses to run on the working
desktop. After the Release Core build,
`pwsh -File tests\DeviceActivity.Script.Tests.ps1` verifies its fixture through
the actual migration/query/grouping path, including real SQLite contention and
successful retry, without launching the app.

The native loading/cancellation fixture uses `FINGVIBE_UI_REVIEW_ACTIVITY_HOLD`
only with UI-review mode and an explicit fixture inventory. A bounded loader
hold records individual starts, cancellations and releases in the isolated
fixture; it never changes the database reader's 100-ms busy policy. This lets
period/device/group/navigation/close checks observe pending work without
mistaking an expired exclusive SQLite lock for a loading state. Real database
contention and stale revisions still exercise explicit errors, and Retry after
releasing contention must restore the current selection. Native phase timings,
partial failure captures and hold records are retained in the suite diagnostics.
Cancellation recording also covers synchronous continuation disposal, so a
cancelled hold cannot lose its marker or release a replacement query.
Activity, retained-summary and Devices Settings positioning share bounded,
geometry-based scrolling rather than exhaustive percentage sweeps. Offscreen
UI Automation elements can have empty bounds; the helper discovers those targets
with at most eight coarse viewport moves before measuring them. Scrollable
content peers can report the full content extent as their bounds, so positioning
uses the intersection with the window as the rendered viewport. Completion
requires every target's rendered bounds inside that viewport; even one pixel of
clipping is not. Positioning logs report adjustments and elapsed time without
replacing full-job duration evidence or removing intentional hover/appearance
waits.

The disposable Windows `details-identity` regression suite also runs
`tests\UsageCategory.Ui.Tests.ps1`. It uses isolated inventory/snapshot/table fixtures
and review network identity to exercise automatic/unavailable/no-evidence states, separate Save/Cancel,
restart persistence, retained failed-save drafts, concurrent reload, unrelated
metadata preservation, keyboard controls, narrow layouts, light/dark themes and
high contrast. It refuses to run outside GitHub Actions; do not automate the
working desktop or real saved inventory for these checks.
After the Release Core build, `pwsh -File tests\UsageCategory.Script.Tests.ps1`
checks the native test's checkbox dispatch, scroll-before-read assertions that
stay inside the physical window, waits for the requested device row and for the
Settings navigation to return after a resize, failure diagnostics and exact
synthetic JSON migration/query/classifier fixture without launching an app or
automating the desktop.

On an interactive Windows desktop at least 1024 logical pixels wide, run the native sidebar regression checks against a built application:

```powershell
powershell.exe -NoProfile -File tests\SidebarNavigation.Tests.ps1 `
    -AppPath "<absolute path to FingVibe.App.exe>" `
    -ScreenshotDirectory "$env:TEMP\FingVibe-sidebar-review"
```

These checks use Windows UI Automation without WinAppDriver or Developer Mode. They launch a separate app in deterministic UI-review mode, verify page routing and expanded/compact/overlay navigation, compare solid sidebar/page background pixels in all six themes, and save full-window captures for each backdrop. They also verify responsive Settings, mode/theme mapping, column visibility/reset, retained devices during refresh/cancellation, filtered counts, and non-overlapping device filters at wide and narrow widths, restoring the original scan snapshot afterward. Settings checks acknowledge the non-release ribbon to compare the normal release viewport; build-identity checks independently cover its reserved space and acknowledgment. The expanded test adapts to the monitor width (up to 1280 logical pixels), with a maximum window height of 720 logical pixels; pass `-ExpandedWindowWidth 1024` to reproduce the hosted runner's 1024x720 viewport on a larger desktop. All layout assertions remain enabled. UI-review mode previews appearance changes without saving them. Verify Windows high contrast separately using the system accessibility settings.

`tests\DevicesList.Ui.Tests.ps1 -AppPath "<absolute path to FingVibe.App.exe>" -ScreenshotDirectory "<capture directory>" [-Group <presentation|filters-previews|columns-sorting|All>]` checks the separate inventory/results/duration hierarchy, expanding search, 140/210-DIP dropdown widths at normal text scaling, responsive filters down to 480-DIP windows, unrestricted/selected dropdown presentation, all four Status/Response visibility combinations, merged/separate layouts, denser rows, Name/Type hierarchy, keyboard resizing, six-theme stripes/header contrast, sorting/filtering, container recycling, and native interaction indicators. CI runs on a disposable 1920px desktop to cover widths through 1880 DIPs. It uses an isolated 80-device snapshot through `FINGVIBE_UI_REVIEW_SNAPSHOT`, which is honored only in UI-review mode, and deletes that fixture afterward without modifying the user's saved scan, table settings or appearance. CI retains its screenshots in the review artifact; do not run it on a working user's desktop.

The sidebar and primary-smoke refresh/cancellation tests each set an isolated `FINGVIBE_UI_REVIEW_SCAN_HOLD` file path. Only in UI-review mode, an existing file holds the scan before probing so retained results and disabled row interactions can be observed deterministically; cancellation remains live. The hold times out explicitly after 30 seconds. The sidebar suite may additionally supply a `.progress` sidecar with synthetic `Completed`/`Total` values. It verifies the real native indicator's value, painted filled thickness at 5% and 90%, single-position action, cancellation/focus cleanup and unclipped scan context at wide and 640-DIP widths in every theme. Extra 480-DIP cases retain native geometry/value/focus assertions without screenshots: the shared capture helper requires at least 640 physical pixels. On the disposable GitHub Actions desktop only, it also verifies static progress with Windows client-area animations disabled and high contrast enabled, restoring both settings in cleanup. These are rendering fixtures, not accelerated discovery; releasing the hold resets the fixture before real loopback probing. Each test removes its fixtures in cleanup, and normal scans never use them. The primary smoke test navigates to Devices before exercising its shared-header Scan LAN action.

For current-response/latency fixture checks, the Devices suite also sets
`FINGVIBE_UI_REVIEW_CURRENT_SNAPSHOT=1`. This is honored only with UI-review
mode and an explicit synthetic snapshot path; normal restored scans remain
historical. CI prepares a 1920x1080 disposable desktop to exercise both wide
and narrow viewports without clipping captures. No display settings are
changed by the application or by local build/test commands.

## Download builds

Local and pull request build/publish outputs retain only English (`en`) managed satellite resources through the application's `SatelliteResourceLanguages` setting. Neutral resources, including dependencies' default English strings, remain included. Official releases retain all available languages: the release workflow overrides the setting with an empty global MSBuild property (`/property:SatelliteResourceLanguages=`), disabling this filter. Both workflows use the Release configuration, so the configuration name alone does not determine language filtering. This does not force the runtime UI culture to English or filter Windows App SDK native/PRI resources in the self-contained deployment. When checking the result locally, start with clean build and publish output directories: previously copied language folders are not removed by changing this setting.

Pull requests affecting application code or validation infrastructure upload a `fingvibe-win-x64-pr-*` artifact from the **🔨 Pull request build** Actions run, plus a `fingvibe-setup-win-x64-pr-*` installer artifact. Each successful same-repository build posts a new runnable-app artifact-link comment, preserving earlier comments and links (artifacts expire after 14 days). Artifact names include the run attempt, so reruns do not replace earlier downloads. Documentation-only and ordinary test-only changes do not publish an app. Every push to `main` publishes a GitHub Release tagged `v1.1.<run number>` (version `1.1.<run number>`) with a self-contained Windows x64 ZIP and `FingVibe-<version>-win-x64-Setup.exe`, both from the same published binaries. Earlier releases used `1.0.<run number>`; the minor feature version orders above any 1.0 run number, so 1.0 installations update normally.

The unsigned Inno Setup installer supports Windows 11 x64 and installs only for
the current user at `%LOCALAPPDATA%\Programs\FingVibe`, without requesting
administrator rights. It adds a Start menu shortcut and a Windows **Installed
apps** entry; a desktop shortcut is optional. Windows may show an unknown
publisher or SmartScreen warning. No code signing or automatic updater is
included; download only builds you trust.

For manual updates, close FingVibe and run the newer installer. Setup refuses to
install or uninstall while FingVibe is running and rejects downgrades. Existing
files from the ZIP convenience script can be adopted in the same location.
Upgrades remove obsolete files recorded in the previous installer's ownership
manifest, not arbitrary directory contents. Unrecognized files from earlier
ZIP/script installations are retained, even if they appear obsolete.
Do not use the ZIP convenience script to update an installer-managed copy;
use Setup so version registration and file ownership remain consistent.

Uninstall through Windows **Installed apps**. Saved settings, inventory, and
other user data in `%LOCALAPPDATA%\FingVibe` remain, as do unknown files in the
installation directory. ZIP and installed copies share this per-user data;
installation does not create an isolated profile.

Contributor packaging uses Inno Setup 6 (`ISCC.exe`, preinstalled on the Windows
GitHub runners). After publishing the app, run:

```powershell
.\tools\New-Installer.ps1 -AppDirectory artifacts\fingvibe-win-x64 `
    -Version 1.1.123 -OutputDirectory artifacts\installer
```

`tests\Installer.Script.Tests.ps1` checks packaging helpers without installing or
launching anything. `tests\Installer.Lifecycle.Tests.ps1` refuses to run outside a
disposable GitHub-hosted runner. PR and release builds compile the actual
installer and verify payload hashes, fresh installation, window launch,
running-app blocking, ZIP/script adoption, upgrade cleanup, downgrade rejection,
shortcuts, uninstall, and saved-data/unknown-file preservation. They also upgrade
a 1.0 installation whose run number is higher to the 1.1 feature version (the
actual release installer on `main`) and verify that synthetic saved inventory,
history, and settings files are unchanged and the 1.0 downgrade is rejected.
Test-only past and future version installers reuse the payload to exercise
upgrades; they are not published. Installer logs are retained as Actions
artifacts, including on failure.
Any installer failure blocks release publication.

Keep the extracted app files together: `Assets\Scanner.ico` supplies the running window's title-bar and taskbar icon. The executable also embeds the same icon for File Explorer.

## Pull request review gates

Pull requests expose two review checks:

- `security-review` scans the repository for exposed secrets and fails on critical dependency vulnerabilities.
- `ui-ux-review` launches the tested WinUI app, exercises the primary **Scan LAN** action, verifies critical accessible controls, and embeds fresh screenshots of Devices and the affected views/states on the pull request.

The **🔨 Pull request build** workflow runs core/script tests and one Windows publish concurrently after change planning. Build and core tests cache NuGet packages with a shared Windows/dependency-configuration key and Windows-scoped fallback; normal restore still verifies/resolves required packages on hits and misses. Native `ui-capture` and the eight `ui-regression` matrix suites start once the build passes, without waiting for core tests. Installer validation still waits for both tests and build. These checks run on separate Windows runners in parallel. Every job downloads the same published payload; none rebuilds the app. The matrix separates sidebar/appearance, three independent Devices groups, three Device Details groups, and Tools/build identity. Suites remain sequential within each runner to avoid competing for focus and input. The sidebar retains Windows PowerShell; other suites retain PowerShell Core. UI-review mode is enabled only at runtime, so the downloaded app remains the normal executable.

`ui-capture` now runs only screenshot-helper validation, baseline scan/filter and cross-page smoke checks, and required captures. History/discovery and restored Activity retain their existing condition: they run when the capture plan includes DeviceDetails. Completed-observation table checks remain dormant for #274; summary/Last seen and other retained checks remain required. UI/test overlap does not waive any required result or move checks to a scheduled-only policy. Regression jobs have a 20-minute job limit and a 15-minute suite-step limit; capture has a 10-minute job limit and a 7-minute smoke-step limit. These outer bounds also stop otherwise unbounded native/process waits without changing the test fixtures. Each regression check and the smoke/capture step report elapsed seconds in logs and the job summary.

Each matrix suite uploads its own `fingvibe-ui-regression-<suite>-pr-*-attempt-*` artifact, including the capture plan, transcript, and available screenshots/diagnostics, even on failure. These replace the suite subdirectories previously bundled into the capture artifact. The existing `fingvibe-ui-review-pr-*` artifact contains the smoke/capture evidence. Matrix fail-fast is disabled so one failed suite does not cancel the others' diagnostics. Screenshot publication and the existing required `ui-ux-review` aggregate gate require successful capture, all regression matrix jobs, and existing installer/tests/build checks. Missing, failed, cancelled, or unexpectedly skipped required matrix results cannot pass. Separate runners shorten the sequential critical path but add startup/transfer overhead and may increase billed minutes; actual durations depend on runner availability.

Publishing uploads a short-lived `fingvibe-validation-payload-pr-*` transfer artifact (one-day retention), explicitly not a tested download. Publishing and native UI work may finish even if concurrent tests fail; their completion does not make the build a tested download or pass the final gate. UI overlap can consume runner time on a revision whose core tests fail. The installer job publishes the existing runnable-app and tested-installer downloads only after core tests and installer lifecycle checks pass; the build-link comment follows that job. Screenshot publication also waits for installer and UI validation to succeed. The required `ui-ux-review` gate aggregates tests, publishing, installer/download validation, native UI checks, and screenshot publication; failed, cancelled, or unexpectedly skipped required stages cannot pass. Separate jobs add runner startup and artifact-transfer overhead, so time savings depend on the run.

Superseded runs on the same PR are cancelled. Documentation-only changes skip tests/build/installer/capture, while ordinary test-only changes run the regression tests without publishing or launching the app. Changes to the interactive screenshot regression tests run the native UI path as well. Workflows still start for every PR, and the `ui-ux-review` gate reports intentional skips or prerequisite failures rather than leaving a required check pending. Security scanning remains independent and runs on every PR.

Manual runs of **🔨 Pull request build** force tests, build, and UI validation, including optional `additional_scenarios`. Read-only jobs execute tests, build, and UI automation without write permissions or persisted Git credentials. Separate publishing jobs receive only the content/comment writes they need. Fork and untrusted-contributor restrictions remain in place; Dependabot runs do not post comments.

CI, release, and security-review JavaScript actions use maintained Node.js 24
releases; this is their execution runtime, not a change to FingVibe's .NET 8 SDK.
They require Actions Runner 2.327.1 or newer, supplied by the existing hosted
Windows images. Artifact uploads remain zipped with the same names and retention;
downloads extract into the existing destinations and now fail on digest mismatch
rather than only warning. NuGet cache paths, dependency keys, and restore behavior
are unchanged. Action migrations must review upstream metadata and breaking
changes without opting into unsafe fork checkout or weakening artifact integrity.

The UI check runs on GitHub's `windows-2025` image and uses its preinstalled WinAppDriver to launch and automate the native application in dark theme. It also exercises overview-card navigation (including keyboard activation), clearing stale filters and enabling/disabling the visible open-port filter. It runs automatically only for same-repository pull requests from trusted collaborators; fork pull requests are not executed. The workflow sets `FINGVIBE_UI_REVIEW=1`, which confines the smoke-test scan to the single loopback host `127.0.0.1/32`, allowing real discovery and enrichment to finish before capturing the hosted-runner review.

Before exercising the UI, the capture script restores and centers the application window inside the monitor's working area, shrinking it only when the desktop cannot fit its initial size. It captures the complete native window (including its title bar and edges) directly from the screen using DPI-aware physical-pixel bounds rather than WinAppDriver's screenshot endpoint. Off-screen, minimized, undersized (below 640 x 480), unfocused, moving/resizing, or blank captures fail the check instead of publishing a clipped image. The workflow logs the original bounds, monitor working area, DPI, and final capture dimensions for diagnosis.

The Windows screenshot regression tests deliberately place a patterned window off-screen and then oversize it. They verify that capture rejects clipping, fits the window on-screen, and preserves all four corner markers in a PNG whose dimensions match the complete window. Run them on an interactive Windows desktop with `pwsh -File tests\UiReviewScreenshot.Tests.ps1`.

When UI review runs, the capture plan always includes **Devices** after its scan/filter smoke test. The PR's merge-base diff selects additional views: page-local XAML changes select that page; device-details and network-identity code select their respective views; results/filter/column changes include the empty-results state and Settings. Tools/speed-test changes select **Tools** and **Speed test**, so a change adding that feature produces exactly those two screenshots plus Devices. Navigation-menu changes are demonstrated in Devices instead of capturing every existing page. Shared window layout and theme/appearance changes still select all scenarios; other application/core and review-pipeline changes use the Devices baseline unless a page-specific rule applies. New views must have explicit capture/navigation rules rather than silently falling back to unrelated screenshots.

Navigation verification is independent of screenshot selection: every supported scenario is exercised, even when only Devices is captured. Existing scan/filter, overview navigation, People/Rooms suggestions, and assignment smoke tests remain enabled. Each capture verifies the selected navigation item and visible page-specific controls; required navigation or capture failures stop the review instead of silently showing the wrong page.

The workflow logs selection reasons and uploads the capture plan, completed manifest, and all PNGs together. Available partial captures, WinAppDriver output, startup/crash diagnostics, and the smoke-test transcript are retained on failure; a completed manifest is written only after all required checks pass. Its existing PR screenshot comment is updated with labeled images, without repeating the detailed file-by-file selection reasons. Security/UI failure comments are still updated and cleared when resolved; only build-artifact comments are append-only. Manual runs can request extra scenarios through the comma-separated `additional_scenarios` input: `Overview`, `Network`, `DeviceDetails`, `People`, `PersonDetails`, `Rooms`, `RoomDetails`, `Tools`, `SpeedTest`, `About`, `SqlEditor`, `Settings`, and `DevicesEmpty`. People and Rooms captures use in-memory review records instead of loading or changing saved user data. New pages or required states must be added to the scenario catalog, selection, navigation, and regression tests. Run the scenario regression tests with `pwsh -File tests\UiReviewScenarios.Tests.ps1`, and validation-planning/comment/gate regression tests with `pwsh -File tests\PrValidation.Tests.ps1`.

The workflow publishes screenshots to the `gh-pages` branch so the bot can embed the PNGs directly in its review comment. After the workflow creates that branch for the first time, open **Settings > Pages**, choose **Deploy from a branch**, select `gh-pages` and `/ (root)`, then save. Published image URLs use `https://<owner>.github.io/<repository>/ui-review/pr-<number>/run-<run-id>/<filename>.png`, keeping captures from different runs separate.

After both workflows have run at least once, configure them as required checks:

1. Open **Settings > Rules > Rulesets** and create or edit the branch ruleset for `main`.
2. Enable **Require status checks to pass**.
3. Add `security-review` and `ui-ux-review`.
4. Enable **Require branches to be up to date before merging**.

Do not merge when either check fails. A detected secret or critical vulnerability fails `security-review`; an app launch, rendering, screenshot, accessibility, or primary-interaction failure fails `ui-ux-review`.