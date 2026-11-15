# Independent loop4 setup

[Task #386](https://github.com/iricigor/fingvibe/issues/386) delivers source
instructions and local PowerShell helpers, not installed or activated Automations.
The human confirmed **two total in-flight tasks, one per Developer**, including
CI/review waits and blocked claims. The four offers are candidates, not four
in-flight execution assignments.

| Separate local Automation | Source profile | Trigger |
| --- | --- | --- |
| 4️⃣ Dispatcher | `.github/agents/automation-4-dispatcher.agent.md` | Manual until separately approved scheduling |
| 4️⃣ Developer 1 | `.github/agents/automation-4-developer-1.agent.md` | Dispatcher invocation only |
| 4️⃣ Developer 2 | `.github/agents/automation-4-developer-2.agent.md` | Dispatcher invocation only |

Both Developers follow the same [execution contract](developer.md) and
[small JSON protocol](protocol.md). The Dispatcher uses deterministic scripts
for allocation; Developers assess scope, authority, dependency delivery,
parallel compatibility and review/CI feedback. Labels help estimate overlap
but do not replace code/diff/shared-contract inspection.

## Setup boundaries

Create separate disabled Automations only after explicit setup approval. Use the
local host, same Windows PC/account, independently verified Automation identities
and isolated task worktrees. Discover real host schemas for the successful 2️⃣
independent invocation, messaging, inspection and retained-context resumption.
Do not add a launcher/transport adapter or substitute a synchronous subagent.
Tools unavailable in an unrelated chat do not invalidate the working mechanism.

Older ⏩, 2️⃣ and 3️⃣ profiles, configurations, settings, claims, counters and
history stay unchanged. Only the unchanged repository gate is reused. Separate
loop4 execution storage never exempts foreign work from repository-wide
ownership/conflict checks. No migration, reset, automatic recovery, saved-profile
replacement or activation is delivered. A future cutover needs separate approval,
verified stopped workers and reconciliation of existing work.

Resolve one absolute shared directory outside all worktrees, for example:

```text
%LOCALAPPDATA%\FingVibe\AgentCoordination\loop4\<owner>\<repo>\
  state.json         Dispatcher-owned configuration, offers, claims and history
  events\            Developer-owned immutable responses/acks/checkpoints/results
  evidence\          Complete cached GitHub snapshots
```

Do not commit these machine-local records. Preserve them; Discussion reporting
is **not a full backup**. Files do not authenticate authors or prove termination.
Both roles verify actual host identities and original human authority independently.

### Explicit configuration

Initialize only after verified absence and original human implementation approval
for the selected Epic. The required configuration object is:

```json
{
  "repository": "iricigor/fingvibe",
  "epic": 92,
  "targetBranch": "main",
  "authorization": {
    "reference": "<original independently retrievable human decision URL>",
    "implementation": true,
    "merge": false
  },
  "maxRepairAttempts": 0,
  "workers": [
    {"id": "developer-1", "name": "4️⃣ Developer 1", "automationId": "<actual ID>"},
    {"id": "developer-2", "name": "4️⃣ Developer 2", "automationId": "<actual ID>"}
  ]
}
```

This is a shape example, **not approval to execute Epic #92**. Use the separately
authorized target and discover the repository's actual default branch. Verify
original approval author/provenance, eligible scope, permissions and configured
repair count before initialization and each consequential action. Both roles
must retrieve the original decision, not trust a Dispatcher's copied assertion.
Changed authority/configuration requires human reconciliation, not overwriting
state. Source delivery requires no workload authorization.

The mandatory cumulative repair limit is **0-12** and must match explicit human
approval. Use **0** if repairs are not approved; there is no inherited allowance.
Count is shared across failures, reviews and affected-UI duration remediation,
never reset per tick/head/worker. Cadence is human-configured, not implemented:
start manually, trial actual host behavior with separate approval, then obtain
explicit schedule approval. Pausing pickup does not terminate Developers.

## One tick and subsequent replies

Acquire `.github/scripts/Invoke-DispatcherGate.ps1` with a fresh UUID and the
standard gate root `%LOCALAPPDATA%\FingVibe\AgentCoordination`. All versions use
its existing physical `<owner>\<repo>.dispatch.json`. Hold it only for a bounded
tick, not while waiting for Developers/CI. Never expire a stale gate.

```powershell
$root = Join-Path $env:LOCALAPPDATA "FingVibe\AgentCoordination\loop4\iricigor\fingvibe"
$owner = [guid]::NewGuid()
.\.github\scripts\Invoke-DispatcherGate.ps1 -Action Acquire -Repository iricigor/fingvibe -Owner $owner
```

After verified setup/approval, use `Invoke-Agent4Coordination.ps1 -Action
Initialize -Directory $root -InputPath <absolute-config-json> -GateOwner $owner`.
Then the normal data call is:

```powershell
.\.github\scripts\Get-Agent4DispatcherPacket.ps1 -Directory $root
```

The packet contains up to four mechanically eligible tasks, exclusions, retained
claims, pending offers and the full evidence-file path. Repository issues/comments,
native children/dependencies, open PR files/reviews/current-head checks and
Actions jobs, and all Discussion comments/replies are paginated. Collection
failure throws and stops the call; it never returns a success-shaped empty queue.
Read the full artifact. It deliberately preserves prose/foreign-claim/authority
evidence for Developer judgment rather than declaring semantic independence.
Closed native dependencies still need verified delivery: closure alone, abandoned
work and planning approval are not completed implementation.

Pass `-TaskOrder <ordered-native-issue-numbers> -OrderEvidence <original-human-link>`
when explicit human order applies. It must cover the open queue; a blocked
predecessor blocks later ordered work. Without explicit order, ascending issue
number is a preference: blocked candidates do not hide independent later tasks.
The artifact contains all collected evidence; stdout is a JSON packet, not a
raw repository dump.

| Coordination action | Required input JSON fields |
| --- | --- |
| Offer | `packet`, `hostObservations[]` (`workerId`, `automationId`, `status`, `evidence[]`) |
| Correlate | `offerId`, actual `runId`, actual `sessionId`, `evidence[]` |
| Confirm | immutable `recordPath`, independently observed `observedActor`, `freshEvidence[]` |
| Progress | immutable `recordPath`, independently observed `observedActor` |
| Followup | `claimId`, `action` (`repair`/`finalize`), retained `runId`, `sessionId`, `stoppedEvidence[]`, `feedback[]`, `expectedHead` |
| Release | `claimId`, `stoppedEvidence[]`, `deliveryEvidence[]`, `cleanupEvidence[]` |
| Publish | Developer `record` and independently observed `observedActor` |

For each action, call:

```powershell
.\.github\scripts\Invoke-Agent4Coordination.ps1 -Action Offer -Directory $root `
    -InputPath <absolute-input-json> -GateOwner $owner
```

Every Dispatcher mutation checks the repository gate and expected state revision,
atomically replaces state and verifies readback. Publish writes only immutable
Developer events and does not mutate aggregate state. Capture actual observations
through host tools; input booleans/strings and evidence references are not
authentication or independent verification.

Offer reserves a pending coordination intent before any launch: Dev1 receives
positions **1/3**, Dev2 **2/4**. Missing positions produce smaller offers. A busy,
unknown or retained worker gets no new offer. Persist/read back before invocation,
then Correlate returned actual IDs before sending one combined task/availability
message. Do not retry uncertain starts/messages. Developer replies asynchronously;
Dispatcher ingests responses on a subsequent bounded tick.

Confirm uses the Developer's current assessed revision and deterministic
lower-overlap/earlier-position preference. A competing confirmation changes the
revision; reassess the second offer against the new reservation before committing.
An offer or preferred-task response grants no permission to code. Confirmed
assignment plus immutable acknowledgment is required. Unchanged pending offers
remain pending; new ticks are not new launches. Rejected candidates can reappear
on later passes; fixed pairs are not permanent restrictions.

Followup is for the **same retained context**, after verified prior stop and
actionable current-head evidence. Persist the new handoff before messaging or
resuming that context through existing host tools. Do not launch a replacement
or infer that a stored session ID is sufficient resumption evidence. Unavailable
resumption or materially changed scope blocks. Pending/unrelated CI does not
authorize a repair. Blocked claims require explicit human reconciliation.

Release requires a delivered result plus independent current delivery, stopped
execution and cleanup evidence. CI/review/blocked waits retain slots; results,
archival, issue closure and accepted messages do not release them.

Release only this tick's gate on orderly completion:

```powershell
.\.github\scripts\Invoke-DispatcherGate.ps1 -Action Release -Repository iricigor/fingvibe -Owner $owner
```

## Human control and reporting

Use task/Epic Discussions for original human decisions, questions, meaningful
assignments/progress, task-wide blockers and outcomes. Both roles read them.
Dispatcher verifies an existing mapping or creates one after permission, adds
and reads back the Discussion link in the issue body, and preserves all unrelated
body content/native Epic membership. Developer uses that mapped task Discussion.
Discussion API/host calls remain normal agent tools, not a new publication stack.
Verify author, body and URL after posting. Machine-only records remain local.

Reports have a short outcome/task/PR/timing summary and collapsed detailed
evidence/decisions/limitations; Epic outcomes link to task reports. Post task-wide
blockers/questions with evidence and required unblock action, but deduplicate
unchanged notices. Routine busy/ack events need no Discussion post. Failed
reporting is explicitly pending/blocking delivery cleanup, never swallowed.
Do not fabricate timings, copy raw transcripts or include secrets.

## Focused checks

Requires PowerShell **7.5+** (including JSON `-DateKind String` support) and `gh`.
No native desktop automation or live worker launch is part of these checks:

```powershell
.\tests\Agent4Coordination.Tests.ps1
.\tests\Agent4DispatcherPacket.Tests.ps1
```

Synthetic evidence tests do not certify real host launch/resume/termination,
Discussion permissions or live cutover. Those need separately approved trials.
