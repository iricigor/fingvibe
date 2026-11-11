# Agentic loop v3 - two developers: results

**Outcome:** successful local feasibility experiment with human-assisted recovery,
not proof of unattended reliability or real PR-validation quality.

On 2026-11-11, @iricigor accepted the experiment as a success and requested its
documentation, manual incident review and closure. This interactive review
examined all 21 canonical incident records, including resolved recovery history;
the six outstanding findings below are retained for follow-up, not represented
as repaired or silently waived.

## Sources and configuration

- [Tracking task #323](https://github.com/iricigor/fingvibe/issues/323),
  [dummy Epic #322](https://github.com/iricigor/fingvibe/issues/322), and
  [final outcome and incident inventory](https://github.com/iricigor/fingvibe/issues/323#issuecomment-6790608758).
- Three local app Automations: **2️⃣ Dispatcher**, **2️⃣ Test Developer 1** and
  **2️⃣ Test Developer 2**, sharing one Windows account and persistent state.
- Manual setup/initial dispatch, then owner-enabled `*/2 * * * *` Dispatcher
  scheduling. Developers remained manual-only, independently launched by
  Dispatcher. Four minutes was suggested as mitigation, not verified as applied.
- [Published source instructions](README.md) came after the user installed
  description-based Automations. Source publication does not prove exact prompt
  parity or model/settings; those were not independently captured here.
- Local `state.json`, immutable events, canonical incident files and recorded
  host inspection supported reconciliation. Backups and repeated observations
  are not additional incidents. Machine-local paths, host IDs and raw session
  dumps are intentionally not committed.

## Measured execution

All times are UTC on 2026-11-11. Monotonic duration is distinct from wall-clock
interval and reporting overhead.

| Task | Developer | Wait start | Wait end | Required seconds | Measured seconds |
| --- | --- | --- | --- | ---: | ---: |
| [#324](https://github.com/iricigor/fingvibe/issues/324#issuecomment-6789897680) | 1 | 07:25:28.7328211 | 07:30:28.8177001 | 300 | 300.0793532 |
| [#325](https://github.com/iricigor/fingvibe/issues/325#issuecomment-6790001937) | 2 | 07:30:46.0361781 | 07:35:46.0615431 | 300 | 300.0198813 |
| [#326](https://github.com/iricigor/fingvibe/issues/326#issuecomment-6790388757) | 1, recovered | 07:51:52.8766356 | 07:54:52.8944998 | 180 | 180.0151043 |
| [#327](https://github.com/iricigor/fingvibe/issues/327#issuecomment-6790475257) | 2 | 07:54:48.3453441 | 07:59:48.3668590 | 300 | 300.0169671 |
| [#328](https://github.com/iricigor/fingvibe/issues/328#issuecomment-6790528283) | 1 | 07:58:32.5462564 | 08:02:32.5575620 | 240 | 240.0070247 |

- Five waits completed, with five acknowledgments/completions and no duplicate
  wait or same-worker overlapping logical assignment found in retained evidence.
  Five original launches used six handoffs: #326's first failed before execution;
  one human-authorized recovery superseded it in its verified-stopped session.
- Actual completed wait overlap: **4.5491557 seconds** for #326/#327 and
  **75.8206026 seconds** for #327/#328. #324/#325 did not overlap; their gap was
  17.218478 seconds. Two occupied slots alone would not prove parallel execution.
- Maximum observed/reconstructed occupied slots: **two**. Matching completions,
  actual stopped-session evidence, child closure and Epic entries were reconciled.
  This does not certify unrecorded external executions.

| Refill | Completion to next launch intent (seconds) | Verified release to intent (seconds) |
| --- | ---: | ---: |
| #324 to initial #326 | 412.9913372 | 2.8096213 |
| #325 to #327 | 1035.1930754 | 942.2552025 |
| Recovered #326 to #328 | 117.4783953 | 0 |

The zero is one persisted release/reservation transition, not instantaneous
worker startup. #326's stage-guard failure froze later dispatch despite Developer
2 being free. The first Dispatcher tick took 231.512 seconds including setup and
recovery; polling, host startup, messaging and reconciliation all reduced useful
overlap. There is no steady-state overhead or continuous-utilization guarantee.

## Incident review

Snapshot: **21 canonical records; 15 technically resolved, six open/review
findings**. This table preserves every identifier and distinguishes technical
status from the closure disposition authorized in this interactive review.
Original reporter attribution was inconsistent: human findings below are known;
missing agent attribution must not be reconstructed from guesswork.

| Incident identifier | Technical status | Reviewed finding / disposition |
| --- | --- | --- |
| `worker-2-repository-association-unverified` | Resolved | Owner corrected repository association; verify configuration before launch. |
| `atomic-replacement-null-binding-failure` | Resolved | Empty backup-path binding prevented publication; verified unchanged state and used supported atomic publication. |
| `correlation-action-nesting-797965b8` | Resolved | Helper branch performed no correlation write; corrected before the sole delivery, without relaunch. |
| `completion-schema-assumption-797965b8` | Resolved | Valid elapsed field and distinct acknowledgment/start timestamps were rejected; require a shared, tested event schema. |
| `dispatcher-acquisition-time-uncaptured-c259f8ed` | Resolved with limitation | Acquisition clock was not independently captured; report unknown instead of deriving it from tool output. |
| `dispatcher-report-preparation-parser` | Resolved | Read-only query syntax failed before execution; corrected without ownership changes. |
| `dispatcher-final-validation-dictionary-grouping` | Resolved | Dictionary/property grouping falsely reported cross-worker overlap; typed grouping corrected validation. |
| `dispatcher-incident-index-incomplete` | Resolved | Final guard found a canonical incident missing from state index; index corrected before lock release. |
| `negative-startup-overhead-3af3a46b` | Resolved | Preserve originals and immutable UTC correction; do not rerun completed work to repair metadata. |
| `startup-overhead-timezone-797965b8` | Resolved | Timezone conversion produced inflated overhead; corrected separately from measured wait. |
| `automation-run-lifecycle-3af3a46b` | Resolved | Bare run ended before assigned session execution; actual session evidence governed release. |
| `automation-run-lifecycle-797965b8` | Resolved | Same run/session distinction for Developer 2. |
| `notification-target-archived-3af3a46b` | Resolved | Optional reply failed; durable completion enabled reconciliation without resend. |
| `notification-target-archived-797965b8` | Resolved | Same archived-target behavior; durable evidence remained authoritative. |
| `worker-preflight-stage-guard-b17a0eaf` | Resolved after human recovery | Valid stage omitted from worker whitelist; stopped/no-start verification, new handoff and guarded recovery completed. |
| `branch-metadata-scope-conflict-3af3a46b` | Needs review | Recorded host-required app-managed branch rename, no repository-file edits reported; accept historical limitation and carry explicit environment-scope handling forward. |
| `branch-metadata-scope-conflict-b17a0eaf` | Needs review | Same historical environment/scope ambiguity for failed #326 attempt; no independent file audit claimed. |
| `branch-metadata-scope-conflict-e7402cd8` | Needs review | Same scope ambiguity for #328; branch metadata corroborated, worker reported no file edits. |
| `developer-task-in-progress-not-reflected-on-github` | Open, human-reported | Define the owner/timing of existing `active` lifecycle transitions in the next environment; do not confuse labels with locks. |
| `dispatcher-tick-exceeds-one-minute-cadence` | Open, human-reported | Retain measured overhead and optimize compact collection; cadence is a measured operating choice, not a guarantee. |
| `scheduler-queued-versus-skipped-ticks-unverified` | Open, human-reported | Owner accepted non-blocking uncertainty: no accumulating queue defect demonstrated; restart-clears-queue is an unverified assumption. |

Resolved helper/reporting defects are not evidence of a stable reusable runtime
implementation: the next environment needs deterministic regression coverage.
Original records remain evidence; this review does not rewrite their historical
statuses or fabricate missing provenance.

## Decisions and next requirements

- **Keep durable state authoritative.** Messages wake consumers but may target
  archived sessions. Never equate queue acceptance, issue closure or a bare
  Automation result with stopped execution.
- **Share deterministic contracts.** Test state transitions, event fields,
  offsets/timing, atomic writes, incident discovery/indexing and partial
  publication instead of regenerating ad hoc helpers on each run.
- **Separate ownership from capacity.** Preserve uncertain claims, but design
  safe independent work so one pre-execution failure need not freeze both slots.
- **Observe progress, not guessed deadlines.** Record next event/owner and
  meaningful changes; unavailable live evidence means unknown. Record tick
  trigger provenance when available; the run-history UI alone was insufficient.
- **Carry forward, do not claim delivery.** #282 partly covers #260's collection
  goal; retained-PR/review evidence and measured compact collection remain useful.
  #285 supersedes #261's three-repair instructions; runtime boundary/cumulative
  evidence regression coverage is not established by this synthetic trial.

The next real environment is **one Dispatcher and two Developers**, all prefixed
`3️⃣`, separate from existing `⏩` agents and this `2️⃣` experiment. Creation of its
task is authorized; implementation, target workload, real merge authority,
installation and activation require their own gates.

The intake task is [#331](https://github.com/iricigor/fingvibe/issues/331), a direct
child of development-environment Epic #92. #260 and #261 are closed as
superseded/not planned, with their remaining requirements preserved in #224;
neither closure asserts that every original acceptance criterion was delivered.

After that delivery, the next activity remains **undecided**:

1. Add scheduled **Architect** for incident/progress analysis and bounded
   recovery/self-healing proposals, including periodic worker-activity checks.
   Auto-approved changes need explicitly agreed authority.
2. Add **Tester** for substantive current-revision acceptance and continuous
   PR-validation handling, not ceremonial sign-off.

The owner-only GitHub communication protocol remains required future design:
accept human control only from verified @iricigor metadata, agree channel,
commands, acknowledgment, deduplication and recovery, and preserve worker reports
as evidence rather than authority. Repository visibility is not private messaging.

The complete future-work disposition belongs to
[#224](https://github.com/iricigor/fingvibe/issues/224). No extra Architect/Tester
Automation, production migration, schedule change or recovery authority is
installed by this closeout.
