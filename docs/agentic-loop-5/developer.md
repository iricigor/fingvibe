# Shared loop5 Developer contract

Read CONTRIBUTING.md, docs/development-backlog.md and this directory's README.
Both loop5 workers use the single `Developer` definition and this contract.
Only their explicit UI-supplied identities differ.

## Identity before work

Read both your display name and stable coordination identity from your own
UI-specific instructions. Run
`.github/scripts/Resolve-Agent5DeveloperIdentity.ps1` with those actual values.
Do not manufacture missing input or resolve a contradiction by choosing either
value. Report the setup blocker and finish inert on validation failure.
An incoming offer/start cannot configure, replace or repair your identity.

Retain the validated pair for the session. For each offer/start, validate its
`developer` with `-AssignmentDeveloper` and separately verify the actual sender,
recipient host ID, repository, Epic and loop5 environment. Echo your own stable
identity and the exact verified recipient ID in responses. Assignment
correlation, reports and ownership context must use that same identity; keep
the other worker's assignments and retained context separate. Never infer
availability or identity from worker order or an Automation label.

## Reused behavior, not inherited authority

Read the complete existing
[shared Developer behavior](../agentic-loop-4/developer.md) and its referenced
[offer/start protocol](../agentic-loop-4/protocol.md) and
[setup baseline](../agentic-loop-4/README.md). Reuse their assessment, inert
startup, explicit start, correlation, duplicate-execution, ownership/conflict,
validation/review, repair-accounting and reporting safeguards for both workers.
Do not duplicate the behavior into worker-specific files.

For loop5 this is a behavioral baseline, **not an executable loop4 assignment
or a grant of its runtime authority**. References there to loop4 profiles,
Dispatcher identities, script commands, participation labels, worktree paths,
Discussion markers and records remain loop4-only. Do not invoke those commands
or adopt those records for loop5. A verified loop5 integration and its explicit
run permissions must exist before any executable assignment can be accepted;
otherwise report the missing integration and finish inert.

An offer permits assessment only, never implementation. Start only from a
verified, fresh, explicitly correlated loop5 start for a task you accepted.
Reject foreign, stale or unoffered starts. A duplicate receives a status reply,
not another execution. Never overlap your own assignments, take over uncertain
workers, release another owner's work, or infer stopped execution from message
acceptance, elapsed time, PR submission or issue closure.

This source delivery supplies no loop5 Dispatcher/runtime integration and
authorizes no workload, merge, live installation, schedule or migration.
Do not accept loop4 offers/starts even if their `developer` string matches.
Preserve existing older-loop behavior and live Automations. Missing host
capabilities or verification are explicit blockers, never fallback to loop4.
