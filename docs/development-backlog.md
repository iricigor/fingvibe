# Development backlog contract

This contract prepares issue intake and future scheduled pickup. It does not
implement dispatch, agent invocation, review automation, or merging. Labels
describe state; they do not enforce authorization, locking, or merge protection.

## Local Dispatcher exception

[Task #222](https://github.com/iricigor/fingvibe/issues/222) delivers
[⏩ Dispatcher](../.github/agents/automation-dispatcher.agent.md), bounded
Developer assignments, and the [short kickoff](automation-prompts/dispatcher.md).
Coordination and reporting rules live directly in the two agent definitions.
It does not install or activate desktop Automations or implement the broader
Actions loop #96-#108.

A human may explicitly authorize unattended selection, implementation, up to
three automatic repairs, and validated merging of eligible native task children
of one Epic identified in the installed Dispatcher description. Record that approval;
the Epic URL or saving a description alone is not authorization. In this bounded
exception individual ready/size/priority approvals are not prerequisites, and
agents must not manufacture them. All other workflows retain their own gates.
The short kickoff identifies the target Epic and Developer Automation by name.
Dispatcher discovers/verifies its actual ID and the repository's default branch.
The first target, #191, and execution policy were explicitly approved by
@iricigor and recorded on #222; the agent carries that reference without requiring
copied IDs or repeated approval text in the kickoff. That original approval
allowed one repair; #285 records @iricigor's 2026-11-08 expansion to three
progressively deeper repairs per claim. Expanded repair assignments cite that
additional approval without changing the original target or authority.
A different target requires human authorization. Scheduling activation remains
separately approved.
Merges to main retain the existing release trigger and all actual gates.

Dispatcher alone selects/claims and routes implement, repair, or non-coding
finalize assignments. Developer starts inert without an assignment and keeps the
same isolated task branch/PR through subsequent runs. Dispatcher does not wait
for coding/CI. One repository-wide claim includes startup, implementation, draft
validation, review, and blocked/uncertain work. Worker reports, issue closure,
and queue admission are not proof that execution stopped. Slot release requires
verified delivery, stopped worker, and reconciled cleanup.

Dispatcher and Developer's finalizer independently enforce the user-approved
UI-regression duration rule before finalization/merge. Discover all applicable
current and future regression jobs, verify current-head job duration and
affected-UI evidence, and require remediation above 240 seconds only when that
UI changed. Green CI alone is insufficient. Duration repairs use the existing
shared three-attempt automatic repair allowance; exhausted repairs, missing
evidence or material scope changes block rather than authorize merging. This instruction
does not change CI gates, merge authority, scheduling or ownership release.

Capacity checks distinguish genuine unfinished work from historical label-only
cleanup. Open PRs (including drafts), open active/review work, known running
workers, and explicit unresolved Dispatcher claims remain repository-wide
blockers even after issue closure or PR merge. Partial/uncertain Dispatcher
launches or messages never qualify for a historical exception.

Closed historical tasks with verified merged linked PRs and no evidence of
genuine unfinished work require stale lifecycle-label/missing manual-release
reconciliation only within the configured Epic's direct native children.
Outside that Epic, those historical records alone do not consume capacity;
leave labels and ownership unchanged. An undiscoverable historical manual
session alone is not evidence of a running worker or unresolved Dispatcher
claim. Verify native membership and merged PR disposition before excluding
historical records; inaccessible/ambiguous membership, missing delivery evidence,
and closed-unmerged PRs remain blockers. Within-Epic historical cleanup still
requires reconciliation, not automatic label removal or ownership release.
This exception does not weaken the release requirements for genuine claims or
change the broader scheduled Actions policy.

All compliant local ticks use the persistent, atomic-create repository gate in
.github/scripts/Invoke-DispatcherGate.ps1, with the same default local state root.
This is single-PC serialization, not a GitHub/Actions lock or protection against
humans/other hosts. Re-read GitHub state before consequential writes. Durable
task-comment correlation is required before launch. Partial launch/message
results hold the claim; do not retry uncertain starts. No claim/gate expiry,
automatic worker replacement, or orphan recovery is authorized. Human inspection
approximately every six hours does not make uncertain state safe.

The Dispatcher description proposes fifteen-minute pickup. Human-controlled
pause prevents new ticks; it does not terminate workers. At most three automatic
repair attempts per claim are permitted only for actionable implementation-related
feedback or in-scope affected-UI duration violations. The allowance is shared
across checks/reviews, not renewed per failure, revision, tick or finalizer.
Dispatcher persists and verifies the increment before launch; Developer verifies
repairAttempt equals repairCount (1-3), the strategy, and prior repair evidence
against retained handoff/result history. Attempt one is targeted diagnosis/fix;
attempt two reassesses the prior root-cause assumption and investigates an
alternative explanation; attempt three compares plausible in-scope solutions
and chooses an evidence-backed alternative when earlier approaches failed.
Reports explain the evidence and why the chosen approach should succeed.
Creativity broadens reasoning, not permission: no blind repetition,
reruns-to-green, weakened tests/gates, timeout increases hiding failures,
speculative rewrites, or scope expansion.

Each repair retains the same task/PR/isolated worktree/branch, verifies preceding
execution stopped, and publishes a fresh checkpoint requiring fresh applicable
validation. Persistent actionable in-scope failures may use the next remaining
attempt; after three unsuccessful repairs, retain the claim and block for human
action. Unrelated validation problems, material scope changes/conflicts,
human-task labels, unavailable capabilities/evidence, and uncertain launch/delivery
block immediately even with attempts remaining. Never reset existing claim
counts/history or retry uncertain launches. The policy change alone does not
restart blocked work, reconcile uncertainty, or release ownership.

Task issues hold structured coordination/result comments and short per-run
summaries with collapsed-by-default detailed logs. Epic reporting is a brief
terminal/blocker outcome linked to those task reports plus its child checklist.
This presentation also replaces detailed Epic diagnostics in the manual-worker
mode below; it does not change that mode's execution/merge authority. Per-run
duration and overall task elapsed time are distinct; never fabricate interruption
timing. Live launch/context reuse/termination must be trialed in the intended
desktop host before scheduling; instruction delivery is not runtime verification.

## Explicitly invoked manual-worker exception

[Task #189](https://github.com/iricigor/fingvibe/issues/189) adds the
[⏩ Epic Developer](../.github/agents/automation-epic-developer.agent.md) and a separate
[Timeline kickoff](automation-prompts/timeline-worker.md). This is an instruction
delivery, not implementation or activation of the scheduled dispatcher.

For this first iteration only, a human explicitly selecting that worker and
invoking "complete and merge at most one eligible task" supplies implementation
and merge authorization for one direct native child of the specified Epic.
The kickoff must identify the target; Epic membership, an agent file, or a saved
prompt alone does not authorize execution. Creating/saving a desktop Automation
is not activation approval; an unattended schedule requires separate approval.

In this explicitly invoked mode, `status:ready`, size, and priority labels and
per-candidate readiness approval records are not prerequisites. The worker
checks delivered dependencies, follows explicit Epic task order (otherwise
ascending issue number), resolves ordinary ambiguities autonomously, and records
decisions, assumptions, questions, corner cases, and unimplemented suggestions in
the task's collapsed report, linked from its parent Epic. It cannot drop acceptance
criteria, expand scope, change gates, or manufacture completion. Only requested changes and directly necessary tests
and documentation are allowed.

The worker checks repository-wide claims and open PRs, including drafts, before
pickup; any unfinished work prevents selection. It records a claim, marks
`active`, and verifies an early WIP draft before edits. Validated PR publication
moves the claim to `status:review`; ownership remains through merge. Failed or
interrupted work retains its claim. No age-based expiry or orphan recovery is
implemented, and labels/PRs are not an atomic lock. Humans must stagger starts;
this is not safe serialized unattended dispatch.

The worker waits for actual applicable final-revision validation and blocking
reviews, repairs implementation-caused failures within scope, and merges only
verified work without bypass. Unrelated failures or unavailable evidence block
delivery. It verifies merge, issue closure, lifecycle cleanup, and the Epic
checklist, then posts and verifies a mandatory task report with collapsed detailed
logs, a brief linked parent Epic outcome, and stops after one task.
The task report records actual run start/work end times in ISO 8601
UTC and total elapsed run duration calculated from those timestamps, task and
PR links, delivered work and validation outcome, decisions,
post-work comments, corner cases, questions to clarify later, and unimplemented
suggestions. Duration includes capacity checks, implementation, CI waits, repairs,
and delivery verification rather than active coding time. Truncate fractional
seconds after subtraction and report `HH:mm:ss` with nonwrapping total hours
and a human-readable equivalent, for example `00:42:17 (42m 17s)`.
Blocked runs measure until stopping and report progress and blockers without
claiming task completion; abrupt interruptions may prevent recording and do not
authorize orphan recovery or fabricated timestamps/durations. Missing or
inconsistent timing evidence must be reported as unavailable with the reason.

Merging into `main` retains the existing release-on-main behavior and triggers
the release workflow. These instructions do not alter or enable repository
auto-merge, protection, review gates, release policy, or app schedules. A kickoff
that forbids releases cannot authorize merging into `main` under that behavior.
This narrow instruction-only mode does not deliver or waive the full scheduled
loop's policy/protection/activation tasks #104–#108.

All other workflows retain the approval, selection, serialization, recovery, and
activation requirements below, except for the separately authorized local
Dispatcher mode above. In particular, Architect remains discussion-first
and publishes for human review without automatically merging its own delivery.
Host permissions and higher-priority instructions still apply to every agent.

## Development-environment planning

For the exploratory single-agent through four-agent designs and diagrams, see
[Autonomous agentic loop discussion](autonomous-agentic-loop.md), published
under [#216](https://github.com/iricigor/fingvibe/issues/216). Remaining Architect
and Tester UI/UX decisions belong to
[#217](https://github.com/iricigor/fingvibe/issues/217). These sketches do not
replace this contract or authorize implementation, merge automation, or activation.

[Epic #92](https://github.com/iricigor/fingvibe/issues/92) organizes the seven
development-environment task groups. Its completed child
[#80](https://github.com/iricigor/fingvibe/issues/80), delivered in
[PR #84](https://github.com/iricigor/fingvibe/pull/84), established this contract.
Its child [task #93](https://github.com/iricigor/fingvibe/issues/93) decomposes
the remaining work into the following bounded task proposals.

Every task below is a **direct native child of Epic #92**, as well as an entry
in its checklist. Each separately depends on #93's verified planning delivery;
the table lists additional prerequisites, not priority order. Task #93 itself
records #80 as its delivered prerequisite.

| Group | Task proposal | Additional prerequisites | Proposed size |
| --- | --- | --- | --- |
| 2: Pickup | [#96: Eligibility and WIP reconciliation](https://github.com/iricigor/fingvibe/issues/96) | #80 (delivered) | small |
| 2: Pickup | [#97: Serialized claims and human pause](https://github.com/iricigor/fingvibe/issues/97) | #96 | small |
| 2: Pickup | [#98: Supported Copilot invocation](https://github.com/iricigor/fingvibe/issues/98) | #97 | small |
| 2: Pickup | [#99: Handoff, recovery, and WIP release](https://github.com/iricigor/fingvibe/issues/99) | #98 | small |
| 3: Baseline | [#100: Approved product/WinUI rubric](https://github.com/iricigor/fingvibe/issues/100) | #80 (delivered) | small |
| 4: UI review | [#101: Current-revision capture provenance](https://github.com/iricigor/fingvibe/issues/101) | #80 (delivered) | small |
| 4: UI review | [#102: Substantive rendered-layout gate](https://github.com/iricigor/fingvibe/issues/102) | #100, #101 | small |
| 5: PO review | [#103: Acceptance and scope gate](https://github.com/iricigor/fingvibe/issues/103) | #100 | small |
| 6: Merge | [#104: Human merge/release-policy decision](https://github.com/iricigor/fingvibe/issues/104) | #80 (delivered), #100 | micro |
| 6: Merge | [#105: Main protection and trusted checks](https://github.com/iricigor/fingvibe/issues/105) | #102, #103, #104 | small |
| 6: Merge | [#106: Policy-gated auto-merge integration](https://github.com/iricigor/fingvibe/issues/106) | #99, #105 | small |
| 7: Enable | [#107: One approved end-to-end trial](https://github.com/iricigor/fingvibe/issues/107) | #106 | small |
| 7: Enable | [#108: Human activation approval/control](https://github.com/iricigor/fingvibe/issues/108) | #107 | micro |

All priorities are proposed **normal**. The generated tasks have only
`type:task`: size, priority, readiness, assignment, and execution remain
unapproved. Planning delivery does not implement or activate the loop.
Each task records acceptance/failure criteria, owning components, validation,
and required human decisions/access.

The release-on-`main` decision belongs to #104. If the approved policy requires
release-workflow changes, merge enablement stays blocked until a separately
bounded, human-approved child of #92 delivers them; this plan does not assume
permission to change release behavior. Product standards, scope, estimates,
readiness, repository access, trial work, and activation retain their human
approval requirements.

## Intake and planning

Use the four templates in GitHub's new-issue chooser:

| Template | Purpose | Initial label |
| --- | --- | --- |
| 🔥 Epic | Agreed larger goal, success criteria, decisions, and child checklist | `type:epic` |
| 🛠️ Task | Bounded scope, acceptance criteria, dependencies, validation, and proposed size/priority | `type:task` |
| 🪲 Bug | Version, Windows version, reproduction, expected/actual behavior, optional redacted evidence | `bug` |
| ✨ Feature | Problem/use case, desired outcome, optional solution | `enhancement` |

Task titles use the task emoji followed by a space and a descriptive title,
for example `🛠️ Simplify task titles`, without `Task:`; the `type:task` label
identifies the issue type. Existing open task titles have been normalized to
this convention; closed issue titles are unchanged. Epic, bug, and feature
titles retain the template's emoji and type followed by a colon and space,
for example `🔥 Epic: `.

Every repository issue must either be an Epic labeled `type:epic` or be a
direct native GitHub sub-issue of an issue labeled `type:epic`. This includes
bug and feature intake, not only issues refined into tasks. Identify the
appropriate Epic, attach each non-Epic issue using GitHub's sub-issue
relationship, and include it in the Epic's child checklist. Verify the native
parent, its label, and the checklist entry on GitHub; a title or body link
alone does not establish membership. Preserve valid existing parentage and
obtain human approval before moving issues between Epics. If the appropriate
Epic is unclear, ask the human before choosing or creating one. Report failed
attachment or verification as an intake blocker. This rule does not authorize
bulk migration of existing issues or implementation of any child.

Intake requires no estimates or implementation plans. A human triages it.
A small report/request can be refined **in place** with the task sections and
`type:task`, preserving its original `bug` or `enhancement` label. A larger
request can lead to an Epic and linked tasks; preserve the source request and
avoid obligatory duplicates. Attach children using GitHub sub-issues as well
as the Epic checklist, including the preserved source request unless it is
itself an Epic. Task dependencies are distinct from parentage and priority.
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
| `human-task` | Human-led work, optionally assisted by Copilot; excluded from unattended Developer selection and implement/repair/finalize handoffs |
| `size:micro` | One narrowly scoped change in one owning component with focused validation |
| `size:small` | A bounded related set of changes with clear acceptance criteria and validation |
| `priority:high` | Human-prioritized ahead of normal work |
| `priority:normal` | Ordinary approved backlog work |
| `priority:low` | Approved work behind normal work |
| `status:ready` | Human has approved the current scope for pickup; not a claim |
| `active` | Authorized implementation underway; existing Architect semantics remain unchanged |
| `status:review` | Verified published PR awaiting checks/review/merge; not available for pickup |
| `status:blocked` | Cannot advance; reason and recovery action must be recorded |

`human-task` applies in both manual-worker and local Dispatcher exceptions.
Dispatcher skips it; Developer independently checks before accepting and before
edits, pushes, or merges. Either agent may add it only when human intervention is
necessary, with a verified label and task comment specifying the reason/action.
Preserve unrelated labels; retained work also becomes blocked without releasing
its claim. Ordinary coding choices, pending CI, and routine dependency waiting
are not reasons to add it. Only humans remove it, and removal does not by itself
authorize resumption or release ownership. Human-led tasks may still be discussed
with Copilot interactively, as in #225.

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
   `status:ready`, one permitted size and priority, no `human-task` or conflicting state,
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
