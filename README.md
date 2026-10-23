# FingVibe

FingVibe is a native Windows 11 LAN scanner built with C# and WinUI 3. It detects active IPv4 network interfaces, shows the machine address and subnet, and probes every usable address concurrently.

## Features

- Native WinUI 3 desktop UI with no embedded web content
- Fixed left navigation with Overview, Network, Devices, People, Rooms, and Settings pages
- Overview page with the network name and online, offline, open-port, and last-scan summaries
- Automatic local IPv4 and CIDR discovery
- Overview subnet-size badge and Network details explaining every IPv4 prefix, address capacity, and private, public, or special-purpose scope
- ISP-based network identity with a Network page showing public and local addresses plus approximate public-IP location (or **Unknown**)
- Device details page opened by clicking a device in the Devices table
- Offline, evidence-backed OS and device-type detection with built-in Fluent icons and saved manual corrections
- Resizable Devices table columns and a Settings column selector (kept for the current session)
- Live appearance settings: Solid, Mica, Mica Alt, or Acrylic backdrops, plus Standard Light, Warm Light, Standard Dark, and True Black (OLED) themes
- Parallel ICMP scanning with up to 256 concurrent probes
- Device names from UPnP/SSDP, mDNS, reverse DNS, and NetBIOS
- MAC vendor lookup using locally cached IEEE registries, including private/randomized detection
- Bounded probes for common TCP services with compact Fluent port icons
- Live progress, cancellation, filtering, and sortable per-host results
- Compact results with subnet-aware IP emphasis, online/offline badges, and two-tone MAC addresses
- Numeric latency labels with green-to-red bars scaled across responding hosts (20% for fastest, 100% for slowest; equal times remain green at 20%)
- MAC address discovery for reachable devices when available
- Pull request build artifacts for Windows x64
- Automatically versioned GitHub Releases from `main`

## Run locally

Prerequisites:

- Windows 11
- .NET 8 SDK
- Visual Studio 2022 with the **Windows application development** workload, or the equivalent Windows SDK build tools

```powershell
dotnet restore FingVibe.sln
dotnet run --project src\FingVibe.App\FingVibe.App.csproj -p:Platform=x64
```

The scanner uses ICMP echo requests. Firewall rules and devices configured not to answer ICMP can cause an active host to appear unreachable. On first use, vendor detection downloads the official IEEE MA-L, MA-M, and MA-S registries and caches them under the current user's local application data for 30 days.

Without a saved theme preference, FingVibe starts with Standard Light or Standard Dark to match the Windows app mode. Appearance choices in **Settings** apply immediately and are saved to `%LOCALAPPDATA%\FingVibe\appearance.json` for the next launch; a saved theme, including Warm Light or True Black (OLED), takes precedence over Windows app mode. Ordinary Windows light/dark changes do not switch the theme while FingVibe is running. Unsupported backdrop materials fall back to a solid theme background without discarding your selection. Material rendering also follows Windows transparency settings; Windows high contrast takes precedence and uses system colors instead.

Public IP and ISP details are retrieved from `ipwho.is`. This optional display depends on internet access and sends the connection's public IP to that provider as part of the HTTPS request. LAN discovery and scanning continue to work when the lookup is unavailable.

The Overview network card shows A, B, or C for /8, /16, or /24 sizes; other sizes show their CIDR prefix. Network details explain all prefixes from /0 through /32, including class-size multiples/divisions and point-to-point or single-host networks. Counts below one million are exact; larger counts use M with two significant digits. Ordinary subnet counts exclude network/broadcast addresses, with a reserved suffix for /17 through /30; /31 assumes point-to-point use and /32 identifies one host. These capacity figures do not change the scanner's 65,534-address safety limit. Scope checks cover the whole subnet, distinguish private and special-purpose ranges (including APIPA/link-local), and flag mixed scopes. "Standard-size private" means a private /8, /16, or /24 subnet, not that other private prefix lengths are invalid.

Results dim complete network-prefix octets using the scanned subnet's CIDR; partially masked octets remain emphasized because they also identify hosts. Latency bars update as responses arrive and keep the same scale when filtering or sorting. Missing responses show a dash, not a performance bar. "Offline" means no ICMP response, not proof that a device is powered off. Select a row with the pointer or keyboard to highlight it; sorting preserves the selection. Hover over service icons for port numbers and service names.

The Devices toolbar has a Fluent inset **All / Alive** segmented switch, built with the Windows Community Toolkit `Segmented` control. A neutral recessed track surrounds a raised, softly rounded selected surface with blue accent text; the unselected option blends into the track. Colors adapt to light, dark, and Windows high-contrast themes. **All** is selected initially; **Alive** shows only online hosts. Both options combine with the text filter and apply to incoming scan results and saved results. Tab to the switch and use the Left/Right arrow keys to change the selection.

### Device identification

Devices show a native Segoe Fluent device icon beside their name. The **OS** and **Device type** columns can be sorted, resized, or hidden in Settings. Both detected and manually selected classifications are included in text filtering. Device details show the identification evidence and whether a value is user-selected. Unknown OS, device type, and vendor values use muted text in both the list and details.

Identification is best-effort and local. SSDP discovery uses the selected interface, and one shared multicast DNS-SD discovery window follows service announcements through SRV, TXT, and IPv4 address records to collect models without confusing proxy responses with the responding device. It listens for multicast replies as well as requested unicast replies. SSDP `SERVER` advertisements and bounded HTTP/SSH banner reads on already-open ports can identify OS-specific platform information. Merely running SSH, SMB, nginx, or Apache is not OS proof. The computer running the scanner is identified directly from its OS, and the selected interface's configured gateway is identified as a router.

Explicit device types/models outweigh service-only clues. When explicit evidence is absent, narrow product/manufacturer clues can suggest categories such as WD My Cloud/Synology/QNAP storage, Philips Lighting/Signify/Tuya smart devices, media devices, or game consoles. OS-specific discovered names, such as `Android-...`, are hints, not proof that the device is a phone. These inferred values are visibly marked **(likely)** in the list and details, with the supporting evidence shown in details. A generic TP-Link, Amazon, or Apple vendor, randomized MAC, or open SMB port alone does not determine an OS or device category. Conflicting or unsupported results remain **Unknown**; silent devices may still require manual correction. No fingerprinting cloud API is contacted; the existing vendor-registry downloads and optional public-network lookup are unchanged.

For otherwise unidentified SMB hosts, an observed ICMP response TTL of 127 or 128 together with open TCP 445 can suggest **Windows (likely)** and **Computer (likely)**. This is a combined heuristic, not definitive OS fingerprinting: it does not apply to known routers, NAS appliances, smart devices, or contradictory OS evidence. TTL alone, SMB alone, and Linux/macOS-style TTL values do not produce an OS guess.

Device details keep the OS, type, and icon visible above the network information and port-scan action. Expand **Identification evidence and corrections** below the network details to inspect the evidence, choose an operating system, device type, and/or a built-in icon, then select **Save identification**. **Automatic** restores detection for an individual field; **Use automatic detection** clears all three saved choices. The icon follows the effective device type unless an explicit icon is selected. Available types include Computer, Phone, Tablet, Router/access point, Printer, TV/media device, NAS/storage, Game console, IoT/smart device, and Unknown. Categories without reliable discovery evidence can be assigned manually; OS also offers Other.

Corrections are stored separately from automatic evidence in `%LOCALAPPDATA%\FingVibe\device-classifications.json`, keyed by MAC address, and apply after rescans, IP changes, and restarts. Saving requires a discovered MAC address. Private/randomized MACs may change and therefore lose their association with saved corrections. Load/save errors are shown in details; a failed load disables edits rather than overwriting existing corrections. Completed scan snapshots preserve automatic evidence and inferred-value markers. Older snapshots remain readable, but are not re-enriched when opening a new build: run **Scan LAN** again to collect current detection evidence.

## Test

```powershell
dotnet test tests\FingVibe.Core.Tests\FingVibe.Core.Tests.csproj
```

## Download builds

Every pull request uploads a `fingvibe-win-x64-pr-*` artifact from the **Actions** run. Every push to `main` publishes a GitHub Release tagged `v1.0.<run number>` with a self-contained Windows x64 ZIP.

## Pull request review gates

Pull requests run two independent review checks:

- `security-review` scans the repository for exposed secrets and fails on critical dependency vulnerabilities.
- `ui-ux-review` builds and launches the WinUI app, exercises the primary **Scan LAN** action, verifies critical accessible controls, and embeds fresh screenshots of Devices and the affected views/states on the pull request.

The UI check runs on GitHub's `windows-2025` image and uses its preinstalled WinAppDriver to launch and automate the native application in dark theme. It runs automatically only for same-repository pull requests from trusted collaborators; fork pull requests are not executed. The workflow sets `FINGVIBE_UI_REVIEW=1`, which confines the smoke-test scan to the local loopback network and keeps the hosted-runner review deterministic.

Before exercising the UI, the capture script restores and centers the application window inside the monitor's working area, shrinking it only when the desktop cannot fit its initial size. It captures the complete native window (including its title bar and edges) directly from the screen using DPI-aware physical-pixel bounds rather than WinAppDriver's screenshot endpoint. Off-screen, minimized, undersized (below 640 x 480), unfocused, moving/resizing, or blank captures fail the check instead of publishing a clipped image. The workflow logs the original bounds, monitor working area, DPI, and final capture dimensions for diagnosis.

The Windows screenshot regression tests deliberately place a patterned window off-screen and then oversize it. They verify that capture rejects clipping, fits the window on-screen, and preserves all four corner markers in a PNG whose dimensions match the complete window. Run them on an interactive Windows desktop with `pwsh -File tests\UiReviewScreenshot.Tests.ps1`.

The capture plan always includes **Devices** after its scan/filter smoke test. The PR's merge-base diff selects additional views: page-local XAML changes select that page; device-details and network-identity code select their respective views; results/filter/column changes include the empty-results state and Settings. Shared layout, other application/core changes, and review-pipeline changes conservatively select all supported scenarios. Nonvisual documentation/test-only changes keep just Devices. Each capture verifies the selected navigation item and visible page-specific controls; required navigation or capture failures stop the review instead of silently showing the wrong page.

The workflow logs selection reasons and uploads the capture plan, completed manifest, and all PNGs together. Its existing PR comment is updated with labeled images, without repeating the detailed file-by-file selection reasons. Manual runs can request extra scenarios through the comma-separated `additional_scenarios` input: `Overview`, `Network`, `DeviceDetails`, `People`, `Rooms`, `Settings`, and `DevicesEmpty`. New pages or required states must be added to the scenario catalog, selection, navigation, and regression tests. Run the scenario regression tests with `pwsh -File tests\UiReviewScenarios.Tests.ps1`.

The workflow publishes screenshots to the `gh-pages` branch so the bot can embed the PNGs directly in its review comment. After the workflow creates that branch for the first time, open **Settings > Pages**, choose **Deploy from a branch**, select `gh-pages` and `/ (root)`, then save. Published image URLs use `https://<owner>.github.io/<repository>/ui-review/pr-<number>/run-<run-id>/<filename>.png`, keeping captures from different runs separate.

After both workflows have run at least once, configure them as required checks:

1. Open **Settings > Rules > Rulesets** and create or edit the branch ruleset for `main`.
2. Enable **Require status checks to pass**.
3. Add `security-review` and `ui-ux-review`.
4. Enable **Require branches to be up to date before merging**.

Do not merge when either check fails. A detected secret or critical vulnerability fails `security-review`; an app launch, rendering, screenshot, accessibility, or primary-interaction failure fails `ui-ux-review`.