# loop5 Developer source setup

[Task #592](https://github.com/iricigor/fingvibe/issues/592) provides one shared
[`Developer`](../../.github/agents/automation-5-developer.agent.md) definition.
This is next-cycle source/setup work, developed alongside the still-used
**4️⃣** environment. It does not replace, rename or modify older source profiles,
saved Automations, schedules, permissions, routing or coordination records.
Do not install or activate loop5 as part of this delivery.

## Two workers, one definition

When separately authorized to configure loop5, both Automations select the same
**Developer** agent. Their UI-specific instructions supply the following distinct
identities; they do not contain copies of the shared behavior contract.

Developer 1:

```text
You are 5️⃣Developer1.
Coordination identity: developer-1
Environment: loop5
Follow docs\agentic-loop-5\developer.md.
```

Developer 2:

```text
You are 5️⃣Developer2.
Coordination identity: developer-2
Environment: loop5
Follow docs\agentic-loop-5\developer.md.
```

| UI display name | Stable coordination identity |
| --- | --- |
| `5️⃣Developer1` | `developer-1` |
| `5️⃣Developer2` | `developer-2` |

Both values must be explicitly supplied by that worker's UI instructions and
match this table exactly. Never infer them from task order, another worker,
an offer, an Automation's display label, or an assumed host API. Neither worker
is the default. Missing, contradictory or unsupported identity blocks setup.
Report the specific error without accepting or executing work.

Use the read-only identity validator with the values actually received:

```powershell
.\.github\scripts\Resolve-Agent5DeveloperIdentity.ps1 -DisplayName '5️⃣Developer1' -Developer developer-1
```

For an offer or start, also pass its `developer` as `-AssignmentDeveloper`.
This rejects a foreign/missing assignment identity, but does not authenticate
the sender, host recipient or environment, or authorize execution.
Do not use the example's values as a fallback for missing UI instructions.
Display names are not Automation/run/session IDs. Even though stable worker
identifiers have the same spelling as in loop4, they belong to separate
environments and must never route work across them.

## Behavior and isolation

Both workers follow the [same behavior contract](developer.md), reusing the
existing loop4 contract as a read-only behavioral baseline rather than copying
it into two profiles. Loop4-specific commands, host identities, participation
labels, assignments and records are not a runnable loop5 configuration.
Missing loop5 runtime integration is a blocker, not permission to run old-loop
helpers or mutate its state. This delivery does not provide a loop5 Dispatcher.

The existing 4️⃣ Automations can continue operating under their existing
instructions. Loop5 has no live workload in this delivery. Any later parallel
execution still requires repository-wide ownership and conflict assessment;
separate agent names do not make competing edits safe.

## Source checks and pending adoption

Run the desktop-free checks:

```powershell
.\tests\Agent5Developer.Tests.ps1
```

They exercise the documented UI identity pairs and invalid/missing/foreign
identity handling. They do not launch, discover or modify live Automations.

Before live adoption, separately authorize and record actual evidence for:

- Both Automations selecting the same shared definition and each receiving its
  own complete UI identity in the intended host.
- Verified loop5 Dispatcher/host routing, distinct recipient IDs and assignment
  correlation for both workers; rejection of foreign or duplicate execution.
- Loop5-specific reporting/ownership/runtime integration that cannot consume or
  modify the still-used loop4 assignments and coordination records.

All of that live verification remains **pending**. A passing source check,
merged PR, configured name or accepted message is not evidence of live routing,
safe execution, stopped workers or activation approval.
