---
name: architect-epic-preparation
description: >-
  Help Architect choose the next Epic from aggregate issue statistics, safely
  audit and close completed task/Epic Discussions, and verify a new Epic
  coordination Discussion.
---

# Architect Epic preparation

Use this skill only when the interactive user asks which Epic to prepare, asks to
prepare the next Epic, or has selected an Epic for upcoming architecture work.
This skill does not authorize child-task implementation, readiness, priority,
assignment, or scheduling.

## Choose an Epic

Run without `-Epic` when no Epic has been identified:

```powershell
& .\.github\skills\architect-epic-preparation\scripts\Prepare-ArchitectEpic.ps1
```

Present every open `type:epic` as an option containing only:

- title and URL;
- one short summary from the Epic's Goal section;
- total, open and completed direct-child counts;
- aggregate label and lifecycle warnings.

Call out counts for human decisions, human-led work, blocked work, active/review
work and missing size, priority or lifecycle metadata. Do not inspect child
bodies, estimate complexity, design dependencies, or evaluate individual task
solutions during selection. Ask one question: which Epic should be prepared?

## Prepare the selected Epic

After explicit selection, ask one focused question: **How many Developers will
work on this Epic?** Record the answer as an integer. Do not infer it from older
loop profiles, two-worker history or an existing Dispatcher configuration.

Then plan the work:

```powershell
& .\.github\skills\architect-epic-preparation\scripts\Prepare-ArchitectEpic.ps1 `
    -Epic <number> -DeveloperCount <count>
```

The helper completely paginates Discussion and direct-child data. It recognizes
these exact scope forms:

```text
<!-- fingvibe:task=<issue-number> -->
<!-- fingvibe:epic=<issue-number> -->
<!-- fingvibe-agent3-discussion:task-<issue-number> -->
<!-- fingvibe-agent3-discussion:epic-<issue-number> -->
```

Task Discussions belong in `🛠️ Task conversations`; Epic Discussions belong in
`🧭 Epic coordination`. Missing, conflicting, duplicate, wrong-repository or
wrong-category mappings are blockers, not cleanup opportunities.

An open task Discussion may be closed only when its exact linked issue is
closed. An open Epic Discussion may be closed only when its Epic and every
direct native child are closed. Leave a Discussion open when any associated
issue or task is open. Report aggregate unresolved issue/task counts and links;
do not turn that report into task-level architecture or complexity analysis.

The selected Epic needs exactly one open Epic coordination Discussion with the
standard marker. Reuse a single matching open Discussion. If none exists,
create one only after the audit is complete. A closed or duplicate matching
mapping requires explicit human reconciliation; do not silently reopen it,
delete history, or create another.

The selected Epic also needs one open `🤖 Agent logs` Discussion for every
developer numbered 1 through the confirmed count. They use the exact marker
`<!-- fingvibe:epic=<number> developer=developer-N -->`. Reuse one matching open
log; block on a closed or duplicate mapping. Existing global/older-loop Agent
logs do not substitute for the selected Epic's per-Developer logs.

Review the plan with the user and apply only when they selected this Epic and
authorized preparation:

```powershell
& .\.github\skills\architect-epic-preparation\scripts\Prepare-ArchitectEpic.ps1 `
    -Epic <number> -DeveloperCount <count> -Apply
```

Every close or create is freshly checked before mutation and canonically read
back afterward. An incomplete read or uncertain/failed write stops further
mutation; never blindly retry, delete, or infer success from age. The helper
prints open-Discussion counts by category, closed mappings, unresolved mappings,
the selected coordination Discussion and every Developer log.

## Audit child-task readiness

This detailed audit starts only after an Epic is selected. Read every direct
native child, its body, labels, comments, native blockers and parent membership.
Do not perform it while presenting Epic choices.

Evaluate each child against the following agent-readiness rubric:

- **Size and cohesion:** one primary outcome that fits a micro/small scope and
  one focused PR; otherwise identify the concrete split pressure. An Epic with
  a single strict dependency chain should explicitly call out unused Developer
  capacity even when every task is well specified.
- **Clarity:** observable goal, explicit boundaries/non-goals, affected
  components and unambiguous defaults. There must be no product decision hidden
  in implementation prose.
- **Verifiability:** measurable acceptance criteria, relevant failure/cancel/
  recovery cases and a named deterministic validation path. Native UI work also
  needs rendered/accessibility states, fixtures and existing regression-group
  placement.
- **Dependencies:** body and native blockers agree; prerequisites are delivered
  or explicitly ordered, and the task does not redefine an upstream specification.
- **Decisions and access:** no unresolved human choice, credential, external
  approval, unavailable host capability or unstable undocumented dependency
  that prevents an agent from making progress. Technical research may remain
  only when its allowed fallback and escalation condition are explicit.
- **Ownership and conflicts:** affected modules/owners, shared contracts,
  persistence/migration, privacy/security and concurrency/coordination behavior
  are clear enough to assess overlap without opening implementation work.
- **Lifecycle metadata:** exactly one human-approved size and priority plus
  `status:ready` are required for normal pickup, with no conflicting ready,
  active, review, blocked or human-task state. Readiness, authorization and
  implementation labels remain human decisions.
- **Completion identity:** distinguish implementation tasks from specification,
  integration-verification or human-led closure tasks. Do not send an
  organizing/verification issue to an implementation agent.

For every child, report one of:

- **Agent-ready:** criteria and validation are complete; only human lifecycle
  approval/labels are pending.
- **Needs refinement:** actionable missing scope, size, dependency or validation
  detail, with the minimum required change.
- **Human decision:** a product/access/authority question must be answered.
- **Verification task:** not an implementation assignment.

Call out the Epic's dependency shape and which Developers can actually work
concurrently. Do not mark readiness, assign agents, estimate implementation
complexity, create tasks, change scope, or begin implementation from this audit.
Publish the concise preparation result as one stable, read-back comment in the
selected Epic coordination Discussion (marker
`<!-- architect-epic-preparation:<epic>:v1 -->`). Include category counts,
Developer logs, each child assessment, dependency capacity, and unresolved
Discussion mappings. Reuse/update that stable preparation record rather than
creating duplicate audit comments.

## Boundaries

This skill does not create issues, alter issue bodies or labels, mark tasks
ready, perform conflict assessment for implementation, or grant execution
authority. It does not modify loop4/Agent-3 dispatcher contracts, claims,
assignments, schedules or merge behavior. Discussion closure is a preparation
operation only; it must not be used as evidence that an issue's work was
delivered.
