# Local documentation synchronization

The repository's **Documentation sync** custom agent keeps FingVibe's
external-user Markdown aligned with recent changes on `main`. The source agent
and its deterministic helpers are the implementation; the GitHub Copilot desktop
Automation is configured manually after the implementation PR is complete.

## Host and ownership

- **Host:** one local Automation in the GitHub Copilot desktop app.
- **Project:** `iricigor/fingvibe`, using an isolated worktree.
- **Identity:** the authenticated user's existing GitHub/Copilot session.
- **Cadence:** daily at the machine's local 03:00.
- **Availability:** the Automation runs only while the computer and Copilot
  desktop app are available. There is no always-on guarantee.
- **Secrets:** no third-party model or GitHub token is stored for this workflow.

The Automation must select the **Documentation sync** agent. Its UI prompt
should be copied from
[`automation-prompts/documentation-sync.md`](automation-prompts/documentation-sync.md):

> Run one FingVibe documentation synchronization cycle.

Do not duplicate the agent contract into the Automation prompt. Do not configure
or enable the Automation as part of a source pull request.

## Run behavior

The agent audits all `main` changes since the latest successful durable record,
with a minimum lookback of 24 hours. The durable record is an exact
`documentation-sync-run:v1` comment on task #650. A `clean` or `updated` record
advances the checkpoint; a `blocked` record never does.

When evidence supports a documentation correction, the agent updates only user
Markdown and checked textual manual metadata, validates MkDocs, and creates one
normal pull request. If a verified open PR with the
`copilot/documentation-sync/` branch prefix and exact ownership marker already
exists, it updates that same branch and PR. Human-owned PRs are never reused or
overwritten.

No pull request is created for a clean or uncertainty-only result. The agent
does not merge its PR, capture screenshots, probe a live network, or modify
application code. Missing native screenshots are reported as a manual follow-up.

## Deterministic helpers

- [`.github/scripts/Get-DocumentationSyncState.ps1`](../.github/scripts/Get-DocumentationSyncState.ps1)
  reads complete checkpoint/PR state, validates the 24-hour window, and reports
  the exact changed revision range. It fails closed on malformed records,
  shallow history, ambiguous agent-owned PRs or a checkpoint no longer on
  `main`.
- [`.github/scripts/Publish-DocumentationSyncRun.ps1`](../.github/scripts/Publish-DocumentationSyncRun.ps1)
  publishes `updated`, `clean` or `blocked` results and verifies each issue
  comment by reading it back.

Run the focused fixture checks with:

```powershell
.\tests\DocumentationSyncAgent.Tests.ps1
```

## Manual trial and activation

After the implementation PR is reviewed and merged:

1. Pull the merged `main` revision into the project checkout.
2. Create one local desktop Automation, select **Documentation sync**, paste the
   one-line prompt, choose the FingVibe repository and worktree workspace, and
   set a daily local-time schedule at 03:00.
3. Keep the Automation disabled until an approved manual trial completes.
4. Run one controlled actionable fixture and verify the generated PR.
5. Run again with an existing open agent-owned PR and verify update/reuse.
6. Run a clean case and verify that no PR is created and the successful
   checkpoint advances.
7. Verify a blocked case retains the previous checkpoint.
8. Only after that evidence is reviewed, enable the schedule and verify the
   saved Automation identity and configuration in the Copilot desktop app.

Source publication, the one-line prompt, and a saved draft Automation do not
prove that the daily schedule is active. Activation and current-run evidence
remain human verification steps.
