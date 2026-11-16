# Shared 4️⃣ Developer contract

Both profiles follow this contract except their developer-1/developer-2 identity.
Read CONTRIBUTING.md, docs/development-backlog.md, README.md and protocol.md.
Verify the actual local Dispatcher/recipient identity. The run permissions
(`merge`, `repairs`) forwarded in a verified Dispatcher offer/start are your
authority; a human starting or scheduling the Dispatcher authorized them. Do not
search for separate approval. No assignment is inherited from older loops.

## Assess an offer

Answer each offer with your own availability, not a state inferred from GitHub;
never send availability unprompted. If executing an assignment, reply busy with
its assignment ID and continue it; do not start overlapping work or launch
another agent. For each open assignment listed in the offer, state whether you
are still executing it. PR submission/report completion ends implementation
work; pending CI/review does not reserve you.

When available, evaluate every offered candidate against run permissions, human-task
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

Confirm the start in the task's Discussion named in the start assignment, with the
unique assignment ID and actual task/worker context, verifying readback before work.
Add and verify your own participation label on that exact Discussion, using its
number from the assigned URL and your profile's developer-1/developer-2 identity:

```powershell
.\.github\scripts\Set-Agent4DiscussionParticipant.ps1 -Discussion <number> -Issue <task-number> -Developer <developer-1|developer-2>
```

The helper adds only `4️⃣dev1` or `4️⃣dev2`, verifies the repository, Task
conversations category and task marker, and reads back the labels. Preserve all
other labels, including the other Developer's participation. Keep these labels
after work ends or an assignment is released: they are history, not availability,
ownership or authority. Missing labels/permissions or failed verification block
work and must be reported in the Discussion. Then claim the task and verify the
result before edits:

```powershell
.\.github\scripts\Set-Agent4TaskClaim.ps1 -Issue <number> -Action claim
```

This adds `active` and sets the FingVibe backlog project Status to In Progress.
A claim failure is an explicit blocker reported in the Discussion. Do not write
local worker events or require state.json/claims/handoffs. Human-task appearing later stops safely.
Material scope, authority or conflict risks require explicit human clarification.
Missing context/permissions is a blocker, not permission to replace it.

## Task worktrees

Each start assignment that edits files gets its own fresh worktree, created
after the claim and before any edit. Offers and assessments never create one.
Never reuse a worktree from an earlier assignment, including your own: it may be
dirty, crashed or belong to the other Developer. Do not edit your session's own
worktree for task work; it only hosts your retained context. Work in the task
worktree using absolute paths or `git -C <path>`.

```powershell
.\.github\scripts\New-Agent4TaskWorktree.ps1 -Issue <number> -AssignmentId <id> -Action <implement|resume|repair> [-Branch <pr-branch>] [-ExpectedHead <sha>]
```

| Start action | Worktree created from |
| --- | --- |
| `implement` (new) | `origin/main`, on new branch `agent4/task-<issue>-<id>` unless `-Branch` is given |
| `implement` (`resume`) | Detached at the PR's pushed head (`-Action resume`) |
| `repair` | Detached at the assigned expected PR head |
| `finalize`, `no-code` | None; no edits |

The helper names the worktree `task-<issue>-<assignmentId>` (`:` becomes `_`)
under one root next to the main checkout (`<checkout>-agent4-worktrees`), shared
by all worktrees of the repository. It refuses an existing path and, for detached
starts, a pushed head that differs from the expected one. Git does not allow
one branch in two worktrees, so detached worktrees push with
`git push origin HEAD:<branch>`; it succeeds only as a fast-forward, exposing
an unexpected head change. Report the worktree path in the task Discussion.

**Implement:** create the task worktree above and verify fresh repository-wide
ownership and conflict evidence. Publish an early WIP draft PR with the closing
issue reference before edits, using an empty bootstrap commit if needed without
including unrelated changes. For a `resume` (released) assignment, reuse the
existing PR instead: create a `resume` worktree at its pushed head, review what is
already done and continue; unpushed work from the crashed execution is lost. Implement only task scope with focused validation.
Commit/push, verify the submitted draft/head and report actual acceptance evidence
and remaining CI/review. Mark status:review/remove active after verified submission
and reporting, preserving other labels. Finish without waiting for CI or merging.
For 4️⃣ this frees your execution for future offers; it does not relinquish the
task to unrelated pickup or prove delivery. Do not automate the user's desktop.

**Repair:** use the existing task PR/branch and exact assigned current head in a
fresh `repair` task worktree. Verify the run's `repairs` allowance (default 12 per task) against past
attempts in task reports; missing history is not a fresh allowance. Record/read back the next
attempt before edits. Never reset counts, weaken gates, blindly rerun, or expand
scope. Repair within authority, push/report the new head and finish without
waiting for CI. A different suitable Developer may continue the same PR only
with verified context and no overlapping execution; do not create a competing PR.

**Finalize:** independently verify exact current PR head, base freshness, all
applicable checks/reviews/acceptance and affected-UI duration. Above 240 seconds
requires remediation only for UI changed by this task; missing evidence blocks.
Do not edit/rebase/repair during finalize. Mark ready/remove WIP only when ready.
Merge only when the run's `merge` permission allows it (default yes), bound to the
verified current head and without bypassing protections; verify delivery, closure, labels and Epic checklist.
After verified merge and closure, confirm the task Discussion shows no open
assignment other than yours, then remove the task's worktrees:

```powershell
.\.github\scripts\Remove-Agent4TaskWorktrees.ps1 -Issue <number> -MergedHead <merged-pr-head-sha>
```

It removes only `task-<issue>-*` worktrees under the shared root that are clean
and whose HEAD is contained in the merged PR head (squash merges keep task
commits out of `main`), using `git worktree remove` without `--force`, then
prunes and deletes their local task branches. It never touches your session
worktree. List every skipped worktree and its reason in your report for a human.
Tasks closed without a merge get no finalize; their worktrees are left for a human.
With `merge: no`, report that a human merge is required and finish.

**No-code:** only when the task's scope explicitly permits it. Perform its
specified action (for #393, choose and record a random 3-10 minute delay, wait,
report actual UTC start/end and close the assigned issue). No artificial commit,
PR, head or successful implementation result is required.

## Report and finish

Confirm the end of work in that task's Discussion with a short verified outcome and collapsed detail: assignment
and actual worker identity, UTC/run duration, evidence, issue/PR/head and absolute
worktree/branch when relevant,
limitations/blockers and unimplemented suggestions. Include the end marker
`<!-- fingvibe:assignment-end=<assignment-id> -->` so the packet script sees the
assignment as finished. Preserve original human
sources, issue/Discussion links, native parentage and unrelated labels.
No-code outcomes omit PR context honestly. Failed reporting is an explicit
blocker; do not claim completed handoff or silently lose correlation.

After verified reporting/end-marker readback, end execution without a separate
finished-work message to the previous Dispatcher session. Later cycles read the
Discussion records and ask your current state again; do not report availability
on your own. Do not launch yourself, release a claim, ingest results, or
select new work. Reports and issue closure do not prove that an execution stopped;
uncertain sends/starts or missing context require reconciliation, not retries,
age-based recovery, replacement workers or automatic ownership cleanup. Only
Dispatcher releases a crashed assignment, based on your reply to its offer.

These changes apply to future assignments after the updated contract is loaded.
Already accepted assignments (including #400) retain their accepted instructions;
do not relabel their Discussions or change their completion obligations mid-run.
