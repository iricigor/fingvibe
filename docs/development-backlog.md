# Development backlog contract

This contract prepares issue intake and future scheduled pickup. It does not
implement dispatch, agent invocation, review automation, or merging. Labels
describe state; they do not enforce authorization, locking, or merge protection.

## Intake and planning

Use the four templates in GitHub's new-issue chooser:

| Template | Purpose | Initial label |
| --- | --- | --- |
| 🔥 Epic | Agreed larger goal, success criteria, decisions, and child checklist | `type:epic` |
| 🛠️ Task | Bounded scope, acceptance criteria, dependencies, validation, and proposed size/priority | `type:task` |
| 🪲 Bug | Version, Windows version, reproduction, expected/actual behavior, optional redacted evidence | `bug` |
| ✨ Feature | Problem/use case, desired outcome, optional solution | `enhancement` |

New issue titles default to the template's emoji and type followed by a colon
and space, for example `🔥 Epic: `. Existing issue titles are unchanged.

Intake requires no estimates or implementation plans. A human triages it.
A small report/request can be refined **in place** with the task sections and
`type:task`, preserving its original `bug` or `enhancement` label. A larger
request can lead to an Epic and linked tasks; preserve the source request and
avoid obligatory duplicates. Attach children using GitHub sub-issues as well
as the Epic checklist. Task dependencies are distinct from parentage and priority.
Use native blocking relationships where available and list them in the body;
disagreement between the two must be resolved before execution.

No template grants readiness or assigns an agent. Additional chore, refactor,
or agent-role templates are unnecessary.

## Label vocabulary

Preserve unrelated existing labels. `bug` and `enhancement` already express
defect/feature intent; do not duplicate them with `type:bug` / `type:feature`.

| Label | Meaning |
| --- | --- |
| `type:epic` | Organizing issue, never executable by pickup |
| `type:task` | Issue refined into bounded execution work |
| `size:micro` | One narrowly scoped change in one owning component with focused validation |
| `size:small` | A bounded related set of changes with clear acceptance criteria and validation |
| `priority:high` | Human-prioritized ahead of normal work |
| `priority:normal` | Ordinary approved backlog work |
| `priority:low` | Approved work behind normal work |
| `status:ready` | Human has approved the current scope for pickup; not a claim |
| `active` | Authorized implementation underway; existing Architect semantics remain unchanged |
| `status:review` | Verified published PR awaiting checks/review/merge; not available for pickup |
| `status:blocked` | Cannot advance; reason and recovery action must be recorded |

Exactly one size and priority are required for pickup. No size means not
eligible; larger work must be split. `type:epic` and `type:task` are mutually
exclusive. Ready, active, and review are mutually exclusive stable states.
Blocked can accompany active or review to describe a retained claim, but not
ready. No lifecycle label means intake/planning or completed work; actual
closure/merge state distinguishes them. Do not invent `status:done`.

The existing `active` label is removed after the final PR is verified ready for
review, not after opening the initial WIP draft or after merge. For this
lifecycle, move to `status:review` at that handoff.
It is also removed when implementation explicitly stops and relinquishment
is verified. Architect still requires separate implementation authorization,
conflict assessment, and any required risk confirmation; readiness does not
bypass those gates. Existing issues are not bulk-migrated by this change.

## Approval, ownership, and work in progress

Only a human approves scope, size, priority, and readiness. Record approval of
the current scope in the issue discussion, identifying the approving human.
Material scope/acceptance changes invalidate it and require human reapproval.
Agents may draft plans but may not grant their own approval, change limits,
weaken gates, or expand permissions. Future automation must verify approval
provenance, not merely the presence of a label.

The issue assignee identifies the implementing agent's GitHub account, not
its current execution state. Record the agent run/session URL or identifier,
claim time, approved scope reference, and linked PR in an issue comment.
Do not create agent-specific labels. Shared bot accounts require a run identifier
to distinguish workers. Reviewer assignment does not replace implementation
ownership. Lack of an assignee does not prove a claim is free.

Start with **one task in flight repository-wide for scheduled pickup**.
Claimed/startup, implementing, review (including draft PRs), changes requested,
and blocked-but-claimed work all consume that slot. Publishing a PR does not
release it. Unclaimed blocked backlog work does not consume it. Existing manual
implementation or review work must also prevent additional scheduled pickup;
this does not prohibit independently authorized human work.

Before selecting work, reconcile all open active/review issues, agent claims,
and open PRs (including drafts), with complete pagination. An unlinked PR,
ambiguous ownership, missing approval, inaccessible API, or unknown agent state
stops dispatch with an actionable report; do not interpret missing evidence
as idle capacity.

## Future pickup algorithm and locking requirements

1. Check the human-controlled pause setting and reconcile work in progress.
2. Consider only open `type:task` issues with human-approved current scope,
   `status:ready`, one permitted size and priority, no conflicting state,
   no existing claim/PR/agent assignment, and no unresolved blockers.
   Closed-but-unmerged prerequisites are not automatically satisfied: require
   evidence that their acceptance criteria were delivered or a human waiver.
3. Sort high, normal, low priority, then ascending issue number. Dependency
   readiness filters candidates before priority ordering.
4. Under a repository-wide serialized claim operation, re-read eligibility,
   pause state, approval, and capacity immediately before recording ownership.
5. Persist the claim and run correlation before invocation, remove ready,
   and mark active. Invoke at most once for that claim. Verify assignment/run
   creation; partial failures retain the claim and block further dispatch.

Labels and separate GitHub API writes are **not an atomic lock**. The future
dispatcher needs one shared Actions concurrency group for hourly, manual,
and recovery paths, with in-progress cancellation disabled. Do not assume all
queued triggers will run. This serializes compliant workflow runs, not human
edits or other integrations: all automated claim writers must use that same
entry point, re-read state, and fail closed on external changes. Durable
claim/run correlation and idempotent invocation or explicit reconciliation
are also necessary; concurrency alone cannot prevent duplicates after a crash.
If the invocation mechanism cannot resolve an uncertain start, require human
recovery rather than starting another worker.

## Transition table

Each multi-write transition requires reconciliation; a partially applied
transition is not permission to dispatch.

| Trigger | Authorized actor | Preconditions | Resulting labels/ownership | WIP effect |
| --- | --- | --- | --- | --- |
| New issue | Reporter | Appropriate template | Type/intent only; unclaimed | None |
| Approve pickup | Human | Bounded complete scope, size/priority, approval recorded | Ready; unclaimed | None |
| Claim/start | Serialized dispatcher | Eligible, unpaused, empty slot, state re-read | Remove ready; active; persist owner/run claim | Reserve 1 |
| Finalize verified ready PR | Implementer/publisher | Final PR and remote branch verified and linked; no longer WIP/draft | Remove active; review; retain owner/claim | Retain 1 |
| Checks fail / changes requested | Reviewer reports; implementer resumes existing run or authorized replacement | Same approved scope, no concurrent worker | Review while waiting; active instead when implementation resumes | Retain 1 |
| Block implementation/review | Owner or human | Reason and recovery action recorded | Add blocked; retain active/review and claim | Retain 1 |
| Block unclaimed backlog | Human or dependency reconciliation | No run/claim/PR | Remove ready; blocked | None |
| Resume same claimed work | Human or bounded recovery under original authorization | Blocker resolved, owner/run verified, unchanged scope | Remove blocked; active or review; same claim | Retain 1 |
| Verified merge/delivery | Reconciler | Linked intended PR merged, no remaining worker or PR | Close issue as completed; clear lifecycle labels/claim | Release 1 |
| Stop/abandon claimed work | Human-directed recovery | Worker stopped, PR disposition verified, claim reconciled | Clear active/review; blocked with reason; release claim | Release 1 |
| Reapprove stopped work | Human | Prior run stopped, no open PR/claim, scope reapproved | Remove blocked; ready | None |

Replacing a worker must verify the previous run is stopped before starting
another under the retained claim. Reviewer comments do not authorize scope
expansion. Closed/unmerged PRs require explicit stop/recovery, not automatic
readiness. Issue closure without verified delivery must not silently free a
running claim.

## Recovery, pause, and worked examples

Age is a diagnostic signal, not a lease expiry. A stale claim or missing PR
requires inspection of the correlated run. A failed worker is marked blocked;
an inaccessible or unknown run holds the slot. A merged PR permits release
only after delivery and worker termination are reconciled. Conflicting labels,
assignees, dependencies, or PR state require a report identifying the issue,
run/PR evidence, mismatch, and human action needed.

The future dispatcher must provide a human-controlled pause independent of
worker-editable issue labels, checked before selection and invocation. For an
Actions implementation, disabling the dispatch workflow prevents new runs;
a pause flag checked by queued/running dispatch steps is also needed. Pausing
does not terminate an already-running coding agent or discard its claim.
Stopping that worker is a separate explicit action with verified termination.
Unpausing must reconcile retained work before starting anything new.

| Scenario | Expected outcome |
| --- | --- |
| Normal task | Human approves A; dispatcher claims A; PR publication changes active to review. Hourly runs select nothing until A's merge/delivery and stopped worker are verified. |
| Review changes | A's PR fails a check. A retains the slot; corrections resume implementation on A without dispatching B or creating a second worker. |
| Blocked backlog | Unclaimed B has an unresolved dependency: blocked, no slot consumed. Once resolved, human approves readiness; B still waits behind any claimed A. |
| Repeated pickup | Two triggers target A. The shared claim path serializes them; the second re-reads A's durable claim and does not invoke again. |
| Crash after invocation | A has a claim but start confirmation is missing. Reconcile the correlated run or stop for human recovery; never infer failure and invoke again. |
| Abandoned worker | A is old and has no PR. Keep the slot, investigate, then verify termination before releasing to blocked. Human reapproval is required for fresh pickup. |
| Closed/unmerged PR | A's PR is closed without merge. Hold the claim pending verified stop/recovery; do not label ready automatically. |
| Pause during review | Human pauses pickup. A remains in review and retains the slot. Unpause reconciles A rather than dispatching B. |

## Operational limits of this delivery

Templates and labels become available independently: labels are repository
metadata; the issue chooser uses templates from the default branch after merge.
Markdown templates guide users but do not validate required fields. The future
dispatcher must validate completeness and allowed label combinations itself.
This PR does not establish that agent invocation, pause controls, serialized
claiming, or protected review/merge checks already exist.
