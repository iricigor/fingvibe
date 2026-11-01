# Deferred ideas

Keep confirmed abandoned ideas here to avoid repeating investigations. Each entry states why we stopped and what would justify reconsideration. Recording is not approval to implement; see the [Architect workflow](../.github/agents/architect.agent.md).

## Table of contents

- [DI-001: Azure-hosted speed-test downloads](#di-001-azure-hosted-speed-test-downloads)
- [DI-002: Isolated local UI testing](#di-002-isolated-local-ui-testing)

## Entry template

Use the next unused `DI-NNN` identifier. Keep entries short; add references or dated decision updates only when useful.

```markdown
### DI-NNN: Descriptive idea title

**Status:** Deferred / Rejected | **Date:** YYYY-MM-DD

**Idea:** What was proposed.
**Stopped because:** The concrete blocker.
**Revisit only if:** What must change, or "None known".
```

## Entries

### DI-001: Azure-hosted speed-test downloads

**Status:** Deferred | **Date:** 2026-10-24

**Idea:** Download a payload from Azure Blob Storage as an additional speed test.

**Stopped because:** We cannot guarantee a hard spending cap. App limits, Azure budget alerts and SAS expiry do not cap total download costs.

**Revisit only if:** An enforceable cost cap becomes available, or the user explicitly relaxes that requirement.

**Context:** [#52](https://github.com/iricigor/fingvibe/issues/52), [#57](https://github.com/iricigor/fingvibe/pull/57). This decision does not abandon Cloudflare testing.

### DI-002: Isolated local UI testing

**Status:** Deferred | **Date:** 2026-11-01

**Idea:** Run native UI tests in a dedicated Windows VM instead of the user's working desktop, building locally and retrieving guest screenshots/logs afterward.

**Stopped because:** Local desktop automation interrupts the user's work by bringing windows forward, moving the pointer, clicking, and sending keyboard input. Isolation options were discussed, but no setup was chosen or authorized. Existing GitHub Actions UI checks are the preferred alternative.

**Revisit only if:** The user needs UI feedback before pushing and chooses to set up an isolated Windows test environment.

**Context:** Task View virtual desktops share the Windows session and input, so they are not reliable isolation. A separate Win32 desktop would require substantial adaptation; another user/RDP session can lose its usable display when locked or disconnected. Windows Sandbox is a disposable option; a persistent VM is preferred for repeatable local tests and must retain a logged-in, unlocked guest desktop with a usable display. VM networking differs from the physical LAN, so real discovery checks need deliberate networking configuration. Recording this decision does not configure a VM or change Copilot permissions or instructions. See [#118](https://github.com/iricigor/fingvibe/issues/118).
