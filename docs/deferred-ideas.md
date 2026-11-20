# Deferred ideas

Keep confirmed abandoned ideas here to avoid repeating investigations. Each entry states why we stopped and what would justify reconsideration. Recording is not approval to implement; see the [Architect workflow](../.github/agents/architect.agent.md).

## Table of contents

- [DI-001: Azure-hosted speed-test downloads](#di-001-azure-hosted-speed-test-downloads)
- [DI-002: Isolated local UI testing](#di-002-isolated-local-ui-testing)
- [DI-003: MSIX release packaging](#di-003-msix-release-packaging)
- [DI-004: One-time firewall setup for LAN discovery](#di-004-one-time-firewall-setup-for-lan-discovery)
- [DI-005: Decorative Connected home application backgrounds](#di-005-decorative-connected-home-application-backgrounds)
- [DI-006: Residual codebase optimization and restructuring](#di-006-residual-codebase-optimization-and-restructuring)
- [DI-007: Full-suite FlaUI/UIA3 comparison](#di-007-full-suite-flauiuia3-comparison)

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

### DI-003: MSIX release packaging

**Status:** Deferred | **Date:** 2026-11-04

**Idea:** Replace the release's unsigned, per-user Inno Setup installer with MSIX for Windows-managed installation, package replacement, Start menu registration, and removal. Retain the portable ZIP.

**Stopped because:** Changing package format alone does not solve publisher trust or SmartScreen warnings. Normal end-user MSIX installation requires a signed package whose certificate Windows trusts; self-signing would require users to establish certificate trust. No trusted signing/distribution route or migration plan has been chosen. MSIX would not automatically replace existing Inno installations, and package identity can affect filesystem behavior, so preserving saved data and avoiding duplicate installs/shortcuts require explicit verification.

**Revisit only if:** A trusted signing/distribution route is chosen (for example, trusted certificate signing for GitHub downloads or Microsoft Store distribution with Store signing) and migration/data-preservation requirements are agreed, or the user explicitly chooses to reconsider.

**Context:** The WinUI project enables MSIX tooling but explicitly builds unpackaged; adoption needs a package manifest, stable identity, assets, and updated packaging/lifecycle validation. Keep FingVibe a full-trust desktop app rather than converting it to sandboxed UWP, and verify packaged LAN discovery and diagnostics. MSIX package replacement does not by itself provide automatic updates from GitHub Releases; that needs a distribution mechanism such as an App Installer feed or the Store. When reconsidered, the recommended first stage is MSIX alongside Setup and ZIP, validating fresh install, upgrades, migration, settings/inventory/saved-scan preservation, uninstall behavior, and real LAN operation before retiring Inno Setup. If the goal is only publisher trust, signing the existing installer is the smaller alternative, not a guarantee of eliminating every SmartScreen warning. Recording this decision does not authorize packaging, signing, Store submission, or release changes. See [#162](https://github.com/iricigor/fingvibe/issues/162).

### DI-004: One-time firewall setup for LAN discovery

**Status:** Deferred | **Date:** 2026-11-06

**Idea:** Provide an explicit "Allow LAN discovery..." action that inspects firewall configuration for the running executable and network profile, explains the requested access, and requests UAC administrator approval for a small setup operation rather than elevating the scanner. Create or repair persistent rules restricted to the executable, Private networks, and required local-subnet discovery traffic; verify the result and report cancellation, failure, or policy restrictions.

**Stopped because:** Support for installed/fixed-folder copies versus changing PR-build folders and the exact mDNS/SSDP rule scope remain unresolved. Standard Windows Firewall program rules use the executable's full path, not its filename or display name; a filename-only allowance is not supported. A port-only rule would also permit other applications using that port and is not the recommended alternative.

**Revisit only if:** The target deployment scenarios are agreed and the necessary mDNS/SSDP permissions can be verified, or the user explicitly chooses to reconsider.

**Context:** A fixed-path installed copy normally needs one allowance for the selected network profiles, persisting across restarts and updates that retain the executable path. Moving/reinstalling to another path, using a profile not previously allowed, removal of rules, or administrator policy can require another allowance or prevent access. Repeated prompts for the same installed path and profile are unexpected and need investigation, not an assumption that repeated approval is normal. This is expected Windows behavior, not a verified diagnosis of the reported prompts.

The current mDNS listener uses UDP 5353 with an ephemeral-port fallback; SSDP uses a dynamically assigned UDP port. Opening only 5353 is not an established complete solution. Discovery timeouts or missing devices do not prove firewall blocking; inspect configuration, account for explicit block rules overriding allowances and managed policies restricting local exceptions, and verify effective access before claiming success. Recording this decision does not implement firewall setup or change security configuration. See [#180](https://github.com/iricigor/fingvibe/issues/180).

### DI-005: Decorative Connected home application backgrounds

**Status:** Rejected | **Date:** 2026-11-13

**Idea:** Place the full-color, full-detail Connected home artwork behind application page content, with very pale, dulled colors and 10-20% transparent container backgrounds while keeping text and controls opaque. Rooms and Overview PNG mockups explored the appearance.

**Stopped because:** The user chose to abandon the background idea because of its impact on UX regression testing. Existing appearance checks compare sidebar and page-background pixels; intentional decoration would require revisiting those assertions and validating readability across themes, window sizes, and high-contrast behavior. The additional validation and maintenance cost is an assessment, not an observed test failure: no application background was implemented or tested.

**Revisit only if:** The user explicitly chooses to reconsider the regression-testing impact.

**Context:** [#349](https://github.com/iricigor/fingvibe/issues/349). This rejects the background treatment and associated container transparency, not the separate Connected home application-icon and downscaling task [#348](https://github.com/iricigor/fingvibe/issues/348), which remains unchanged.

### DI-006: Residual codebase optimization and restructuring

**Status:** Rejected | **Date:** 2026-11-20

**Idea:** Pursue the residual candidates in [#275](https://github.com/iricigor/fingvibe/issues/275): initial history-loading/UI-thread redesign, concrete SQLite/history-interface cleanup, broad shell or shared-row restructuring, an application-logic test assembly, and standalone Full Devices parallelization.

**Stopped because:** After extracting the concrete Full-script isolation failure and measured inventory-presentation optimization, the user chose to abandon the remaining lower-priority work and resolve the review collection. The user reports generally good application responsiveness; no measured production benefit currently justifies the speculative refactors and their regression surface. Full Devices parallelization improves validation turnaround, not application responsiveness: its historical 354-second passing job remains evidence, but this optional follow-up is not a current priority. This decision does not establish that the recorded costs or boundary risks disappeared.

**Revisit only if:** A measured bottleneck or concrete maintenance/correctness defect justifies a bounded change, validation turnaround becomes a renewed priority, or the user explicitly requests reconsideration.

**Context:** Decision record [#646](https://github.com/iricigor/fingvibe/issues/646). Full-script isolation remains [#643](https://github.com/iricigor/fingvibe/issues/643); measure/optimize/remeasure inventory presentation remains [#645](https://github.com/iricigor/fingvibe/issues/645). Neither is abandoned or authorized for implementation by this entry. Regression-gate policy [#256](https://github.com/iricigor/fingvibe/issues/256) and the separately parked FlaUI experiment [#311](https://github.com/iricigor/fingvibe/issues/311) are unchanged. Preserve existing behavior, cancellation/error contracts, accessibility and million-row performance budgets; this rejects speculative projects, not those standards. Historical findings remain in #275.

**Later decision - 2026-11-20:** The user separately approved abandoning #311's unfinished expansion. Its parked disposition above is superseded by [DI-007](#di-007-full-suite-flauiuia3-comparison); the DI-006 scope and rationale are unchanged.

### DI-007: Full-suite FlaUI/UIA3 comparison

**Status:** Rejected | **Date:** 2026-11-20

**Idea:** Expand the original history comparison into a full native-suite FlaUI/UIA3 parity experiment and associated test-quality audit, as recorded in [#311](https://github.com/iricigor/fingvibe/issues/311).

**Stopped because:** The user approved abandoning the unfinished expansion after reviewing its evidence. The initial frozen-revision history comparison passed 30/30 trials per backend, with total medians of 5.299 seconds for PowerShell/UIA and 5.929 seconds for FlaUI/UIA3; it demonstrated no speed or reliability advantage. Different startup/lifecycle costs and the small local sample prevent an engine-level or general reliability verdict. The expanded prototype never established a successful end-to-end scenario: locked-desktop, WinAppDriver Developer Mode and clipboard-preservation blockers prevented meaningful full-suite results. Remaining parity and maintenance work has no demonstrated benefit to justify continuing now.

**Revisit only if:** A specific recurring harness problem justifies a focused, assertion-preserving comparison with a suitable disposable execution environment, or the user explicitly requests reconsideration. A framework migration requires separate evidence and approval.

**Context:** #311 is resolved as not planned for its unfinished scope, not completed parity or a successful audit. Preserve the completed initial measurements, diagnostic limitations and checkpoint [a85f13a4](https://github.com/iricigor/fingvibe/commit/a85f13a48e820ffe81b37a200b49c6fbc04a95ce) on `iricigor-improved-disco`; [PR #312](https://github.com/iricigor/fingvibe/pull/312) remains closed unmerged. The saved README and CSV retain the detailed protocol and results. No branch/artifact deletion, experiment resumption, production harness migration, native-coverage weakening or change to #256 is authorized. Recording task: [#646](https://github.com/iricigor/fingvibe/issues/646).
