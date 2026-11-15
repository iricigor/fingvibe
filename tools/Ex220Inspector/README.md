# EX220 local inspector

Temporary standalone Windows tool for inspecting the TP-Link EX220 at
`http://192.168.0.1`. It does not reference FingVibe or open its database.
Requires .NET 8 Desktop Runtime and Microsoft Edge WebView2 Runtime.

```powershell
dotnet run --project tools\Ex220Inspector\Ex220Inspector.csproj
```

Focused checks:

```powershell
dotnet test tests\FingVibe.Core.Tests\FingVibe.Core.Tests.csproj --filter FullyQualifiedName~Ex220ClientCaptureTests
node --test tools\Ex220Inspector\ExtractClients.Tests.cjs
```

Log in **inside the tool**, not in chat. Open each page in the embedded router UI:

1. Advanced / Network: Client List.
2. Basic / Network Map: Wired Clients.
3. Advanced / Security / IP and MAC Binding: ARP Client List.

Choose the corresponding source above the results and click **Capture visible
table**. Captures accumulate by normalized MAC, so visit and capture every page
of a paginated table. After capturing all Wired Clients pages, check the
complete-list checkbox. Client List entries not in that complete list are then
marked Wireless. ARP-only entries stay Unknown; ARP evidence does not prove
current connectivity. ARP comparison is an IP cross-check, **not DB comparison**.
Clear captures before beginning a new snapshot; the three reads are not atomic.

This inspector reads rendered, visible HTML tables with MAC/IP column headings
rather than decrypting raw API responses. Ambiguous tables and malformed rows
produce an error rather than a partial success. Actual firmware compatibility
must be confirmed with a logged-in router. The source selection is your
confirmation of which table is open; the inspector does not guess it.

Only client name, MAC and IP are extracted into memory. There is no raw page,
traffic, credential, or client-data export. Password saving and autofill are
disabled. The browser uses a unique temporary profile, deleted after browser
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
