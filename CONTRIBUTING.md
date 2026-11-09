# Contributing

For local builds, core/native regression checks, build identity, and CI review
gates, see the [FingVibe reference](docs/reference.md#test).

## Parallel feature work

Keep changes within the owning module whenever possible. Coordinate changes to shared models and contracts before editing them, and keep pull requests focused on one feature or structural refactor.

Current ownership boundaries:

- `MainWindow.xaml.cs` owns shell initialization, page routing, navigation, and top-level wiring.
- `MainWindow.NavigationPane.cs` owns navigation-pane resizing, icon-only collapse, and its saved width/collapse preference.
- `MainWindow.Scan.cs` owns scan start, cancellation, progress, and completion status, implementing the UI steps of the shared scan path.
- `ScanExecution` owns the single serialized LAN scan path shared by manual and scheduled requests: the network-activity lease, per-scan network identity, and outcome classification.
- `PeriodicScanScheduler` owns recurring-scan timing, retry backoff, and missed-interval handling.
- `PeriodicScanController` owns the scheduled-scan lifecycle: loading readiness, enable/interval changes, sleep pause/resume, and shutdown on close.
- `PeriodicScanPresentation` owns scheduled-scan status, header-summary, and deferred-discovery text; `MainWindow.PeriodicScans.cs` wires it to Settings, saved preferences, and Windows power events.
- `MainWindow.ScanPresentation.cs` owns responsive shared network-header layout and the scan-progress pulse.
- `MainWindow.Results.cs` owns result collection, filtering, sorting, comparer state, and result summaries.
- `Views/DeviceLastSeenAgeRefresh.cs` owns the Devices page's presentation-only minute refresh of Last seen ages while that page is shown.
- `MainWindow.NetworkIdentity.cs` owns local network selection and public/local network identity display.
- `MainWindow.Snapshots.cs` owns snapshot restoration, persistence status, and saved-scan state.
- `MainWindow.DeviceDetails.cs` owns the selected-device details view.
- `MainWindow.DeviceActivity.cs` supplies selected identity/network/revision context; `Views/DeviceDetailsPageView.Activity.cs` owns Activity controls, cancellable query lifecycle and grid presentation. Core `DeviceActivity` owns aligned buckets and weekday counts.
- `MainWindow.PeopleRooms.cs` owns People/Rooms persistence and assignment orchestration across pages.
- `Views/PeoplePageView` and `Views/RoomsPageView` own local search and list presentation; their detail views own the selected person/room and reconcile it with refreshed display data. `PeopleRoomsPresentation` supplies pure name validation, suggestions, assignment projections and count text.
- `Views/PeopleRoomsDialogs` owns People/Rooms add/edit, delete-confirmation and device-choice UI for all entry points. The shell supplies the window's `XamlRoot`, current records and a save callback; dialogs keep failed saves open and return a saved record only after success. Stores, serialized/revision-checked writes, navigation and cross-page refreshes remain outside the views.
- `Views/*PageView.xaml(.cs)` owns each page's visual tree, child controls, local layout, and UI request events. Child controls stay private; the shell supplies display data and handles requests through focused page APIs.
- `MainWindow.xaml` owns navigation, the shared scan header and independent build-ribbon overlay, and composes the page controls. `Tools/ToolsPage.xaml(.cs)` continues to own Tools navigation and lifecycle forwarding.
- `LanScannerService` owns scan orchestration and probe lifecycle. `IScanResultEnricher` and `ScanResultEnricher` own device name, vendor, MAC, and port enrichment.

Keep page-specific layout and state with the page when adding or substantially changing a page. Limit shell changes to route registration and top-level wiring. Add regression tests alongside the module whose behavior they cover, and avoid unrelated formatting or cleanup in parallel pull requests.

Extracted pages have separate WinUI XAML namescopes and compiled-binding roots. Preserve automation names/IDs and shared `DeviceColumnLayout.Current` bindings when changing page boundaries. Update the page-to-scenario rules in `.github/scripts/UiReviewScenarios.ps1` and their regression tests whenever a view is added or renamed.

## Extending native UI regression coverage

Devices and Sidebar keep their existing test entry points; focused behavior
modules live in `tests/UiRegression`. Keep shared lifecycle/readiness/input
helpers separate from feature assertions. Entry points dot-source scenario
modules at script scope, in the recorded order, because scenarios share fixture,
selection and rendering state. Do not invoke them through a new function scope
or append unrelated feature matrices to the baseline.

Use the shared bounded waits, visible/nonempty page-scoped lookup, isolated
fixture directories, normal shutdown and process-specific cleanup. Reacquire
controls after navigation, filtering, reconstruction or virtualization;
automation enumeration alone does not establish visible reachability. Wait for
the current selection's completed state, not just control existence or a changed
scroll percentage. Preserve intentional hover/dwell, debounce, animation and
appearance-settling checks. Failures must remain failures with partial
diagnostics, not retries-to-green or longer timeouts hiding the cause.

For data-heavy features, agree measurable budgets before implementation and
reuse existing performance requirements. Test data correctness, query cost,
aggregation/allocation and cancellation in Core/storage where possible. Add an
isolated representative native fixture with small/empty/error and relevant
large/virtualized states; native tests still prove real binding, paging,
reachability, keyboard/accessibility and layout. Exercise loading, selection
changes, stale-completion protection and cancellation through controllable
dependencies or scoped fixtures, not a database lock beyond the production
busy timeout.

Review current-revision disposable Windows evidence for affected behavior and
retain coverage mappings and phase diagnostics. See the [test reference](docs/reference.md#test)
for the desktop-free foundation check. These are contributor/reviewer
expectations, not a new mandatory manifest or gate. Enforced coverage
selection remains separate work in #256.

Device Details checks run in three independent CI jobs that follow the planned
Overview/History tab boundary: `details-summary`, `details-identity` and
`details-history`. Add Activity or observation-table checks to `details-history`,
and keep every job within the 240-second budget using its `call-costs.json` and
`phases.jsonl` evidence. Mark each logical segment with a phase, keep the
original failure when cleanup also fails, and do not dispatch a matrix job that
runs no checks. Ship harness changes like these separately from feature changes.

The Sidebar People/Rooms module covers list/detail editors, search, validation,
cancel/save, selection refresh, assignments and deletion. Its isolated inventory
fixture also checks a retained failed-save draft, retry, restart and unavailable
data restrictions. The capture smoke keeps short-name suggestion coverage and
checks add-and-assign and cancellation from Device Details. Run these native
paths on disposable CI desktops, not the user's working desktop.

Native execution modes reuse the existing smoke and suite implementations.
The independent observational comparison runs a short launch/scan/filter/details
baseline on the exact trusted PR head; it does not replace any authoritative
PR check or reviewer requirement. Full validation forces every currently
enabled suite and catalog capture, with core/script/security and installer
checks, independently of PR scenario selection. Temporarily disabled features
remain omitted until their separately authorized restoration; full execution
does not re-enable them. Standalone full validation runs automatically on
pushes to `main` (including merges) and remains manually dispatchable, without
changing PR or release gates. See [execution modes and evidence](docs/reference.md#independent-native-validation).
Enforced specifications and any gate cutover remain #256, not this comparison.

### Asynchronous surfaces

New or changed UI surfaces that load asynchronously expose one observable state
and keep their lifecycle testable without WinUI:

- **Observable state.** Publish `AsyncSurfaceSession.Status` as UI Automation
  `ItemStatus` on an always-present control of the surface (Activity uses
  `ActivityScroll`). The format is `<State> (request <n>): <selection>` with
  `Loading`, `Ready`, `Empty` or `Error`, or `Idle` while inactive. Request
  numbers only increase, and the selection names what the user chose. An
  outcome is reported only after it is rendered and laid out. Controls with
  automation IDs keep their peers in every state; keep text non-empty instead of
  clearing it.
- **Native waits.** Read the request number before an action, then use
  `Wait-UiRegressionSurfaceState -After <n>` (with `-Selection` or `-State` as
  needed) and assert the rendered content once. Do not poll incidental cells,
  text or scroll positions to infer readiness. An unexpected `Error` fails
  immediately with its status; a surface that is briefly absent (for example
  while its page opens) is awaited rather than failed. `Assert-UiRegressionPeers`
  checks that identified controls survive loading and error states.
- **Positioning.** Bring a control into view the way the app does: focus it if
  it is focusable, then use UI Automation `ScrollItemPattern.ScrollIntoView()`.
  Reserve scroll-percentage arithmetic for targets without either, and treat a
  momentarily missing peer inside a wait as "not yet" rather than a failure.
- **Lifecycle tests.** Prove cancellation, replacement, stale completion and
  Retry deterministically in `FingVibe.Core.Tests` against `AsyncSurfaceSession`
  (or a surface-specific component linked the same way) with a controllable
  loader. Native tests prove wiring, binding, reachability, keyboard access,
  accessibility, layout and appearance; they do not use timing to prove races.
- **Applicability.** This applies to new or changed asynchronous surfaces.
  Convert existing surfaces, such as Discovery, only when a task already
  changes them; there is no bulk retrofit.

## Explicitly invoked Epic Developer

[⏩ Epic Developer](.github/agents/automation-epic-developer.agent.md) is an ordinary
repository custom agent for the first-iteration noninteractive workflow.
The name prefix distinguishes it in the picker; it does not grant permissions.
Its reusable rules are separate from the
[Timeline kickoff](docs/automation-prompts/timeline-worker.md), which identifies
the target Epic and links back to the intended agent.

In the Copilot desktop app, select **⏩ Epic Developer**, choose a new isolated
worktree, and use these instructions for a manual run or a manually triggered
Automation:

```text
Read docs\automation-prompts\timeline-worker.md and execute its instructions.
```

The kickoff's link does not select/switch agents, and this Markdown file is not
automatically discovered Automation configuration. The selected checkout must
contain both files; reopen the picker/start a fresh session after pulling them.
The instructions authorize at most one task and a validated merge when explicitly
invoked by a human under the
[manual-worker exception](docs/development-backlog.md#explicitly-invoked-manual-worker-exception).
They do not change Architect's workflow.

Schedule, selected agent, model, host, and enabled state remain app configuration.
This delivery creates or enables no Automation and verifies no live picker/run.
A local scheduled run requires the app/computer to be available and separate
activation approval. Start manually; do not overlap invocations. Existing
claims/draft PRs block pickup even after an hour, and orphan recovery is excluded.
Every claimed run must publish and verify a task report with collapsed detailed
logs, plus a brief parent Epic outcome linking to that report:
actual UTC start/end times and calculated total elapsed run duration, task and
PR links, work/validation outcome, decisions,
post-work comments, corner cases, later clarification questions, and unimplemented
suggestions. Duration includes capacity checks, implementation, CI waits, repairs,
and delivery verification, not just active coding time. Report `HH:mm:ss` with
total hours that do not wrap at 24 and a human-readable equivalent, for example
`00:42:17 (42m 17s)`, truncating fractional seconds after subtracting timestamps.
An incomplete run measures duration until stopping and must not claim task
completion. Never fabricate an interrupted run's end time or duration; missing
or inconsistent timing evidence must be reported as unavailable with the reason.
Use Windows build prerequisites and existing CI for native UI validation, not
automation of the user's working desktop.

The worker merges by waiting for applicable validation and using its authorized
GitHub identity; it does not enable GitHub's repository auto-merge setting.
Host access must support issue updates, pushes, PRs, checks/log retrieval, comments,
and merge. Missing permissions are blockers. Merges to `main` trigger the existing
release workflow; no protection, review, release, or scheduling settings change.

## Local Dispatcher and Developer

[⏩ Dispatcher](.github/agents/automation-dispatcher.agent.md) routes bounded
implement, repair, and finalize assignments to the existing **⏩ Epic Developer**.
Only Dispatcher is scheduled; Developer starts inert without an assignment.
Use the [short kickoff](docs/automation-prompts/dispatcher.md).
Coordination, reporting, and trial instructions live in the agent definitions;
see also the [local exception](docs/development-backlog.md#local-dispatcher-exception).
The short kickoff names the target Epic and Developer Automation. Dispatcher
discovers the actual Automation ID; the agent instructions carry the recorded
authorization and execution policy. The first approved target is #191.
No individual readiness labels are required in that explicitly authorized mode.

The repository supplies instructions and a local serialization helper, not
installed Automations or guaranteed desktop tools. Use an updated repository
checkout with both agents. These two agents intentionally omit a `tools`
allowlist to inherit the host's available tools, including Automation discovery,
launch, and cross-session messaging. A read/search/edit/execute-only allowlist
can exclude those app tools; inheriting tools does not grant host permissions
or relax the agents' authorization safeguards.

After updating, select each custom agent in a fresh run and use a read-only
diagnostic prompt to inspect its callable catalog for `list_workflows`,
`run_workflow`, `send_session_message`, and the session inspection/resumption
tools or their supported equivalents. The diagnostic must not acquire gates,
claim tasks, launch workers, send messages, or modify files/GitHub. Names in a
skill or agent document are not callable-tool evidence. If tools remain absent,
compare with Default agent in the same Automation context and report the host
limitation; do not substitute a subagent. Existing sessions/worktrees may retain
the old configuration.

A proposed fifteen-minute schedule still needs a
successful live trial and separate activation approval. Verify independent launch,
message correlation, worker termination, and exact task worktree/branch reuse for
repair/finalize. Never substitute a synchronous subagent.

Compliant Dispatchers on the same PC share the helper's default persistent gate.
Unknown workers, partial launches, stale gates, or missing host capabilities stop
pickup and retain claims for human reconciliation; there is no age-based recovery.
Open PRs, open active/review work, known running workers, and explicit unresolved
Dispatcher claims are checked repository-wide. Closed historical tasks with
verified merged linked PRs and no genuine unfinished work need label-only or
missing historical manual-release cleanup only within the target Epic's direct
native children. Out-of-Epic historical records alone do not block and remain
unchanged; missing historical session discovery alone is not a live-worker
claim. Verify membership/delivery before excluding them; unknown/unmerged
disposition and real unresolved claims still block. Within-Epic cleanup is not
automatic ownership release. See the local exception's full capacity contract.
Task issues contain short summaries, collapsed detailed diagnostics, and separate
structured handoff state. Epic outcomes remain brief, linked to task reports.
The original Timeline human-invoked kickoff remains available and is not an
unattended Dispatcher description.

Run the deterministic gate regression checks without starting real agents:

```powershell
.\tests\DispatcherGate.Tests.ps1
```

## Architecture discussions with Architect

For issue intake, Epic/task templates, and the label/ownership contract for
future scheduled work, see [Development backlog](docs/development-backlog.md).
Intake is not execution approval. Publishing a PR ends `active` implementation
but retains claimed work in `status:review` until verified delivery or recovery.

The repository's `.github/agents/architect.agent.md` defines **Architect**, a discussion-first partner for architecture decisions and implementation tradeoffs. It is manually selected rather than automatically delegated based on task similarity.

### Selecting Architect

In the GitHub Copilot app, select **Architect** from the agent picker in the prompt box before or during a session, or type `/agent` and choose it. Continue the discussion in the same session to preserve its conversation context.

In Copilot CLI, start an interactive session from this checkout with `copilot --agent architect`, or use `/agent` in an existing interactive session to select it. Use the filename stem, `architect`, for the command-line flag.

The definition must be present in the checkout used by the session. After adding it or pulling the change, reopen the agent picker; if it is not discovered, start a new session from the updated checkout. An existing worktree does not automatically receive files merged into another checkout. Agent availability and GitHub write operations also depend on the host's supported features, permissions, and authentication.

Typing "Architect, what do you think about...?" alone does not select or switch agents. After selecting Architect, that phrasing is simply a conversational cue. Asking a different active agent to delegate a question to Architect instead creates a separate subagent interaction; it does not switch the main chat's active agent. Do not assume separate invocations share context: provide the prior decisions, issue, and any authorization explicitly, or use the active Architect session for ongoing discussion.

The profile grants repository read/search, edit, and command-execution tools for its full workflow. Its discussion-first and confirmation gates are behavioral instructions, not a read-only security sandbox. Normal host permissions still apply. A host without issue, push, PR, or comment permissions cannot complete delivery; Architect must disclose the limitation rather than claim success.

### Deferred ideas and the recording exception

Keep confirmed abandoned ideas in [the deferred-ideas backlog](docs/deferred-ideas.md). Confirmation to record a specific decision authorizes a simple task and documentation PR without another implementation approval, not feature implementation. See [Architect's instructions](.github/agents/architect.agent.md#deferred-and-rejected-ideas) for the workflow and safeguards.

### Example conversation and delivery

After selecting Architect:

> **User:** Architect, what do you think about separating snapshot persistence from the window?
>
> **Architect:** Inspects the relevant code, explains alternatives and tradeoffs, and asks about requirements that materially affect the design. No files are changed and no issue is created yet.
>
> **User:** I agree with that scope. Capture it in an issue.
>
> **Architect:** Creates the agreed GitHub issue and shares its link. Implementation has not started.
>
> **User:** Implement this issue.
>
> **Architect:** Checks all current open PRs, including drafts, and all other open issues labeled `active` against the planned changes, with complete pagination. Reads active issues' scope and relevant discussion to assess concurrent work even when no PR exists. With no potential conflicts, proceeds without redundant confirmation. If there is a potential conflict, explains the affected issues, PRs, and components and waits for an additional explicit confirmation. An incomplete or failed assessment, including insufficient information in an active issue, also requires confirmation.
>
> **User, only if another confirmation is needed:** Proceed despite the conflicts you identified.
>
> **Architect:** Adds the repository's existing `active` label (Active) to the issue and verifies it. Immediately pushes the session branch and opens a draft PR with `WIP` in the title and `Closes #<issue-number>` in the description, then verifies the draft and closing issue reference before implementation edits. Implements the agreed scope, validates it, commits and pushes the final changes, updates the same PR, removes `WIP`, and marks it ready for review. Once the final remote branch, ready PR, title, and closing issue reference are verified, adds `status:review`, removes `active`, and verifies both changes without waiting for merge or issue closure. Review retains the work-in-progress slot for future scheduled pickup. It does not merge the PR.
>
> **Architect:** Shares the PR link and discusses **Unclear or underspecified requirements** and **Suggested additions** here in the interactive session. Asks one focused question at a time and waits for the user's answers rather than ending with a PR comment.
>
> **User:** Discusses an ambiguity or a suggested addition, or indicates that no further discussion is needed.
>
> **Architect:** Continues the discussion, then records its outcome in a supplementary retrospective PR comment. Optional additions remain proposals unless separately requested.

Interactive discussion is the primary intent: Architect preserves the interactive nature of the session through the retrospective. A PR comment is a record of that conversation, not its replacement. In a non-interactive run, Architect instead posts the retrospective directly on the PR and summarizes it in the final output without waiting for unavailable input.

The Active label tracks authorized implementation, not discussion or review. It is not applied during issue creation or while awaiting implementation authorization or conflict confirmation. Label changes preserve unrelated labels and reuse the existing lowercase `active` label. If PR publication or verification is blocked, the label remains; any label operation or verification failure must be reported explicitly.

The WIP draft PR makes authorized work visible before implementation edits, not before authorization or conflict checks. If the branch has no commits ahead of its target, Architect uses an empty bootstrap commit to open the draft without including unrelated changes. An existing PR for the same implementation is reused as a WIP draft rather than duplicated. A blocked draft creation or verification stops implementation; incomplete delivery keeps or restores the PR as a WIP draft where possible. The closing reference remains in the description so merging the ready PR closes the agreed issue.

The conflict assessment excludes the current implementation issue and distinguishes its own PR from competing work. It considers affected components, shared contracts, dependencies, intended behavior, and structural changes, not just filenames. Having no open PRs does not bypass the active-issue check.

Material uncertainties must be clarified during the work, not left only for the final retrospective. If no ambiguities or useful additions were found, Architect says so explicitly rather than inventing discussion points.

The selection syntax and profile fields follow GitHub's [app customization guide](https://docs.github.com/en/copilot/how-tos/github-copilot-app/customize-github-copilot-app#using-custom-agents) and [custom-agent configuration reference](https://docs.github.com/en/copilot/reference/custom-agents-configuration). CLI invocation can also be checked with `copilot --help` and `copilot help commands`. Local smoke checks do not establish picker discovery or write permissions in every host; verify those in the intended session.
