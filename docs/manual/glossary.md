# Terms and icons

Use these short explanations when a network term or visual hint is unfamiliar.

## Network terms

| Term | Plain-English meaning |
| --- | --- |
| LAN | Local area network, such as equipment connected through your home router. |
| Adapter | A Windows network connection, such as Wi-Fi, Ethernet, or a virtual interface. |
| IPv4 / IP address | An address such as `192.168.1.20`. It can change and is not permanent device identity. |
| Subnet / prefix | A network range. `/24` indicates how much of the IPv4 address belongs to its network portion. |
| MAC address | A link-layer address, usually six bytes such as `02-00-00-00-00-01`. Some devices change it. |
| ARP | A local IPv4 address-resolution request. A fresh response can confirm a device without a ping reply. |
| ICMP / ping | A small network request that can measure a response; not every device answers. |
| Gateway | The router/address used to reach destinations outside the local subnet. |
| DNS | A service that resolves names, such as `example.com`, to addresses. |
| TCP / UDP | Two transport protocols used by services. Silent UDP results are inconclusive. |
| Port | A numbered service endpoint, such as TCP 443. An open port is not a security verdict. |
| ISP | Internet service provider. Public-IP lookup can identify a provider approximately. |
| WAN | The internet-facing side of a router or network. |
| VPN | A virtual private network; it can change Windows routing and visible addresses. |
| ms | Milliseconds, used for response delays. |
| Mbps | Megabits per second, used for internet bandwidth measurements. |
| Snapshot / checkpoint | Saved scan state. An incomplete checkpoint is not a completed scan. |
| SQLite / SQL | The local database format / language used to query saved data. |

## Visual hints

The website uses locally served SVG icons from the documentation theme.
They help scan a page but do not replace text.
The Windows app uses its own native glyphs.

| Visual | Meaning and limitation |
| --- | --- |
| <span aria-hidden="true">:material-radar:</span> Scan hint | Look for **Scan LAN**. The website glyph is not an app button. |
| <span aria-hidden="true">:material-filter-outline:</span> Funnel | Show or hide more filters. Hidden restrictions still apply. |
| <span aria-hidden="true">:material-content-copy:</span> Copy | Copy the associated value. Check privacy before sharing it. |
| <span aria-hidden="true">:material-pencil-outline:</span> Edit | Change the associated saved information. Read the page's save behavior. |
| <span aria-hidden="true">:material-account-outline:</span> Person | A manual equipment assignment, not proof of presence. |
| <span aria-hidden="true">:material-home-outline:</span> Room | A manual location label, not a physical location measurement. |
| Multiple-PC app icon | An inferred virtual identity; not necessarily a virtual machine. |
| Colored status dot | Supports Online/Offline/Unknown/Fing Only text. Color alone is not evidence. |
| Service app icon | An observed port/service. Hover for its number and name. |

**(likely)** signals uncertainty. **Unavailable** signals missing or unreadable
information. Neither should be replaced with an assumed fact.
