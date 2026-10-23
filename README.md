# FingVibe

FingVibe is a native Windows 11 LAN scanner built with C# and WinUI 3. It detects active IPv4 network interfaces, shows the machine address and subnet, and probes every usable address concurrently.

## Features

- Native WinUI 3 desktop UI with no embedded web content
- Fixed left navigation with Overview, Network, Devices, People, Rooms, and Settings pages
- Overview page with the network name and online, offline, open-port, and last-scan summaries
- Automatic local IPv4 and CIDR discovery
- ISP-based network identity with a Network page showing public and local addresses plus approximate public-IP location (or **Unknown**)
- Device details page opened by clicking a device in the Devices table
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

Results dim complete network-prefix octets using the scanned subnet's CIDR; partially masked octets remain emphasized because they also identify hosts. Latency bars update as responses arrive and keep the same scale when filtering or sorting. Missing responses show a dash, not a performance bar. "Offline" means no ICMP response, not proof that a device is powered off. Select a row with the pointer or keyboard to highlight it; sorting preserves the selection. Hover over service icons for port numbers and service names.

The Devices toolbar has a Fluent inset **All / Alive** segmented switch, built with the Windows Community Toolkit `Segmented` control. A neutral recessed track surrounds a raised, softly rounded selected surface with blue accent text; the unselected option blends into the track. Colors adapt to light, dark, and Windows high-contrast themes. **All** is selected initially; **Alive** shows only online hosts. Both options combine with the text filter and apply to incoming scan results and saved results. Tab to the switch and use the Left/Right arrow keys to change the selection.

## Test

```powershell
dotnet test tests\FingVibe.Core.Tests\FingVibe.Core.Tests.csproj
```

## Download builds

Every pull request uploads a `fingvibe-win-x64-pr-*` artifact from the **Actions** run. Every push to `main` publishes a GitHub Release tagged `v1.0.<run number>` with a self-contained Windows x64 ZIP.

## Pull request review gates

Pull requests run two independent review checks:

- `security-review` scans the repository for exposed secrets and fails on critical dependency vulnerabilities.
- `ui-ux-review` builds and launches the WinUI app, exercises the primary **Scan LAN** action, verifies critical accessible controls, and embeds the current screenshot on the pull request.

The UI check runs on GitHub's `windows-2025` image and uses its preinstalled WinAppDriver to launch and automate the native application in dark theme. It runs automatically only for same-repository pull requests from trusted collaborators; fork pull requests are not executed. The workflow sets `FINGVIBE_UI_REVIEW=1`, which confines the smoke-test scan to the local loopback network and keeps the hosted-runner review deterministic.

Before exercising the UI, the capture script restores and centers the application window inside the monitor's working area, shrinking it only when the desktop cannot fit its initial size. It captures the complete native window (including its title bar and edges) directly from the screen using DPI-aware physical-pixel bounds rather than WinAppDriver's screenshot endpoint. Off-screen, minimized, undersized (below 640 x 480), unfocused, moving/resizing, or blank captures fail the check instead of publishing a clipped image. The workflow logs the original bounds, monitor working area, DPI, and final capture dimensions for diagnosis.

The Windows screenshot regression tests deliberately place a patterned window off-screen and then oversize it. They verify that capture rejects clipping, fits the window on-screen, and preserves all four corner markers in a PNG whose dimensions match the complete window. Run them on an interactive Windows desktop with `pwsh -File tests\UiReviewScreenshot.Tests.ps1`.

The workflow publishes the latest screenshot for each pull request to the `gh-pages` branch so the bot can embed the PNG directly in its review comment. After the workflow creates that branch for the first time, open **Settings > Pages**, choose **Deploy from a branch**, select `gh-pages` and `/ (root)`, then save. The published image URL uses `https://<owner>.github.io/<repository>/ui-review/pr-<number>/fingvibe-ui-review.png`.

After both workflows have run at least once, configure them as required checks:

1. Open **Settings > Rules > Rulesets** and create or edit the branch ruleset for `main`.
2. Enable **Require status checks to pass**.
3. Add `security-review` and `ui-ux-review`.
4. Enable **Require branches to be up to date before merging**.

Do not merge when either check fails. A detected secret or critical vulnerability fails `security-review`; an app launch, rendering, screenshot, accessibility, or primary-interaction failure fails `ui-ux-review`.