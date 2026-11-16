# Simple loop4 dispatch

[Task #403](https://github.com/iricigor/fingvibe/issues/403) simplifies the
source environment introduced by #386. The Dispatcher collects task evidence,
sends script-built offers, waits for Developer assessments and sends explicit starts.
When offerable work or open assignments exist, the Dispatcher asks both Developers
for their availability/state; they answer only when asked and never report
availability on their own. If the packet has no candidates or open assignments
and the retained cycle has no unresolved offer/start, the Dispatcher ends without
calling either Developer. An unresolved offer/start is continued, not discarded
or resent.
PR submission frees a Developer for later work; pending CI does not retain a
Developer slot. [Task #413](https://github.com/iricigor/fingvibe/issues/413)
adds Developer claims, crash detection and prompt-based authority.

## Task worktrees

[Task #441](https://github.com/iricigor/fingvibe/issues/441) separates a
Developer's retained context from task execution. A Developer stays available in
its session after submitting a PR; the next start assignment that edits files
(`implement`, `resume`, `repair`) gets a fresh git worktree created by the
Developer with `New-Agent4TaskWorktree.ps1`, named `task-<issue>-<assignmentId>`
under `<checkout>-agent4-worktrees` next to the main checkout. Worktrees are never
reused. `resume`/`repair` worktrees are detached at the verified pushed head and
push with `HEAD:<branch>`. After a verified merge, the finalize assignment runs
`Remove-Agent4TaskWorktrees.ps1`, which removes only clean worktrees contained in
the merged PR head, without `--force`, and reports skipped ones. Tasks closed
without merge leave worktrees for a human. See the
[Developer contract](developer.md#task-worktrees).

## Local profiles and authority

Use **4️⃣ Dispatcher**, **4️⃣ Developer 1**, and **4️⃣ Developer 2** with actual
independent local host tools, not synchronous subagents or a scripted launcher.
The [protocol](protocol.md) and [Developer contract](developer.md) are mandatory.

No machine-local state.json setup is required. A human manually starting the
Dispatcher, or configuring its schedule, authorizes that run's workload for the
Epic named in its prompt; no separate approval link is needed. Optional prompt
lines adjust the run's permissions, with these defaults:

| Prompt line | Default | Meaning |
| --- | --- | --- |
| `merge: yes` / `merge: no` | `yes` | Developers may merge finalized PRs |
| `repairs: <N>` | `12` | Cumulative repair attempts allowed per task |

### Hourly Epic chart

As its final step, after coordination and the normal cycle outcome, each
existing Dispatcher cycle invokes the repository
[`loop4-epic-chart` skill](../../.github/skills/loop4-epic-chart/SKILL.md) with
its packet evidence, including idle cycles. Reporting is not interleaved with
offers, responses, releases or starts. The helper posts at most once per rolling 60
minutes to the marked Epic coordination Discussion, using server-timestamped
durable comments rather than context memory or an additional schedule.

The PNG has genuinely stacked completed (green), in-progress including CI/review
(orange), and not-started (red) categories. Trend lines follow cumulative stack
tops; a gray reference denotes the total. It reconstructs the current native
child cohort's history, shows at most 24 hourly boundaries plus the current
partial hour, and labels timezone/date/offset explicitly. Historical membership
is not inferred. Missing lifecycle evidence or non-completed closures stop the
chart with an explicit error, not invented totals.

The reporting-only exception to duplicate-query restrictions permits timeline
reads and fresh Discussion publication/throttle verification. Images are hosted
as authenticated GitHub user attachments, never local links. A pending
publication marker blocks retries regardless of age until human reconciliation;
published markers throttle across restarts. Windows and a supported GitHub.com
upload credential are required. Reporting errors remain explicit and do not
alter assignment/merge decisions. See the skill for invocation and recovery.

Dispatcher forwards the Epic and these permissions in every offer and start.
Developers trust them from a verified Dispatcher message; they do not search for
other approval. Agent-authored summaries, source publication and tool availability
do not grant permissions on their own, and `human-task` exclusions still apply.

Example Dispatcher instructions:

```text
Run one loop4 offer/start cycle for Epic #<number>.
Follow the loop4 contract. Wait for Developer assessments, not implementation or CI.
```

A cycle is **run the script → send offers → process each response → release
confirmed crashed assignments → send compatible starts**. At startup,
Dispatcher reads only this README and the protocol, not CONTRIBUTING.md or the
development backlog. It uses the packet's `candidates`, `blocked` and
`openAssignments` output directly. It does not read the
full evidence artifact or repeat GitHub/GraphQL requests for collected data unless
a specific candidate's data is missing or contradictory. Starts still require
Developer assessments, a fresh check of the selected task and a verified
"Sending #<number> to Developer N" comment in the task's own Discussion.

Immediately after attempting offers, before waiting for assessments or processing
starts, Dispatcher reports each Developer's exact sent issue list in chat, in
offer order (including shared candidates), or `none` for an empty sent list.
Failed or uncertain delivery is reported explicitly with the attempted list,
never as sent. The summary distinguishes offers from starts; send admission is
not proof of assessment or execution. See the [offer protocol](protocol.md#offer).

Task-specific records (assignment, Developer start and end of work) go to one
Discussion per task in the Task conversations category, marked
`<!-- fingvibe:task=<number> -->`. The Epic coordination Discussion, marked
`<!-- fingvibe:epic=<number> -->`, holds only Epic-level summaries and blockers.
Dispatcher creates either Discussion when missing; no issue-body links are added.
Assignment comments carry machine-readable markers (see the
[protocol](protocol.md#assignment-records)); an assignment is open until a
matching end-of-work or release marker follows it.
Developers finish after verified Discussion reporting/end-marker readback, without
a separate completion message to the previous Dispatcher session. Later cycles
read these durable records and ask fresh availability; failed reporting is a blocker.

## Independent starts and participation

Dispatcher forwards the packet's `developerOffers` lists without allocating
candidates itself. With multiple candidates, the script assigns positions 1/3
to Developer 1 and 2/4 to Developer 2, up to two each.
With exactly one candidate, both Developers receive it. A sole `success` candidate
is also shared when lower-priority work exists: Developer 2 receives it first, followed by its
highest-ranked base candidate. Each offer remains capped at two entries;
displaced candidates stay in the full queue. Zero or multiple successful
candidates otherwise retain the alternating allocation. For either shared case,
if both accept, Dispatcher starts only Developer 1. Developer 1 may start without
waiting for Developer 2; Developer 2 may start only after Developer 1 definitively replies
busy or rejects the candidate. A missing/uncertain reply keeps Developer 2 pending.
Retain this arbitration across late responses and continuation to prevent
duplicate starts; the losing shared offer alone does not block compatibility.
Developer assessment and start handling remain unchanged.
An empty offer never authorizes a start or task transfer.
When there are no candidates or open assignments, and no unresolved offers or
starts in retained context, no Developer calls are needed. Open assignments alone
still require offers even when no candidates are eligible.

Process correlated assessments independently, subject to shared-candidate arbitration
above. For disjoint offers, one Developer can start its
accepted offered task before the other replies only when compatibility is verified
against both Developers' existing work, unresolved offered candidates and starts
already sent. A nonresponding Developer stays unknown with its work/offers held;
overlap or insufficient evidence defers the start. Check late responses against
newly started work, retaining at most one start per Developer per cycle and all
offer/start correlation. Report the unresolved portion as pending, not the entire
cycle blocked when compatible work has already started.

On confirming a start, each Developer adds/verifies only its own task Discussion
label (`4️⃣dev1` or `4️⃣dev2`) with `Set-Agent4DiscussionParticipant.ps1`.
The labels remain as participation history across follow-ups and release; they
do not represent availability, ownership or authority. Missing labels/permissions
or failed readback block work. No developer labels are added to issues or PRs.

These changes apply only to future assignments after loading the updated contract.
Already accepted assignments, including #400, retain their original instructions
and existing Discussion labels; no live Automation settings or schedules change.

## Claims and crash recovery

On accepting a start, the Developer claims the task: it adds the `active` label
and sets the task's **FingVibe backlog** project Status to **In Progress**:

```powershell
.\.github\scripts\Set-Agent4TaskClaim.ps1 -Issue <number> -Action claim
```

Verified PR submission still adds `status:review` and removes `active`; the
project Status stays In Progress until the issue closes.

Each offer lists the recipient's open assignments. If the assigned Developer
replies `busy` with that assignment ID, it is still running. If it replies that it
is not running it (for example `available`, or busy with a different assignment),
the execution ended without a report. Dispatcher then posts a verified release
marker in the task Discussion and runs
`Set-Agent4TaskClaim.ps1 -Issue <number> -Action release` (removes `active`,
Status **Todo**). The next cycle offers the task again. A missing or uncertain
reply keeps the assignment held; age alone never releases it. Release relies on
the Developer's own report, so a hung execution that its Developer cannot see
could overlap with the new assignment.

Developer instructions (select the matching numbered profile):

```text
Handle verified loop4 offers and start assignments.
Answer each offer with your availability and candidate preferences.
Do not start from an offer alone. Without an assignment, remain inert.
```

Discover actual Automation identities through the host. Do not overlap Dispatcher
cycles or launch another Developer execution to ask whether an existing one is
busy. If waiting/resumption tools are unavailable, report the cycle pending;
do not fabricate a synchronous substitute or schedule.

## PowerShell candidate collection

Requires PowerShell 7.5+ and authenticated `gh`:

```powershell
.\.github\scripts\Get-Agent4DispatcherPacket.ps1 -Epic <number>
```

The script accepts repository/Epic directly and writes a complete evidence
artifact under the temporary directory (or explicit `-Directory`). It reads no
coordination state and acquires no repository gate. JSON contains the evidence
path, all ordered candidates, explicit exclusions and every open assignment
(`openAssignments`: issue, assignment ID, Developer, action, Discussion URL) for
crash detection. It does not grant execution
permission, infer Developer availability or reserve/assign execution.
Its `developerOffers` array contains two entries (`developer`, `candidates`),
including empty candidate arrays, built from the existing sorted candidate list.

Default order, with ascending issue number within each group:

1. Linked open PR with successful completed current-head CI.
2. Linked open PR with failed completed current-head CI.
3. `resume`: released implementation with its existing linked PR, whatever its CI.
4. Eligible new native task (including released work that has no PR yet).

Released candidates carry the `released` assignment. Dispatcher repeats its
action (continuing an existing PR/branch, never a competing PR).

Cancelled/timed-out/action-required CI is failed attention work, not permission
to retry. Neutral/skipped checks are non-failing, but alone do not prove success.
Latest observed checks/statuses/workflow runs for the head determine the category.
Any pending CI waits; missing/unrecognized evidence is explicitly unknown.
This classification is an offer priority, not proof that every required check,
review, acceptance condition or affected-UI duration requirement is satisfied.

Native PR closing references associate tasks; an ambiguous multi-PR task is
excluded with a reason. Active/review work without a linked open PR is not new
work. A task with an open assignment, or more than one task Discussion, is excluded.
Human tasks, explicit blockers and open native dependencies are excluded.
Closed dependency disposition and foreign work remain evidence for Developer
assessment, not automatic proof of delivery. Issues, PR diffs/reviews, CI jobs
and Discussions are completely paginated; collection errors stop explicitly.
Discussions keep their category (Agent logs, Epic coordination, Task
conversations) and body markers, so Epic and task Discussions are found there.

Optional `-TaskOrder` with `-OrderEvidence` supplies an explicit human ordering
within priority groups; a blocked predecessor prevents later ordered candidates.
It must cover the open native queue. The script builds offers from only the
first four at positions 1/3 and 2/4, sharing a whole-queue singleton or a sole
`success` candidate in a mixed queue as described above.
Dispatcher processes responses independently except for the shared
candidate's Developer 1 precedence, with compatibility checks before each start.

## Boundaries

No Progress/Confirm/Release protocol or delivery-based slot management remains in
the active flow; the only release is the Discussion-marker release above. Historical `Agent4Coordination` helpers/records are preserved
for old-state diagnostics, not invoked to run this design. Reconcile outstanding
old work before using it; do not reset files or waive foreign ownership.
Older loops, Automations, scheduling and CI/protection/release policies stay
unchanged. Repair attempts are limited by the run's `repairs` allowance; merging
follows its `merge` permission and never bypasses branch protection.

Wait-and-close tasks may run as explicitly authorized no-code assignments,
reporting actual delay/timing and issue closure without a fabricated PR.
Creating #393 did not authorize its live execution or configure Automations.

## Focused checks

```powershell
.\tests\Agent4DispatcherPacket.Tests.ps1
.\tests\Agent4Coordination.Tests.ps1
.\tests\Agent4TaskWorktree.Tests.ps1
```

Synthetic checks do not prove live host messaging, continuation, Developer
availability or Discussion permissions. A live trial needs separate approval.
