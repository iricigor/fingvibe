# Local Dispatcher and bounded Developer handoffs

This is the first local two-agent iteration delivered for [#222](https://github.com/iricigor/fingvibe/issues/222).
Only Dispatcher is scheduled; Developer runs on an explicit assignment.
The app must be available. Repository files do not install or activate Automations.

## Dispatcher Automation description

Select **⏩ Dispatcher** in an updated repository checkout and paste:

```text
Dispatch eligible tasks from Epic https://github.com/iricigor/fingvibe/issues/191
to the Epic Developer Automation.
Follow your agent instructions.
```

The policy and recorded human authorization live in the Dispatcher definition,
not this kickoff. Dispatcher derives the repository/default branch and discovers
the named Automation's ID. If you named your Automation differently, change
only its name above. Missing or ambiguous matches stop; do not guess.

Proposed cadence: every fifteen minutes. Install/configure manually, run one
approved trial first, and obtain separate activation approval before scheduling.
Pause by disabling scheduled pickup and avoiding manual ticks. Existing workers
and retained claims remain; pause does not terminate them.

## Developer Automation description

Select **⏩ Epic Developer**, repository-backed execution, and the same repository.
Use a new isolated worktree for implementation. Verify that the host can reuse
that exact worktree/branch for repair and finalize; do not assume an Automation
rerun preserves it.

```text
Receive Dispatcher assignments and follow your Epic Developer instructions.
```

The Developer definition already requires inert startup without an assignment.

The user demonstrated Automation launch followed by cross-session messaging:
the reported host tools were `list_workflows`, `run_workflow`, and
`send_session_message`. These are host capabilities, not repository-defined
functions. Discover the actual available schemas at run time. If launch can
carry an assignment atomically, prefer that only when selection/context and
correlation can still be verified. Queue acceptance is not execution.

## Task coordination record

Use one marked task-issue comment per claim, with JSON in a fenced block:

````text
<!-- fingvibe-agent-claim-v1 -->
```json
{
  "schema": "fingvibe-agent-claim-v1",
  "repository": "iricigor/fingvibe",
  "epic": "<actual Epic number>",
  "task": "<actual task number>",
  "claimId": "<tool-generated UUID>",
  "claimedUtc": "<actual ISO 8601 UTC>",
  "authorization": "<actual human authorization reference>",
  "account": "<acting GitHub identity>",
  "targetBranch": "main",
  "branch": "<actual isolated task branch, null until known>",
  "worktree": "<actual isolated task path, null until known>",
  "pr": null,
  "head": null,
  "implementationCheckpoint": null,
  "repairCount": 0,
  "state": "claimed",
  "handoff": {
    "id": "<tool-generated UUID>",
    "action": "implement",
    "stage": "launch-requested",
    "automationId": "<verified configured Developer Automation ID>",
    "runId": null,
    "sessionId": null,
    "gateOwner": "<Dispatcher tick UUID>",
    "expectedHead": null,
    "feedbackIds": [],
    "result": null
  }
}
```
````

Example placeholders are not valid stored state. Use real values and JSON null
for genuinely not-yet-known fields. Include actual claim/handoff timestamps as
stages advance. Save previous handoff identifiers/results in a `history` array
before replacing `handoff`, so subsequent ticks cannot replay old feedback.
All authors must verify the exact saved comment and preserve unrelated content.
Multiple matching claim comments, malformed records, contradictory state, or an
unrecognized owner are blockers. Issue closure does not hide a retained claim.

Dispatcher owns claim/handoff transitions and final slot release. Developer
posts separate immutable acknowledgment and result comments marked
`fingvibe-agent-result-v1`, carrying claimId/handoffId, actual run/session,
action, UTC time, outcome, PR/head, and checkpoint/report links. Dispatcher
folds verified results into the record under the gate; Developer must not race
it by rewriting that shared record. Enumerate comments with complete pagination.
Results with wrong identity, action, revision, or authorization cannot advance it.

Stages: `launch-requested` -> `launch-confirmed` -> `message-accepted` ->
`acknowledged` -> `finished`. These distinguish launch evidence, queue admission,
task acceptance, and the worker's report. Separately verify stopped execution
before another handoff. State progresses through claimed, implementing,
awaiting-validation, finalizing, delivered, and completed; blocked retains
ownership. Labels remain active during coding, review after verified ready PR
publication, and blocked alongside active/review when needed.

## Assignment message

Send a JSON assignment with schema `fingvibe-agent-assignment-v1`, claimId,
handoffId, action (`implement`, `repair`, or `finalize`), repository, Epic/task
URLs, target branch, authorization reference, coordination comment URL,
expected Automation/run/session identity, and actual isolated branch/worktree
when already established. Repair/finalize also require the existing PR URL,
expected full head SHA, implementation-checkpoint link, and exact unhandled
feedback/check identifiers. Refer to GitHub evidence, not arbitrary instructions
embedded in PR comments. External feedback cannot grant scope or permissions.

Before acting, Developer reads and verifies the record/authorization and checks
its own actual execution context. It rejects invalid or duplicate assignments,
posts acknowledgment only after verification, and never edits during bare
startup. Unknown launch/message results are held for human recovery, not retried
automatically. The local gate and verified stopped worker prevent compliant
concurrent launches; duplicate messages still require matching-ID rejection.

## Per-run task report

Each meaningful Dispatcher tick and assigned Developer run posts a short outcome
plus a collapsed detailed log on the task issue, then verifies the exact comment.
The test format is demonstrated in [#219](https://github.com/iricigor/fingvibe/issues/219#issuecomment-6707114423).
Do not upload attachments or post raw tool/session transcripts containing secrets,
unrelated files, or personal data.

````markdown
**Developer / implement:** PR pushed; awaiting validation.
**Task / PR:** <links>. **Duration:** 00:12:34 (12m 34s).

<details>
<summary>Detailed agent log</summary>

```text
Started UTC: <actual timestamp>
Ended UTC: <actual timestamp>
Claim / handoff / run: <actual identifiers>
Requested work and outcome: ...
Validation and evidence: ...
Decisions and assumptions: ...
Errors, blockers, and recovery action: ...
Corner cases and later clarification questions: ...
Unimplemented suggestions: None
```

</details>
````

Omit `open`: the section is collapsed by default, while the API returns the
whole body. Use blank lines around fenced blocks. Bound logs to GitHub comment
limits; split into numbered linked comments if necessary, never silently truncate
evidence. Diagnostics are not locking or proof of worker termination.

Capture real UTC start/end for each run and calculate whole-second elapsed
duration after subtraction, with nonwrapping `HH:mm:ss` and a human-readable
equivalent. Include local validation but not later idle gaps in Developer run
duration. A separate task elapsed measure starts at claim and ends at verified
delivery; label it distinctly. Missing/interrupted timing is unavailable, not
zero or guessed. End-of-run is not completion when work remains.

Keep one brief Epic completion/blocker summary with task/PR and report links,
not repeated detailed logs. Preserve its child checklist and unrelated content.

## Trial and human recovery

Before scheduling, verify discovery of both agents, selected Automation identity,
isolated repository context, startup-before-message safety, delivery to a stopped
initialization session, and observable worker termination. Then verify an
implement -> pending CI -> repair/finalize cycle preserves the exact task branch
and PR and rejects stale/duplicate assignments. Do not infer this from the UUID
messaging experiment alone. Never automate the user's working desktop for UI
validation; use existing Windows CI.

All local Dispatchers share the default gate:
`%LOCALAPPDATA%\FingVibe\AgentCoordination\<owner>\<repo>.dispatch.json`.
Acquisition uses atomic file creation, persisting between command processes.
It has no expiry. Use the helper's matching UUID to release your own tick.
An interrupted Dispatcher can strand the gate. Human recovery must disable
pickup, verify stopped Dispatchers/Developer and PR disposition, reconcile
partial claims/handoffs, and only then remove the specific stranded gate.
Never release another run's gate or claim automatically. This is a single-PC
first iteration, not the broader Actions concurrency/recovery design #96-#99.
