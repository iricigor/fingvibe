# Agent 3 coordination contract

This is the mandatory operating contract for the three source profiles in
[the agent-3 environment](README.md). It derives from the production
[Dispatcher](../../.github/agents/automation-dispatcher.agent.md) and
[Developer](../../.github/agents/automation-epic-developer.agent.md), preserving
their delivery safeguards. Its explicit overrides apply **only** to `3️⃣`:
two Developer slots, separate bounded task backlog, the schemas below,
configurable human authority, twelve cumulative repairs after implementation,
and the 3️⃣-only historical manual-completion reconciliation below.
No manual selection by Developers, inherited #191 authorization or global
single-claim veto applies to verified compatible work within this environment.

## Ownership and capacity

Dispatcher owns task selection/claim, shared state, active/blocker visibility,
CI observation, repair routing, release reconciliation and final Epic cleanup.
Developers own bounded implementation/repair/finalize execution and immutable
acknowledgments/results; they never release shared claims themselves.

One task claim survives worker changes, CI gaps, PR publication, blockage and
repairs until verified delivery and cleanup. One unresolved handoff occupies a
Developer, including startup, message uncertainty, stopped-but-unreconciled
results and finalization. One task cannot have overlapping handoffs. At most
two Developers are occupied; at most two tasks are waiting in `validation`,
`finalize-ready` or `human-review`. A stopped Developer may take another
compatible task while the former awaits CI.

Backpressure: two already-running implementations can finish while both waiting
places fill. Persist their results immediately, verify stopped execution, but
retain their worker reservations in `implementing` until they can enter
`validation`. This is a stopped checkpoint, not active coding or missing evidence.
Do not exceed the waiting bound, discard a result or release occupancy early.
Blocked tasks retain claims; verified stopped/reconciled blocked work need not
occupy a worker. Unknown execution holds its worker, not necessarily the other
one: continuing requires evidence of independent execution and compatible scope.

Reconcile all retained work first; eligible finalize/repair precedes new work.
Launch at most one new handoff per tick. Safe independence considers planned
scope and actual diffs, shared files/models/contracts, dependency delivery,
tests, base changes and integration order, not filenames alone. A later merge
can stale another PR's validation: refresh base/head evidence before finalizing.
No conflict repair or base-update commit occurs in finalize; route an authorized
in-scope repair with remaining allowance and fresh validation instead.

Foreign/manual/old-environment claims remain owned by their original workflow.
They are not free capacity or automatically adopted. Assess repository-wide
open PRs (including drafts), active/review/blocked claims and actual live workers.
Verified independent external work may coexist only after required conflict
confirmation; unknown execution/shared risk blocks affected actions. Never
reset old counters, clear foreign labels or move issues between Epics.

The 3️⃣-only bounded exception is historical **manual** completion reconciliation, not
foreign structured-claim adoption. Follow the
[30-minute completion procedure](dispatcher-preflight.md#automatic-historical-completion-reconciliation)
in the independent `Get-Agent3DispatcherPreflight.ps1`:
verify current completed closure and intended merged PRs, wait strictly more
than 30 minutes after all closure/merge events, inspect current work, and
post/read back one policy-based self-healing notice. Missing historical
termination metadata alone does not require a human task when current checks
find no ongoing work. Preserve uncertainty and original history; do not invent
claims, stopped-execution proof or events. Reuse matching notices without
duplicates; revalidate changed delivery/closure. Failed collection, positive
live-work evidence and unresolved structured handoffs remain blockers.
Only stale closed-issue active/review labels may be cleared and verified by this
procedure. Reopening or undoing/reverting merged work is outside the stopped loop.
The older ⏩ and 2️⃣ agents and scripts are unchanged. The independent
`Invoke-Agent3DispatcherGate.ps1` deliberately preserves the same physical
repository lock path and format for cross-version serialization.

## Schemas and transition authority

PowerShell helpers consume JSON objects as hashtables, preserving string dates.
Versions are exact, field names case-sensitive, no implicit aliases. Missing
required fields are errors. Optional unknown values are explicit JSON `null`;
unknown provenance uses the string `unknown`. Schema evolution requires an
explicit version/migration decision, never silent defaulting.

### State: `fingvibe-real-state-v1`

| Field | Shape |
| --- | --- |
| `schema`, `repository`, `epic`, `targetBranch` | Exact schema, normalized owner/repo, positive Epic number, discovered default branch |
| `authorization` | `{ reference, implementation, merge }`; verified human decision reference and explicit booleans |
| `workers` | Exactly two `{ id, name, automationId }` objects; stable IDs `developer-1`/`developer-2`, distinct verified Automations |
| `revision`, `updatedUtc` | Positive integer, actual UTC publication time |
| `tasks` | Array of task objects below; retained after delivery |
| `events` | Processed `{ id, hash, claimId, handoffId, kind }` entries; hashes cover canonical full immutable events |
| `incidents` | Canonical `{ id, path, hash }` index, rebuilt from actual incident files, never index-only discovery |
| `reports` | Append-only `{ id, claimId, handoffId, url, utc, nextOwner, nextAction }` verified report checkpoints |

Every task has `claimId` (fresh UUID), `issue` (positive native child number),
`state`, `repairCount` (integer 0-12), `handoffs` (ordered retained history),
`branch`, `worktree` (absolute), `pr` (URL), `head` (full lowercase SHA),
`checkpoint` (immutable implementation evidence reference), `scopeEvidence`
(nonempty inspected evidence references), `dispositions` (append-only
`{ state, utc, evidence }`) and `changedUtc` (last meaningful change).
Branch/worktree/PR/head/checkpoint may be null before implementation establishes
them; repair/finalize require the established task context. Never replace the
task branch/worktree/PR to resume a repair on a different worker.

Task states: `implementing`, `validation`, `repair-needed`, `finalize-ready`,
`human-review`, `blocked`, `delivered`. A result and a task disposition are
different records. Implementation-ready plus stopped-session evidence allows
validation when a waiting place exists. Fresh actionable feedback permits
repair-needed; fresh complete acceptance/check/review/duration evidence permits
finalize-ready. Finalize without merge authority produces human-review.
Verified target delivery and cleanup allow delivered; publication/closure alone
does not. Blocked may be recorded at any point without releasing execution.
Resuming blocked work requires current evidence resolving the blocker; clearing
a GitHub label alone does not restart it.

`Add-Agent3Event` promotes an accepted `implementation-ready` head/checkpoint
into the task during ingestion, not publication or preflight. Historical
duplicates cannot roll it back. Validation requires the latest coding handoff
to have succeeded and its head/checkpoint to match the task. Recovery through a
later non-coding finalizer also requires its assigned head to match; a failed
coding repair cannot reuse an earlier success.

Blocked claims without a handoff retain ownership. To allow independent new
work, record a blocked disposition using `-IndependentEvidence` with verified
scope/conflict observations; this adds `independentEvidence[]` to that disposition.
Without that assessment the unassigned claim still blocks admission.
Readmission of reconciled work to the waiting backlog reserves places for
outstanding coding handoffs, preventing recovered tasks from filling the queue
while both workers implement newer tasks. The backlog limit remains two.

Fresh review/check feedback permits `human-review -> repair-needed` without
changing the claim, task context or repair count. Separately verified human
delivery uses `Set-Agent3Disposition -Disposition delivered -HumanDelivery`
with `{ head, targetBranch, evidence[], cleanupEvidence[] }`. Execution must
already be reconciled; the target branch must match the environment and the
head must be a full SHA. The disposition retains `humanDelivery` and the task
records the externally delivered head. These references must establish actual
target-branch delivery and completed cleanup, not just PR closure. This does
not grant merge authority or weaken Developer `delivered` event checks.

Each handoff has:

```text
id, action, stage, workerId, runId, sessionId, expectedHead,
feedback[], priorRepairEvidence[], repairAttempt, strategy,
transitions[{stage, utc, evidence[]}], ackEventId, resultEventId, result
```

`action` is exactly `implement`, `repair` or `finalize`. Repair attempt is 1-12
and equals its cumulative position in retained repair history; other actions
use 0. Strategy is `targeted` for repair 1, `reassess` for 2-12, null otherwise.
Later repairs include evidence of prior handoffs, approaches, results/heads,
reports and actual check/review outcomes. Preserve all prior evidence.

The shared transition validator is used by **both** roles:

```text
prepared -> launch-requested -> correlated -> delivered -> acknowledged
         -> result-recorded -> stopped-verified -> reconciled
```

The diagram is one sequence: result-recorded follows acknowledged.
Persist/read back launch intent before invoking the host. Correlated requires
actual separate run/session IDs and verified Automation identity. Delivered
means confirmed assignment queue admission, not execution acknowledgment.
Developer acknowledgment/result events drive those two stages; Dispatcher
drives the rest from fresh evidence. Reconciliation requires a task disposition,
actual stopped-session evidence and durable bookkeeping before freeing a worker.
No skipped stages based on inferred idleness.

A verified `blocked-before-start` result may move correlated/delivered directly
to result-recorded without acknowledgment. This records rejection, not executed
implementation; it still needs actual stopped-session proof. Uncertain launch
without actual correlation cannot take this shortcut. Record the blocker and
request human reconciliation instead of inventing run/session IDs.

`Resolve-Agent3Handoff` is the explicit human-authorized exception, not an
automatic shortcut. It takes the exact claim/handoff, `-HumanAuthorization`
and nonempty verified `-Evidence`:

| Mode | Required actual observations |
| --- | --- |
| `no-launch` | Prepared/launch-requested intent definitively never launched; no run/session/ack/result exists |
| `stopped` | Correlated/delivered/acknowledged session independently verified stopped, with no worker result |
| `pre-start-rejected` | `blocked-before-start` result without acknowledgment, already stopped-verified or reconciled |

It appends a terminal `reconciled` transition and a blocked task disposition,
releasing occupancy but retaining ownership. It never creates a worker event
or invents run/session IDs. The handoff retains an optional immutable `recovery`
object `{ mode, priorStage, authorization, evidence[], utc, restartImplementation }`
matching its final transition. Publish under the owned gate using normal revision
checks. Original events, identities, counters and transitions remain unchanged.

Only `no-launch` and `pre-start-rejected` initial implementations can additionally
receive explicit `-RestartImplementation` approval. This permits a fresh initial
handoff ID, preserving the abandoned history and repair count. A stopped coding
run is not a pre-start failure. Without explicit restart approval, no replacement
is allowed. Late unindexed events cannot reopen recovered handoffs, and an
already ingested event remains an idempotent duplicate.

### Assignment: `fingvibe-real-assignment-v1`

Every operational host message uses the closed
[JSON message protocol](protocol.md), including assignments, worker events,
blockers, clarification and notifications. Generate and publish it with the
shared scripts; no surrounding prose or Markdown fences. The payload contracts
below remain authoritative. GitHub human-facing reports retain their existing
presentation and are not operational host-message bodies.

Use `Get-Agent3Assignment`, not an independently invented payload:

```text
schema, repository, epic, issue, claimId, handoffId, action,
workerId, runId, sessionId, targetBranch, authorization,
branch, worktree, pr, expectedHead, checkpoint,
repairAttempt, strategy, feedback[], priorRepairEvidence[]
```

Message after publishing correlated state. Publish delivered immediately after
verified admission. A worker receiving a verified actual assignment may accept
correlated or delivered state: its acknowledgment can precede Dispatcher's
delivery readback. A correlated record alone is not an assignment or permission
to start. When a matching acknowledgment is independently verified, ingestion
records delivered before acknowledged if needed; no stage is omitted. This
reconciles proven delivery without resending an uncertain message.

`Assert-Agent3Assignment` matches the entire payload to authoritative state
and the worker's actual identity/run/session. It rejects stale stages,
acknowledged handoffs and altered action/head/authority. This checks structural
correlation, not the truth of the referenced host/authorization observations.
Developers additionally inspect canonical events for an existing acknowledgment
or result, including not-yet-indexed files. Reserve acknowledgment atomically
using `Publish-Agent3Acknowledgment`; duplicate reservation means no execution.

### Event: `fingvibe-real-event-v1`

Required exact fields:

```json
{
  "schema": "fingvibe-real-event-v1",
  "eventId": "ack-<handoff-UUID>",
  "kind": "ack",
  "claimId": "<claim-UUID>",
  "handoffId": "<handoff-UUID>",
  "action": "implement",
  "workerId": "developer-1",
  "runId": "<actual-Automation-run-ID>",
  "sessionId": "<actual-executing-session-ID>",
  "utc": "2026-11-11T12:00:00Z",
  "actor": "<actual-recording-identity>",
  "originalReporter": "<actual-reporter-or-unknown>",
  "trigger": "unknown",
  "elapsedSeconds": null,
  "result": null,
  "evidence": ["<verified-evidence-reference>"]
}
```

The JSON is illustrative, not runtime evidence. Kind is `ack` or `result`.
Acknowledgment ID is `ack-<handoffId>` and result ID is `result-<handoffId>`.
Result payload is `{ outcome, head, checkpoint, evidence[] }`; outcome is
`implementation-ready`, `blocked`, `blocked-before-start`, `pr-ready` or
`delivered`. Implementation-ready requires full head/checkpoint evidence;
finalize results must match the assigned head without coding. Delivered from
the finalizer requires explicit merge permission. Report externally observed
human delivery separately with verified delivery/cleanup disposition evidence.

Use actual ISO 8601 UTC strings (`Z` or `+00:00`), not inferred/local times.
`elapsedSeconds` is a nonnegative finite monotonic measurement within one
execution, or null with its unavailability explained in the linked report.
Do not subtract monotonic clocks across sessions/restarts. Wall-clock intervals
and task elapsed are separate observations; corrections preserve original
evidence and attribution. Trigger is `scheduled`, `manual`, `worker-message`
or `unknown`, only when actually observed.

Canonical full-event hashes use ordinal, case-sensitive keys and ignore JSON
object field order, not payload differences or the current culture. Event and
result objects reject extra fields, including case-variant aliases. Validate
action/outcome, full head SHA and required implementation checkpoint before
immutable publication, so malformed results cannot reserve their event IDs.
Identical event ID/payload is processed once; conflicting duplicates,
unknown schema/aliases, malformed/partial records, wrong actors/correlation or
missing evidence block the affected handoff. No new repair/finalize authority
comes from duplicate delivery. Events never rewrite Dispatcher-owned state.

Every report checkpoint must reference a retained task/handoff, even when the
task list is empty. Publication preserves every prior event/report exactly once;
its retained-evidence comparison hashes each current and prior entry once
rather than comparing every pair.

### GitHub mirrors and reports

Before launch, Dispatcher posts/verifies one task claim comment marked
`<!-- fingvibe-real-claim-v1 -->` containing fenced JSON with repository/Epic,
issue, claimId, authorization, state revision/path, acting account, branch/PR/head,
task state, repairCount and current handoff/history. Preserve prior evidence
and correlate every remote update to local state. Neither GitHub comments nor
local publication forms a distributed transaction: partial publication holds
ownership, records exact successful/missing operations and blocks launch.

Developers post immutable result comments marked
`<!-- fingvibe-real-result-v1 -->`, containing the full event and report link.
Verify current GitHub identity/host correlation against actual sender evidence,
not merely an `actor` string in JSON. Paginate all relevant comments and
checks/reviews. Reports are short summaries with collapsed detailed logs using
the existing Developer format: actual UTC start/end, nonwrapping elapsed
HH:mm:ss/human equivalent, task/PR/head, evidence, decisions, limitations,
next owner/action, questions and unimplemented suggestions. Verify saved
comments/checkpoints. No unchanged heartbeat comments or raw transcripts.

Dispatcher sets/verifies active before assigning. Pending CI remains active.
Developer finalize removes WIP/marks ready, moves active to status:review and
verifies. Blockers add status:blocked while preserving ownership and other
labels. Either role may apply human-task only when actual human action is
needed, with evidence/exact action; never remove it automatically. Re-read
human-task before assignment, edits, pushes and merge. Dispatcher reconciles
verified delivery/issue closure, lifecycle cleanup and native Epic checklist
before releasing task ownership; only brief linked terminal/blocker Epic
outcomes, not duplicated detailed logs.

## Evidence collection and integration

### Developer procedure

1. Without an explicit correlated assignment, finish awaiting-assignment with
   no task selection or mutations. Read the shared contract and production
   Developer safeguards; verify native Epic membership, actual authority,
   GitHub claim/identity, human-task labels, current state/events, actual
   assignment sender/message and host worker/run/session. Correlated state
   plus a verified actual assignment permits acknowledgment before delivery
   readback. Missing/uncertain evidence is an explicit blocker.
2. Verify isolated context and assess current competing work/shared contracts.
   New material risks need required human confirmation before edits, even
   after Dispatcher selection. For repair/finalize, independently verify
   preceding execution stopped and exact task context/head/history.
3. Re-read state/events immediately before starting. Use
   `Assert-Agent3Assignment` and `Publish-Agent3Acknowledgment`, passing
   actual worker/run/session and evidence. A duplicate/failed reservation
   means no execution. Post/verify the immutable GitHub acknowledgment.
   Developer never acquires the Dispatcher gate or mutates shared state.
4. Implement: push the assigned branch and verify an early WIP draft with
   Closes #task before edits (empty bootstrap commit if needed). Follow
   production Developer section 4's scope/quality rules and section 5's local
   checks/validation planning. Repair: diagnose the assigned fresh feedback
   and retained attempts, fix only in-scope actionable causes in the same
   worktree/branch/PR. Keep WIP/active, push and report exact new checkpoint,
   full SHA, acceptance evidence and applicable remote validation expectations.
   Do not wait for CI, publish ready or merge during implement/repair.
5. Finalize: no coding/commits. Independently apply the complete integration
   gates below. Pending evidence produces an explicit incomplete/blocked
   result, not a repair or success. When ready, update the same PR, remove WIP,
   mark ready, move active to status:review and verify. Without merge
   authority stop at pr-ready; with authority perform only verified
   head-bound integration and report actual disposition.
6. Publish the immutable result `result-<handoffId>.json`, short task report
   with collapsed diagnostics and immutable GitHub result; verify all writes.
   Include actual start/end/elapsed, identities, exact checkpoint, decisions,
   evidence, blockers and next action/owner. Failed publication is reported
   explicitly; never replace the result with a success-shaped fallback.
7. Stop. No second task, CI busy polling, ownership release, independent
   relaunch or worker replacement. Dispatcher verifies actual session
   termination and reconciles task/worker release separately.

Use `Get-Agent3DispatcherPreflight.ps1` once under the gate for fully paginated
repository-wide evidence and compact diagnostics. Read any complete diagnostic
artifact it points to. Its legacy candidate/reconcile guidance cannot enforce
two-worker capacity and may stop before dependency inventory when it finds
occupied work. Never interpret its return as a complete candidate inventory.
The independent collector retains legacy claim-marker parsing and the three-repair
schema, not `fingvibe-real-claim-v1`. Inspect the agent-3 mirrors explicitly;
never feed twelve-repair records to the old schema or treat their absence from
legacy findings as released ownership.
Independently collect only the still-needed native queue/dependencies and
retained-PR details; cache reads within the tick.

Classify every finding as verified own claim, foreign/manual work, historical
disposition, conflicting/unknown evidence or collection failure. Apply the
production historical-reconciliation rules without deleting prose or inventing
delivery. Do not simply override reconcile because a free worker exists.
Collect full pagination for native children/dependencies, all open PRs/drafts,
active/review/blocked claims and relevant comments. Preserve current full head,
base, workflow/run/job/check identity, review identity/dismissal, applicability,
full duration and affected-UI rationale. Missing evidence is explicit; collection
failure never means no competing work.

Pending applicable evidence means wait without a worker. Actionable
implementation-related failure/changes requested or over-budget affected UI
permits repair within scope and allowance. Unrelated failures, unavailable
evidence, material conflicts/design changes or human-task block immediately.
No reruns-to-green or timeout/coverage weakening.

Finalize independently applies the production Developer validation and
integration safeguards: actual current-head applicable workflows/checks and
blocking reviews; justified policy-based skips only; every applicable current
and future UI-regression job's full duration including setup/cleanup. An affected
job above 240 seconds requires repair even when green. Unaffected UI is exempt
only from duration remediation, not failed checks. Independent baseline/full
validation remains additional evidence, not a gate waiver.
Finalize handoffs retain a nonempty feedback/evidence snapshot. Do not assign
the same finalize action/head/evidence twice; a blocked finalizer can return
to validation only from retained implementation-checkpoint evidence and fresh
blocker-resolution evidence. A meaningful new validation snapshot is required
before another finalize handoff, not another unchanged tick. Finalize
deduplication compares ordinal sets of evidence references: reordering or
repeating the same references is not new evidence. The original feedback
snapshot remains unchanged in retained history.

Finalize never edits code or creates a base-update commit. Without merge
authority, publish ready for human review and retain ownership. With explicit
authority, freshly verify head/base/reviews/durations and use an allowed
head-bound merge without admin bypass (`--match-head-commit <full-SHA>`).
Verify actual delivery on the target branch, issue closure and cleanup, not
queued merge. Merging main retains release-on-main; a no-release instruction
cannot authorize that merge. Recheck other retained PRs after integration.

## Repairs, recovery and incidents

There is one initial implementation plus at most **12 cumulative repairs** per
claim, shared across checks, reviews and affected-UI duration failures. Persist
the increment before launch; an uncertain repair launch still consumes its
reservation, never resets or grants another launch. History and counts survive
worker/revision/finalizer/tick changes. Attempt 1 is targeted diagnosis; 2-12
reassess prior outcomes, challenge failed assumptions and choose evidence-backed
approaches. Prior repair evidence is mandatory after attempt 1. Repeating an
approach requires new evidence, not arbitrary different edits or blind retries.
The human-approved replacement of a proven unstarted initial handoff described
above preserves that history; it is not an additional executed implementation
or a reset of the repair allowance.

Every repair verifies preceding execution stopped, exact existing task
worktree/branch/PR, assignment expected head, actual fresh feedback identity,
persisted count/history and scope. A different Developer may repair only with
verified supported reuse of that **same task context**, never its unrelated
default worktree. Missing host capability blocks. Every new checkpoint needs
fresh applicable validation. After 12 repairs, retain claim and escalate.

Recovery is narrower than repair:

- At most two retries of a definite transient failed read per read/tick.
  Diagnose read/query errors rather than repeatedly retrying invalid requests.
- Idempotently ingest existing events, rebuild a missing incident index, and
  complete demonstrably incomplete bookkeeping under the gate, from current
  evidence and verified prior operation disposition.
- Never automatically retry uncertain writes, launches or assignment messages;
  never expire claims/gates, replace unknown workers, reset state or silently
  repeat a task. Definite pre-start failure still needs stopped proof and human
  reconciliation before a replacement handoff.
- Missing capabilities, corrupt authority, exhausted repairs, material conflicts
  or scope changes stop the affected action. Preserve claims/evidence, explicitly
  identify next human owner/action and isolate safe independent work only when
  its independence is established.

Each canonical incident file includes `id`, `originalReporter`, `recordingActor`,
`changedUtc`, `nextOwner`, `nextAction`, `evidence[]`, plus category, expected/
observed behavior, affected claim/handoff, first/last observation, status,
append-only recovery history/count and resolution evidence. Unknown reporter
stays unknown. Deduplicate the same underlying problem/handoff; repeated
observations do not change meaningful-change time or create new incidents.
Discover files independently of the index and verify previously indexed files
still exist. Corrections/resolutions preserve original evidence and dated notes.

No automatic instruction edits, setting/schedule changes, architecture recovery
loop, Tester, ownership expiry or human-command protocol is introduced here.
The Architect-versus-Tester next choice in #224 remains unresolved.
