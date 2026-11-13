# 3️⃣ Dispatcher preflight and historical completion

3️⃣ uses independent PowerShell 7.5+ implementations:
`Get-Agent3DispatcherPreflight.ps1` and `Invoke-Agent3DispatcherGate.ps1`.
Neither calls the older Dispatcher scripts. The older scripts and 2️⃣ experiment
retain their original behavior. The two gate implementations deliberately use
the same physical repository lock location and `fingvibe-dispatch-gate-v1` format
so older and newer Dispatchers cannot concurrently claim repository work.
Do not create a separate production lock namespace.

After acquiring its gate, 3️⃣ Dispatcher runs:

```powershell
.\.github\scripts\Get-Agent3DispatcherPreflight.ps1 -Repository iricigor/fingvibe -Epic <number>
```

The helper is read-only. It collects fully paginated GitHub evidence once,
returns compact diagnostics and never posts comments, changes labels, starts
workers or proves host termination. It retains the existing
`fingvibe-dispatcher-preflight-v1` evidence format and 8 KiB stdout bound.
Read the complete diagnostic artifact when stdout points to one.

The candidate/reconcile guidance is conservative, not the real environment's
two-worker capacity policy. Follow the [shared contract](contract.md) for
native membership, ordering, dependencies, foreign work, current host checks,
authorization and fresh reads before writes. The collector reads legacy
three-repair claim records; independently inspect agent-3 claims/events
using the agent-3 helpers. Never treat missing discovery as free capacity.
Collection errors remain explicit blockers. Accepted design/trial scope,
abandonment and transferred ideas require their own evidence review; this
completion policy does not invent merged PRs for them.

## Automatic historical completion reconciliation

For historical **manual** work within the selected Epic, 3️⃣ Dispatcher
automatically repairs missing completion bookkeeping instead of asking a
human to prove that an old session stopped. This is a policy-based disposition,
not termination proof or general orphan recovery. Do not invent a missing
implementation claim.

Preflight verifies native membership, current completed issue closure and the
complete intended closing-PR set merged into the default branch. It reads
timezone-qualified issue `closedAt` and each PR's `closedAt` and `mergedAt`.
All events must be **strictly more than 30 minutes old**: use the latest event,
not the first closure or issue update time. Exactly 30 minutes is too soon.
Missing, invalid or future timestamps, reopened/not-planned issues, unmerged
or wrong-target PRs and failed collection do not qualify.

| Finding | Dispatcher action |
| --- | --- |
| `historical-grace-period` | Defer until after `completion.eligibleAfterUtc`; report the wait without adding `human-task` or launching work. |
| `historical-self-heal` | Inspect current work, then publish and verify the self-healing notice below. No human approval per historical task is required. |
| Previously reconciled history in `skipped` | Reuse the linked notice after verifying its author/provenance and checking for current conflicting work; do not post another notice. |

Before healing or reusing a notice, inspect current repository claims/open PRs
and available correlated host execution information. Positive active-work
evidence, a genuine retained structured claim, unresolved launch/handoff,
contradictory evidence or failed current-work collection still blocks.
An archived/undiscoverable historical manual session or unavailable historical
termination endpoint **alone** does not block this path. Record which inspection
was possible and the remaining uncertainty; never assert verified termination.
Do not treat an API failure as an empty result.

Under the existing owned repository gate, freshly recheck issue closure,
intended PR delivery/timestamps and current work before writing. Post a short
task comment such as: "Self-healing historical completion bookkeeping after the
30-minute grace period. Delivery is verified and current checks found no
correlated ongoing work. Historical termination is not proven. Manual ownership
is reconciled by policy." Include the following marker and exactly one JSON
block using `finding.completion.record`:

```text
<!-- fingvibe-historical-completion-v1 -->
```

Populate `checkedUtc` with the actual inspection time and fill `evidence` with
nonempty traceable references/descriptions for delivery and current-work checks,
including host scope/limitations. Preserve the template's repository, task,
target branch, issue-closure instant and complete PR timestamp set.
Publish as a verified repository owner/member/collaborator and read the comment
back to verify both its body and author. Preserve original claim/progress prose;
clear and verify only stale `active`/`status:review` labels on the closed issue,
if present. Do not alter unrelated labels, ownership records or repair counters.
Record the notice URL in tick diagnostics and link the brief Epic outcome.

Only after publication/readback and cleanup may Dispatcher mark that cached
finding reconciled and continue normal queue selection/fresh capacity checks.
Do not wait for preflight to return `candidate` or recollect the whole repository.
A later preflight revalidates delivery and reuses a matching trusted notice;
changed issue closure or PR delivery invalidates it. A verified prior manual
release with actual stopped-host evidence also satisfies historical cleanup;
do not demand repeated release or duplicate notices for it.
No notice overrides open PRs, open active/review work or genuine unresolved claims.

This path does not adopt/release agent-3 or other structured handoffs: those
retain their owning workflow's stopped-execution/recovery rules. Reopening
issues or undoing/reverting merged PRs is outside the loop, while it is stopped.
No automatic restart, replacement, merge or schedule authority is granted.

## Validation

```powershell
.\tests\Agent3DispatcherGate.Tests.ps1
```

This runs independent gate/cross-version contention checks and the dedicated
preflight suite. Fixtures cover the strict 30-minute threshold, multiple PRs,
repeated notices, changed delivery, malformed evidence and retained claims.
The older Dispatcher suite remains unchanged and runs separately in CI.
