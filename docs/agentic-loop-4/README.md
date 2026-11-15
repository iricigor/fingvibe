# Simple loop4 dispatch

[Task #403](https://github.com/iricigor/fingvibe/issues/403) simplifies the
source environment introduced by #386. The Dispatcher collects task evidence,
sends disjoint offers, waits for Developer assessments and sends explicit starts.
Developers report their own availability. PR submission frees them for later work;
pending CI does not retain a Developer slot.

## Local profiles and authority

Use **4️⃣ Dispatcher**, **4️⃣ Developer 1**, and **4️⃣ Developer 2** with actual
independent local host tools, not synchronous subagents or a scripted launcher.
The [protocol](protocol.md) and [Developer contract](developer.md) are mandatory.

No machine-local state.json setup is required. Supply the requested Epic and a
link to the original human workload approval in the Dispatcher prompt. Dispatcher
reads only that link, without searching for approval, and stops if it is missing.
Both roles verify its human author, scope, implementation/no-code authority, merge
permission and cumulative repair allowance; Dispatcher forwards the link in offers
and starts. Missing permission is not approval. Agent-authored summaries do not
replace the original decision. Source delivery authorizes no workload, trial,
Automation installation/activation or scheduling.

Example Dispatcher instructions for an already authorized local Automation:

```text
Run one loop4 offer/start cycle for Epic #<number>.
approval: <link to the original human approval comment>
Follow the loop4 contract. Wait for Developer assessments, not implementation or CI.
```

A cycle is **run the script → read the approval link → send offers**. At startup,
Dispatcher reads only this README and the protocol, not CONTRIBUTING.md or the
development backlog. It uses the packet's `candidates` and `blocked` output directly. It does not read the
full evidence artifact or repeat GitHub/GraphQL requests for collected data unless
a specific candidate's data is missing or contradictory. Before offering, it checks
previous assignments/responses only for the candidates about to be offered, using
its retained context and the artifact's Discussion data. Starts still require
Developer assessments, a fresh check of the selected task and a verified
assignment comment in the Epic coordination Discussion.

Developer instructions (select the matching numbered profile):

```text
Handle verified loop4 offers and start assignments.
Report your own availability and candidate preferences.
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
path, all ordered candidates and explicit exclusions. It does not grant execution
permission, infer Developer availability or allocate/reserve tasks.

Default order, with ascending issue number within each group:

1. Linked open PR with successful completed current-head CI.
2. Linked open PR with failed completed current-head CI.
3. Eligible new native task.

Cancelled/timed-out/action-required CI is failed attention work, not permission
to retry. Neutral/skipped checks are non-failing, but alone do not prove success.
Latest observed checks/statuses/workflow runs for the head determine the category.
Any pending CI waits; missing/unrecognized evidence is explicitly unknown.
This classification is an offer priority, not proof that every required check,
review, acceptance condition or affected-UI duration requirement is satisfied.

Native PR closing references associate tasks; an ambiguous multi-PR task is
excluded with a reason. Active/review work without a linked open PR is not new
work. Human tasks, explicit blockers and open native dependencies are excluded.
Closed dependency disposition and foreign work remain evidence for Developer
assessment, not automatic proof of delivery. Issues, PR diffs/reviews, CI jobs
and Discussions are completely paginated; collection errors stop explicitly.
Discussions keep their category (Agent logs, Epic coordination, Task
conversations); the Epic's Discussion is found there, without issue-body links.

Optional `-TaskOrder` with `-OrderEvidence` supplies an explicit human ordering
within priority groups; a blocked predecessor prevents later ordered candidates.
It must cover the open native queue. Dispatcher offers only the first four at
positions 1/3 and 2/4, then consolidates responses.

## Boundaries

No Progress/Confirm/Release protocol or delivery-based slot management remains in
the active flow. Historical `Agent4Coordination` helpers/records are preserved
for old-state diagnostics, not invoked to run this design. Reconcile outstanding
old work before using it; do not reset files or waive foreign ownership.
Older loops, Automations, scheduling and CI/protection/release policies stay
unchanged. Repair/merge still require explicit original human permission.

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
