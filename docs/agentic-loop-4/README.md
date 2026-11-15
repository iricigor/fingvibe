# Simple loop4 dispatch

[Task #403](https://github.com/iricigor/fingvibe/issues/403) simplifies the
source environment introduced by #386. The Dispatcher collects task evidence,
sends disjoint offers, waits for Developer assessments and sends explicit starts.
Every cycle, the Dispatcher asks both Developers for their availability; they
answer only when asked and never need to report availability on their own.
PR submission frees a Developer for later work; pending CI does not retain a
Developer slot. [Task #413](https://github.com/iricigor/fingvibe/issues/413)
adds Developer claims, crash detection and prompt-based authority.

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

Dispatcher forwards the Epic and these permissions in every offer and start.
Developers trust them from a verified Dispatcher message; they do not search for
other approval. Agent-authored summaries, source publication and tool availability
do not grant permissions on their own, and `human-task` exclusions still apply.

Example Dispatcher instructions:

```text
Run one loop4 offer/start cycle for Epic #<number>.
Follow the loop4 contract. Wait for Developer assessments, not implementation or CI.
```

A cycle is **run the script → send offers → wait for responses → release crashed
assignments → send starts**. At startup,
Dispatcher reads only this README and the protocol, not CONTRIBUTING.md or the
development backlog. It uses the packet's `candidates`, `blocked` and
`openAssignments` output directly. It does not read the
full evidence artifact or repeat GitHub/GraphQL requests for collected data unless
a specific candidate's data is missing or contradictory. Starts still require
Developer assessments, a fresh check of the selected task and a verified
"Sending #<number> to Developer N" comment in the task's own Discussion.

Task-specific records (assignment, Developer start and end of work) go to one
Discussion per task in the Task conversations category, marked
`<!-- fingvibe:task=<number> -->`. The Epic coordination Discussion, marked
`<!-- fingvibe:epic=<number> -->`, holds only Epic-level summaries and blockers.
Dispatcher creates either Discussion when missing; no issue-body links are added.
Assignment comments carry machine-readable markers (see the
[protocol](protocol.md#assignment-records)); an assignment is open until a
matching end-of-work or release marker follows it.

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
permission, infer Developer availability or allocate/reserve tasks.

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
It must cover the open native queue. Dispatcher offers only the first four at
positions 1/3 and 2/4, then consolidates responses.

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
```

Synthetic checks do not prove live host messaging, continuation, Developer
availability or Discussion permissions. A live trial needs separate approval.
