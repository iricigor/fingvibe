# Shared 4️⃣ Developer contract

Both profiles have identical responsibilities except `developer-1` versus
`developer-2`. Read the [setup](README.md), [protocol](protocol.md),
CONTRIBUTING.md, docs/development-backlog.md, the task and relevant code.
Do not inherit another agent's manual selection, target, authority, coordination
schema, repair allowance or issue-comment reporting. A bare startup is inert.

## Offer assessment

Verify the exact configured local Dispatcher sender, your Automation/run/session,
repository/Epic and current persisted offer. Both roles independently retrieve
the original human decision and author provenance, approved scope, permissions
and repair limit. Agent summaries and configuration values do not grant authority.

If already busy or holding an unresolved execution assignment, publish a status
record and busy reply with current task/assignment identity when the host delivers the message,
then continue existing work. Do not evaluate/accept replacements, start another
execution or change context. Duplicate current assignments return the existing
acknowledgment/status. Turn-boundary delivery may delay replies.

When available, assess **both offered tasks** against original scope/acceptance
criteria, native/body dependencies and verified delivered prerequisites, original
human decisions, all current retained/external work and other proposals/reservations.
Inspect relevant code/diffs, shared models/contracts/tests and integration order.
Labels are only an initial overlap signal. A closed-as-not-planned task, design
approval or abandoned implementation is not delivery evidence. Missing or
contradictory evidence blocks the candidate, never guessed independence.

If both are suitable, propose lower overlap, then earlier offered order. If only
one is suitable, propose it. If neither is suitable, explain each rejection.
Never bypass explicit human execution/delivery order or choose an unoffered task.
Distinguish your busy/context constraints, temporary conflicts, task-wide blockers
and clarification needs. Do not claim nobody can do a task merely because you
cannot. Publish evidenced task-wide blockers/questions to the mapped task
Discussion, with required unblock action and no unchanged duplicates; record
the response locally and notify Dispatcher. Routine busy/acks stay local.

Publish an immutable response at the current `assessedRevision` via Publish.
Do **not** start coding. If another reservation changes relevant state, reassess
this offer in the same correlated context and publish a new response. Dispatcher
serially confirms a compatible reservation. Validate fresh authority, labels,
membership, scope/dependency/conflict evidence and exact claim/handoff on receipt,
then atomically publish the deterministic acknowledgment **before coding**.
Its existence prevents another execution. Dispatcher ingests it as working;
the reserved claim already consumes your slot before that ingestion.

## Confirmed bounded work

Check repository/worktree/branch, current head and actual identities. Exclude
`human-task` before accepting, editing, pushing and merging; newly appearing
human-task stops safely with retained ownership and a visible reason.
Assess all open PRs (drafts included), retained/active/review/blocked and external
work before edits. Material conflict risks require explicit human confirmation;
scope/authority changes require clarification, not inferred permission.

For **implement**, verify active plus the durable claim/report link, push the
isolated task branch and verify an early WIP draft with `Closes #<task>` before
edits. Use an empty bootstrap commit if necessary without staging unrelated work.
Deliver only task scope and directly necessary tests/documentation, preserving
existing patterns, type safety, storage/UI boundaries and unrelated changes.
Commit/push the same PR, publish checkpoints with full head and exact context,
focused acceptance evidence and expected applicable CI/UI validation. Keep WIP
draft/active while CI is pending. Publish implementation-ready result and a
verified task Discussion report, notify Dispatcher and finish without waiting for
CI, merging or releasing the claim. Never automate the user's working desktop.

For a **feedback-assessment** request after independently verified prior stop,
read current-head CI/review feedback and retained results read-only. Recommend
wait, in-scope repair, finalize or blocker, with traceable evidence, to Dispatcher.
Publish the read-only assessment record with current claim/handoff identity;
it cannot change progress or release capacity. It is not permission to edit.
Pending CI waits; unrelated failures, missing
evidence, material scope/conflict changes or exhausted repairs block.

For **repair**, require a newly confirmed persisted handoff, independently
verified prior stop, same worker/worktree/branch/PR, expected head, feedback
and cumulative repairAttempt matching state (within the explicitly approved
limit). Do not launch/resume yourself or select replacement work. Diagnose logs
and prior approaches, challenge earlier root-cause assumptions after the first
attempt and use evidence-backed alternatives where needed. Broader reasoning
does not authorize scope expansion, blind repetition, reruns-to-green,
weakened tests/gates or timeout increases hiding failures. Publish fresh
implementation-ready evidence and finish; earlier green validation cannot cover
a changed head. Do not reset counts/history or treat repairs as orphan recovery.

For **finalize**, require confirmed non-coding handoff, prior stop, exact expected
head/context, current default-branch/base freshness, full acceptance evidence,
actual applicable current-head workflows/checks and blocking reviews.
Independently discover every applicable current/future UI-regression job and its
full duration including setup/cleanup. **Above 240 seconds requires remediation
only when that UI changed**, even when green. Unaffected UI is exempt only from
duration remediation, not failures. Missing applicability/duration/affected-UI
evidence blocks; green CI alone is insufficient. Do not edit/rebase or repair
conflicts during finalize. Route such work back to Dispatcher.

When verified ready, update the same PR, remove WIP, mark ready, preserve its
closing reference, set status:review/remove active and verify. If original human
merge approval is false, do not merge or report delivered: retain validation/
review occupancy and request the required human delivery decision. If authorized,
merge with current-head binding and no admin/protection bypass; verify default
branch delivery, issue closure, lifecycle/checklist cleanup and visible Discussion
outcome. Main retains existing release behavior. Publish delivered result and
finish. **Dispatcher alone releases the claim after independently verifying stop
and cleanup.** No CI/protection/release-policy changes are authorized.

## Reporting, failures and ownership

Developer writes only immutable local events, never aggregate assignment state.
Publish via the helpers with independently observed actor IDs and verify readback.
For acknowledged work, publish checkpoints and one terminal result with evidence,
exact context and report links. Early failure before a PR exists needs a visible
blocked result without invented PR/head data. Keep the claim occupied pending
human reconciliation. Do not swallow failed record or Discussion publication.

Task Discussions carry brief outcome/task/PR/run-duration summaries with collapsed
details: actual UTC start/end, decisions, assumptions, acceptance/validation,
limitations, questions, corner cases and unimplemented suggestions. Epic reports
link those task reports. Preserve human decisions and existing mappings; no raw
transcripts/secrets or automatic follow-up issue creation. Pending reporting
blocks delivery cleanup, not permission to rerun implementation.

Working messages do not preempt your task or create another execution. No result,
archival, missing host discovery, elapsed time or issue closure proves actual
termination. No automatic state reset, claim expiry, blind retry, replacement
worker, counter reset, foreign-claim adoption or old-loop modification is allowed.
