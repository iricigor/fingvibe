# EX220 local inspector

Temporary standalone Windows tool for inspecting the TP-Link EX220 at
`http://192.168.0.1`. It does not reference FingVibe or open its database.
Requires .NET 8 Desktop Runtime and Microsoft Edge WebView2 Runtime.

```powershell
dotnet run --project tools\Ex220Inspector\Ex220Inspector.csproj
```

Focused checks:

```powershell
dotnet test tests\FingVibe.Core.Tests\FingVibe.Core.Tests.csproj --filter "FullyQualifiedName~Ex220ClientCaptureTests|FullyQualifiedName~Ex220LoginSessionTests"
node --test tools\Ex220Inspector\ExtractClients.Tests.cjs tools\Ex220Inspector\RouterLogin.Tests.cjs
```

Log in **inside the tool**, not in chat. Its in-app login prompt appears when the
router's local password login form is detected. Enter the password in that
prompt and leave **Remember only until this inspector closes** checked to allow
one automatic re-login when a signed-in session expires. A rejected attempt or
15-second timeout clears the password and prompts again; there is no automatic
retry loop. **Forget password** clears it without logging out the current router
session. Restarting the inspector always requires a new password. Choosing
**Use router page** dismisses the prompt; passwords entered directly in the
router page are not remembered by the inspector.

**Sign in...** always opens the password panel. If the router is already signed
in, the panel offers **Remember password** for the next expired session without
sending a login request or logging out. If the login form is unavailable, the
panel explains that instead of appearing inactive.

**Forced refresh** stops loading, discards pending capture/login work, clears
cached page resources, reopens the router start page, and restarts login
detection. It keeps captures, remembered in-process credentials and cookies.
It does not log out explicitly or change router configuration. Return to the
desired table afterward. Script/cache operations have five-second waits;
recovery failures are reported instead of claiming success. If the browser
itself cannot recover, close and reopen the inspector (which clears password
memory). Pre-refresh completions cannot overwrite refreshed state.

Only the router's known local password login form is filled and submitted.
Username-required, cloud-login and password-setup forms are not automated.
No password is intentionally persisted to disk or uploaded to any external
service. It is held in process memory while remembered (ordinary strings, not
a promise of secure erasure or protection against memory inspection).

Open each page in the embedded router UI:

1. Advanced / Network / LAN Settings: Client List.
2. Basic / Network Map / Wired Clients: click Wired Clients to open its table.
3. Advanced / Security / IP and MAC Binding: ARP Client List.

Choose the corresponding source above the results and click **Capture visible
table**. Tables are matched to that source by the nearest section title above
them (or their caption), so co-visible wireless/binding lists are not mixed in.
A single unlabelled MAC/IP table is accepted for firmware compatibility;
unknown or duplicate matching titles fail explicitly. Captures accumulate by normalized MAC, so visit and capture every page
of a paginated table. After capturing all Wired Clients pages, check the
complete-list checkbox. Client List entries not in that complete list are then
marked Wireless. ARP-only entries stay Unknown; ARP evidence does not prove
current connectivity. ARP comparison is an IP cross-check, **not DB comparison**.
Clear captures before beginning a new snapshot; the three reads are not atomic.

This inspector reads rendered, visible HTML tables with MAC/IP column headings
rather than decrypting raw API responses. Ambiguous tables and malformed rows
produce an error rather than a partial success. The user confirmed Client List
capture on the actual EX220; title-based Wired/ARP capture and re-login still
require real-router confirmation. The source selection identifies the title to
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
