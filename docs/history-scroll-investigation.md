# Native history scrolling investigation

Task [#266](https://github.com/iricigor/fingvibe/issues/266) investigates the
automation failures in [#264](https://github.com/iricigor/fingvibe/pull/264).
It does not repair production traversal or replace required PR checks.

The separate **History scrolling investigation** workflow runs only when its
diagnostic files change in a same-repository PR, or when explicitly dispatched.
It publishes the app and loads the history fixture/helpers from immutable commit
`ebd4f07d731d5f4df45d1949f4c3b79fb1ebb9e2`, independently of later changes to
the implementation branches. It never automates the working desktop.

The section experiment replays the pinned five small-fixture iterations,
normal/virtual navigation, summary collapse/expand and existing small-row checks.
If those complete, it also replays the pinned light/dark, narrow-resize,
collapse/position/restore-width sequence. Only the section helper's scrolling,
bring-into-view and focus calls are instrumented; production decisions are
unchanged. Replay sampling adds observation overhead, but no polling delays.
Replay does not enumerate observation rows; row sampling is confined to the
independent list experiment to limit observer-driven realization. Properties are
batch-cached for each measurement, and snapshots report their sampling cost.

The list experiment starts in a separate process with the pinned 205-observation
fixture and first 100-row page. It positions the outer page independently of the
production section helper. Each inner large increment and small decrement is
observed separately, with eight 250-ms polls and no compensating movement during
that interval. Commands are bounded; unsupported focus, ineffective movement,
setup failure and reported boundaries remain explicit.

Download the workflow's `history-investigation-<run>-attempt-<attempt>` artifact:

- `section` and `list` contain append-only `scroll-trace.jsonl`, provenance and
  representative/failure screenshots.
- Each snapshot includes raw window/owner/target/row geometry, runtime IDs,
  supported patterns, scroll metrics, expansion/focus, page status, all enumerated
  rows and candidate-visible rows.
- Source-helper cached containers and fresh peers are recorded separately;
  command records retain the issuing object's identity, resolved arguments and
  its scroll metrics before/after, rather than only freshly acquired metrics.
- `observation` records compare visible labels and both inner/outer percentages
  after a quiet interval. `command-error` and `experiment-error` retain messages
  and script stack traces.

Candidate visibility combines `IsOffscreen`, nonempty rectangles and intersection
with the window and reported list rectangle. These are measurements, not a claim
that an automation peer exposes the true viewport. Corroborate with screenshots,
especially when reported rectangles move or are clipped. UIA enumeration can
itself realize peers and change timing; preserve this observer limitation in
findings.

Run desktop-free helper checks with:

```powershell
.\tests\HistoryScroll.Investigation.Script.Tests.ps1 -SourceDirectory <pinned-checkout>
```

A diagnostic workflow failure can be the recorded reproduction, not a repaired
regression. Read both experiments' artifacts even if section replay fails.
Completing a diagnostic is not exhaustive 205-row acceptance or speedup evidence.
Publish actual run/artifact links and distinguish demonstrated behavior, likely
causes and unresolved questions before separately authorizing any fix.
