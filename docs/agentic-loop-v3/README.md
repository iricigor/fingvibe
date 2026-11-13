# Agentic loop v3 - two developers

An isolated **local app** experiment: one Dispatcher routes five synthetic wait
tasks across two independent Developers. It tests handoffs, overlapping execution,
slot recycling and durable incident reporting, not application implementation,
PR validation or self-healing.

Tracking: [#323](https://github.com/iricigor/fingvibe/issues/323).
Dummy Epic: [#322](https://github.com/iricigor/fingvibe/issues/322).
Publication: [#329](https://github.com/iricigor/fingvibe/issues/329).
Publishing these instructions does not complete the runtime experiment.

**Completed experiment:** see [results and the complete 21-incident review](experiment-results.md)
for measured overlap, human-assisted recovery, accepted limitations and the
separate `3️⃣` agent-3 environment direction. The instructions below preserve the
trial setup; they are not permission to rerun its five tasks or reset its state.
The separate agent-3 successor is [#331](https://github.com/iricigor/fingvibe/issues/331)
(intake only); extended Architect/Tester directions remain in #224.

## Local setup

| Local Automation / agent | Trigger |
| --- | --- |
| [2️⃣ Dispatcher](../../.github/agents/automation-v3-dispatcher.agent.md) | Every two minutes, after explicit user activation |
| [2️⃣ Test Developer 1](../../.github/agents/automation-v3-developer-1.agent.md) | Manual-only; launched by Dispatcher |
| [2️⃣ Test Developer 2](../../.github/agents/automation-v3-developer-2.agent.md) | Manual-only; launched by Dispatcher |

Use the `iricigor/fingvibe` project, local host and isolated worktrees for all
three. Select each corresponding agent in an updated checkout; do not combine
these profiles with production Dispatcher/Developer instructions. They inherit
host tools intentionally, following the [existing host-tool guidance](../../CONTRIBUTING.md#local-dispatcher-and-developer).
Inherited tools grant neither permissions nor guaranteed runtime capabilities.

The instructions may also be used as self-contained local Automation descriptions
with their referenced README available. Saved descriptions and selected agents do
not synchronize automatically from this repository. Do not replace prompts,
reset state or change settings during an active run without separate approval.

Create new Automations disabled and trial manually first. The user reported
creating these three, then enabling the Dispatcher schedule on 2026-11-11.
No configuration is installed or changed by these source files. The agreed cron:

```cron
*/2 * * * *
```

Schedules require the app/computer to be available. The host's skip/queue/overlap
policy is unverified. A first manual tick took about 3m 51s, including setup and
recovery; two minutes is an experimental cadence, not a safe-runtime guarantee.

## Work and evidence

| Child task | Assigned wait |
| --- | --- |
| [#324](https://github.com/iricigor/fingvibe/issues/324) | 300 seconds |
| [#325](https://github.com/iricigor/fingvibe/issues/325) | 300 seconds |
| [#326](https://github.com/iricigor/fingvibe/issues/326) | 180 seconds |
| [#327](https://github.com/iricigor/fingvibe/issues/327) | 300 seconds |
| [#328](https://github.com/iricigor/fingvibe/issues/328) | 240 seconds |

Dispatcher assigns at most one new task per tick, with two unresolved slots and
one assignment per worker. Bare Developers are inert until a correlated explicit
assignment arrives. They persist acknowledgment, actively wait, persist completion,
report and stop. Dispatcher verifies actual stopped execution before slot reuse
and reconciles child closure/checklists. Queue admission, reports and issue
closure are not execution-stop proof. Measure actual interval overlap and refill
delays; polling cannot guarantee continuously busy workers.

All three use the same Windows account and shared directory outside worktrees:

```text
%LOCALAPPDATA%\FingVibe\AutomationExperiments\fingvibe-322\
  state.json     Dispatcher-owned task/slot/handoff state
  events\        Immutable worker events
  incidents\     Deduplicated incidents and recovery evidence
```

Use atomic publication/readback and an owner-specific atomic-create Dispatcher
lock. This is single-PC coordination, not distributed locking. Never reset state,
expire ownership by age, replace unknown workers or retry uncertain starts.
Failures must be explicit. New incident files, including human-reported entries,
must be discovered even when not indexed in state. Record original reporter
separately from recording agent when known. Do not commit machine-local records
or sensitive host details; publish concise review outcomes on #323 instead.

## Review and deferred work

The current findings include cadence overhead/unknown overlap policy, missing
GitHub in-progress visibility and inconsistent provenance in older records.
They remain review items, not silently implemented fixes. Consolidation with
production agents and reliable `active` lifecycle transitions require follow-up.
The existing [backlog contract](../development-backlog.md#local-dispatcher-exception)
and production single-claim/validation/merge policy are unchanged.

After five verified completions, reconcile one final report and make later ticks
no-ops. Schedule deactivation remains user-controlled. #323's closure gate was
manual incident review and explicit disposition of these future plans; the
[closeout record](experiment-results.md) preserves that review without claiming
the future work is implemented:

- **Tester:** optional substantive, revision-bound validation/acceptance review;
  no sign-off-only Automation in this iteration.
- **Architect:** optional scheduled incident/progress analysis while work runs,
  initially proposal-only; auto-approved changes need separate bounded authority.
- **GitHub communication:** agree an owner-only protocol for @iricigor before
  implementation; verify author metadata and distinguish worker evidence from
  human commands. Repository visibility does not provide private communication.

This publication adds no executable orchestration service, agents beyond these
three, schedule activation, production migration or automatic recovery.
