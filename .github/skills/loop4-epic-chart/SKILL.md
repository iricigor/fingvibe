---
name: loop4-epic-chart
description: >-
  Publish a loop4 Epic's hourly stacked task-status chart with cumulative
  trend lines to its Epic coordination Discussion, at most once per 60 minutes.
---

# loop4 Epic progress chart

Use only from an authorized **4️⃣ Dispatcher** cycle, for its configured
repository/Epic. This is reporting, not authority to start work, change claims,
merge, configure Automations or create a schedule. Other loops are unchanged.

As the final step of the cycle, after offers, responses, releases, starts and
the normal cycle outcome (including an idle-cycle outcome), invoke:

```powershell
& .\.github\skills\loop4-epic-chart\scripts\Publish-EpicChart.ps1 `
    -EvidencePath <packet.evidencePath>
```

Run once per cycle, including cycles with no offerable work. Do not wait an hour
or schedule another run. Do not insert reporting before coordination or between
offers and responses/starts.
The helper reuses packet repository, Epic, native-child inventory and Discussion
identity. Its additional reads are narrowly for chart history, fresh throttle
checks and publication verification, not candidate selection.

## Requirements and output

- Local Windows, PowerShell 7.5+, `gh`, existing GitHub.com access, and a token
  accepted by GitHub user-attachments (OAuth or PAT, not a GitHub App token).
  No dependency installation, sign-in or credential substitution is automatic.
- The helper reuses packet facts when at most ten minutes old; after a longer
  coordination cycle it refreshes only reporting repository/Epic/child facts,
  never dispatch candidates. The helper finds exactly one Epic
  coordination Discussion marked `<!-- fingvibe:epic=<number> -->`. If missing,
  use the Dispatcher's existing create/readback procedure and collect fresh
  evidence on the next cycle; do not guess a Discussion number.
- Native child issues define the **current cohort**, not historical membership.
  Complete lifecycle pagination reconstructs status: first `active` or
  `status:review` starts work; removal during review/CI does not make work
  unstarted; completed closure finishes it; reopening resumes it.
  PR submission, successful CI and ended assignments are not completion.
- All three categories must be evidenced. Missing/truncated/inconsistent history
  and non-completed closures stop reporting explicitly, rather than inventing
  counts. This can prevent charts for legacy Epics; reconcile evidence with a
  human, never relabel/close issues to make a chart.
- The image shows at most the latest 24 hourly snapshots plus the current partial
  hour, starting no earlier than Epic creation. Default timezone is the local
  Windows timezone; `-TimeZoneId` selects another installed timezone. Labels show
  date and UTC offset, including DST. Each stack contains green completed,
  orange in progress (including review/CI waits), and red not started. Trend
  lines follow their **cumulative tops**; a gray dashed line marks total tasks.
  The comment includes the timestamp, timezone, counts, cohort and window caveat.

## Publication safety

Dispatcher cycles must remain serialized under the existing loop4 contract.
The helper freshly paginates Discussion comments before posting, even when the
packet already has comments. A verified published marker's server `updatedAt`
enforces a **rolling 60 minutes**, not a calendar-hour bucket, across restarts.
Exactly 60 minutes permits the next report. Clock uncertainty fails closed.

A reservation comment is created and read back **before uploading**:

```text
<!-- fingvibe:epic-chart=v1 epic=<number> status=pending -->
```

That same comment is updated with a GitHub user-attachment PNG and
`status=published`; the exact comment and hosted image are read back. No chart
files or credentials are committed. The upload uses the authenticated GitHub
user-attachments endpoint; no third-party service is used.

Any pending marker, even older than an hour, blocks another publication:
an upload, mutation or verification may have succeeded despite a lost response.
Do not blindly retry, delete a reservation or infer failure from age.
Report its URL for human reconciliation. After checking the actual write/image,
a human may reconcile the comment to the published marker or explicitly delete
an abandoned reservation. Keep its explanation/evidence.

Reporting errors must be surfaced in the Dispatcher's chat/Epic outcome with
the failing operation and any reservation URL. They do not modify assignments,
relax gates or reinterpret the offer packet. Never publish a local image link,
pretend Mermaid grouped bars are stacked, or silently omit reporting failures.
