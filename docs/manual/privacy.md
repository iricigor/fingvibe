# Privacy and network requests

FingVibe keeps its inventory, names, assignments, and saved scans on your PC.
Local discovery is not a cloud inventory upload.
Some features contact external services as explained below.

## Requests by feature

| Feature | Where requests go | Information involved |
| --- | --- | --- |
| LAN discovery and identification | Devices on the selected local network | Ping, fresh ARP, mDNS/DNS-SD and SSDP name/service discovery, and bounded service probes: 17 common TCP ports per responding device, plus TCP checks of up to 64 ports per scan that devices advertised for their own address. |
| Manual device service scans | Only the device selected in details | When you choose them: 193 additional TCP ports with optional single DNS/NTP UDP requests, or, after a warning, a full scan of all 65,535 TCP ports. Many connection attempts can trigger security monitoring on the device or network. |
| MAC vendor lookup | Official IEEE registries | Registry downloads, cached locally for 30 days. No inventory upload is needed. |
| Public IP/provider details | `ipwho.is` | Your public source IP; the service returns provider and approximate location information. |
| Configured provider logos | Logo.dev | Provider name and your public source IP, not LAN inventory or scan results. |
| Speed test | `speed.cloudflare.com` | Measurement traffic, public source IP, and default engine result reporting after per-run confirmation. |
| Network health diagnostics | Local checkpoints, public IP targets, and DNS resolvers | Ping/traceroute traffic and DNS queries for `example.com`. |
| Optional background network monitoring | Selected LAN gateway, `1.1.1.1`, `8.8.8.8`, Windows DNS, and public DNS resolvers; after a confirmed incident, also loopback, this PC's address and a traceroute toward `1.1.1.1` | Five one-second-spaced ICMP probes per target every 60 seconds plus DNS queries for `example.com`, and one automatic deeper check (at most 45 seconds) per confirmed incident. Raw check results stay in the app's live state; confirmed incidents and their deeper-check evidence are saved only in the local inventory database and never uploaded. |
| Service status provider reports | Official Microsoft Azure, AWS, Google, Cloudflare and GitHub status endpoints | Ordinary public GET requests for provider status data and your public source IP; no LAN inventory, selected adapter, credentials, local diagnostic results or monitoring history is sent. Results are held only in memory for five minutes. |
| Stable-release update checks and downloads | `api.github.com`, GitHub Releases and its asset CDN | Public source IP and ordinary HTTP headers; no LAN inventory or saved scans are sent. Verified installed stable builds can download Setup in the background on an unmetered connection. |
| Links opened from the app | Your external browser | Normal requests to the selected website. |

Public lookup and provider logos are optional displays. Missing configuration
or service failure does not prevent local scanning.
The speed test is manual and asks for confirmation before each run.
Manual Network health probes start only when you choose **Run diagnostics**.
Background monitoring is separately opt-in from Background activity Settings and
is off by default. The option discloses its targets and cadence before use.
Official stable builds check for updates automatically while open. Verified
installed copies can silently download and stage a confirmed Setup on an
unmetered connection; metered or unknown-cost connections and portable copies
do not background-download. Installation still requires your confirmation:
**Restart now** or **When I close**. Development, PR and Test builds do not check
or download updates automatically. See [Check for updates](navigation.md#check-for-updates).

## Understand public addresses

An internet service normally sees your connection's public source IP.
That may belong to a VPN or provider gateway rather than this PC's LAN address.
Approximate public-IP location is not a reliable physical location.

Windows controls routing for internet measurements. A selected LAN adapter
does not guarantee that a VPN is bypassed.

## Saved data

Your saved data can include device names, full MAC/IP addresses, people/room
names and notes, assignments, network identities, and observation times.
Treat the [data folder and backups](data.md) as private.

The app does not establish human presence, continuous uptime, or a physical
network map from these observations.
Keeping data local does not make a shared screenshot or backup harmless.

## Share screenshots safely

Before posting a screenshot or log:

1. Check every visible name, address, MAC, note, and hostname.
2. Remove or redact private values, including repeated values in diagrams.
3. Keep error text and build identity useful for diagnosis.
4. Say when values or results are sample data.

Do not post router credentials, provider credentials, connection strings,
private Fing workbooks, or a complete inventory database.
Use [Version and support](support.md) for a safe bug-report checklist.

The documentation website uses locally served fonts, scripts, search data,
screenshots, and icons. It includes no analytics configuration.
Following an external link still contacts that external website.
