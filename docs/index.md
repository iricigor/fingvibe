# FingVibe user manual

**Discover your local network. Understand and organize your devices.**

FingVibe is a Windows 11 application. It scans your local network, shows devices
that respond, and helps you organize them by person and room.

You do not need programming knowledge to use this manual.
Start with [Install and update](manual/install.md), then follow
[Your first scan](manual/first-scan.md).

| What would you like to do? | Start here |
| --- | --- |
| <span aria-hidden="true">:material-download:</span> Get FingVibe | [Install, update, or remove the app](manual/install.md) |
| <span aria-hidden="true">:material-radar:</span> Find devices | [Run your first scan](manual/first-scan.md) |
| <span aria-hidden="true">:material-devices:</span> Understand a result | [Device status, filters, and icons](manual/devices.md) |
| <span aria-hidden="true">:material-account-group:</span> Organize equipment | [People and rooms](manual/people-rooms.md) |
| <span aria-hidden="true">:material-tools:</span> Check a connection | [Network health](manual/network-checks.md) |
| <span aria-hidden="true">:material-shield-lock:</span> Understand privacy | [Network requests and local data](manual/privacy.md) |

[![FingVibe Overview with a selected sample network and links to device results](screenshots/manual/overview.png)](screenshots/manual/overview.png)

*Native Windows screenshot with safe test data. It shows a test build, not a
real home network. [Screenshot sources](manual/screenshots.md).*

## What this manual describes

This manual was checked against release **v1.4.223** on **2026-11-20**
([source revision](https://github.com/iricigor/fingvibe/commit/abb11b9199e5672d2061588056181218669a7f87)).
It describes available behavior, not planned features.
Your version is shown in **Settings > About FingVibe & updates**.

Activity grids, scan observations, first/last-seen summaries and usage categories
are available. See [History](manual/history.md). You can also run
[SQL reports](manual/sql.md), review [new-device discoveries](manual/scheduled-scans.md#new-device-discoveries),
and inspect [virtual and linked identities](manual/devices.md#private-and-virtual-devices).

Select a screenshot to open it at full size. Screenshots may show a different
test-build number. [Screenshot sources](manual/screenshots.md) identifies each
capture's revision and visible state; sample values and test-only messages are
not instructions.

!!! warning "A scan is a sample, not continuous monitoring"
    Online means a device responded in its latest applicable scan evidence. Offline does not
    prove a device is turned off. An assigned device does not prove its owner
    is present. Only scan networks you own or have permission to inspect.

## Find help

Use the search box to find a term or task. On a small screen, open the menu,
choose a section, then choose a chapter. [Common problems](manual/problems.md) gives practical
checks before you report a bug.

Downloads, source code, and issue reports are available in the
[FingVibe repository](https://github.com/iricigor/fingvibe).
