# Issue titles

For task issues, use the task emoji followed by a space and a descriptive
title, for example `🛠️ Simplify task titles`. Do not include `Task:` in task
titles; the `type:task` label identifies the issue type. Keep the existing
title conventions for Epics, bugs, and feature requests.

# Issue organization

Every repository issue must either be an Epic labeled `type:epic` or be a
direct native GitHub sub-issue of an issue labeled `type:epic`. This applies
to tasks, bugs, and feature requests, including issues created during intake.
A title or body link alone does not establish Epic membership.

When creating or updating a non-Epic issue, identify the appropriate Epic,
attach the issue using GitHub's native sub-issue relationship, and include it
in the Epic's child checklist. Verify the native parent, its `type:epic` label,
and the checklist entry on GitHub before claiming issue intake is complete.
Preserve valid existing parentage and unrelated labels, scope, state, and
ownership; do not move issues between Epics without human approval.

If the appropriate Epic is unclear, ask the user before choosing or creating
one. If attachment or verification fails, report the blocker explicitly rather
than treating a body link as success. Do not bulk-migrate existing issues
without an explicit request.

Epic grouping does not authorize implementation or grant readiness, priority,
assignment, or ownership. Follow the existing approval and lifecycle contract
in `docs/development-backlog.md` and the selected agent's workflow.
