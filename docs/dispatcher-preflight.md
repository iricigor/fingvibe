# Dispatcher preflight

The local Dispatcher uses `.github\scripts\Get-DispatcherPreflight.ps1` after
acquiring its existing serialization gate. This PowerShell 7 helper replaces
repeated repository-wide discovery with one cached, fully paginated GitHub
collection and compact JSON guidance. It is not a new dispatcher or an
authorization/ownership service.

```powershell
.\.github\scripts\Get-DispatcherPreflight.ps1 -Repository iricigor/fingvibe -Epic 191
```

The helper requires authenticated `gh` reads for repository metadata, issues,
comments, PRs, native sub-issues, dependencies, and GraphQL closing-PR evidence.
It never writes GitHub, starts agents, sends messages, changes lifecycle labels,
or acquires/releases a gate. A standalone benchmark need not acquire a gate
because it performs no dispatch mutations; a real Dispatcher tick still must.
Do not use a benchmark as permission to pick up work.

## Results

| Decision | Meaning |
| --- | --- |
| `reconcile` | Open PRs, active/review work, retained claims, or historical/manual ownership evidence prevent mechanical pickup. |
| `blocked` | Collection/state errors, inconsistent dependencies, or unresolved ordering/delivery need explicit review. |
| `candidate` | One mechanically eligible native task is suggested, subject to all Dispatcher checks. |
| `no-work` | No mechanical candidate remains in the evaluated queue; this does not prove host capacity. |

The `fingvibe-dispatcher-preflight-v1` JSON includes evidence URLs, current
collection time, ordering, findings/skips, record counts, per-source elapsed
seconds and raw JSON byte counts, and total helper elapsed seconds. Duplicate,
foreign or malformed claims and failed/incomplete APIs produce `blocked`, a
visible `collectionFailure`, and a nonzero command exit. Ordinary reconciliation
or review findings are successful evidence collection, not task completion.
Existing ISO timestamps with explicit nonzero offsets are accepted as exact
instants; missing timezones are invalid. New Dispatcher records still use UTC.
Claim `repairCount` must be an integer from 0 through 3, matching the approved
three-repair policy. Accepting that range does not authorize another repair,
reset history, or release a retained claim; normal Dispatcher reconciliation
and stopped-worker verification still apply.

Stdout is limited to 8 KiB. Larger complete results are saved to a uniquely named
`dispatcher-preflight-<UUID>.json` in the existing absolute
`-DiagnosticsDirectory` (the OS temporary directory by default). Stdout then
contains the artifact path/byte count and an explicit review requirement instead
of a candidate. Read the complete artifact before acting; findings are never
silently truncated. Local diagnostics contain evidence summaries, not the full
repository comment bodies. Remove only that specific artifact when no longer
needed. Normal-sized runs create no files.

## Conservative mechanical rules

The helper first collects repository-wide open PRs, all issues and claim
comments, plus the configured Epic's native children. Occupied capacity returns
immediately without expensive historical/dependency investigation.

When capacity is mechanically empty, historical active/review labels and prose
ownership cues are reviewed. Closed historical records qualify for the local
out-of-Epic exception with verified membership outside the configured Epic
or an authoritative explicit null parent, plus merged closing PRs to the current
default branch. Parentless records appear in `skipped` with an explicit separate
Epic-organization requirement; this does not waive native membership for intake
or authorize historical migration. API failures, omitted/malformed fields,
non-Epic parents and contradictions with native children do not qualify.
Within-Epic cleanup still blocks by default. Only 3️⃣ Dispatcher enables the
30-minute completion reconciliation below with `-HistoricalCompletionSelfHealing`.
Unresolved structured claims always hold capacity, even on closed issues.
Prose cues are intentionally conservative and can require Dispatcher judgment;
the helper does not automatically release ownership or prove a worker stopped.
GitHub's repository issues and issue-comments APIs also include PR records and
PR discussion comments. The helper retains PR identities from the all-state
inventory so their prose comments are not mistaken for task ownership evidence.
Open PRs still occupy capacity, structured claims on PRs remain invalid, and
ownership comments for unknown or foreign records fail closed with the offending
comment URL. Ignoring PR discussion prose does not establish task delivery,
release a task claim, or prove that a worker stopped.
Likewise, prose on a `type:epic` organizing issue is not task ownership and is
reported in `skipped`. This filtering runs after explicit coordination records,
open PRs and open active/review labels have been checked; it cannot hide those
blockers or a real task's manual ownership evidence.

### Reviewing historical findings

`reconcile` is guidance to inspect every finding, not a requirement to invent a
PR for accepted design work or repeatedly release already-reconciled history.
Use current task discussions and linked reconciliation reports to verify:

| Evidence | Disposition |
| --- | --- |
| Manual release plus actual stopped-host evidence | Historical ownership already reconciled; preserve its audit trail. |
| Explicit human abandonment, stopped execution and closed-unmerged PRs | Not planned, not delivered implementation. |
| Explicit human design/trial acceptance | Accepted non-code scope, not application implementation. |
| Recorded source-ideas transfer | Backlog disposition, not delivery of remaining ideas. |
| Nested PR merge followed by verified integration into the default branch | Delivery only after checking the actual integration evidence, not merely a PR body link. |
| Authorization/progress prose mentioning ownership | Not itself a task claim; check for actual task claims and live work. |

Closure, a final worker message or absent session discovery alone proves none
of these dispositions. Unresolved claims and unknown execution still block.
Human acceptance/abandonment must not silently satisfy an implementation
prerequisite. Missing or contradictory evidence stops pickup.

After all historical/prose findings have been independently reconciled,
Dispatcher records finding URLs, dispositions and supporting evidence in its
normal task diagnostics, then may select from the cached native-child inventory
using all normal ordering, dependency, authorization and fresh-read checks.
The helper intentionally still returns review findings it cannot certify; no
new override parameter, automatic ownership release or comment deletion is
needed. Collection failures and genuine occupied/uncertain capacity cannot be
overridden. Do not repeatedly recollect unchanged history hoping for `candidate`.

### Automatic historical completion reconciliation

This is an explicit **3️⃣-only** override. The older ⏩ and 2️⃣ agents retain
their original policies. The shared helper remains read-only and its default
behavior is unchanged. 3️⃣ Dispatcher uses PowerShell 7.5+ and invokes:

```powershell
.\.github\scripts\Get-DispatcherPreflight.ps1 -Repository iricigor/fingvibe -Epic <number> -HistoricalCompletionSelfHealing
```

For historical **manual** work within the selected Epic, 3️⃣ Dispatcher automatically
repairs missing completion bookkeeping rather than asking a human to prove that
an old session stopped. This is a policy-based disposition, not termination proof
or general orphan recovery. Do not invent a missing implementation claim.

Preflight verifies native membership, current completed issue closure, and the
complete intended closing-PR set merged into the default branch. It reads
timezone-qualified issue `closedAt` and each PR's `closedAt` and `mergedAt`.
All events must be **strictly more than 30 minutes old**: use the latest event,
not the first closure or the issue's update time. Exactly 30 minutes is too soon.
Missing, invalid or future timestamps, reopened/not-planned issues, unmerged
or wrong-target PRs and failed collection do not qualify.

| Finding | Dispatcher action |
| --- | --- |
| `historical-grace-period` | Defer this reconciliation until after `completion.eligibleAfterUtc`; report the wait without adding `human-task` or launching work. |
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

Under the existing owned Dispatcher gate, freshly recheck issue closure,
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
nonempty traceable references/descriptions for the delivery and current-work
checks (including host scope/limitations). Preserve the template's repository,
task, target branch, issue-closure instant and complete PR timestamp set.
Publish as a verified repository owner/member/collaborator and read the comment
back to verify both its body and author. Preserve original claim/progress prose;
clear and verify only stale `active`/`status:review` labels on the closed issue,
if present. Do not alter unrelated labels, ownership records or repair counters.
Record the notice URL in the tick diagnostics and link the brief Epic outcome.

Only after publication/readback and cleanup may Dispatcher mark that cached
finding reconciled and continue normal queue selection/fresh capacity checks.
Do not wait for preflight to return `candidate` or recollect the whole repository.
A later preflight revalidates delivery and reuses a matching trusted notice;
changed issue closure or PR delivery invalidates it. The notice never overrides
open PRs, open active/review work or genuine unresolved claims.

This path does not adopt/release real-task or other structured handoffs: those
retain their owning workflow's stopped-execution/recovery rules. Reopening
issues or undoing/reverting merged PRs is outside the loop, while it is stopped.
No automatic restart, replacement, merge or schedule authority is granted.

### Ordering and dependencies

Unambiguous `Delivery order: #200 -> #201` (also execution/implementation order)
in the Epic body is recognized. Otherwise explicit narrative/historical order
requires Dispatcher review, not an ascending fallback. With no explicit-order
evidence, ascending issue number is used. For a verified narrative order:

```powershell
.\.github\scripts\Get-DispatcherPreflight.ps1 -Repository iricigor/fingvibe -Epic 191 `
    -TaskOrder 273,274,239,241 `
    -OrderEvidenceUrl https://github.com/iricigor/fingvibe/issues/191
```

This override must contain unique native children and an evidence URL on the
configured Epic. Dispatcher must independently verify the URL's content and
the current discussion; URL validation alone does not establish human approval.
Tasks outside an explicit queue are not appended automatically.

Human tasks, blocked tasks, assigned tasks and previously claimed tasks are not
new candidates. Native dependencies are read with pagination; open dependency
graphs are checked for cycles. In the standard `## Dependencies...` section,
simple `Native blockers: #190`, `Blocking prerequisites: #190`, `Depends on:
#190`, or `Dependencies: None` declarations can be checked mechanically against
native relationships. Ambiguous prose/mismatches stop selection for review.
Closed prerequisites require merged closing-PR evidence to the default branch;
closure, an arbitrary PR body link, closed-unmerged work, transferred acceptance
or a human design approval is not silently treated as implementation delivery.
Those non-PR acceptance cases remain for Dispatcher verification.

This is a point-in-time guide. Dispatcher must still inspect applicable scope,
acceptance criteria/discussion, authorization, matching worker results and actual
host execution/termination. Even excluded out-of-Epic historical records require
the host check for genuine unfinished work. Re-read mutable capacity, candidate,
labels, authorization and dependency evidence immediately before claiming.
The existing repair/finalize validation and duration rules are unchanged.

## Validation and timing

```powershell
.\tests\DispatcherPreflight.Tests.ps1
.\tests\DispatcherGate.Tests.ps1
```

The existing gate-test entry point also runs the new offline preflight suite,
so its existing CI step covers both without changing workflow policy. Fixtures
exercise pagination, capacity, claims/errors, selection, ordering, dependencies,
historical exceptions and oversized output; they never contact GitHub.

For a read-only live measurement:

```powershell
$timer = [Diagnostics.Stopwatch]::StartNew()
$output = & .\.github\scripts\Get-DispatcherPreflight.ps1 -Repository iricigor/fingvibe -Epic 191
$exitCode = $LASTEXITCODE
$timer.Stop()
$output
"Seconds=$($timer.Elapsed.TotalSeconds); UTF8Bytes=$([Text.Encoding]::UTF8.GetByteCount(($output -join "`n"))); Exit=$exitCode"
```

The exploratory collector measured 8.68 seconds and 1,509 stdout bytes on
2026-11-08. It fetched 167 issues, 776 comments and 22 native children, but did
not implement the full rules above. A live run of the completed helper that day
measured 9.19 seconds and 2,435 stdout bytes, processing 168 issues, 780 comments,
five structured claims and 22 native children. It returned `reconcile` for the
retained #273 claim and repository-wide open PRs/active work, even though the
claim's handoff had reached `finished`; reporting is not stopped execution.
Compare measured results, not a promised
network-time threshold or identical-state speedup. Runtime depends on API
latency, pagination and the amount of historical/dependency evidence required.
