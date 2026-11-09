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
out-of-Epic exception only with verified native Epic membership and merged
closing PRs to the current default branch. Within-Epic cleanup still blocks.
Unresolved structured claims always hold capacity, even on closed issues.
Prose cues are intentionally conservative and can require Dispatcher judgment;
the helper does not automatically release ownership or prove a worker stopped.

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
