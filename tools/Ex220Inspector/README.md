# EX220 local inspector

Temporary standalone Windows tool for inspecting the TP-Link EX220 at
`http://192.168.0.1`. It reuses FingVibe Core models but remains separate from
the application. Optional SQLite comparison is strictly read-only.
Requires .NET 8 Desktop Runtime and Microsoft Edge WebView2 Runtime.

```powershell
dotnet run --project tools\Ex220Inspector\Ex220Inspector.csproj
```

Focused checks:

```powershell
dotnet test tests\FingVibe.Core.Tests\FingVibe.Core.Tests.csproj --filter FullyQualifiedName~Ex220
node --test tools\Ex220Inspector\ExtractClients.Tests.cjs tools\Ex220Inspector\RouterLogin.Tests.cjs tools\Ex220Inspector\RouterNavigation.Tests.cjs
```

Log in **inside the tool**, not in chat. Its in-app login prompt appears when the
router's local password login form is detected. It occupies a separate panel
beside the browser, not an overlay that native WebView2 can cover. Enter the password in that
prompt and leave **Remember only until this inspector closes** checked to allow
one automatic re-login when a signed-in session expires. A rejected attempt or
15-second timeout clears the password and prompts again; there is no automatic
retry loop. **Forget password** clears it without logging out the current router
session. Restarting the inspector always requires a new password. Choosing
**Use router page** dismisses the prompt; passwords entered directly in the
router page are not remembered by the inspector.

**Sign in...** ensures a valid session: it keeps an already-signed-in session,
otherwise opens the local login entry when needed and fills/submits a remembered
password. Missing or rejected passwords prompt inside the inspector. The
operation waits at most two minutes for user login and can be cancelled.
**Password...** opens the password panel explicitly, including **Remember
password** while already signed in, without sending a request or logging out.

**Forced refresh** stops loading, discards pending capture/login work, clears
cached page resources, reopens the router start page, and restarts login
detection. It cancels automatic capture/sign-in and keeps the last completed
capture, remembered in-process credentials and cookies.
It does not log out explicitly or change router configuration. Return to the
desired table afterward. Script/cache operations have five-second waits;
recovery failures are reported instead of claiming success. If the browser
itself cannot recover, close and reopen the inspector (which clears password
memory). Pre-refresh completions cannot overwrite refreshed state.

Only the router's known local password login form is filled and submitted.
Submission sends the Enter key to that input, using the router's existing
Enter handler rather than its unreliable button-click path. Wired Clients
navigation uses its stable label to locate the PC icon's clickable link,
scrolls that link into view, and clicks it rather than a separate text label.
The changing client count is not used to identify the link.
Username-required, cloud-login and password-setup forms are not automated.
No password is intentionally persisted to disk or uploaded to any external
service. It is held in process memory while remembered (ordinary strings, not
a promise of secure erasure or protection against memory inspection).

**Capture Client List**, **Capture Wired Clients**, and **Capture ARP List**
sign in if needed and independently visit the selected list below, reading every
pagination page. A successful capture replaces only that source, removing stale
rows while retaining the other sources. Failure or cancellation keeps all prior
captures. A complete Wired Clients capture automatically verifies wired
completeness; Client List or ARP capture does not change that flag.
Independent captures can be from different times, not a simultaneous router
snapshot. Each success refreshes read-only DB comparison when selected.

**Capture all** remains available and visits all three:

1. Advanced / Network / LAN Settings: Client List.
2. Basic / Network Map / Wired Clients: click Wired Clients to open its table.
3. Advanced / Security / IP and MAC Binding: ARP Client List.

Automatic capture requires uniquely titled tables. It starts each list at page
1 and follows the TP-Link `table-bottom-pages` widget's selected-page marker and
next-page button through every page, including page numbers hidden behind
ellipses. Selected page, stable total page count, title and distinct page contents
are checked. A page transition must change the rendered client contents, and
reads require consecutive consistent observations. Missing/ambiguous controls, changed lists, logout, empty paginated pages
and timeouts fail explicitly. There is a 1,000-page-per-source safety limit;
exceeding it fails instead of silently truncating. Page readiness waits are
bounded to 15 seconds, and individual browser calls to five seconds.

Only after all three sources finish does the new capture replace the old one.
**Cancel**, errors and **Forced refresh** keep the previous completed snapshot.
Successful capture verifies Wired Clients completeness automatically. The reads
are not atomic router snapshots: changes between reads remain possible.

For manual inspection, choose a source and click **Capture visible table**.
Tables are matched to that source by the nearest section title above
them (or their caption), so co-visible wireless/binding lists are not mixed in.
A single unlabelled MAC/IP table is accepted for firmware compatibility;
unknown or duplicate matching titles fail explicitly. Captures accumulate by normalized MAC, so visit and capture every page
of a paginated table. After capturing all Wired Clients pages, check the
complete-list checkbox. Client List entries not in that complete list are then
marked Wireless. ARP-only entries stay Unknown; ARP evidence does not prove
current connectivity. ARP comparison is an IP cross-check, separate from DB comparison.
ARP can legitimately have multiple IPs for one MAC; these are retained and
shown as **Multiple ARP IPs**, not silently overwritten or rejected as paging
duplicates. ARP-only identities with multiple IPs have no single comparison IP.
Repeated whole pages still fail, and duplicate MACs in Client/Wired lists
remain an explicit error. ARP List is matched separately from Binding List;
Inspector automation never clicks Bind/Modify controls.
Clear captures before beginning a new snapshot; the three reads are not atomic.

Expand **FingVibe database (read-only)** to choose a SQLite file and its saved
network/subnet. The default file is
`%LOCALAPPDATA%\FingVibe\device-inventory.sqlite`. **Load DB** reads saved scopes;
only a single unambiguous scope is preselected. With multiple scopes, choose
the router's network explicitly. **Compare** refreshes matches, and completed
captures compare automatically when a baseline is selected.

Comparison matches normalized MACs and compares both router name and IP with
the displayed database name (custom name, imported name, discovered hostname,
or address fallback) and latest saved local IP for the selected network/subnet.
Active virtual devices use their displayed custom/automatic name and current
saved connection. Names ignore case and surrounding spaces; IPs compare as
addresses. Results show **Same in DB**, **Different in DB**, or **Not in DB**,
plus baseline name/IP and which fields differ. **Cannot compare** explicitly
marks missing names/IPs or ambiguous/historical virtual associations; another
network's or historical imported IP is never silently used as a local baseline.
Database failures remain visible, not **Not in DB**.

The comparer opens an existing file with `SqliteOpenMode.ReadOnly`, enables
`query_only`, uses bound parameters and a single deferred read transaction, and
applies cancellation/five-second query guards. It does not call FingVibe's
migration-capable inventory loader, create missing files, update schema, save
names, import clients or write inventory data. It reads only required device
entities in bounded batches; entities over the existing 8 MiB limit fail.

This inspector reads rendered, visible HTML tables with MAC/IP column headings
rather than decrypting raw API responses. Ambiguous tables and malformed rows
produce an error rather than a partial success. The user confirmed all three
manual captures on the actual EX220, and subsequently confirmed login plus
automatic Client List and ARP capture. The revised automatic Wired Clients
PC-link selection and session-expiry re-login still require confirmation.
The source selection identifies the title to
match, not an instruction to accept any MAC/IP table on the page.

Only client name, MAC and IP are extracted into memory. There is no raw page,
traffic, credential, or client-data export. Browser password saving and autofill
are disabled; optional inspector password memory is separate. The browser uses
a unique temporary profile, deleted after browser
shutdown on normal close; a cleanup failure is shown explicitly. A crash or
forced termination can leave a `FingVibe-Ex220-*` folder under your Windows temp
directory containing session cookies. Remove that specific folder after its
browser processes exit. Login credentials necessarily pass to the router itself;
HTTP at this address is not transport-encrypted.

Browser navigation and network requests are restricted to this router's normal
HTTP/HTTPS ports; downloads, popups and permissions are blocked. Certificate
errors are not bypassed. **The embedded router controls remain live**: do not
click configuration Save/Apply buttons. The inspector itself does not issue
configuration commands.
