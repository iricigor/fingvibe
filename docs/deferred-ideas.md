# Deferred ideas

Keep confirmed abandoned ideas here to avoid repeating investigations. Each entry states why we stopped and what would justify reconsideration. Recording is not approval to implement; see the [Architect workflow](../.github/agents/architect.agent.md).

## Table of contents

- [DI-001: Azure-hosted speed-test downloads](#di-001-azure-hosted-speed-test-downloads)

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
