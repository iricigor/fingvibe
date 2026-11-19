# loop5 Developer source setup

[Task #592](https://github.com/iricigor/fingvibe/issues/592) provides one shared
[`Developer`](../../.github/agents/automation-5-developer.agent.md) definition.
This is next-cycle source/setup work. It does not replace, rename or modify
any existing source profile, saved Automation, schedule, permission, routing
or coordination record.
Do not install or activate loop5 as part of this delivery.

## Any number of workers, one definition

When separately authorized to configure loop5, every Developer Automation
selects the same **Developer** agent. Its UI-specific instructions supply the
worker's exact name; they do not contain a copy of the shared behavior contract.
No Developer count is assumed and no second coordination identifier is needed.

Example for one worker:

```text
You are 5️⃣Developer1.
Environment: loop5
Follow docs\agentic-loop-5\developer.md.
```

Another worker can be configured independently:

```text
You are 5️⃣Developer2.
Environment: loop5
Follow docs\agentic-loop-5\developer.md.
```

These are examples, not an exhaustive or required list. `5️⃣Developer3` or a
differently numbered/name-styled future worker uses the same definition and its
own exact `You are ...` instruction.

For this stage, the configured name is the stable worker identity. It must come
from that worker's UI-specific instructions, not be inferred from task order,
another worker, an offer, an Automation display label, or an assumed host API.
There is no default worker. If the name is absent/contradictory, or an
assignment names a different worker, report the mismatch and execute nothing.
The name is not an Automation/run/session ID. Names that happen to match an
older-loop worker still belong to separate environments and do not route work
across loops.

## Behavior and isolation

Every worker follows only the [same loop5 behavior contract](developer.md). The
shared definition, UI-specific name and loop5 integration are self-contained;
they do not import another environment's behavior, instructions, host identity,
scripts, participation labels, assignments, reporting records or permissions.
Missing loop5 runtime integration is a blocker, not permission to borrow another
environment's helpers or mutate its state. This delivery does not provide a
loop5 Dispatcher.

Loop5 has no live workload in this delivery. Any later parallel execution still
requires repository-wide ownership and conflict assessment; separate agent names
do not make competing edits safe.

## Source checks and pending adoption

Run the desktop-free checks:

```powershell
.\tests\Agent5Developer.Tests.ps1
```

They exercise the shared-definition and missing/contradictory/foreign-name
instruction safeguards. They do not launch, discover or modify live Automations.

Before live adoption, separately authorize and record actual evidence for:

- Every configured Automation selecting the same shared definition and
  receiving its own exact UI-supplied worker name in the intended host.
- Verified loop5 Dispatcher/host routing, distinct recipient IDs and assignment
  correlation for every configured worker; rejection of foreign or duplicate
  execution.
- Loop5-specific reporting/ownership/runtime integration that cannot consume or
  modify any other environment's assignments and coordination records.

All of that live verification remains **pending**. A passing source check,
merged PR, configured name or accepted message is not evidence of live routing,
safe execution, stopped workers or activation approval.
