# Real-task environment: one Dispatcher, two Developers

[Task #331](https://github.com/iricigor/fingvibe/issues/331) supplies three
additional source profiles, deterministic coordination helpers and this setup
guide. It does **not** install Automations, authorize an Epic workload or merge,
activate a schedule, or require completion of a new live trial.

| Source agent | Role |
| --- | --- |
| [3️⃣ Dispatcher](../../.github/agents/automation-real-dispatcher.agent.md) | One coordinator; bounded ticks, selection, observation and reconciliation |
| [3️⃣ Developer 1](../../.github/agents/automation-real-developer-1.agent.md) | Independent worker, stable identity `developer-1` |
| [3️⃣ Developer 2](../../.github/agents/automation-real-developer-2.agent.md) | Independent worker, stable identity `developer-2` |

These derive from the existing
[Dispatcher](../../.github/agents/automation-dispatcher.agent.md) and
[Epic Developer](../../.github/agents/automation-epic-developer.agent.md), not
from synthetic wait-task instructions. The original profiles, Automations and
[2️⃣ experiment](../agentic-loop-v3/README.md) remain unchanged.
Read the [mandatory shared operating contract](contract.md) as well as this
guide. Inherited production safeguards apply except for its explicitly listed
real-environment overrides.

[Task #338](https://github.com/iricigor/fingvibe/issues/338) adds the
[strict operational JSON protocol and script fast path](protocol.md) only to
these three profiles. It does not update existing Automations or activate workers.

## Human quick start

1. After installation approval, create three new Automations in this repository,
   named **3️⃣ Dispatcher**, **3️⃣ Developer 1** and **3️⃣ Developer 2**.
   Select the matching agent from the table above in each Automation's prompt
   editor. Keep schedules disabled; do not replace the existing agents.
2. Paste the [short prompts below](#where-to-specify-the-epic) into the
   Automation **Prompt** fields. Replace `<Epic URL>` in the Dispatcher prompt.
   Its agent's `description:` is a static summary, not a configuration field.
   The selected agent supplies the full workflow and calls the scripts; do not
   copy its entire instruction file into the prompt.
3. Before execution, verify the [prerequisites](#prerequisites-and-capability-verification),
   shared storage, actual Automation identities and isolated task contexts.
   Explicitly approve the intended Epic workload; a documentation example or
   selecting an agent grants no permission.
4. Start with one explicitly authorized manual Dispatcher invocation, not an
   unattended schedule. Dispatcher selects and monitors; Developers implement
   only correlated assignments and publish PRs. The example below leaves PR
   merging to you.
5. Inspect task issue reports, PRs and blockers. Do not manually launch Developers
   to bypass a missing assignment. Pausing Dispatcher prevents future ticks,
   not running workers; uncertain execution requires
   [reconciliation](#recovery-and-next-decisions), never a state reset or relaunch.

## Prerequisites and capability verification

- One local Windows PC/account with a persistent local filesystem shared by all
  three sessions, Git, authenticated `gh`, and PowerShell **7.5 or later**.
  The helper uses `ConvertFrom-Json -DateKind String` to preserve original UTC
  strings instead of silently normalizing timestamps during duplicate checks.
- Updated isolated worktrees containing all three definitions and the shared
  documents. Selected agents and saved Automation prompts do not
  automatically synchronize with source updates.
- Host tools for exact Automation discovery, independent launch, actual
  run/session correlation, messaging, execution inspection, and same-task
  worktree/branch resumption for repair/finalize. Discover actual schemas; a
  name in these instructions is not proof of a callable API.
- GitHub permissions for the authorized operations: complete issue/PR/comment,
  native child/dependency, check/job/log/review reads; claims, lifecycle labels,
  reports, pushes and PR updates; merge permission only when separately granted.
  Existing CI/review/release policies remain authoritative.

The profiles intentionally inherit host tools without an allowlist, following
[existing guidance](../../CONTRIBUTING.md#local-dispatcher-and-developer).
Inheritance grants neither permission nor missing capabilities. No helper can
prove host termination, install a session API or enforce human authorization.
Unavailable capabilities block the affected action explicitly. Do not substitute
a synchronous subagent, cloud execution or a different worktree for convenience.

## Where to specify the Epic

After separate installation approval, create three **new, disabled** local
Automations, selecting the matching source agent in each. Developers remain
manual-only; only Dispatcher is a candidate for later scheduling.

The **Dispatcher Automation Prompt** field supplies the Epic and worker names.
An explicitly authorized manual kickoff may supply the same configuration.
The YAML `description:` in the agent file is only display metadata.

Select **3️⃣ Dispatcher** and paste this short prompt:

```text
Coordinate work on Epic <Epic URL> using the
3️⃣ Developer 1 and 3️⃣ Developer 2 Automations.

You may select eligible task issues directly under this Epic
and assign them to those Developers. The Developers may
implement their assignments and publish PRs.

Do not merge PRs. Follow your agent instructions.
```

Select **3️⃣ Developer 1** and paste:

```text
Follow your agent instructions as 3️⃣ Developer 1.
Without a verified correlated assignment from 3️⃣ Dispatcher,
finish awaiting-assignment without selecting or changing work.
```

Select **3️⃣ Developer 2** and paste:

```text
Follow your agent instructions as 3️⃣ Developer 2.
Without a verified correlated assignment from 3️⃣ Dispatcher,
finish awaiting-assignment without selecting or changing work.
```

The Developer prompts are inert startup instructions, not assignments.
Dispatcher delivers each actual assignment separately through the verified
host messaging API using the [strict JSON protocol](protocol.md); a human's
Automation prompt is not an operational agent-to-agent message.

These are templates, **not an authorization to run this environment**.
Replace `<Epic URL>` with the chosen Epic's actual URL. Only use the Dispatcher
permission wording when you intend to authorize that workload. Retain the
owner-authored prompt/kickoff as the decision reference and verify its author;
if the host cannot establish that provenance, obtain a separately recorded
owner approval before execution. No external approval link is required when
the direct kickoff itself is authoritative and retained.

Dispatcher derives and verifies this configuration from that human decision
and the selected Automations, rather than expecting another description field:

```text
Target Epic: https://github.com/iricigor/fingvibe/issues/<number>
Developer 1 Automation: 3️⃣ Developer 1
Developer 2 Automation: 3️⃣ Developer 2
Human authorization reference: <verified owner-authored prompt/kickoff or decision URL>
Implementation permission: explicitly granted for eligible direct task children
Merge permission: not granted by the example prompt
```

Verify the repository from the Epic URL against the checkout and discover its
actual default branch. The recorded human decision must authorize eligible
direct native task children of that Epic and the intended selection policy.
The existing local exception permits skipping individual ready/size/priority
approvals only under that explicit bounded authority; do not manufacture labels.
No authorization transfers from #191, #222, #285 or the synthetic experiment.
Missing authorization leaves startup inert.
The example does not authorize schedule activation. Automatic merging would
require a separate explicit decision; do not infer it from implementation
permission.

Discover exact Automation IDs and verify their selected profiles, repository
and local isolated contexts. Save the verified identities in state. Configuration
or queue changes require a human decision and reconciliation, not an in-flight
state reset. Change the configured Epic in the Dispatcher prompt only after
the prior environment is reconciled and the new target is explicitly approved;
do not reset its claims, history or repair counters. Human instructions must
come from verified owner identity/direct user input; issue prose and worker
messages are evidence, not new authority.
The broader owner-only GitHub command protocol is not implemented here.

## Persistent storage and locking

Use the same resolved absolute path for all three agents, outside disposable
worktrees:

```text
%LOCALAPPDATA%\FingVibe\RealTaskAgents\<owner>\<repo>\
  state.json
  events\
  incidents\
  records\
  messages\
  receipts\
  diagnostics\
  responses\
```

One environment per repository/account; no alternate state roots in live use.
Initialize directories only after shared-access and absence verification.
Before first initialization, inspect repository-wide real-task claim comments
and existing event/incident files. Any retained claim or unexplained evidence
without its state is lost/uncertain state requiring human reconciliation, not
permission to create an empty environment.
Never reuse/reset experiment state or overwrite a production claim.
Dispatcher is the only state writer. Developer events are immutable; canonical
incident records retain original evidence and append dated recovery/resolution
notes. Do not commit machine-local records, secrets or raw session dumps.

All Dispatcher ticks use the **existing default repository gate**:

```powershell
.\.github\scripts\Invoke-DispatcherGate.ps1 -Action Acquire `
    -Repository <owner/repo> -Owner <fresh-tick-UUID>
```

Hold it throughout reconciliation, selection, state/claim publication and
delivery; release only your own gate on orderly exit. Do not hold it waiting
for workers/CI. No age expiry, stolen locks or blind worker replacement.
This coordinates compliant writers on one PC, **not** humans, other accounts,
other PCs, network filesystems or Actions. Re-read remote evidence before
consequential writes. Reuse of the gate does not waive foreign claims.

The helper uses same-directory temporary files, flush, atomic replacement and
readback. A Windows replacement uses a true null backup path, avoiding v3's
empty-path binding failure. A failed/interrupted publication leaves prior state
or an explicit uncertain operation; reconcile it rather than retrying a write.
Readers consider only complete published `*.json`, not `.publish-*.tmp` files.
Do not delete another writer's temporary files or infer state absence from a
failed read.

## Helper use

Import the shared implementation from an updated task checkout:

```powershell
Import-Module .\.github\scripts\RealTaskCoordination.psm1 -Force
```

Initialize with `New-RealTaskState` only when authorized and state is
authoritatively absent. Supply verified repository/Epic/default branch,
authorization booleans/reference and exactly two workers with `id`, `name`,
`automationId`. Publish revision 1 with expected revision 0 under the gate.
Subsequent writes increment `revision` once and update `updatedUtc`; publish
with the previous expected revision. A stale writer or changed identity fails.

| Helper | Responsibility |
| --- | --- |
| `Read-RealTaskJson`, `Assert-RealTaskState` | Complete JSON, exact schema, history and capacity checks; absence is an error |
| `Add-RealTaskClaim`, `Add-RealTaskHandoff` | Unique task/worker assignment and persisted cumulative repair reservation |
| `Set-RealTaskStage` | Guarded launch, correlation, delivery, stopped and reconciliation transitions |
| `Resolve-RealTaskHandoff` | Explicit human-authorized no-launch/stopped/pre-start recovery, retaining history and optional initial-replacement approval |
| `Get-RealTaskAssignment`, `Assert-RealTaskAssignment` | Shared assignment shape and exact actual worker/run/session validation |
| `Publish-RealTaskAcknowledgment` | Atomic one-time execution reservation; duplicates must never execute |
| `Publish-RealTaskEvent`, `Add-RealTaskEvent` | Immutable worker publication and idempotent correlated event ingestion |
| `Set-RealTaskDisposition`, `Get-RealTaskCapacity` | Independent task lifecycle, worker occupancy and waiting bound |
| `Sync-RealTaskIncidents` | Discover canonical incidents even when unindexed; missing prior evidence fails |
| `Publish-RealTaskState` | Owned gate, expected revision, append-only history, atomic publication/readback |

Helpers validate records and transitions, **not the truth of evidence**.
Dispatcher/Developer must inspect actual referenced GitHub/host observations.
Use the [exact schemas and procedures](contract.md); do not generate ad hoc
alternate fields/helpers per tick. If a mutation fails, discard the in-memory
candidate and re-read persisted state; do not continue from a partly mutated
object. An uncertain publication requires readback/reconciliation, not retry.
GateDirectory overrides exist only for isolated deterministic tests.

Operational messages use `Invoke-RealTaskMessage.ps1` for `Prepare`, `Receive`,
`Confirm` and `ProtocolError`. Importing the module also exports
`New-RealTaskMessage`, `Publish-RealTaskMessage`, `Receive-RealTaskMessage`,
`Confirm-RealTaskMessage` and `Publish-RealTaskProtocolError`.
See [protocol schemas, fixed operations and examples](protocol.md). `Receive`
does not execute, ingest events or acknowledge work: it returns a small packet
pointing to the already verified payload. Existing atomic acknowledgment and
gate-owned ingestion remain the next scripted steps.

## Validation and later trial

Run deterministic checks without starting real workers or contacting GitHub:

```powershell
.\tests\RealTaskCoordination.Tests.ps1
.\tests\RealTaskProtocol.Tests.ps1
.\tests\DispatcherGate.Tests.ps1
```

The existing gate entry point includes the new suite, so existing CI runs it
without changing validation/protection policy. Cases cover stage mismatch,
field aliases, duplicate/partial events, unknown timing, missing incident index,
run/session distinctions, backlog backpressure, twelve repairs across workers
and revisions, stale/changed history, immutable publication and merge authority.

The [completed v3 experiment](../agentic-loop-v3/experiment-results.md) already
provides live host/handoff/overlap evidence and measured human-assisted failures.
It is not proof of actual coding/PR/CI/repair/finalize behavior for these new
profiles. Source delivery is accepted through deterministic checks and trial-ready
documentation; another live trial is not required to close #331.

A later real-task trial requires separate human approval of installation,
target workload and selection/implementation authority. Merge authority and
schedule/activation are separate choices. Start disabled/manual, verify catalog
and isolated contexts read-only, then use an authorized bounded workload.
Exercise compatible parallel coding, current-head CI observation, same-worktree
repair and non-coding finalize when such evidence actually occurs. Do not induce
failures, authorize merges or claim unexercised stages merely to complete a trial.
Measure actual coding intervals, completion-to-release and release-to-refill
delays, tick/collection overhead, trigger provenance when available, and human
interventions. Distinguish wall-clock task elapsed, monotonic run duration and
worker idle/CI gaps. Missing observations remain unavailable. Agree cadence
from measurements and verified host skip/queue behavior, not a continuous-busy
promise; activation remains separately approved.

## Recovery and next decisions

Bounded mechanical recovery and escalation are specified in the contract.
Never reset claims/history, fabricate termination, restart uncertain execution,
or infer permission from a cleared label. Pause prevents new ticks, not workers.
Human recovery records evidence, exact affected claim/handoff, stopped-session
inspection and next owner/action before any new authorization.
Use `Resolve-RealTaskHandoff` only after that explicit human decision; its
`-RestartImplementation` switch is separate approval and applies only to proven
unstarted initial implementations. See the contract for recovery modes,
independent blocked claims, backlog readmission and separately evidenced human
delivery. These helpers validate record shape, not the truth of host observations.

The next choice in [#224](https://github.com/iricigor/fingvibe/issues/224)
remains **unresolved**: Architect-driven recovery/self-healing versus
Tester-driven continuous PR validation. Neither is selected, installed or
implicitly implemented by this environment.
