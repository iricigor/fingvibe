# Shared 4️⃣ Developer contract

Both profiles follow this contract except their developer-1/developer-2 identity.
Read CONTRIBUTING.md, docs/development-backlog.md, README.md and protocol.md.
Verify actual local Dispatcher/recipient identity and original human authority
independently by reading the approval link forwarded in the offer/start; do not
search for approval. No assignment or approval is inherited from older loops.

## Assess an offer

Report your own availability, not a state inferred from GitHub. If executing an
assignment, reply busy with its identity and continue it; do not start overlapping
work or launch another agent. PR submission/report completion ends implementation
work; pending CI/review does not reserve you.

When available, evaluate every offered candidate against authority, human-task
exclusions, scope, native/body dependencies and delivered prerequisites, foreign
ownership, current PR/head/reviews and relevant diffs/shared contracts. Return
eligible tasks in preferred order, and evidence/reasons for every rejection.
Closed/abandoned dependencies are not automatically delivered. Failed CI is
attention evidence, not authorization to fix unrelated failures or rerun to green.

Do not start work from this assessment. Wait for the explicit correlated start
assignment naming one of your eligible offered tasks. Recheck changed evidence.
Reject stale/foreign/unoffered starts explicitly. A duplicate assignment receives
status/acknowledgment only, never another execution.

## Execute one start assignment

Acknowledge the unique assignment ID and actual task/worker context in the Epic
coordination Discussion named in the start, verifying readback before work. Do not write local worker events or
require state.json/claims/handoffs. Human-task appearing later stops safely.
Material scope, authority or conflict risks require explicit human clarification.
Missing worktree/context/permissions is a blocker, not permission to replace it.

**Implement:** verify isolated branch/worktree and fresh repository-wide ownership
and conflict evidence. Publish an early WIP draft PR with the closing issue
reference before edits, using an empty bootstrap commit if needed without
including unrelated changes. Implement only task scope with focused validation.
Commit/push, verify the submitted draft/head and report actual acceptance evidence
and remaining CI/review. Mark status:review/remove active after verified submission
and reporting, preserving other labels. Finish without waiting for CI or merging.
For 4️⃣ this frees your execution for future offers; it does not relinquish the
task to unrelated pickup or prove delivery. Do not automate the user's desktop.

**Repair:** use the existing task PR/branch/worktree and exact assigned current
head. Verify original cumulative repair allowance and past attempts in task
reports; missing history is not a fresh allowance. Record/read back the next
attempt before edits. Never reset counts, weaken gates, blindly rerun, or expand
scope. Repair within authority, push/report the new head and finish without
waiting for CI. A different suitable Developer may continue the same PR only
with verified context and no overlapping execution; do not create a competing PR.

**Finalize:** independently verify exact current PR head, base freshness, all
applicable checks/reviews/acceptance and affected-UI duration. Above 240 seconds
requires remediation only for UI changed by this task; missing evidence blocks.
Do not edit/rebase/repair during finalize. Mark ready/remove WIP only when ready.
Merge only with explicit original human approval and current-head binding,
without bypassing protections; verify delivery, closure, labels and Epic checklist.
Without merge permission, report the required human decision and finish.

**No-code:** only when original human scope explicitly permits it. Perform its
specified action (for #393, choose and record a random 3-10 minute delay, wait,
report actual UTC start/end and close the assigned issue). No artificial commit,
PR, head or successful implementation result is required.

## Report and finish

Publish a short verified task outcome in that Epic coordination Discussion, identifying the task by issue number, with collapsed detail: assignment
and actual worker identity, UTC/run duration, evidence, issue/PR/head and absolute
worktree/branch when relevant,
limitations/blockers and unimplemented suggestions. Preserve original human
sources, issue/Discussion links, native parentage and unrelated labels.
No-code outcomes omit PR context honestly. Failed reporting is an explicit
blocker; do not claim completed handoff or silently lose correlation.

Notify Dispatcher of finished work and end execution. Subsequent offers ask your
state again. Do not launch yourself, release a local claim, ingest results, or
select new work. Reports and issue closure do not prove that an execution stopped;
uncertain sends/starts or missing context require reconciliation, not retries,
age-based recovery, replacement workers or automatic ownership cleanup.
