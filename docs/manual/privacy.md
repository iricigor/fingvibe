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
| Network troubleshooting | Local checkpoints, public IP targets, and DNS resolvers | Ping/traceroute traffic and DNS queries for `example.com`. |
| Stable-release update checks and user-requested downloads | `api.github.com`, GitHub Releases and its asset CDN | Public source IP and ordinary HTTP headers; no LAN inventory or saved scans are sent. |
| Links opened from the app | Your external browser | Normal requests to the selected website. |

Public lookup and provider logos are optional displays. Missing configuration
or service failure does not prevent local scanning.
The speed test is manual and asks for confirmation before each run.
Troubleshooting probes start only when you choose **Run checks**.
Official stable builds check for updates automatically while open; downloads and
installation require your action. Development, PR and Test builds do not check
automatically. See [Check for updates](navigation.md#check-for-updates).

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
